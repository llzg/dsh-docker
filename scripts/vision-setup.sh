#!/usr/bin/env bash
# vision-setup.sh —— 一键安装本地识图能力（Qwen2.5-VL-3B，CPU 推理）
# 依赖：uv（或 python3.11+）、网络（PyPI + ModelScope）
#
# 用法:
#   bash scripts/vision-setup.sh          # 装到 <repo>/.vision-venv 与 .vision-models/
#   MODEL_ID=Qwen/Qwen2.5-VL-3B-Instruct bash scripts/vision-setup.sh   # 换模型
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.vision-venv"

# uv 缓存放到工作区内（沙箱/只读 HOME 环境下 /root/.cache 可能不可写；
# 注意不能放在 .vision-venv 里，否则 uv 初始化缓存会先建出同名目录导致 venv 失败）
export UV_CACHE_DIR="${UV_CACHE_DIR:-$ROOT/.uv-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$ROOT/.uv-cache/.xdg}"
MODELS_DIR="$ROOT/.vision-models"
# modelscope 的缓存/配置目录放到工作区内（新 SDK：cache=MODELSCOPE_CACHE，
# config=MODELSCOPE_HOME；默认都落在 $HOME 下，沙箱/只读 HOME 环境会失败）
export MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-$MODELS_DIR/.ms-cache}"
export MODELSCOPE_HOME="${MODELSCOPE_HOME:-$MODELS_DIR/.ms-home}"
MODEL_ID="${MODEL_ID:-Qwen/Qwen2.5-VL-3B-Instruct}"
MODEL_DIR="$MODELS_DIR/$(basename "$MODEL_ID")"

echo "==> 1/3 创建 Python 虚拟环境: $VENV"
if [ ! -x "$VENV/bin/python" ]; then
  uv venv "$VENV"
fi

echo "==> 2/3 安装依赖 (torch / transformers / accelerate / pillow / modelscope)"
uv pip install --python "$VENV/bin/python" \
  torch transformers accelerate pillow safetensors modelscope

echo "==> 3/3 从 ModelScope 下载模型: $MODEL_ID"
mkdir -p "$MODELS_DIR"
if [ ! -d "$MODEL_DIR" ]; then
  "$VENV/bin/modelscope" download --model "$MODEL_ID" \
    --local_dir "$MODEL_DIR"
else
  echo "    模型已存在，跳过下载: $MODEL_DIR"
fi

# ── 4/4 (可选但推荐) GGUF 加速后端：llama.cpp + Q4_K_M 量化 ──────────────
# 权重 12GB fp32 → 1.9GB Q4，生成快 3-5 倍、内存低 6 倍。失败不影响
# transformers 后端（see.sh 自动回退）。
LLAMA_DIR="$ROOT/.llama.cpp"
GGUF_DIR="$MODELS_DIR/$(basename "$MODEL_ID")-GGUF"
if [ -x "$LLAMA_DIR/build/bin/llama-cli" ] && [ -f "$GGUF_DIR/qwen25vl-3b-q4_k_m.gguf" ]; then
  echo "==> 4/4 GGUF 后端已存在，跳过构建"
else
  echo "==> 4/4 构建 GGUF 加速后端（llama.cpp Q4_K_M，约 10-20 分钟）"
  if [ ! -d "$LLAMA_DIR" ]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  fi
  uv pip install --python "$VENV/bin/python" cmake ninja gguf
  cd "$LLAMA_DIR"
  # CPU 版（始终构建，兜底）
  "$VENV/bin/cmake" -B build -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release
  "$VENV/bin/cmake" --build build -j"$(nproc)" --target llama-cli llama-quantize
  mkdir -p "$GGUF_DIR"
  "$VENV/bin/python" convert_hf_to_gguf.py "$MODEL_DIR" \
    --outfile "$GGUF_DIR/qwen25vl-3b-f16.gguf" --outtype f16
  "$VENV/bin/python" convert_hf_to_gguf.py "$MODEL_DIR" \
    --outfile "$GGUF_DIR/mmproj-qwen25vl-3b-f16.gguf" --outtype f16 --mmproj
  build/bin/llama-quantize "$GGUF_DIR/qwen25vl-3b-f16.gguf" \
    "$GGUF_DIR/qwen25vl-3b-q4_k_m.gguf" Q4_K_M
  # mmproj 转 F32：无 AVX512 的 CPU 上视觉编码 f32 比 f16 快（实测 ~20%）
  build/bin/llama-quantize "$GGUF_DIR/mmproj-qwen25vl-3b-f16.gguf" \
    "$GGUF_DIR/mmproj-qwen25vl-3b-f32.gguf" F32
  rm -f "$GGUF_DIR/qwen25vl-3b-f16.gguf" "$GGUF_DIR/mmproj-qwen25vl-3b-f16.gguf"
  cd "$ROOT"
fi

# Vulkan 版（核显加速视觉编码）：独立于上面的缓存判断，缺了就补编
if [ ! -x "$LLAMA_DIR/build-vulkan/bin/llama-cli" ]; then
  echo "==> 4b 构建 Vulkan 版 llama-cli（核显加速，需 glslc + vulkan 头文件）"
  # 容器若未预装 Vulkan 工具链（镜像未更新时），自己补装；失败不阻塞，回退 CPU
  if ! command -v glslc >/dev/null 2>&1; then
    echo "    安装 Vulkan 工具链（apt）..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq --no-install-recommends \
      libvulkan-dev libvulkan1 mesa-vulkan-drivers glslc glslang-tools spirv-tools spirv-headers \
      >/dev/null 2>&1 || echo "    apt 安装失败，跳过 Vulkan（回退 CPU 版）"
  fi
  if command -v glslc >/dev/null 2>&1; then
    # Debian 自带 Vulkan 头文件偏旧（llama.cpp 新版需要 VK_EXT_layer_settings 等），
    # 统一用 GitHub 最新头文件构建，避免头文件版本不匹配。
    if [ ! -d "$LLAMA_DIR/.vulkan-headers" ]; then
      git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers "$LLAMA_DIR/.vulkan-headers"
    fi
    cd "$LLAMA_DIR"
    "$VENV/bin/cmake" -B build-vulkan -DGGML_NATIVE=ON -DGGML_VULKAN=ON \
      -DVulkan_INCLUDE_DIRS="$LLAMA_DIR/.vulkan-headers/include" -DCMAKE_BUILD_TYPE=Release
    "$VENV/bin/cmake" --build build-vulkan -j"$(nproc)" --target llama-cli || \
      echo "    Vulkan 编译失败，将使用 CPU 版（不影响功能）"
    cd "$ROOT"
  else
    echo "    Vulkan 依赖缺失（glslc），跳过；装依赖后重跑本脚本即可"
  fi
fi

echo
echo "安装完成。用法:"
echo "  scripts/see.sh <图片路径> \"描述这张图片\""
echo "  scripts/see.sh <图片路径> --question \"图里写了什么文字？\""
