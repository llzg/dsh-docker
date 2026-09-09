#!/bin/sh
# 健康检查自动回滚守护（cron 每 5 分钟执行一次，每通道一行）：
#   * 容器健康/无健康检查 → 重置计数
#   * 连续 N 次（默认 3 次，约 15 分钟）不健康 →
#       且容器"刚部署"（.State.StartedAt ≤ 3 小时，部署时间而非镜像构建时间）→
#       自动回滚到上一个已发布版本（semver 严格更低者中的最高者），
#       并以 DSH_PIN_REASON=auto-rollback 钉住（残留时允许下次重试）。
#   * 仅 DSH_PIN_REASON=manual 时跳过（人工回滚进行中）。
# 日志: $STATE_ROOT/<channel>/<channel>-watchdog.log
set -eu
. "$(dirname "$0")/lib.sh"

if [ "$#" -gt 0 ]; then
  echo "用法：DSH_CHANNEL=<alpha|rc> sh watchdog.sh（不接受位置参数；通道用 DSH_CHANNEL 环境变量）" >&2
  exit 2
fi

watchdog_main() {
  CNT="$STATE/unhealthy_count"
  THRESHOLD="${DSH_WATCHDOG_THRESHOLD:-3}"
  MAX_AGE="${DSH_WATCHDOG_MAX_AGE:-10800}"

  H=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo missing)
  case "$H" in
    healthy|none|missing)
      rm -f "$CNT"
      exit 0
      ;;
  esac

  N=$(cat "$CNT" 2>/dev/null || echo 0)
  case "$N" in ''|*[!0-9]*) N=0 ;; esac
  N=$((N + 1))
  echo "$N" > "$CNT"
  [ "$N" -lt "$THRESHOLD" ] && exit 0

  # 仅"人工钉住"跳过；auto-rollback 残留（上次自动回滚未成功/仍不健康）允许重试
  _reason=$(env_get DSH_PIN_REASON)
  if [ "$_reason" = "manual" ]; then
    echo "$(date '+%F %T') watchdog[$CHANNEL]: manual pin $(env_get DSH_PIN_VERSION) active, skip" >> "$WLOG"
    exit 0
  fi

  # 新鲜度：容器部署时间（.State.StartedAt），不是镜像构建时间（.Created）
  _started=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || echo "")
  if [ -z "$_started" ]; then
    echo "$(date '+%F %T') watchdog[$CHANNEL]: no .State.StartedAt, skip" >> "$WLOG"
    exit 0
  fi
  if ! _age=$(age_seconds "$_started"); then
    echo "$(date '+%F %T') watchdog[$CHANNEL]: unparseable StartedAt=$_started, skip" >> "$WLOG"
    exit 0
  fi
  if [ "$_age" -ge "$MAX_AGE" ]; then
    echo "$(date '+%F %T') watchdog[$CHANNEL]: unhealthy=$H but container started ${_age}s ago (>${MAX_AGE}s), skip auto-rollback" >> "$WLOG"
    exit 0
  fi

  _cur=$(current_version)
  if [ -z "$_cur" ]; then
    echo "$(date '+%F %T') watchdog[$CHANNEL]: cannot resolve current version, skip" >> "$WLOG"
    exit 0
  fi
  if ! _prev=$(prev_version "$_cur"); then
    echo "$(date '+%F %T') watchdog[$CHANNEL]: no previous version for $_cur, skip" >> "$WLOG"
    exit 0
  fi

  echo "$(date '+%F %T') AUTO-ROLLBACK[$CHANNEL] $_cur -> $_prev (unhealthy=$H, started ${_age}s ago)" >> "$WLOG"
  log "auto-rollback $CHANNEL $_cur -> $_prev (unhealthy=$H)"
  if ! pin_version_locked "$_prev" auto-rollback; then
    echo "$(date '+%F %T') AUTO-ROLLBACK[$CHANNEL] $_cur -> $_prev FAILED (见 rollback 日志)" >> "$WLOG"
    exit 1
  fi
  rm -f "$CNT"
  exit 0
}

with_lock watchdog_main
