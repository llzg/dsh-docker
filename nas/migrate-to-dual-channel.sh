#!/bin/sh
# migrate-to-dual-channel.sh —— 把现有（可能是手写的）dsh 部署迁移到本仓库的通道化资产。
#
# 设计原则：**默认只读**（--dry-run），--apply 才动手；每一步都可回滚；数据目录绝不搬动，
# 而是把 SSOT 的 dataDir 对齐到现状（这是最容易"迁移完会话就没了"的坑）。
#
# 用法（在部署资产目录 /volume1/docker/dsh-deploy 下执行）：
#   sh migrate-to-dual-channel.sh                 # 只读：打印现状与迁移计划
#   sh migrate-to-dual-channel.sh --apply        # 执行（会重建容器，每通道约 1 分钟）
#   DSH_CHANNELS="alpha rc" sh migrate-to-dual-channel.sh --apply
#   sh migrate-to-dual-channel.sh --apply --move-data   # 显式要求把数据搬到标准目录（有风险）
#
# 它做的事：
#   1) 只读探测现有 dsh 容器（项目名/数据挂载/端口/镜像/健康）
#   2) 按宿主端口把容器映射到 SSOT 的通道，并把 SSOT 的 dataDir/container/project 对齐现状
#   3) 每通道执行 install.sh（覆盖前自动备份）→ switch.sh（重建容器）
#   4) 验证：健康状态 + 端口 + 版本页；失败则打印回滚命令
set -eu

SELF_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"

APPLY=0
MOVE_DATA=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --move-data) MOVE_DATA=1 ;;
    --dry-run) APPLY=0 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "未知参数：$a（可用：--dry-run / --apply / --move-data）" >&2; exit 2 ;;
  esac
done

CHANNELS="${DSH_CHANNELS:-$(ssot_channels 2>/dev/null || printf 'alpha\nrc')}"
[ -n "$CHANNELS" ] || CHANNELS="alpha rc"

echo "== dsh 双通道迁移（模式：$([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)）=="
echo "SSOT=$SSOT"
command -v docker >/dev/null 2>&1 || { echo "ERROR: 找不到 docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon 不可用" >&2; exit 1; }

# ── 1. 只读探测现有 dsh 容器 ──────────────────────────────────────────────
echo
echo "--- 现有 dsh 相关容器 ---"
LEGACY=""
for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'dsh|deepseek|harness' || true); do
  _img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null || echo '?')
  _proj=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)
  _wd=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
  _health=$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo '?')
  _data=$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/data/dsh"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
  _root=$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/root"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
  _ports=$(docker inspect "$c" --format '{{range $p,$v := .NetworkSettings.Ports}}{{range $v}}{{.HostPort}} {{end}}{{end}}' 2>/dev/null | tr -s ' ' || true)
  printf '  %-22s image=%-45s project=%-14s health=%-9s data=%-45s root=%-40s ports=%s\n' \
    "$c" "$_img" "${_proj:-none}" "$_health" "${_data:-none}" "${_root:-none}" "${_ports:-none}"
  LEGACY="$LEGACY $c"
done
[ -n "$LEGACY" ] || echo "  (未发现任何 dsh 容器)"

# ── 2. 通道映射（按宿主端口 → SSOT 通道）─────────────────────────────────
# 目的：为每个通道找出"现有数据目录"，避免迁移后挂到空目录。
echo
echo "--- 通道映射计划 ---"
PLAN=""
for ch in $CHANNELS; do
  _port=$(ssot_channel_field "$ch" port); [ -n "$_port" ] || _port=$(channel_default "$ch" port)
  _want_container=$(ssot_channel_field "$ch" container); [ -n "$_want_container" ] || _want_container=$(channel_default "$ch" container)
  _want_project=$(ssot_channel_field "$ch" project); [ -n "$_want_project" ] || _want_project=$(channel_default "$ch" project)
  _want_dir=$(ssot_channel_field "$ch" dataDir); [ -n "$_want_dir" ] || _want_dir=$(channel_default "$ch" dataDir)

  # 找占用该端口的容器（宿主端口映射）
  _hit=""
  for c in $LEGACY; do
    _p=$(docker inspect "$c" --format '{{range $p,$v := .NetworkSettings.Ports}}{{range $v}}{{.HostPort}} {{end}}{{end}}' 2>/dev/null | tr -s ' ')
    case " $_p " in *" $_port "*) _hit="$c"; break ;; esac
  done

  _data=""
  _root=""
  if [ -n "$_hit" ]; then
    _data=$(docker inspect "$_hit" --format '{{range .Mounts}}{{if eq .Destination "/data/dsh"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
    _root=$(docker inspect "$_hit" --format '{{range .Mounts}}{{if eq .Destination "/root"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
  fi

  # 现有数据目录 → 推导部署目录（要求形如 <DIR>/dsh-data）
  _dir_from_data=""
  case "$_data" in
    */dsh-data) _dir_from_data="${_data%/dsh-data}" ;;
  esac
  _final_dir="$_want_dir"
  _action="新建通道目录 $_want_dir（无现有容器占用端口 $_port）"
  if [ -n "$_dir_from_data" ]; then
    if [ "$_dir_from_data" = "$_want_dir" ]; then
      _action="复用现有目录 $_want_dir（容器 $_hit 的数据挂载已匹配）"
    else
      _final_dir="$_dir_from_data"
      _action="对齐 SSOT：dataDir $_want_dir → $_dir_from_data（容器 $_hit 的实际数据目录，避免挂空）"
    fi
  fi

  printf '  [%s] port=%s 现有容器=%-20s 目标容器=%-12s 部署目录=%s\n' \
    "$ch" "$_port" "${_hit:-none}" "$_want_container" "$_final_dir"
  echo "        动作：$_action"
  [ -n "$_root" ] && echo "        /root 挂载：$_root（迁移后保留 → 版本页可读实时 SSOT）"
  PLAN="$PLAN$ch|$_port|$_hit|$_want_container|$_want_project|$_final_dir|$_data|$_root
"
done

# ── 3. 备份清单 ────────────────────────────────────────────────────────────
echo
echo "--- 执行前会做的备份 ---"
echo "  * 每通道 compose/.env：install.sh 内置时间戳备份（<通道部署目录>/docker-compose.yml.bak-*）"
echo "  * SSOT：本脚本写 dataDir 前先备份 $SSOT.bak-<ts>"
echo "  * 数据目录：不移动（除非 --move-data），因此无需拷贝"

if [ "$APPLY" != 1 ]; then
  echo
  echo "== DRY-RUN 结束：以上为迁移计划，未做任何修改。确认无误后加 --apply 执行 =="
  exit 0
fi

# ── 4. 执行 ────────────────────────────────────────────────────────────────
echo
echo "== 开始执行 =="
TS=$(date +%Y%m%d-%H%M%S)
FAILED=0

# 4.1 SSOT 对齐（dataDir/container/project/port），原子写 + 备份
if [ -f "$SSOT" ] && command -v jq >/dev/null 2>&1; then
  cp -p "$SSOT" "$SSOT.bak-$TS"
  while IFS='|' read -r ch port hit container project dir data root; do
    [ -n "${ch:-}" ] || continue
    _tmp="$SSOT.tmp.$$"
    if jq --arg ch "$ch" --arg d "$dir" --arg c "$container" --arg p "$project" --argjson port "${port:-0}" \
      '(.channels[$ch] //= {}) | .channels[$ch].dataDir=$d | .channels[$ch].container=$c | .channels[$ch].project=$p | .channels[$ch].port=$port' \
      "$SSOT" > "$_tmp"; then
      mv -f "$_tmp" "$SSOT"
      echo "  SSOT 对齐 $ch：dataDir=$dir container=$container project=$project port=$port"
    else
      rm -f "$_tmp"
      echo "  !! SSOT 对齐 $ch 失败（jq 报错），请人工检查 $SSOT" >&2
      FAILED=$((FAILED + 1))
    fi
  done <<EOF
$PLAN
EOF
else
  warn "jq 不可用或 SSOT 不存在 → 跳过 SSOT 自动对齐；请手工确认 channels.<ch>.dataDir 指向现有数据目录"
fi

# 4.2 每通道 install + switch + 验证（失败不中断，逐通道汇报）
while IFS='|' read -r ch port hit container project dir data root; do
  [ -n "${ch:-}" ] || continue
  echo
  echo "---- 通道 $ch ----"
  if [ "$MOVE_DATA" = 1 ] && [ -n "$data" ] && [ -n "$dir" ] && [ "$data" != "$dir/dsh-data" ]; then
    echo "  --move-data：把 $data 迁移到 $dir/dsh-data（原目录保留为 .moved-$TS）"
    mkdir -p "$dir"
    mv "$data" "$dir/dsh-data" && echo "  已移动数据目录"
  fi
  echo "  执行 install.sh（DSH_CHANNEL=$ch）"
  if ! DSH_CHANNEL="$ch" sh "$SELF_DIR/install.sh"; then
    echo "  !! install 失败（通道 $ch），跳过该通道；可修复后重跑本脚本（幂等）" >&2
    FAILED=$((FAILED + 1))
    continue
  fi
  echo "  执行 switch.sh（重建容器，约 1 分钟）"
  if ! DSH_CHANNEL="$ch" sh "$SELF_DIR/switch.sh"; then
    echo "  !! switch 失败（通道 $ch）—— 回滚：DSH_CHANNEL=$ch sh $SELF_DIR/rollback.sh" >&2
    FAILED=$((FAILED + 1))
    continue
  fi
  _h=$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo missing)
  _run=$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null || echo false)
  _code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || echo 000)
  echo "  验证：container=$container running=$_run health=$_h http(:$port)=$_code"
  if [ "$_run" != "true" ]; then
    echo "  !! 通道 $ch 容器未运行 —— 回滚：DSH_CHANNEL=$ch sh $SELF_DIR/rollback.sh" >&2
    FAILED=$((FAILED + 1))
  fi
done <<EOF
$PLAN
EOF

echo
echo "== 迁移完成 =="
echo "验证清单："
echo "  1) docker ps --format '{{.Names}} {{.Status}} {{.Ports}}' | grep -E 'dsh-'"
echo "  2) curl -s http://127.0.0.1:3082/version.json | head -40   # 两条通道 + cache.ssotIsFallback 应为 false"
echo "  3) scripts/dsh-safe-deploy status --channel all"
echo "回滚："
echo "  * 单通道：DSH_CHANNEL=<ch> sh $SELF_DIR/rollback.sh"
echo "  * compose：用 $DIR/docker-compose.yml.bak-$TS 覆盖回去后 DSH_CHANNEL=<ch> sh $SELF_DIR/switch.sh"
echo "  * SSOT：mv -f $SSOT.bak-$TS $SSOT"

[ "$FAILED" -eq 0 ] || { echo; echo "== 有 $FAILED 项未成功，请按上面提示处理 ==" >&2; exit 1; }
