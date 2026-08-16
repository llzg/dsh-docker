#!/bin/sh
# 一键回滚 deepseek-harness 到上一个已发布版本（或指定版本）。
# 用法: rollback.sh            # 回滚到当前版本的前一个已发布版本
#       rollback.sh 0.1.0-rc.5 # 回滚到指定版本
# 回滚后自动更新会暂停（compose 钉住旧版本）；恢复运行 resume-auto-update.sh
set -eu
. /volume1/docker/dsh-deploy/lib.sh

CUR=$(current_version)
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION=$(prev_version "$CUR")
  if [ -z "$VERSION" ]; then
    echo "未找到可回滚的版本（当前=$CUR，无更早版本）" >&2
    exit 1
  fi
fi

if [ "$VERSION" = "$CUR" ]; then
  echo "当前已是最新部署版本 $CUR，无需回滚"
  exit 0
fi

echo "回滚 deepseek-harness: $CUR -> $VERSION"
pin_version "$VERSION"
log "rollback $CUR -> $VERSION (manual)"
echo "完成。自动更新已暂停；恢复请运行: resume-auto-update.sh"
