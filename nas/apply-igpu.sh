#!/bin/sh
# apply-igpu.sh —— NAS 宿主侧启用核显加速（Intel 核显直通 + Vulkan 版 llama-cli）
#
# 必须在 NAS 宿主上执行（SSH 进 NAS 后运行）：
#   sudo sh /volume1/docker/dsh-deploy/apply-igpu.sh                 # 默认通道
#   DSH_CHANNEL=rc sudo sh /volume1/docker/dsh-deploy/apply-igpu.sh  # 指定通道
#
# 设计（契约 §9 / defect 8）：base compose **不再硬要求** /dev/dri，
# 本脚本生成独立 override 文件 docker-compose.igpu.yml，由 compose_cmd() 自动追加：
#   docker compose -p <project> --project-directory <dir> \
#     -f <dir>/docker-compose.yml -f <dir>/docker-compose.igpu.yml ...
# 无核显宿主 / 不需要核显时：rm <dir>/docker-compose.igpu.yml 即回退。
#
# 幂等：重复执行安全（override 覆盖写，容器重建）。
set -eu

SRC=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$SRC/lib.sh"

DEV=/dev/dri

if [ "$#" -gt 0 ]; then
  echo "用法：DSH_CHANNEL=<alpha|rc> [DSH_DEPLOY_DIR=<dir>] sh apply-igpu.sh（不接受位置参数）" >&2
  exit 2
fi

echo "== apply-igpu 通道=$CHANNEL 目录=$DIR 项目=$PROJECT 容器=$CONTAINER =="

igpu_main() {
# 1) 宿主设备检查
if [ ! -e "$DEV" ]; then
  echo "ERROR: 宿主不存在 $DEV（i915 驱动未加载？）。本步骤不需要核显请直接忽略，" >&2
  echo "       base compose 已不再硬依赖 $DEV，容器可正常启动。" >&2
  exit 1
fi

# 2) 生成 override（不修改 base compose；历史缺陷：直接 sed/python 改 base compose）
OVERRIDE=$(igpu_override_write "$DEV")
echo "==> 1/4 已生成 override: $OVERRIDE"

# 3) 校验 compose 上下文（override 合并后 project name / 卷源仍必须匹配）
echo "==> 2/4 校验 compose 上下文"
_errs=$(validate_compose_context) || true
if [ -n "$_errs" ]; then
  echo "ERROR: compose 上下文校验失败，已保留 override 待人工检查：" >&2
  printf '%s\n' "$_errs" >&2
  exit 1
fi
echo "    PASS（project=$PROJECT，卷源均在 $DIR 下）"

# 4) 重建容器使直通生效
echo "==> 3/4 重建容器使直通生效（$CONTAINER 重启约 1 分钟）"
if ! compose_up_wait; then
  echo "ERROR: 容器未就绪；可执行 rm $OVERRIDE 后重新 compose_cmd up 回退" >&2
  exit 1
fi

_i=0
while [ "$_i" -lt 30 ]; do
  if docker exec "$CONTAINER" test -e "$DEV" 2>/dev/null; then
    echo "    $DEV 直通成功"
    break
  fi
  _i=$((_i + 1))
  if [ "$_i" -ge 30 ]; then
    echo "警告：容器起来了但 $DEV 未出现（检查宿主 i915 驱动）" >&2
  else
    sleep 3
  fi
done

# 5) 容器内补编译 Vulkan 版 llama-cli
echo "==> 4/4 容器内补编译 Vulkan 版 llama-cli（无则自动装依赖，约 5-10 分钟）"
docker exec "$CONTAINER" bash /root/nas_docker/scripts/vision-setup.sh || \
  echo "警告：vision-setup.sh 执行有告警，见上方输出" >&2

echo
echo "完成。验证："
echo "  docker exec $CONTAINER ls $DEV              # 应看到 card0 renderD128"
echo "  docker exec $CONTAINER bash /root/nas_docker/scripts/see.sh <图片> --question 描述"
echo "  # see.sh 日志出现 --mmproj-offload 即核显已接管视觉编码"
}

# 写操作（override 生成 + 容器重建）加 flock（$STATE/deploy.lock，契约 §9）
with_lock igpu_main
