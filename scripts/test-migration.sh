#!/usr/bin/env bash
# migrate-to-dual-channel.sh 的离线测试（docker 桩；不联网、不碰真实主机）。
# 重点验证"迁移不丢数据"的核心不变量：现有容器的数据目录会被对齐进 SSOT，
# 而不是被换成新的空目录。
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t() { if [ "$3" = "1" ]; then PASS=$((PASS+1)); echo "PASS  $1  $2${4:+ | $4}"; else FAIL=$((FAIL+1)); echo "FAIL  $1  $2${4:+ | $4}"; fi; }

mkdir -p "$TMP/bin" "$TMP/repo"
cp -a "$REPO/nas" "$TMP/repo/nas"
cp "$REPO/dsh-version.json" "$TMP/repo/dsh-version.json"

# docker 桩：模拟"alpha 跑在旧目录 deepseek-harness(3081)，rc 已符合新布局(3083)"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "info ") exit 0 ;;
  "ps -a") echo deepseek-harness; echo dsh-rc; exit 0 ;;
esac
if [ "$1" = "inspect" ]; then
  c="$2"; shift 2; fmt=""
  while [ $# -gt 0 ]; do case "$1" in --format) fmt="$2"; shift 2;; *) shift;; esac; done
  case "$c" in
    deepseek-harness)
      case "$fmt" in
        *Config.Image*) echo "ghcr.io/llzg/dsh-docker:0.1.3-alpha.2" ;;
        *com.docker.compose.project*) echo "deepseek-harness" ;;
        *"State.Health"*) echo "healthy" ;;
        *"/data/dsh"*) echo "/volume1/docker/deepseek-harness/dsh-data" ;;
        *"/root"*) echo "/volume1/docker/deepseek-harness/dsh-root" ;;
        *NetworkSettings.Ports*) echo "3081 " ;;
        *) echo "" ;;
      esac ;;
    dsh-rc)
      case "$fmt" in
        *Config.Image*) echo "ghcr.io/llzg/dsh-docker:0.1.2-rc.1" ;;
        *com.docker.compose.project*) echo "dsh-rc" ;;
        *"State.Health"*) echo "healthy" ;;
        *"/data/dsh"*) echo "/volume1/docker/dsh-rc/dsh-data" ;;
        *"/root"*) echo "/volume1/docker/dsh-rc/dsh-root" ;;
        *NetworkSettings.Ports*) echo "3083 " ;;
        *) echo "" ;;
      esac ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/docker"

run_dry() {
  ( cd "$TMP/repo/nas" && PATH="$TMP/bin:$PATH" \
      DSH_SSOT="$TMP/repo/dsh-version.json" DSH_DEPLOY_STATE="$TMP/state" \
      sh ./migrate-to-dual-channel.sh 2>&1 )
}

OUT="$(run_dry)"; RC=$?
t M1 "dry-run 退出码 0" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "rc=$RC"
t M2 "识别出两个现有容器" "$(printf '%s' "$OUT" | grep -q 'deepseek-harness' && printf '%s' "$OUT" | grep -q 'dsh-rc' && echo 1 || echo 0)"
t M3 "alpha 对齐到现有数据目录（不换空目录）" \
  "$(printf '%s' "$OUT" | grep -q 'dataDir /volume1/docker/dsh-alpha → /volume1/docker/deepseek-harness' && echo 1 || echo 0)"
t M4 "rc 复用已匹配目录" "$(printf '%s' "$OUT" | grep -q '复用现有目录 /volume1/docker/dsh-rc' && echo 1 || echo 0)"
t M5 "明确声明不移动数据目录" "$(printf '%s' "$OUT" | grep -q '数据目录：不移动' && echo 1 || echo 0)"
t M6 "dry-run 不修改 SSOT" \
  "$([ "$(node -e 'const j=require(process.argv[1]);console.log(j.channels.alpha.dataDir||"")' "$TMP/repo/dsh-version.json")" = "/volume1/docker/dsh-alpha" ] && echo 1 || echo 0)"

# --apply：应写 SSOT（对齐 dataDir），并在 install 失败时逐通道报告、不整体崩溃
OUT2="$( ( cd "$TMP/repo/nas" && PATH="$TMP/bin:$PATH" \
      DSH_SSOT="$TMP/repo/dsh-version.json" DSH_DEPLOY_STATE="$TMP/state" \
      sh ./migrate-to-dual-channel.sh --apply 2>&1 ) )"; RC2=$?
NEWDIR="$(node -e 'const j=require(process.argv[1]);console.log(j.channels.alpha.dataDir||"")' "$TMP/repo/dsh-version.json")"
t M7 "--apply 把 SSOT 的 alpha.dataDir 对齐到现有目录" "$([ "$NEWDIR" = "/volume1/docker/deepseek-harness" ] && echo 1 || echo 0)" "got=$NEWDIR"
t M8 "--apply 备份了 SSOT" "$(ls "$TMP"/repo/dsh-version.json.bak-* >/dev/null 2>&1 && echo 1 || echo 0)"
t M9 "--apply 失败时逐通道报告且退出非 0" "$([ "$RC2" -ne 0 ] && printf '%s' "$OUT2" | grep -q 'install 失败' && echo 1 || echo 0)" "rc=$RC2"
( cd "$TMP/repo/nas" && sh ./migrate-to-dual-channel.sh --bogus >/dev/null 2>&1 ); RC3=$?
t M10 "参数校验：未知参数 exit 2" "$([ "$RC3" = "2" ] && echo 1 || echo 0)" "rc=$RC3"

echo
echo "----------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
