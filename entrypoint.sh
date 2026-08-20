#!/bin/sh
set -e
mkdir -p "$DSH_HOME/profiles/web"
if [ ! -f "$DSH_HOME/profiles/web/cordis.patch.yml" ]; then
  cp /opt/dsh-profiles/web/cordis.patch.yml "$DSH_HOME/profiles/web/cordis.patch.yml"
fi
# 自愈：容器每次启动都重跑 LAN/vision 补丁（幂等，失败不阻塞启动）。
# 镜像里 patch-dsh.sh 已随构建烤入 /opt；工作区副本兜底（本地修改未重建镜像时）。
if [ -x /opt/patch-dsh.sh ]; then
  /opt/patch-dsh.sh || echo "[entrypoint] patch-dsh 自愈告警（非致命）"
elif [ -x /root/nas_docker/patch-dsh.sh ]; then
  /root/nas_docker/patch-dsh.sh || echo "[entrypoint] 工作区 patch-dsh 自愈告警（非致命）"
fi
# 自愈：corepack pnpm shim 随镜像层存在，但容器 recreate 后若镜像未含 pnpm
# （旧镜像 + 未推送 Dockerfile 修复期间），writable 层 shim 会丢失。
# 幂等重建 shim（包体在 /root/.cache/node/corepack，随 /root 持久卷保留），失败不阻塞启动。
corepack enable >/dev/null 2>&1 \
  || echo "[entrypoint] corepack enable 自愈告警（非致命）"
# 版本信息页（3082 端口）：http://<NAS-IP>:3082/  （镜像内嵌，随容器启动）
if [ -f /opt/version-server.js ]; then
  node /opt/version-server.js >>/tmp/version-server.log 2>&1 &
fi
exec "$@"
