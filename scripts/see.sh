#!/usr/bin/env bash
# see.sh —— 图片处理统一入口（无 GPU 稳定优先：默认纯 CPU OCR）
#
# 用法:
#   scripts/see.sh "图片路径" --question "问题"        # 默认只跑 OCR（秒级）
#
# 参数:
#   --mode ocr|vision           默认 ocr；vision 需显式指定才调用 Qwen2.5-VL
#   --force-vision              等价于 --mode vision（显式才允许视觉模型）
#   --timeout N                 视觉推理超时（秒，默认 600；失败不重试）
#   --max-edge N                输入视觉模型前的最长边上限（默认 1024）
#   --json                      输出机器可读 JSON
#   --max-tokens N              视觉模型输出上限（透传）
#   （注：--mode auto 已弃用，接受但按 OCR 处理，绝不自动调用视觉模型）
#
# 环境变量:
#   VISION_VENV    venv 目录（默认 <repo>/.vision-venv）
#   VISION_MODEL   模型目录（默认优先 GGUF 量化版，其次 transformers 原版）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${VISION_VENV:-$ROOT/.vision-venv}"
GGUF_MODEL="${VISION_GGUF_MODEL:-$ROOT/.vision-models/Qwen2.5-VL-3B-Instruct-GGUF}"
HF_MODEL="${VISION_HF_MODEL:-$ROOT/.vision-models/Qwen2.5-VL-3B-Instruct}"
if [ -n "${VISION_MODEL:-}" ]; then
  MODEL="$VISION_MODEL"
elif [ -d "$GGUF_MODEL" ]; then
  MODEL="$GGUF_MODEL"     # llama.cpp Q4 量化版（快）
else
  MODEL="$HF_MODEL"       # transformers fp32 兜底
fi
PY="$VENV/bin/python"

if [ ! -x "$PY" ]; then
  echo "see.sh: venv 不存在: $VENV（先运行 scripts/vision-setup.sh）" >&2
  exit 1
fi
if [ ! -d "$MODEL" ]; then
  echo "see.sh: 模型不存在: $MODEL（先运行 scripts/vision-setup.sh）" >&2
  exit 1
fi

# 全程保持 VISION_GPU=0（Intel Vulkan GPU 路径已知会输出乱码）
export VISION_GPU=0

# 全局视觉锁快速拒绝：--mode vision / --force-vision 且锁被占用时立即退出，
# 不排队、不后台等待、不重试（真正持有锁的是 vision.py，此处仅探测）。
if printf '%s ' "$@" | grep -qE -- "(--force-vision|--mode[ =]vision)"; then
  if ! (exec 9>>/tmp/deepseek-harness-vision.lock 2>/dev/null && flock -n 9 2>/dev/null); then
    echo "已有视觉任务运行，拒绝启动新任务" >&2
    exit 1
  fi
fi

exec "$PY" "$ROOT/scripts/see-router.py" --model-dir "$MODEL" "$@"
