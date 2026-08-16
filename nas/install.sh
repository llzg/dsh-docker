#!/bin/sh
# 一次性部署（幂等，可重复执行）：
#   1) 备份旧 compose（不覆盖已有备份）
#   2) 安装新 compose（image 指向 ghcr.io/llzg/dsh-docker:latest）
#   3) 安装脚本 + watchdog cron（每 5 分钟）
#   4) 预拉取 GHCR 镜像
# 容器切换（会重启 deepseek-harness）单独执行: sh /volume1/docker/dsh-deploy/switch.sh
set -eu

SRC=/volume1/docker/dsh-deploy
DIR=/volume1/docker/deepseek-harness
STATE="$SRC/state"
mkdir -p "$STATE"

# 1) 备份旧 compose
if [ -f "$DIR/docker-compose.yml" ]; then
  BAK="$DIR/docker-compose.yml.bak-$(date +%Y%m%d%H%M%S)"
  if ! ls "$DIR"/docker-compose.yml.bak-* >/dev/null 2>&1; then
    cp "$DIR/docker-compose.yml" "$BAK"
    echo "备份旧 compose -> $BAK"
  else
    echo "已有 compose 备份，跳过"
  fi
fi

# 2) 安装新 compose
cp "$SRC/docker-compose.yml" "$DIR/docker-compose.yml"
echo "已安装新 compose（image=ghcr.io/llzg/dsh-docker:latest，可回滚钉住）"

# 3) 脚本可执行 + watchdog cron
chmod +x "$SRC/lib.sh" "$SRC/rollback.sh" "$SRC/resume-auto-update.sh" "$SRC/watchdog.sh" "$SRC/switch.sh"
crontab -l 2>/dev/null | grep -v 'dsh-deploy/watchdog.sh' > /tmp/dsh-cron.new || true
echo "*/5 * * * * $SRC/watchdog.sh >> $STATE/watchdog.log 2>&1" >> /tmp/dsh-cron.new
crontab /tmp/dsh-cron.new
echo "watchdog cron 已安装（每 5 分钟）"

# 4) 预拉取 GHCR 镜像（首次）
docker pull ghcr.io/llzg/dsh-docker:latest
echo "install 完成。切换容器（重启一次）请运行: sh $SRC/switch.sh"
