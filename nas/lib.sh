#!/bin/sh
# dsh-deploy 共享函数库（rollback.sh / watchdog.sh / resume-auto-update.sh 共用）

# watchdog 容器内通过 DSH_DEPLOY_DIR / DSH_DEPLOY_STATE 覆盖路径
#（脚本目录只读挂载为 /dsh-deploy，compose 目录挂载为 /dsh-app，state 挂载为 /dsh-state）
DIR="${DSH_DEPLOY_DIR:-/volume1/docker/deepseek-harness}"
STATE="${DSH_DEPLOY_STATE:-/volume1/docker/dsh-deploy/state}"
IMG=ghcr.io/llzg/dsh-docker
LOG="$STATE/rollback.log"
mkdir -p "$STATE" 2>/dev/null || true

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 当前运行（或被钉住）的版本
current_version() {
  if [ -f "$DIR/.env" ]; then
    grep '^DSH_IMAGE=' "$DIR/.env" 2>/dev/null | head -1 | sed 's#.*:##'
  else
    docker inspect deepseek-harness --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
  fi
}

# 列出 GHCR 上已发布的版本标签（不含 latest）。
# 包为 public：优先匿名 token；失败再试 docker 配置里的 GHCR 凭据。
ghcr_tags() {
  local hdr="" tok="" cfg="/home/lzg/.docker/config.json" auth=""
  tok=$(curl -sf "https://ghcr.io/token?scope=repository:llzg/dsh-docker:pull&service=ghcr.io" | jq -r '.token // empty' 2>/dev/null || true)
  if [ -n "$tok" ]; then
    hdr="Authorization: Bearer $tok"
  elif [ -f "$cfg" ]; then
    auth=$(jq -r '.auths["ghcr.io"].auth // empty' "$cfg" 2>/dev/null || true)
    [ -n "$auth" ] && hdr="Authorization: Basic $auth"
  fi
  [ -z "$hdr" ] && { echo "ERROR: no GHCR credentials (anonymous failed, check /home/lzg/.docker/config.json)" >&2; return 1; }
  curl -sf -H "$hdr" "https://ghcr.io/v2/llzg/dsh-docker/tags/list" 2>/dev/null \
    | jq -r '.tags[]' 2>/dev/null | grep -v '^latest$' | sort -V
}

# 当前版本的前一个版本（按版本号排序）
prev_version() {
  local cur="$1" prev="" v
  for v in $(ghcr_tags); do
    if [ "$v" = "$cur" ]; then break; fi
    prev="$v"
  done
  echo "$prev"
}

# 钉住版本并重建（暂停自动更新）
pin_version() {
  local v="$1"
  docker pull "$IMG:$v"
  printf 'DSH_IMAGE=%s:%s\n' "$IMG" "$v" > "$DIR/.env"
  docker compose -f "$DIR/docker-compose.yml" up -d --force-recreate
}

# 解除钉住，恢复跟随 latest 自动更新
unpin() {
  rm -f "$DIR/.env"
  docker compose -f "$DIR/docker-compose.yml" pull
  docker compose -f "$DIR/docker-compose.yml" up -d --force-recreate
}
