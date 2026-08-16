#!/bin/sh
# 健康检查自动回滚守护（cron 每 5 分钟执行一次）：
#   * 容器健康 → 重置计数
#   * 连续 3 次（约 15 分钟）不健康 → 若当前镜像是"刚更新"（镜像构建时间 ≤ 3 小时），
#     自动回滚到上一个已发布版本并暂停自动更新（避免误处理长期存在的问题）。
#   日志: /volume1/docker/dsh-deploy/state/watchdog.log
set -eu
. "$(dirname "$0")/lib.sh"

C=deepseek-harness
CNT="$STATE/unhealthy_count"
WLOG="$STATE/watchdog.log"

H=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$C" 2>/dev/null || echo missing)

case "$H" in
  healthy|none|missing)
    rm -f "$CNT"
    exit 0
    ;;
esac

N=$(cat "$CNT" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$CNT"
[ "$N" -lt 3 ] && exit 0   # 连续 3 次不健康才动作

# 已被钉住（手动回滚进行中）则不重复动作
if [ -f "$DIR/.env" ]; then
  echo "$(date '+%F %T') watchdog: rollback pin exists, skip" >> "$WLOG"
  exit 0
fi

# 镜像必须"刚更新"（构建 3 小时内），避免把长期问题误当更新失败
IMG_ID=$(docker inspect -f '{{.Image}}' "$C" 2>/dev/null || echo "")
[ -z "$IMG_ID" ] && exit 0
CREATED=$(docker image inspect -f '{{.Created}}' "$IMG_ID" 2>/dev/null || echo "")
if [ -n "$CREATED" ]; then
  AGE=$(($(date +%s) - $(date -d "$CREATED" +%s 2>/dev/null || echo 0)))
  if [ "${AGE:-99999}" -ge 10800 ]; then
    echo "$(date '+%F %T') watchdog: unhealthy=$H but image built ${AGE}s ago (>3h), skip auto-rollback" >> "$WLOG"
    exit 0
  fi
fi

CUR=$(current_version)
[ -z "$CUR" ] && exit 0
PREV=$(prev_version "$CUR")
if [ -z "$PREV" ]; then
  echo "$(date '+%F %T') watchdog: no previous version found for $CUR, skip" >> "$WLOG"
  exit 0
fi

echo "$(date '+%F %T') AUTO-ROLLBACK $CUR -> $PREV (unhealthy=$H)" >> "$WLOG"
log "auto-rollback $CUR -> $PREV (unhealthy=$H)"
pin_version "$PREV"
rm -f "$CNT"
