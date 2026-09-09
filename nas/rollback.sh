#!/bin/sh
# 一键回滚通道容器到上一个已发布版本（或指定版本）。
# 用法: rollback.sh            # 回滚到当前版本的前一个已发布版本（semver 严格更低者中的最高者）
#       rollback.sh 0.1.3-alpha.2
#       DSH_CHANNEL=rc sh rollback.sh
# 回滚后自动更新暂停（.env 钉住旧版本 + DSH_PIN_REASON=manual）；恢复运行 resume-auto-update.sh
set -eu
. "$(dirname "$0")/lib.sh"

case "${1:-}" in
  -*) echo "用法：DSH_CHANNEL=<alpha|rc> sh rollback.sh [version]（不接受 --channel；通道用 DSH_CHANNEL 环境变量）" >&2; exit 2 ;;
esac

CUR=$(current_version)
[ -n "$CUR" ] || { echo "ERROR: 无法确定当前版本（.env 与容器标签均为空）" >&2; exit 1; }
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
  # prev_version 失败时返回非 0 并已打印原因（当前版本不在候选列表 / 无更早版本）
  if ! VERSION=$(prev_version "$CUR"); then
    echo "ERROR: 未找到可回滚的版本（当前=$CUR，通道=$CHANNEL）" >&2
    exit 1
  fi
fi

if [ "$VERSION" = "$CUR" ]; then
  echo "当前已是最新部署版本 $CUR，无需回滚"
  exit 0
fi

# 防"回滚变升级"：目标必须严格低于当前版本（semver 比较，非字符串/版本列表顺序）
if ! CMP=$(semver_cmp "$VERSION" "$CUR"); then
  echo "ERROR: 版本无法比较（target=$VERSION current=$CUR）" >&2
  exit 1
fi
case "$CMP" in
  -1) : ;;
  0)  echo "目标版本与当前版本相同（$CUR），无需回滚"; exit 0 ;;
  *)  echo "ERROR: 拒绝执行：目标 $VERSION 高于当前 $CUR（回滚不允许变升级）" >&2; exit 1 ;;
esac

echo "回滚通道 $CHANNEL ($CONTAINER): $CUR -> $VERSION"
if ! pin_version "$VERSION" manual; then
  echo "ERROR: 回滚失败（已尝试还原旧 .env / 旧容器），请人工检查 $STATE/$CHANNEL-rollback.log" >&2
  exit 1
fi
log "rollback $CHANNEL $CUR -> $VERSION (manual)"
echo "完成。自动更新已暂停（DSH_PIN_REASON=manual）；恢复请运行: resume-auto-update.sh"
