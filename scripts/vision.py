#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地识图脚本：Qwen2.5-VL-3B，双后端。

- GGUF 后端（默认，快）：llama.cpp + Q4_K_M 量化模型，纯 CPU。
  model 目录里放 *.gguf（主模型 + mmproj-*.gguf）即自动走此路径。
- transformers 后端（兜底）：原 torch fp32 推理，model 目录为 HF 格式时使用。

用法:
  vision.py <图片路径> [更多图片...] [--question "想问什么"] [--max-tokens 512]
  vision.py --question "把图里的文字念出来" photo.png

不带 --question 时默认让模型详细描述图片内容。
输出：模型回答打印到 stdout（进度日志走 stderr，不干扰管道）。
"""
import argparse
import glob
import os
import subprocess
import sys
import time


def run_llama_backend(model_dir: str, args: argparse.Namespace) -> int:
    """llama.cpp 后端：调用 llama-cli 跑 Qwen2.5-VL（GGUF + mmproj）。"""
    ggufs = sorted(glob.glob(os.path.join(model_dir, "*.gguf")))
    if not ggufs:
        print("error: GGUF backend: no *.gguf found in model dir", file=sys.stderr)
        return 2
    main = None
    mmproj = None
    for f in ggufs:
        base = os.path.basename(f)
        if base.startswith("mmproj"):
            # 同目录可能同时有 f16/f32 两个 mmproj；AVX2 CPU 上 f32 视觉编码更快
            if mmproj is None or "f32" in base:
                mmproj = f
        elif main is None or "q4" in base or "q5" in base or "q8" in base:
            # 优先量化文件；否则用第一个非 mmproj 的 gguf
            if main is None or ("q4" in base or "q5" in base or "q8" in base):
                main = f
    if main is None:
        print("error: GGUF backend: no main model gguf found", file=sys.stderr)
        return 2
    if mmproj is None:
        print("error: GGUF backend: no mmproj-*.gguf found (vision projector needed)",
              file=sys.stderr)
        return 2

    # llama-cli 选择：优先 Vulkan 版（核显加速视觉编码，需要 /dev/dri 直通）。
    # VISION_GPU=1 强制 GPU 版 / 0 强制 CPU 版 / auto（默认）自动检测。
    repo = os.path.join(os.path.dirname(__file__), "..")
    cpu_cli = os.path.join(repo, ".llama.cpp", "build", "bin", "llama-cli")
    vk_cli = os.path.join(repo, ".llama.cpp", "build-vulkan", "bin", "llama-cli")
    use_gpu = os.environ.get("VISION_GPU", "auto")
    gpu_ok = os.path.isdir("/dev/dri") and os.path.isfile(vk_cli)
    if use_gpu == "1":
        llama_cli, offload = vk_cli, gpu_ok
    elif use_gpu == "0":
        llama_cli, offload = cpu_cli, False
    else:  # auto
        llama_cli, offload = (vk_cli, True) if gpu_ok else (cpu_cli, False)
    llama_cli = os.environ.get("LLAMA_CLI", llama_cli)
    if not os.path.isfile(llama_cli):
        print(f"error: llama-cli not found at {llama_cli} (set LLAMA_CLI)", file=sys.stderr)
        return 2

    # Qwen 官方处理器对大图有 ~1M 像素上限；llama.cpp 不限，超大会产生数倍
    # 视觉 token 导致 prompt 阶段极慢甚至像卡死。先统一缩到上限以内
    # （可用 VISION_MAX_PIXELS 调小换取速度，调大保留细节）。
    from PIL import Image
    import tempfile
    max_pixels = int(os.environ.get("VISION_MAX_PIXELS", "700000"))  # 默认 700k（~836×836）；可调大保留细节
    tmpdir = tempfile.TemporaryDirectory(prefix="vision-")
    image_paths = []
    try:
        for i, p in enumerate(args.images):
            im = Image.open(p)
            w, h = im.size
            if w * h > max_pixels:
                scale = (max_pixels / (w * h)) ** 0.5
                im = im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
            out = os.path.join(tmpdir.name, f"img{i}.jpg")
            im.convert("RGB").save(out, quality=90)
            image_paths.append(out)

        threads = os.environ.get("VISION_THREADS", str(os.cpu_count() or 8))
        cmd = [
            llama_cli, "-m", main, "--mmproj", mmproj,
            "--image", ",".join(image_paths),
            "-p", args.question,
            "-n", str(args.max_tokens),
            "-no-cnv", "-st",          # -st 必需：否则 -p 用完一次后进入交互循环
            "--no-display-prompt", "--simple-io",
            "--no-warmup",
            "--temp", "0",             # 贪心解码，防止长文重复（对齐旧后端 do_sample=False）
            "-t", threads,
        ]
        if offload:
            cmd += ["--mmproj-offload"]  # 视觉编码（ViT）放核显，主模型仍走 CPU

        t0 = time.time()
        print(f"[vision] llama.cpp: {os.path.basename(main)} + {os.path.basename(mmproj)}", file=sys.stderr)
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        print("error: llama-cli timed out", file=sys.stderr)
        return 1
    finally:
        tmpdir.cleanup()
    if proc.returncode != 0:
        print(f"error: llama-cli exit {proc.returncode}", file=sys.stderr)
        sys.stderr.write(proc.stderr[-4000:])
        return 1

    # stdout = banner + "> 问题" 回显 + 回答 + 计时 + Exiting...
    # 取最后一个 "> " 之后的内容作为回答，再去掉计时/退出等杂行
    answer = proc.stdout
    marker = "\n> "
    idx = answer.rfind(marker)
    if idx != -1:
        answer = answer[idx + len(marker):]
    clean = []
    for line in answer.splitlines():
        s = line.strip()
        if (s.startswith("[ Prompt:") or s.startswith("[End thinking]")
                or s == "Exiting..." or s == ">"):
            continue
        clean.append(line)
    answer = "\n".join(clean).strip()

    print(f"[vision] inference took {time.time() - t0:.1f}s", file=sys.stderr)
    if answer:
        print(answer)
    else:
        # 兜底：stdout 为空时给出 stderr 尾部，便于排查
        print("(no output; see stderr)", file=sys.stderr)
        sys.stderr.write(proc.stderr[-2000:])
        return 1
    return 0


def run_transformers_backend(model_dir: str, args: argparse.Namespace) -> int:
    """transformers 后端（torch fp32 CPU），作为无 GGUF 时的兜底。"""
    import torch
    from PIL import Image
    from transformers import AutoProcessor, Qwen2_5_VLForConditionalGeneration

    t0 = time.time()
    print(f"[vision] loading transformers model from {model_dir} ...", file=sys.stderr)
    processor = AutoProcessor.from_pretrained(model_dir)
    model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
        model_dir,
        torch_dtype=torch.float32,
        low_cpu_mem_usage=True,
    )
    model.eval()
    print(f"[vision] model loaded in {time.time() - t0:.1f}s", file=sys.stderr)

    images = [Image.open(p).convert("RGB") for p in args.images]
    messages = [{
        "role": "user",
        "content": [
            {"type": "image", "image": img} for img in images
        ] + [{"type": "text", "text": args.question}],
    }]
    text = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = processor(text=[text], images=images, return_tensors="pt")
    # 像素值对齐模型 dtype（CPU 上模型以 float32 运行）；image_grid_thw 等
    # 索引张量必须保持 long，不能转换
    if "pixel_values" in inputs:
        inputs["pixel_values"] = inputs["pixel_values"].to(torch.float32)

    t1 = time.time()
    print(f"[vision] generating (max {args.max_tokens} tokens) ...", file=sys.stderr)
    with torch.no_grad():
        out = model.generate(
            **inputs,
            max_new_tokens=args.max_tokens,
            do_sample=False,
        )
    answer = processor.decode(out[0][inputs["input_ids"].shape[1]:],
                              skip_special_tokens=True)
    print(f"[vision] inference took {time.time() - t1:.1f}s", file=sys.stderr)
    print(answer.strip())
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Local image understanding (Qwen2.5-VL, CPU)")
    ap.add_argument("images", nargs="+", help="image file path(s)")
    ap.add_argument("--question", default="请详细描述这张图片里的内容。",
                    help="question/instruction about the image(s)")
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--model-dir", default=None,
                    help="model directory (default: env VISION_MODEL_DIR)")
    args = ap.parse_args()

    model_dir = args.model_dir or os.environ.get("VISION_MODEL_DIR")
    if not model_dir:
        print("error: --model-dir or env VISION_MODEL_DIR required", file=sys.stderr)
        return 2

    ggufs = sorted(glob.glob(os.path.join(model_dir, "*.gguf")))
    if ggufs:
        return run_llama_backend(model_dir, args)
    return run_transformers_backend(model_dir, args)


if __name__ == "__main__":
    sys.exit(main())
