#!/bin/sh
# 创建 dsh-watchdog 守护容器（幂等）：
#   - 挂载 docker socket + 部署脚本（只读）+ state（可写）+ GHCR 凭据
#   - 容器内 cron 每 5 分钟跑 watchdog.sh（UGOS 限制 lzg 的 crontab，故用容器代替）
#   - 通过代理变量访问 apk 源（NAS 出网走 192.168.5.36:7893）
set -eu

PROXY="${HTTP_PROXY:-http://192.168.5.36:7893}"
docker rm -f dsh-watchdog 2>/dev/null || true

docker run -d --name dsh-watchdog --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /volume1/docker/dsh-deploy:/dsh-deploy:ro \
  -v /volume1/docker/dsh-deploy/state:/dsh-state \
  -v /volume1/docker/deepseek-harness:/dsh-app \
  -v /home/lzg/.docker/config.json:/root/.docker/config.json:ro \
  -e TZ=Asia/Shanghai \
  -e DSH_DEPLOY_STATE=/dsh-state \
  -e DSH_DEPLOY_DIR=/dsh-app \
  -e HTTP_PROXY="$PROXY" -e HTTPS_PROXY="$PROXY" \
  -e NO_PROXY=localhost,127.0.0.1 \
  --entrypoint /bin/sh alpine:3.20 -c '
    set -e
    echo "[bootstrap] installing tools..."
    apk add --no-cache --quiet docker-cli docker-cli-compose jq curl coreutils
    echo "*/5 * * * * /dsh-deploy/watchdog.sh >> /dev/null 2>&1" > /etc/crontabs/root
    echo "[bootstrap] cron:"
    cat /etc/crontabs/root
    echo "[bootstrap] starting crond"
    crond -f -l 2
  '

echo "watchdog container:"
docker ps --filter name=dsh-watchdog --format "{{.Names}} {{.Status}}"
