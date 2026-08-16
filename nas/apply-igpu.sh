#!/bin/bash
# apply-igpu.sh —— NAS 宿主侧一键启用核显加速（/dev/dri 直通 + Vulkan 版 llama-cli）
#
# 必须在 NAS 宿主上执行（SSH 进 NAS 后运行），不能在容器内运行：
#   sudo sh /volume1/docker/dsh-deploy/apply-igpu.sh
#   或指定部署目录：sudo sh apply-igpu.sh /volume1/docker/dsh-deploy
#
# 幂等：重复执行安全（已直通则跳过改 compose，重建容器 + 补编译缺的组件）。
set -e

# ── 定位部署目录 ──────────────────────────────────────────────────────────
DIR="${1:-$(dirname "$(readlink -f "$0")")}"
COMPOSE="$DIR/docker-compose.yml"
if [ ! -f "$COMPOSE" ]; then
  echo "错误：找不到 $COMPOSE（传部署目录作为参数，或把本脚本放到 dsh-deploy 目录）" >&2
  exit 1
fi

echo "==> 1/4 检查 compose 是否已直通 /dev/dri"
if grep -q '/dev/dri' "$COMPOSE"; then
  echo "    已直通，跳过修改"
else
  cp "$COMPOSE" "$COMPOSE.bak.$(date +%Y%m%d-%H%M%S)"
  python3 - "$COMPOSE" <<'PY'
import sys
f = sys.argv[1]
src = open(f, encoding="utf-8").read()
# 在 deepseek-harness 服务的 labels: 行之前插入 devices 块（仓库 compose 结构）
anchor = "    labels:"
assert anchor in src, "compose 中没有预期的 labels: 锚点，请手动在服务下加 devices:"
block = "    # Intel 核显直通（Iris Xe，加速本地视觉模型的图像编码）\n"
block += "    devices:\n      - /dev/dri:/dev/dri\n"
src = src.replace(anchor, block + anchor, 1)
open(f, "w", encoding="utf-8").write(src)
print("    已写入 devices 直通（备份: docker-compose.yml.bak.*）")
PY
fi

echo "==> 2/4 校验 compose 语法"
docker compose -f "$COMPOSE" config -q || { echo "错误：compose 校验失败，已保留备份待回滚" >&2; exit 1; }

echo "==> 3/4 重建容器使直通生效（deepseek-harness 会重启约 1 分钟）"
docker compose -f "$COMPOSE" up -d --force-recreate deepseek-harness
for i in $(seq 1 30); do
  if docker exec deepseek-harness test -e /dev/dri 2>/dev/null; then
    echo "    /dev/dri 直通成功"
    break
  fi
  [ "$i" = 30 ] && echo "警告：容器起来了但 /dev/dri 未出现（检查宿主 i915 驱动）" || sleep 3
done

echo "==> 4/4 容器内补编译 Vulkan 版 llama-cli（无则自动装依赖，约 5-10 分钟）"
docker exec deepseek-harness bash /root/nas_docker/scripts/vision-setup.sh || \
  echo "警告：vision-setup.sh 执行有告警，见上方输出"

echo
echo "完成。验证："
echo "  docker exec deepseek-harness ls /dev/dri        # 应看到 card0 renderD128"
echo "  docker exec deepseek-harness bash /root/nas_docker/scripts/see.sh <图片> --question 描述"
echo "  # see.sh 日志出现 --mmproj-offload 即核显已接管视觉编码"
