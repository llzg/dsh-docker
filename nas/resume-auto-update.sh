#!/bin/sh
# 恢复自动更新：移除回滚钉住（.env 中的 DSH_IMAGE），拉取 latest 并重建容器。
set -eu
. /volume1/docker/dsh-deploy/lib.sh

log "resume auto-update (unpin -> latest)"
unpin
echo "完成，已恢复跟随 ghcr.io/llzg/dsh-docker:latest 自动更新。"
