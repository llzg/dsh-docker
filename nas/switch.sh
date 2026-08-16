#!/bin/sh
# 将 deepseek-harness 容器切换到 GHCR 镜像（首次启用 watchtower 自动更新时执行一次）。
# 注意：会重建容器（容器重启约 1 分钟，会话数据在 ./dsh-data 持久化不受影响）。
set -eu
. /volume1/docker/dsh-deploy/lib.sh

log "switch to GHCR image (first enable)"
(cd "$DIR" && docker compose pull && docker compose up -d --force-recreate)
log "switch done"
echo "已切换到 ghcr.io/llzg/dsh-docker:latest"
echo "当前版本: $(current_version)"
