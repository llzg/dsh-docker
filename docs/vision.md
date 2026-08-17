# 本地识图能力（Qwen2.5-VL，纯 CPU）

dsh 智能体/命令行自带的"看图"工具：本地运行 **Qwen2.5-VL-3B-Instruct**，
不需要外网 API，不依赖 GPU（本机 12 核 i5 + 40GB 内存即可流畅运行）。

## 组件来源（不自己造轮子）

| 组件 | 来源 | 说明 |
|---|---|---|
| 模型 | [QwenLM/Qwen2.5-VL](https://github.com/QwenLM/Qwen2.5-VL)（GitHub） | 3B 视觉语言模型，中文/英文识别与描述、OCR 都支持 |
| 推理框架 | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)（GitHub） | **默认后端**：Q4_K_M 量化，快、内存低 |
| 推理框架（兜底） | [huggingface/transformers](https://github.com/huggingface/transformers)（GitHub） | 原 fp32 后端，GGUF 缺失时自动回退 |
| 权重下载 | [ModelScope](https://www.modelscope.cn/models/Qwen/Qwen2.5-VL-3B-Instruct) | 国内 CDN，速度快 |

## 安装（一次性）

```sh
bash scripts/vision-setup.sh
```

会自动：
1. 建虚拟环境 `.vision-venv/`，装 torch / transformers / modelscope；
2. 从 ModelScope 下载模型到 `.vision-models/Qwen2.5-VL-3B-Instruct/`（约 7.5GB）；
3. **构建 GGUF 加速后端**：clone llama.cpp → 编译 llama-cli/llama-quantize →
   把下载的权重转成 Q4_K_M GGUF（1.9GB）→ 删掉中间文件。约 10~20 分钟。

`scripts/see.sh` 自动优先用 GGUF 后端；GGUF 缺失时回退 transformers 后端。

## 用法

```sh
# 描述图片
scripts/see.sh 图片.jpg

# 问具体问题 / 指定语言
scripts/see.sh 图片.jpg --question "图里的人在做什么？"
scripts/see.sh 图片.jpg --question "Describe this image in English."

# OCR：把图里的文字念出来
scripts/see.sh 截图.png --question "把图片里的所有文字原样念出来"

# 多图 + 限制输出长度
scripts/see.sh a.jpg b.jpg --question "两张图有什么共同点？" --max-tokens 300
```

输出 = 模型回答（stdout）；加载/耗时日志走 stderr。

调优环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `VISION_MAX_PIXELS` | 700000 | 图片像素上限。实测编码耗时随像素近似线性：1M→73s，700k→55s，500k→42s（本机截图场景）。调小 = 快但截图小字会糊，调大 = 慢但细节多 |
| `VISION_THREADS` | 全部 | 限制 CPU 线程数（如 `6`，降低占用换速度） |
| `VISION_MODEL` | 自动 | 手动指定模型目录 |

## 在聊天对话框里直接粘贴图片

dsh 的输入框原生支持粘贴/拖拽图片（PNG/JPEG/WebP/GIF），但原本有**两道**关卡会挡住图片：

1. `session.prompt` 入口的模型能力闸门（`MODEL_DOES_NOT_SUPPORT_IMAGES`，客户端提示
   "当前模型不支持图片"）——`patch-dsh.sh` 的 **vision-gate** 补丁去掉这道闸门；
2. DeepSeek 适配器是纯文本通道，遇到图片块抛 `UNSUPPORTED_CONTENT`——**vision-materialize**
   补丁把图片块物化成文本：`（用户粘贴了一张图片，已保存到 /data/dsh/attachments/v1/objects/<xx>/<sha256>；请用 scripts/see.sh 查看这张图片）`

补丁后的链路：

- 图片正常显示在对话里（消息保留图片块）；
- 发给模型时图片块变成附件路径文本（附件是内容寻址存储，`attachmentId = sha256:<hash>`，
  路径确定、无需拷贝）；
- 智能体看到路径后直接 `scripts/see.sh` 看图回答，图片不出本机。

> 两个补丁都随镜像构建自动应用（STRICT 校验）；若升级后失效会构建失败并提示更新。

## 性能参考（本机 CPU 实测）

| 项目 | transformers fp32 | llama.cpp Q4_K_M |
|---|---|---|
| 模型内存 | 12GB | **1.9GB** |
| 模型加载 | ~7s | ~3s |
| 小图（照片，<1M 像素）总耗时 | ~80s+ | **~40~60s** |
| 大图（截图 1910×1094）总耗时 | 139s/96 token | **~75s 起 + 0.3~0.6s/token** |
| 生成速度 | ~1~2 token/s | **~9~15 token/s** |

说明：大头是**视觉编码**（ViT 处理整张图，CPU 上固有成本，量化帮不上太多）；
生成阶段（文本输出）量化后快 5~10 倍。大图可调小 `VISION_MAX_PIXELS` 提速。

## Intel 核显加速（Iris Xe，实验性）

视觉编码（ViT 把整张图变 token）是 CPU 上的主要固定成本。Iris Xe 核显正好
是干矩阵乘法的，把**视觉编码**放核显、主模型仍留 CPU（生成是内存带宽瓶颈，
共享带宽下核显无意义）。

**实测结论（2026-08-17，已部署验证）**：

- ✅ `/dev/dri` 直通成功（card0/renderD128），Vulkan 版 llama-cli 编译成功，
  GPU 路径确实接管（推理时 CPU 占用从 ~700s 降到 ~18s）；
- ❌ **但视觉编码输出损坏**（模型输出变乱码）——bookworm 自带的 mesa 22.3.6
  ANV Vulkan 驱动下，Qwen2.5-VL 的 mmproj 在 GPU 上编码结果错误（f16/f32
  mmproj 均复现）。CPU 路径同一张图输出正常。
- 因此 **VISION_GPU 默认关闭（0）**，走 CPU；待升级 mesa（Debian 13/手动装新版）
  或改用 OpenVINO 后，设 `VISION_GPU=1` 再验证。

前置（已写入本仓库）：

1. `nas/docker-compose.yml`：已加 `devices: [/dev/dri:/dev/dri]`；
2. `Dockerfile`：已装 `mesa-vulkan-drivers`（Intel Vulkan ICD）+ glslc 等编译依赖；
3. `scripts/vision-setup.sh`：会额外编译 Vulkan 版 llama-cli（`build-vulkan/`），
   缺依赖自动 apt 补装，编译失败自动跳过，不影响 CPU 版。

**部署（需在 NAS 宿主执行，容器内无 docker 权限）**——一条命令：

```bash
sudo sh /volume1/docker/dsh-deploy/apply-igpu.sh
```

脚本自动：改部署目录 compose（幂等，带备份）→ 校验语法 → `--force-recreate`
重建容器 → 容器内自动补编译 Vulkan 版 llama-cli → 提示验证方法。

运行期自动切换（`scripts/vision.py`）：

| `VISION_GPU` | 行为 |
|---|---|
| `auto`（默认） | `/dev/dri` 存在且 Vulkan 版二进制存在 → 核显；否则 CPU |
| `1` | 强制 Vulkan 版（设备缺失会报错） |
| `0` | 强制 CPU 版 |

验证核显是否生效：容器内 `ls /dev/dri`（应看到 card0/renderD128），
`vulkaninfo --summary` 能看到 Intel 设备；`scripts/see.sh` 日志会显示
`--mmproj-offload`。

> 本容器（未直通 /dev/dri）里无法实测核显速度；真实收益以 NAS 上
> 直通后的同一张图对比为准。

## 说明

- 全部离线推理，图片不会上传到任何服务器。
- 目录 `.vision-venv/` `.vision-models/` `.uv-cache/` `.llama.cpp/` 已加入
  `.gitignore`，不会进版本库；如需在 NAS 上持久化，可把 `scripts/vision-setup.sh`
  的执行并进 Dockerfile（见下）。

### 可选：烤进 NAS 镜像（Dockerfile）

```dockerfile
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
    && git clone --depth 1 https://github.com/ggml-org/llama.cpp /opt/llama.cpp \
    && uv venv /opt/vision-venv \
    && uv pip install --python /opt/vision-venv/bin/python torch transformers accelerate pillow safetensors modelscope cmake ninja gguf \
    && (cd /opt/llama.cpp && /opt/vision-venv/bin/cmake -B build -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release \
         && /opt/vision-venv/bin/cmake --build build -j"$(nproc)" --target llama-cli llama-quantize) \
    && /opt/vision-venv/bin/modelscope download --model Qwen/Qwen2.5-VL-3B-Instruct --local_dir /opt/vision-models/Qwen2.5-VL-3B-Instruct \
    && mkdir -p /opt/vision-models/Qwen2.5-VL-3B-Instruct-GGUF \
    && (cd /opt/llama.cpp \
         && /opt/vision-venv/bin/python convert_hf_to_gguf.py /opt/vision-models/Qwen2.5-VL-3B-Instruct --outfile /opt/vision-models/Qwen2.5-VL-3B-Instruct-GGUF/qwen25vl-3b-f16.gguf --outtype f16 \
         && /opt/vision-venv/bin/python convert_hf_to_gguf.py /opt/vision-models/Qwen2.5-VL-3B-Instruct --outfile /opt/vision-models/Qwen2.5-VL-3B-Instruct-GGUF/mmproj-qwen25vl-3b-f16.gguf --outtype f16 --mmproj \
         && build/bin/llama-quantize /opt/vision-models/Qwen2.5-VL-3B-Instruct-GGUF/qwen25vl-3b-f16.gguf /opt/vision-models/Qwen2.5-VL-3B-Instruct-GGUF/qwen25vl-3b-q4_k_m.gguf Q4_K_M \
         && rm /opt/vision-models/Qwen2.5-VL-3B-Instruct-GGUF/qwen25vl-3b-f16.gguf)
```

镜像会增大约 10GB；构建时间取决于 NAS 到 ModelScope 的带宽与编译耗时。
