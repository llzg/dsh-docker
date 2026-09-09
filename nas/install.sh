#!/bin/sh
# 一次性部署（幂等，可重复执行）—— 每通道独立安装：
#   1) mkdir -p 部署目录 + 状态目录
#   2) 同步 SSOT（仓库根 dsh-version.json → 部署目录）+ 每次覆盖前时间戳备份
#   3) 安装 compose（base + versionpage override）+ 用该通道 SSOT production 初始化 .env
#   4) 脚本可执行 + watchdog 守护容器（每 5 分钟，覆盖所有通道）
#   5) 预拉取该通道 SSOT production 镜像（不再预拉 latest）
#   6) compose 上下文自检（project name / 卷源断言）
#
# 用法：
#   sh install.sh                      # 默认通道（SSOT primaryChannel，再默认 alpha）
#   DSH_CHANNEL=rc sh install.sh       # 安装 rc 通道
#
# 注意：脚本自身放在部署目录（如 /volume1/docker/dsh-deploy），compose 装到通道目录
#       （如 /volume1/docker/dsh-alpha）。切换容器（会重启）单独执行 switch.sh。
# 写操作整体加 flock（$STATE/deploy.lock，契约 §9）。
set -eu

SRC=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$SRC/lib.sh"

if [ "$#" -gt 0 ]; then
  echo "用法：DSH_CHANNEL=<alpha|rc> sh install.sh（不接受位置参数；通道用 DSH_CHANNEL 环境变量）" >&2
  exit 2
fi

echo "== install 通道=$CHANNEL 项目=$PROJECT 容器=$CONTAINER 目录=$DIR =="

# 每次覆盖前备份（时间戳，不跳过）
backup_if_exists() { # <file>
  [ -f "$1" ] || return 0
  _bak="$1.bak-$(date +%Y%m%d%H%M%S)"
  if cp -p "$1" "$_bak" 2>/dev/null; then
    echo "备份 -> $_bak"
  else
    echo "WARN: 备份失败（继续安装）：$1" >&2
  fi
}

install_main() {
  # 1) 目录（缺失时 mkdir -p；历史缺陷：直接 cp 到不存在的目录会失败）
  mkdir -p "$DIR" "$STATE" "$STATE_ROOT"

  # 1b) SSOT 随部署资产一起落地：仓库根的 dsh-version.json 不会自己跑到部署目录，
  #     缺失时通道参数会退回内置默认表、resume 也拿不到 production。
  _src_ssot="$SRC/../dsh-version.json"
  if [ -n "${DSH_SSOT:-}" ] && [ -f "${DSH_SSOT:-}" ]; then
    echo "SSOT: 使用 DSH_SSOT=$DSH_SSOT"
  elif [ -f "$_src_ssot" ]; then
    if [ ! -f "$SRC/dsh-version.json" ] || ! cmp -s "$_src_ssot" "$SRC/dsh-version.json"; then
      backup_if_exists "$SRC/dsh-version.json"
      cp -p "$_src_ssot" "$SRC/dsh-version.json"
      echo "已同步 SSOT -> $SRC/dsh-version.json"
    else
      echo "SSOT 已是最新：$SRC/dsh-version.json"
    fi
  elif [ -f "$SRC/dsh-version.json" ]; then
    echo "SSOT: $SRC/dsh-version.json"
  else
    echo "WARN: 部署目录没有 dsh-version.json，且 $SRC/../dsh-version.json 不存在 —— 请设置 DSH_SSOT=<file>；" >&2
    echo "      否则通道参数退回内置默认、resume/switch 拿不到 channels.<ch>.production" >&2
  fi
  # SSOT 可能刚刚落地 → 重新解析通道配置（DIR/PROJECT/CONTAINER/PORT 等）
  lib_init
  echo "SSOT 解析：${SSOT:-（无）} | 通道=$CHANNEL 项目=$PROJECT 目录=$DIR"

  # 2) 安装 compose（base + 版本页 override）
  backup_if_exists "$DIR/docker-compose.yml"
  cp "$SRC/docker-compose.yml" "$DIR/docker-compose.yml"
  echo "已安装 compose -> $DIR/docker-compose.yml"

  if [ -f "$SRC/docker-compose.versionpage.yml" ]; then
    backup_if_exists "$DIR/docker-compose.versionpage.yml"
    cp "$SRC/docker-compose.versionpage.yml" "$DIR/docker-compose.versionpage.yml"
    echo "已安装版本页 override -> $DIR/docker-compose.versionpage.yml（DSH_VERSION_PORT=$VERSION_PORT）"
  fi

  # 3) .env：首次安装用该通道 SSOT production 初始化（compose 的 image 现在是必填项，
  #    不能再依赖 ${DSH_IMAGE:-…:latest} 兜底）；已存在则保留钉住状态，只备份。
  if [ ! -f "$DIR/.env" ]; then
    _prod=$(ssot_channel_production "$CHANNEL")
    if is_release_tag "$_prod"; then
      write_env_image "$_prod" ssot-production "" "$DIR/.env.pending" \
        && mv -f "$DIR/.env.pending" "$DIR/.env"
      echo "已写入 .env：DSH_IMAGE=$IMG:$_prod（来源 SSOT channels.$CHANNEL.production，reason=ssot-production）"
    else
      echo "WARN: SSOT 未提供合法的 channels.$CHANNEL.production（got='${_prod:-}'）→ .env 初始化为 $IMG:latest" >&2
      echo "WARN: latest 仅由 stable 通道发布，可能跨通道降级；请人工确认后 pin_version 到正确版本" >&2
      write_env_image "latest" "ssot-fallback" "" "$DIR/.env.pending" \
        && mv -f "$DIR/.env.pending" "$DIR/.env"
    fi
  else
    backup_if_exists "$DIR/.env"
    echo "已有 .env（version=$(env_get DSH_PIN_VERSION) reason=$(env_get DSH_PIN_REASON)），保留钉住状态（已备份）"
  fi

  # 4) 脚本可执行 + watchdog 守护容器（UGOS 限制 lzg 的 crontab，用独立容器跑 cron）
  chmod +x "$SRC/lib.sh" "$SRC/rollback.sh" "$SRC/resume-auto-update.sh" "$SRC/watchdog.sh" \
           "$SRC/switch.sh" "$SRC/watchdog-container.sh" "$SRC/apply-igpu.sh" 2>/dev/null || true

  if docker info >/dev/null 2>&1; then
    sh "$SRC/watchdog-container.sh" || echo "WARN: watchdog 容器创建失败（可稍后重跑）" >&2
    echo "watchdog 守护容器已创建（每 5 分钟检查健康并自动回滚；覆盖 SSOT 中所有通道）"
  else
    echo "WARN: docker 不可用，跳过 watchdog 容器创建与镜像预拉取" >&2
  fi

  # 5) 预拉取该通道 SSOT production（不再预拉 latest：latest 只由 stable 通道发布）；
  #    取不到 production 时退 latest 并明确告警。另预拉 .env 里已钉住的镜像（若不同）。
  if docker info >/dev/null 2>&1; then
    _pull=$(ssot_channel_production "$CHANNEL")
    if is_release_tag "$_pull"; then
      echo "预拉取 $IMG:$_pull（来源 SSOT channels.$CHANNEL.production）"
      docker pull "$IMG:$_pull" >/dev/null 2>&1 || echo "WARN: 预拉取 $IMG:$_pull 失败（首次可忽略）" >&2
    else
      echo "WARN: SSOT 未提供合法的 channels.$CHANNEL.production（got='${_pull:-}'）→ 预拉取 $IMG:latest（可能跨通道降级）" >&2
      docker pull "$IMG:latest" >/dev/null 2>&1 || echo "WARN: 预拉取 $IMG:latest 失败（首次可忽略）" >&2
    fi
    _pinned=$(env_get DSH_IMAGE)
    case "$_pinned" in
      ""|"$IMG:$_pull") : ;;
      *) echo "预拉取 .env 钉住的镜像 $_pinned"
         docker pull "$_pinned" >/dev/null 2>&1 || echo "WARN: 预拉取 $_pinned 失败" >&2 ;;
    esac
  fi

  # 6) compose 上下文自检（P0-1 断言：project name + 卷源必须落在 $DIR 下）
  if docker info >/dev/null 2>&1; then
    _errs=$(validate_compose_context) || true
    if [ -n "$_errs" ]; then
      echo "ERROR: compose 上下文自检失败（拒绝继续）：" >&2
      printf '%s\n' "$_errs" >&2
      exit 1
    fi
    echo "compose 上下文自检 PASS（project=$PROJECT，卷源均在 $DIR 下）"
  fi

  echo "install 完成。切换容器（重启一次）请运行: sh $SRC/switch.sh"
}

with_lock install_main
