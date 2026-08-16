#!/usr/bin/env bash
# see.sh —— 智能体/命令行“看图”工具（本地 Qwen2.5-VL，纯 CPU，无需外网）
#
# 用法:
#   scripts/see.sh <图片1> [图片2 ...] [--question "问题"] [--max-tokens N]
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

exec "$PY" "$ROOT/scripts/vision.py" --model-dir "$MODEL" "$@"
