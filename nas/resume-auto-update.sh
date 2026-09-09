#!/bin/sh
# 恢复自动更新：把该通道切回 SSOT 的 production 版本（**不是 latest**），
# 并保留通道身份。钉住原因写 DSH_PIN_REASON=ssot-production，
# watchdog 仍可对不健康容器自动回滚（只有 manual 才跳过）。
#
# 目标版本解析顺序：SSOT channels.<ch>.production（旧格式回退顶层 productionChannel/version）
# 镜像不可用时回退 compose 默认镜像并显式告警（latest 仅由 stable 通道发布，alpha/rc 可能被降级）。
#
# 调用方式（不接受位置参数 / 不接受 --channel）：
#   DSH_CHANNEL=alpha sh resume-auto-update.sh
#   DSH_CHANNEL=rc    sh resume-auto-update.sh
set -eu
. "$(dirname "$0")/lib.sh"

if [ "$#" -gt 0 ]; then
  echo "用法：DSH_CHANNEL=<alpha|rc> sh resume-auto-update.sh（不接受位置参数；通道用 DSH_CHANNEL 环境变量）" >&2
  exit 2
fi

log "resume auto-update $CHANNEL (target = SSOT channels.$CHANNEL.production)"
if ! unpin; then
  echo "ERROR: 恢复失败，请检查 $STATE/$CHANNEL-rollback.log" >&2
  exit 1
fi
echo "完成：通道 $CHANNEL 当前版本 $(current_version)（钉住原因 $(env_get DSH_PIN_REASON)）。"
