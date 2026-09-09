#!/bin/sh
# dsh 容器入口（PID 1）：数据目录准备 + 补丁自愈 + 版本页守护，最后 exec 主进程。
# 契约：docs/dual-channel.md §6（环境变量）、§7（版本页）。
set -eu

# ── 环境变量兜底（契约 §6）─────────────────────────────────────────────────
# 旧实现直接 mkdir -p "$DSH_HOME/profiles/web"：DSH_HOME 未设时会创建 /profiles/web。
DSH_HOME="${DSH_HOME:-/data/dsh}"
DSH_CHANNEL="${DSH_CHANNEL:-alpha}"
DSH_VERSION_PORT="${DSH_VERSION_PORT:-3082}"
DSH_VERSION_SSOT="${DSH_VERSION_SSOT:-}"
export DSH_HOME DSH_CHANNEL DSH_VERSION_PORT DSH_VERSION_SSOT
# 兼容：当前 version-server.js 读的是 VERSION_PORT（契约 §6 命名为 DSH_VERSION_PORT）。
# 两个都导出，version-server.js 改造完成后 DSH_VERSION_PORT 即为唯一来源。
VERSION_PORT="$DSH_VERSION_PORT"
export VERSION_PORT

mkdir -p "$DSH_HOME/profiles/web" "$DSH_HOME/logs"
if [ ! -f "$DSH_HOME/profiles/web/cordis.patch.yml" ]; then
  cp /opt/dsh-profiles/web/cordis.patch.yml "$DSH_HOME/profiles/web/cordis.patch.yml"
fi
# 自愈：容器每次启动都重跑 LAN/vision 补丁（幂等，失败不阻塞启动）。
# 镜像里 patch-dsh.sh 已随构建烤入 /opt；工作区副本兜底（本地修改未重建镜像时）。
if [ -x /opt/patch-dsh.sh ]; then
  /opt/patch-dsh.sh || echo "[entrypoint] patch-dsh 自愈告警（非致命）"
elif [ -x /root/nas_docker/patch-dsh.sh ]; then
  /root/nas_docker/patch-dsh.sh || echo "[entrypoint] patch-dsh 工作区自愈告警（非致命）"
fi
# 自愈：corepack pnpm shim 随镜像层存在，但容器 recreate 后若镜像未含 pnpm
# （旧镜像 + 未推送 Dockerfile 修复期间），writable 层 shim 会丢失。
# 幂等重建 shim（包体在 /root/.cache/node/corepack，随 /root 持久卷保留），失败不阻塞启动。
corepack enable >/dev/null 2>&1 \
  || echo "[entrypoint] corepack enable 自愈告警（非致命）"

# ── 版本信息页（3082）受守护的后台进程 ──────────────────────────────────────
# 契约 §6：DSH_VERSION_PORT=0 → 不启动（rc 容器由 alpha 容器统一渲染两条通道）。
# 日志写持久卷 $DSH_HOME/logs（旧实现写 /tmp，容器重建即丢）。
# 崩溃（非 0 退出）后 5s 重启，最多 DSH_VERSION_RESTART_MAX 次；正常退出不重启。
VERSION_LOG="$DSH_HOME/logs/version-server.log"
VERSION_RESTART_MAX="${DSH_VERSION_RESTART_MAX:-5}"

run_version_server() {
  tries=0
  while :; do
    if node /opt/version-server.js >>"$VERSION_LOG" 2>&1; then
      echo "[entrypoint] $(date -Is) version-server 正常退出，不再重启" >>"$VERSION_LOG"
      return 0
    fi
    tries=$((tries + 1))
    echo "[entrypoint] $(date -Is) version-server 异常退出（第 $tries 次），5s 后重启（上限 $VERSION_RESTART_MAX）" >>"$VERSION_LOG"
    if [ "$tries" -ge "$VERSION_RESTART_MAX" ]; then
      echo "[entrypoint] $(date -Is) version-server 连续失败 $tries 次，放弃守护" >>"$VERSION_LOG"
      return 1
    fi
    sleep 5
  done
}

if [ "$DSH_VERSION_PORT" = "0" ]; then
  echo "[entrypoint] DSH_VERSION_PORT=0，跳过版本页"
elif [ ! -f /opt/version-server.js ]; then
  echo "[entrypoint] /opt/version-server.js 不存在，跳过版本页" >&2
else
  echo "[entrypoint] 启动版本页守护：port=$DSH_VERSION_PORT channel=$DSH_CHANNEL log=$VERSION_LOG"
  run_version_server &
fi

# exec：保持 PID 1 语义，信号（SIGTERM/SIGINT）可传给 dsh 主进程
exec "$@"
