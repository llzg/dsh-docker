#!/bin/sh
# 将通道容器切换到"应有的镜像"（首次启用/人工切换时执行一次）：
#   * .env 已钉住（DSH_IMAGE 非空）→ 拉取并重建，沿用当前钉住版本；
#   * 未钉住 → 跟随 SSOT channels.<ch>.production（**不是 compose 默认的 latest**，
#     latest 仅由 stable 通道发布，直接跟 latest 会让 alpha/rc 被降级）；
#     该版本镜像不可用时回退 compose 默认镜像并显式告警。
# 注意：会重建容器（约 1 分钟；数据在 ./dsh-data 持久化不受影响）。
#
# 调用方式（不接受位置参数 / 不接受 --channel）：
#   DSH_CHANNEL=alpha sh switch.sh
#   DSH_CHANNEL=rc    sh switch.sh
# 写操作加 flock（$STATE/deploy.lock，契约 §9）。
set -eu
. "$(dirname "$0")/lib.sh"

if [ "$#" -gt 0 ]; then
  echo "用法：DSH_CHANNEL=<alpha|rc> sh switch.sh（不接受位置参数；通道用 DSH_CHANNEL 环境变量）" >&2
  exit 2
fi

switch_main() {
  log "switch $CHANNEL container=$CONTAINER project=$PROJECT dir=$DIR"
  if [ -n "$(env_get DSH_IMAGE)" ]; then
    echo "switch: 沿用 .env 钉住版本 $(current_version)（DSH_PIN_REASON=$(env_get DSH_PIN_REASON)）"
    compose_cmd pull
    compose_cmd up -d --force-recreate
  else
    echo "switch: .env 未钉住 → 跟随 SSOT channels.$CHANNEL.production"
    resume_to_channel_production
  fi
  log "switch done"
  echo "已切换通道 $CHANNEL 容器 $CONTAINER"
  echo "当前版本: $(current_version)"
}

with_lock switch_main
