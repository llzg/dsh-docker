#!/bin/sh
# realign.sh —— 一条命令把通道容器对齐到 registry 上**当前 tag** 指向的最新构建。
#
# 为什么需要：DSH 的镜像 tag 是**可变**的 —— CI 用同一个版本号重建时会重推同一个 tag，
# 于是运行中的容器会"落后一次构建"（同版本、行为一致，但不确定跑的是哪次）。本脚本：
#   1) 读通道的 .env / SSOT 得到 项目名、镜像、数据目录
#   2) docker pull 该 tag（拿到最新构建）
#   3) docker compose up -d --wait（镜像 ID 变了 compose 会自动重建容器）
#   4) 用 check-image-drift.sh 复核，并探活对外端口
#
# 用法（在 dsh-deploy 目录下）：
#   sh realign.sh                # 所有通道
#   sh realign.sh rc             # 只对齐 rc
#   sh realign.sh all --dry-run  # 只打印将要执行的动作
#
# 环境变量：
#   DSH_SSOT        SSOT 路径（默认同目录 dsh-version.json）
#   DSH_DEPLOY_DIR  部署目录（默认脚本所在目录）
#   DSH_PORTS       额外探活的端口（默认 3081 3083）
#
# 退出码：0 = 全部对齐；1 = 有通道未对齐/探活失败；2 = 用法或环境错误。
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/.env" ] || [ -f "$SELF_DIR/dsh-version.json" ] || [ -f "$SELF_DIR/check-image-drift.sh" ]; then
  DEPLOY_DIR="$SELF_DIR"
else
  DEPLOY_DIR="$(cd "$SELF_DIR/.." && pwd)"
fi
DEPLOY_DIR="${DSH_DEPLOY_DIR:-$DEPLOY_DIR}"
SSOT="${DSH_SSOT:-$DEPLOY_DIR/dsh-version.json}"

CHANNELS=""
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    alpha|rc|stable) CHANNELS="$CHANNELS $a" ;;
    all) CHANNELS="" ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "找不到 docker" >&2; exit 2; }
[ -f "$SSOT" ] || { echo "找不到 SSOT: $SSOT" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "需要 node 解析 SSOT" >&2; exit 2; }

# 通道（未指定则取 SSOT 里全部；legacy 顶层字段交给 node 归一化）
if [ -z "$CHANNELS" ]; then
  CHANNELS="$(node -e '
    const fs=require("fs");let j;try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){process.exit(2)}
    const ch=j.channels||{[j.channel||"alpha"]:{dataDir:j.dataDir||""}};
    process.stdout.write(Object.keys(ch).join(" "))' "$SSOT")" || { echo "解析 SSOT 失败" >&2; exit 2; }
fi

env_get() { # <file> <key>
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | tail -1 | sed 's/^"//; s/"$//'
}

rc_all=0
for ch in $CHANNELS; do
  dir="$(node -e '
    const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const c=(j.channels&&j.channels[process.argv[2]])||{};
    process.stdout.write(c.dataDir||"")' "$SSOT" "$ch" 2>/dev/null)"
  [ -n "$dir" ] || { echo "[$ch] SSOT 里没有 channels.$ch.dataDir，跳过" >&2; rc_all=1; continue; }
  [ -d "$dir" ] || { echo "[$ch] 数据目录不存在: $dir（若本脚本跑在 NAS 宿主上应存在）" >&2; rc_all=1; continue; }

  ENVF="$dir/.env"
  proj="$(env_get "$ENVF" DSH_PROJECT || true)"; proj="${proj:-dsh-$ch}"
  img="$(env_get "$ENVF" DSH_IMAGE || true)"
  if [ -z "$img" ]; then
    echo "[$ch] .env 里没有 DSH_IMAGE，无法确定镜像；请先运行 install.sh 生成 .env" >&2
    rc_all=1; continue
  fi
  tag="${img##*:}"

  # compose 调用与 nas/lib.sh 的约定一致：显式 -p / --project-directory / -f，override 按存在性追加
  set -- -p "$proj" --project-directory "$dir"
  [ -f "$dir/docker-compose.docker-sock.yml" ] && set -- "$@" -f "$dir/docker-compose.docker-sock.yml"
  set -- "$@" -f "$dir/docker-compose.yml" --profile proxy

  echo "══ [$ch] 项目=$proj 镜像=$img"
  echo "    目录: $dir"
  if [ "$DRY" = "1" ]; then
    echo "    [dry-run] docker pull $img"
    echo "    [dry-run] docker compose $* up -d --wait"
    continue
  fi

  before="$(docker inspect "$(env_get "$ENVF" DSH_CONTAINER || echo "${ch}-container")" --format '{{.Image}}' 2>/dev/null || echo '')"
  if ! docker pull -q "$img" >/dev/null 2>&1; then
    echo "    ✗ docker pull 失败（registry 不可达或凭据失效；检查 ~/.docker/config.json 与 .env）" >&2
    rc_all=1; continue
  fi
  after_img="$(docker image inspect "$img" --format '{{.Id}}' 2>/dev/null || echo '')"
  if ! docker compose "$@" up -d --wait 2>&1 | tail -4 | sed 's/^/    /'; then
    echo "    ✗ compose up 失败" >&2
    rc_all=1; continue
  fi
  echo "    镜像: ${before:-无} -> ${after_img:-未知}"
done

if [ "$DRY" != "1" ]; then
  echo ""
  echo "══ 对齐复核（check-image-drift.sh）══"
  if [ -x "$DEPLOY_DIR/check-image-drift.sh" ] || [ -f "$DEPLOY_DIR/check-image-drift.sh" ]; then
    sh "$DEPLOY_DIR/check-image-drift.sh" || rc_all=1
  else
    echo "  （找不到 check-image-drift.sh，跳过）"
  fi
  echo ""
  echo "══ 端口探活 ══"
  for p in ${DSH_PORTS:-3081 3083}; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 "http://127.0.0.1:$p/" 2>/dev/null || echo 000)"
    printf "  %-6s -> %s\n" "$p" "$code"
    [ "$code" = "200" ] || rc_all=1
  done
fi

[ "$rc_all" = "0" ] && echo "" && echo "realign: 完成" || { echo ""; echo "realign: 有未对齐项（见上）" >&2; }
exit "$rc_all"
