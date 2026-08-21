#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
see.sh 简化版图片处理流程（无 GPU 环境稳定优先）：

- 默认只跑 CPU OCR（RapidOCR + ONNX Runtime），OCR 超时 60s；
- 只有显式 --mode vision / --force-vision 才调用 Qwen2.5-VL（超时 600s，失败不重试）；
- 不再自动调用视觉模型（无 auto 回退）；
- 视觉输入图片最长边缩放到 1024；
- 视觉任务天然串行（单进程），并发数恒为 1；
- SHA-256 缓存（.vision-cache/），原子写入。

用法（由 see.sh 转发）:
  see.sh IMAGE --question "..." [--mode ocr|vision] [--force-vision]
              [--timeout 600] [--max-edge 1024] [--json] [--max-tokens N]
"""
import argparse
import fcntl
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(ROOT, ".vision-cache")
OCR_TIMEOUT = 60       # OCR 硬超时（秒）
VISION_TIMEOUT = 600   # 视觉推理超时（秒）

# 全局视觉任务锁（与 vision.py / see.sh 共用同一路径）
VISION_LOCK_PATH = "/tmp/deepseek-harness-vision.lock"
LOCK_BUSY_MSG = "已有视觉任务运行，拒绝启动新任务"


class LockBusyError(RuntimeError):
    pass

MAGIC = [
    (b"\x89PNG\r\n\x1a\n", "png"),
    (b"\xff\xd8\xff", "jpg"),
    (b"GIF87a", "gif"),
    (b"GIF89a", "gif"),
    (b"BM", "bmp"),
    (b"II*\x00", "tif"),
    (b"MM\x00*", "tif"),
]
WEBP_SIG = b"RIFF"


def log(stage, msg):
    print(f"[router] {stage}: {msg}", file=sys.stderr, flush=True)


def detect_image_type(path):
    with open(path, "rb") as f:
        head = f.read(16)
    for sig, ext in MAGIC:
        if head.startswith(sig):
            return ext, ext
    if head.startswith(WEBP_SIG) and head[8:12] == b"WEBP":
        return "webp", "webp"
    return None, None


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cache_path(image_hash, mode, question, max_edge, max_tokens):
    key = "|".join([image_hash, mode, question, str(max_edge), str(max_tokens)])
    k = hashlib.sha256(key.encode()).hexdigest()[:16]
    return os.path.join(CACHE_DIR, f"{image_hash[:16]}.{mode}.{k}.json")


def atomic_write(path, data):
    fd, tmp = tempfile.mkstemp(dir=CACHE_DIR, prefix=".tmp-cache-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def run_ocr(img_path, py):
    """OCR 子进程，60s 硬超时（超时即杀，不重试）。"""
    worker = os.path.join(ROOT, "scripts", "ocr_worker.py")
    proc = subprocess.run([py, worker, img_path], capture_output=True,
                          text=True, timeout=OCR_TIMEOUT)
    if proc.returncode != 0:
        raise RuntimeError(f"OCR 失败（exit {proc.returncode}）: {proc.stderr[-300:]}")
    return json.loads(proc.stdout)


def run_vision(py, model_dir, images, question, max_tokens, timeout):
    """视觉模型调用：单次执行，失败/超时直接报错，不重试。
    vision.py 内部持有全局锁（单实例）；此处仅做快速拒绝探测 + 独立进程组清理。"""
    env = dict(os.environ)
    env["VISION_GPU"] = "0"
    cmd = [py, os.path.join(ROOT, "scripts", "vision.py"),
           "--model-dir", model_dir, "--question", question,
           "--max-tokens", str(max_tokens)] + images
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=env, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            out, err = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            out, err = proc.communicate()  # 回收，避免僵尸/孤儿
        raise TimeoutError(f"视觉推理超过 {timeout}s，进程组已清理（不重试）") from None
    if proc.returncode != 0 or not out.strip():
        if proc.returncode == 3:  # vision.py 的全局锁拒绝码
            raise LockBusyError(LOCK_BUSY_MSG)
        raise RuntimeError(f"视觉推理失败（exit {proc.returncode}，不重试）: "
                           f"{err[-400:]}")
    return out.strip()


def vision_lock_busy():
    """非阻塞探测全局视觉锁（探测即释放；真正持有由 vision.py 负责）。"""
    try:
        fd = os.open(VISION_LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    finally:
        os.close(fd)
    return False


def scale_image(src, dst, max_edge):
    """长边缩放到 max_edge（保宽高比），返回是否缩放。"""
    from PIL import Image
    with Image.open(src) as im:
        w, h = im.size
        if max(w, h) <= max_edge:
            return False, src
        scale = max_edge / max(w, h)
        im.convert("RGB").resize(
            (max(1, int(w * scale)), max(1, int(h * scale))),
            Image.LANCZOS).save(dst)
        return True, dst


def print_ocr_text(items, avg_conf):
    print(f"（OCR 识别 {len(items)} 行，平均置信度 {avg_conf:.2f}）")
    for i, it in enumerate(items, 1):
        box = ",".join(map(str, it["box"]))
        print(f"[{i}] conf={it['conf']:.2f} box=[{box}] {it['text']}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="see.sh 图片处理（默认纯 OCR；视觉模型仅显式 --mode vision 触发）")
    ap.add_argument("images", nargs="+", help="image file path(s)")
    ap.add_argument("--question", default="请把图片里的文字念出来。")
    ap.add_argument("--mode", choices=["ocr", "vision", "auto"], default="ocr")
    ap.add_argument("--force-vision", action="store_true",
                    help="等价于 --mode vision，强制走视觉模型")
    ap.add_argument("--timeout", type=int, default=VISION_TIMEOUT,
                    help="视觉推理超时秒数（默认 600）")
    ap.add_argument("--max-edge", type=int, default=1024,
                    help="输入视觉模型前的最长边上限（默认 1024）")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--model-dir", default=None)
    args = ap.parse_args()

    if args.force_vision:
        args.mode = "vision"
    if args.mode == "auto":  # 兼容旧参数：不再自动调用视觉，按 OCR 处理
        log("模式", "--mode auto 已弃用：不再自动调用视觉模型，本次按 OCR 执行")
        args.mode = "ocr"
    if not args.model_dir:
        print("error: --model-dir 必填（由 see.sh 传入）", file=sys.stderr)
        return 2

    py = os.path.join(os.path.dirname(sys.executable), "python")
    t0 = time.time()
    img = args.images[0]
    result = {"mode": args.mode, "cache_hit": False}

    # 1) 文件检查 + 真实类型嗅探（不依赖扩展名）
    if not os.path.isfile(img):
        print(f"error: 文件不存在: {img}", file=sys.stderr)
        return 1
    kind, ext = detect_image_type(img)
    if kind is None:
        print(f"error: 不是支持的图片格式（魔数识别失败）: {img}", file=sys.stderr)
        return 1
    log("文件检查", f"{img} → 真实类型 {kind}")

    image_hash = sha256_file(img)
    cp = cache_path(image_hash, args.mode, args.question, args.max_edge,
                    args.max_tokens)
    if os.path.isfile(cp):
        try:
            with open(cp, encoding="utf-8") as f:
                cached = json.load(f)
            result.update({"cache_hit": True})
            log("缓存", "命中，直接输出（未推理）")
            if args.json:
                result["elapsed"] = round(time.time() - t0, 2)
                result["payload"] = cached["payload"]
                print(json.dumps(result, ensure_ascii=False))
            else:
                if args.mode == "ocr":
                    print_ocr_text(cached["payload"]["items"],
                                   cached["payload"]["avg_conf"])
                else:
                    print(cached["payload"]["answer"])
            log("总耗时", f"{time.time() - t0:.2f}s")
            return 0
        except (OSError, ValueError, KeyError):
            log("缓存", "损坏或不可读，忽略并重新处理")

    tmpdir = tempfile.mkdtemp(prefix="see-router-")
    try:
        if args.mode == "vision":
            # 全局锁快速拒绝：已占用则不启动任何视觉子进程（不排队/不重试）
            if vision_lock_busy():
                print(LOCK_BUSY_MSG, file=sys.stderr)
                return 1
            # 视觉路径：每张图先缩放到最长边 max_edge，再交给 vision.py
            prepared = []
            for i, p in enumerate(args.images):
                dst = os.path.join(tmpdir, f"vis{i}.{ext if i == 0 else 'png'}")
                scaled, used = scale_image(p, dst, args.max_edge)
                if scaled:
                    log("预处理", f"第{i + 1}张图长边超限 → 缩放到 ≤{args.max_edge}")
                prepared.append(used)
            t1 = time.time()
            log("视觉", f"调用 Qwen2.5-VL（超时 {args.timeout}s，不重试）…")
            try:
                answer = run_vision(py, args.model_dir, prepared, args.question,
                                    args.max_tokens, args.timeout)
            except LockBusyError as e:
                print(str(e), file=sys.stderr)
                return 1
            except (TimeoutError, RuntimeError) as e:
                print(f"error: {e}", file=sys.stderr)
                return 1
            log("视觉", f"完成，耗时 {time.time() - t1:.1f}s")
            payload = {"answer": answer}
        else:
            # OCR 路径：修正无扩展名（临时副本，不改原附件），不缩放，立即输出
            processed = img
            if os.path.splitext(img)[1].lower() != f".{ext}" or kind in ("webp", "gif"):
                from PIL import Image
                out = os.path.join(tmpdir, f"input.{ext}")
                with Image.open(img) as im:
                    im.convert("RGB").save(out)
                processed = out
                log("预处理", f"无扩展名/特殊格式 → 临时副本 {os.path.basename(out)}")
            t1 = time.time()
            log("OCR", f"开始（超时 {OCR_TIMEOUT}s）…")
            payload = run_ocr(processed, py)
            log("OCR", f"完成：{len(payload['items'])} 行，平均置信度 "
                       f"{payload['avg_conf']:.2f}，耗时 {time.time() - t1:.1f}s")

        os.makedirs(CACHE_DIR, exist_ok=True)
        atomic_write(cp, {"payload": payload})

        if args.json:
            result["elapsed"] = round(time.time() - t0, 2)
            result["payload"] = payload
            print(json.dumps(result, ensure_ascii=False))
        else:
            if args.mode == "ocr":
                print_ocr_text(payload["items"], payload["avg_conf"])
            else:
                print(payload["answer"])
        log("总耗时", f"{time.time() - t0:.2f}s")
        return 0
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
