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
#   ⚠ DSH_HOME / DSH_CHANNEL / DSH_TRUSTED_HOST / DSH_VERSION_PORT **不是**本脚本的调优项：
#     它们一律以各通道 .env 为准，脚本启动即 unset（2026-09-16"对话记录消失"事故，见下）。
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
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    alpha|rc|stable) CHANNELS="$CHANNELS $a" ;;
    all) CHANNELS="" ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "找不到 docker" >&2; exit 2; }
[ -f "$SSOT" ] || { echo "找不到 SSOT: $SSOT" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "需要 node 解析 SSOT" >&2; exit 2; }

# ── 环境隔离：这 4 个键只允许来自各通道的 .env ────────────────────────────────
# 2026-09-16 事故（P0）：镜像的 ENV 曾固化 DSH_HOME / DSH_CHANNEL / DSH_TRUSTED_HOST /
# DSH_VERSION_PORT。当本脚本在**基于该镜像的容器**里被执行时（实测：
#   docker run <dsh 镜像> sh -c 'sh realign.sh alpha'
# 容器 env 恰好带着这 4 个镜像默认值），它们会随进程环境泄漏给 docker compose；
# 而 compose 的插值规则是 **shell 环境优先于 --project-directory 下的 .env** ——
# 于是通道 .env 被静默压掉，容器被重建成了错误的配置：
#   * DSH_HOME 掉回 /data/dsh（alpha 真实 home 是 /data/dsh/test/0.1.2-alpha.5）
#     → DSH 去读 2026-09-08 之后就不再写入的旧 home，界面表现为"对话记录全没了"
#     （数据没丢，只是读错了目录）；
#   * DSH_TRUSTED_HOST 只剩一个地址 → 用户端 /api/* 与 WebSocket 全 403，
#     界面空列表 + 一直重连（与 2026-09-10 的受信围栏事故同源）。
# 结论：realign 支持调优的环境变量只有 DSH_SSOT / DSH_DEPLOY_DIR / DSH_PORTS，
# 这 4 个通道身份/数据目录键一律以通道 .env 为准，调用者环境里的一律丢弃。
# 配套：Dockerfile 已移除这些 ENV 固化，重建后还有 env 断言兜底（见下）。
unset DSH_HOME DSH_CHANNEL DSH_TRUSTED_HOST DSH_VERSION_PORT DSH_TELEMETRY_DISABLED

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
  cname="$(env_get "$ENVF" DSH_CONTAINER || true)"
  if [ -z "$cname" ]; then
    cname="$(node -e '
      const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const c=(j.channels&&j.channels[process.argv[2]])||{};
      process.stdout.write(c.container||"")' "$SSOT" "$ch" 2>/dev/null)"
  fi
  [ -n "$cname" ] || cname="${ch}-container"

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

  before="$(docker inspect "$cname" --format '{{.Image}}' 2>/dev/null || echo '')"
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

  # ── 重建后断言：容器 env 必须与通道 .env 一致 ──────────────────────────────
  # 上面 unset 只挡住"本脚本这一层的泄漏"；这里正向校验结果，任何来源（镜像 ENV、
  # 外层包装、compose override）导致的静默覆盖都会在此暴露为失败，而不是悄悄上线。
  # 校验失败即判定该通道未对齐（rc_all=1），并打印期望值便于直接比对。
  _bad=0
  for _k in DSH_HOME DSH_CHANNEL DSH_TRUSTED_HOST DSH_VERSION_PORT; do
    _want="$(env_get "$ENVF" "$_k" || true)"
    [ -n "$_want" ] || continue
    _got="$(docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n "s/^$_k=//p" | tail -1)"
    if [ "$_got" != "$_want" ]; then
      echo "    ✗ env 不一致 $_k: 容器=[$_got] 期望=[$_want]（通道 .env 被覆盖——界面会读错 home/受信围栏失效）" >&2
      _bad=1
    fi
  done
  if [ "$_bad" != "0" ]; then
    echo "    ✗ [$ch] 重建后 env 校验失败，该通道视为未对齐；请修 .env 后重跑 realign.sh" >&2
    rc_all=1; continue
  fi
  echo "    env 校验: 与 $ENVF 一致 ✓"
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
