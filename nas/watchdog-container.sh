#!/bin/sh
# 创建 dsh-watchdog 守护容器（幂等）：
#   - 挂载 docker socket + 部署脚本（只读）+ state（可写）+ GHCR 凭据
#   - ⚠ 通道目录按"宿主同路径"挂载（-v /volume1/docker/dsh-alpha:/volume1/docker/dsh-alpha）：
#     容器内看到的路径与宿主完全一致，compose_cmd() 的 --project-directory / 卷源
#     才不会解析到容器内的临时路径（历史 P0：挂成 /dsh-app 导致 project=dsh-app、
#     卷源 /dsh-app/dsh-data）。
#   - 容器内 cron 每 5 分钟对每个已安装通道跑 watchdog.sh
#     （UGOS 限制 lzg 的 crontab，故用独立容器代替）
#   - 通过代理变量访问 apk 源（NAS 出网走 192.168.5.36:7893）
#
# 通道来源：DSH_CHANNELS 环境变量 > SSOT channels keys > "alpha rc"。
# 未安装（数据目录不存在）或 stable 通道会被跳过。
set -eu

SRC=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$SRC/lib.sh"   # 复用 SSOT 解析 / 通道默认表（会覆盖通道全局变量，无副作用）

if [ "$#" -gt 0 ]; then
  echo "用法：DSH_CHANNEL=<alpha|rc> sh watchdog-container.sh（不接受位置参数；通道用 DSH_CHANNEL 环境变量）" >&2
  exit 2
fi

PROXY="${HTTP_PROXY:-http://192.168.5.36:7893}"
STATE_ROOT="${DSH_DEPLOY_STATE:-/volume1/docker/dsh-deploy/state}"
mkdir -p "$STATE_ROOT"

# 通道数据目录（与 lib_init 同规则：SSOT channels[ch].dataDir > 内置默认表）
channel_dir() {
  _d=$(ssot_channel_field "$1" dataDir)
  [ -n "$_d" ] || _d=$(channel_default "$1" dataDir)
  [ -n "$_d" ] || _d="/volume1/docker/dsh-$1"
  printf '%s' "$_d"
}

# ── 解析通道列表 ──────────────────────────────────────────────────────────
CHANNELS="${DSH_CHANNELS:-}"
if [ -z "$CHANNELS" ]; then
  CHANNELS=$(ssot_channels 2>/dev/null | tr '\n' ' ') || CHANNELS=""
fi
[ -n "$CHANNELS" ] || CHANNELS="alpha rc"

CRON_FILE="$STATE_ROOT/watchdog.crontab"
: > "$CRON_FILE"
ACTIVE=""

for ch in $CHANNELS; do
  case "$ch" in
    stable) echo "跳过 stable 通道（契约 §2：本期不启用部署）"; continue ;;
  esac
  _dir=$(channel_dir "$ch")
  if [ ! -f "$_dir/docker-compose.yml" ]; then
    echo "跳过通道 $ch：$_dir/docker-compose.yml 不存在（先跑 DSH_CHANNEL=$ch sh $SRC/install.sh）"
    continue
  fi
  ACTIVE="$ACTIVE $ch"
  _ssot_env=""
  [ -f "$SSOT" ] && _ssot_env="DSH_SSOT=$SSOT"
  printf '*/5 * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DSH_CHANNEL=%s DSH_DEPLOY_DIR=%s DSH_DEPLOY_STATE=%s %s %s/watchdog.sh >> /dev/null 2>&1\n' \
    "$ch" "$_dir" "$STATE_ROOT" "$_ssot_env" "$SRC" >> "$CRON_FILE"
done

if [ -z "$ACTIVE" ]; then
  echo "ERROR: 没有可监控的通道（先安装至少一个通道）" >&2
  rm -f "$CRON_FILE"
  exit 1
fi

echo "watchdog 监控通道:$ACTIVE"
echo "crontab:"
cat "$CRON_FILE"

# ── 组装 docker run 参数（宿主同路径挂载）────────────────────────────────
set -- \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$SRC:$SRC:ro" \
  -v "$STATE_ROOT:$STATE_ROOT" \
  -e TZ=Asia/Shanghai \
  -e DSH_CRONTAB="$CRON_FILE" \
  -e HTTP_PROXY="$PROXY" -e HTTPS_PROXY="$PROXY" \
  -e NO_PROXY=localhost,127.0.0.1

for ch in $ACTIVE; do
  _dir=$(channel_dir "$ch")
  set -- "$@" -v "$_dir:$_dir"
done

if [ -f "${DSH_DOCKER_CFG:-/home/lzg/.docker/config.json}" ]; then
  set -- "$@" -v "${DSH_DOCKER_CFG:-/home/lzg/.docker/config.json}:/root/.docker/config.json:ro"
fi

docker rm -f dsh-watchdog >/dev/null 2>&1 || true

docker run -d --name dsh-watchdog --restart unless-stopped "$@" \
  --entrypoint /bin/sh alpine:3.20 -c '
    set -e
    echo "[bootstrap] installing tools..."
    apk add --no-cache --quiet docker-cli docker-cli-compose jq curl coreutils util-linux
    cp "$DSH_CRONTAB" /etc/crontabs/root
    chmod 600 /etc/crontabs/root
    echo "[bootstrap] cron:"
    cat /etc/crontabs/root
    echo "[bootstrap] starting crond"
    crond -f -l 2
  '

echo "watchdog container:"
docker ps --filter name=dsh-watchdog --format "{{.Names}} {{.Status}}"
