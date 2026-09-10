#!/usr/bin/env bash
# patch-dsh.sh 的离线回归测试（合成夹具，不联网、不需要 docker）。
#
# 重点守护 2026-09-10 的事故：token-pinning 补丁只在"容器可写层 + workspace 副本"里，
# 仓库里没有 → 重建容器后 DSH 生成新 launch token → host 网络代理 401。
# 现在它必须在仓库里、必须有 marker、锚点失配必须让构建失败。
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t() { if [ "$3" = "1" ]; then PASS=$((PASS+1)); echo "PASS  $1  $2${4:+ | $4}"; else FAIL=$((FAIL+1)); echo "FAIL  $1  $2${4:+ | $4}"; fi; }

PATCH="$REPO/patch-dsh.sh"

# ── 1) 仓库里必须存在 token-pinning 补丁段 ────────────────────────────────
grep -q 'dsh-docker-patch:token-pinning' "$PATCH" && P=1 || P=0
t P1 "patch-dsh.sh 含 token-pinning marker" "$P"
grep -q 'DSH_LAUNCH_TOKEN' "$PATCH" && P=1 || P=0
t P2 "token-pinning 认 DSH_LAUNCH_TOKEN" "$P"
grep -q 'verify_marker "$TOKEN_FILE" token-pinning' "$PATCH" && P=1 || P=0
t P3 "STRICT 正向校验 token-pinning" "$P"
# token-pinning 的 verify 不得被塞进 favicon 的 if 块（图标缺失时就不会校验）
awk '/if \[ -f "\$ICON" \] && \[ -f "\$MAKE_FAVICON" \]/{f=1} f&&/token-pinning/{print "INSIDE"; exit} /^fi$/{f=0}' "$PATCH" | grep -q INSIDE && P=0 || P=1
t P4 "token-pinning verify 独立于图标条件" "$P"

# ── 2) 构造"只让 token-pinning 相关"的合成夹具 ───────────────────────────
#    index.js: token-pinning 锚点 + privileged-loopback 已满足形态（否则该补丁会 FAIL 干扰 rc）
#    client.js: randomuuid 锚点
mkdir -p "$TMP/base/dsh-client-connection/lib"
python3 - "$PATCH" "$TMP/base" <<'PY'
import re, sys, os
patch = open(sys.argv[1], encoding='utf-8').read()
base = sys.argv[2]
pat = r"old_fn = " + "'''" + r"(function processLaunchToken\(owner\) \{.*?\n\})" + "'''"
m = re.search(pat, patch, re.S)
if not m:
    sys.exit("无法从 patch-dsh.sh 抽出 token-pinning 锚点")
anchor = m.group(1)
idx = os.path.join(base, "dsh-client-connection", "lib", "index.js")
with open(idx, "w", encoding="utf-8") as fh:
    fh.write("// synthetic fixture\n" + anchor + "\n")
    fh.write("// privileged-loopback 已由上游满足\n")
    fh.write("function isTrustedApiRequest(request, this.trustedHosts) { return trustedHosts.length > 0; }\n")
with open(os.path.join(base, "dsh-client-connection", "lib", "client.js"), "w", encoding="utf-8") as fh:
    fh.write("window.__ModuleLoader__.load({ id: 'x' });\n")
print("锚点已抽出，行数:", anchor.count("\n") + 1)
PY
[ -s "$TMP/base/dsh-client-connection/lib/index.js" ] && P=1 || P=0
t P5 "抽出的锚点非空（补丁结构可解析）" "$P"

# ── 3) 正向：打补丁必须成功、写 marker、STRICT 全绿 ───────────────────────
OUT=$(DSH_PATCH_BASE="$TMP/base" STRICT=1 DSH_ICON=/nonexistent bash "$PATCH" 2>&1); RC=$?
grep -q 'dsh-docker-patch:token-pinning' "$TMP/base/dsh-client-connection/lib/index.js" && M=1 || M=0
t P6 "正向：锚点命中 → 函数被改写并写 marker" "$([ "$M" = "1" ] && echo 1 || echo 0)"
printf '%s' "$OUT" | grep -q 'verify: token-pinning OK' && P=1 || P=0
t P7 "正向：STRICT 打印 verify: token-pinning OK" "$P"
t P7b "正向：整体 STRICT 通过（exit 0）" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "rc=$RC"

# ── 4) 幂等：再跑一次不应重复改 ──────────────────────────────────────────
S1=$(md5sum "$TMP/base/dsh-client-connection/lib/index.js" | cut -d' ' -f1)
DSH_PATCH_BASE="$TMP/base" STRICT=1 DSH_ICON=/nonexistent bash "$PATCH" >/dev/null 2>&1 || true
S2=$(md5sum "$TMP/base/dsh-client-connection/lib/index.js" | cut -d' ' -f1)
t P8 "幂等：二次运行结果不变" "$([ "$S1" = "$S2" ] && echo 1 || echo 0)"

# ── 5) 反向 A：锚点失配（无 marker）→ 必须 exit 1 ─────────────────────────
mkdir -p "$TMP/bad/dsh-client-connection/lib"
python3 - "$TMP/base/dsh-client-connection/lib/index.js" "$TMP/pristine.js" <<'PY'
import sys
s = open(sys.argv[1], encoding='utf-8').read()
s = s.replace("// dsh-docker-patch:token-pinning\n", "")
s = s.replace("\tconst pinned = process.env.DSH_LAUNCH_TOKEN;\n", "")
open(sys.argv[2], 'w', encoding='utf-8').write(s)
PY
sed 's/function processLaunchToken(owner) {/function processLaunchTokenRenamed(owner) {/' \
  "$TMP/pristine.js" > "$TMP/bad/dsh-client-connection/lib/index.js"
cp "$TMP/base/dsh-client-connection/lib/client.js" "$TMP/bad/dsh-client-connection/lib/client.js"
DSH_PATCH_BASE="$TMP/bad" STRICT=1 DSH_ICON=/nonexistent bash "$PATCH" > "$TMP/neg.log" 2>&1; RC=$?
t P9 "反向：锚点失配 → exit 1" "$([ "$RC" -eq 1 ] && echo 1 || echo 0)" "rc=$RC"
grep -q 'VERIFY FAIL: anchor missing token-pinning' "$TMP/neg.log" && P=1 || P=0
t P10 "反向：报错指明 anchor missing token-pinning" "$P"

# ── 6) 反向 B：marker 被删（锚点已被改写）→ 校验必须失败 ─────────────────
mkdir -p "$TMP/nomarker/dsh-client-connection/lib"
sed 's#// dsh-docker-patch:token-pinning#// marker-removed#' \
  "$TMP/base/dsh-client-connection/lib/index.js" > "$TMP/nomarker/dsh-client-connection/lib/index.js"
cp "$TMP/base/dsh-client-connection/lib/client.js" "$TMP/nomarker/dsh-client-connection/lib/client.js"
DSH_PATCH_BASE="$TMP/nomarker" STRICT=1 DSH_ICON=/nonexistent bash "$PATCH" > "$TMP/nm.log" 2>&1; RC=$?
grep -q 'marker missing for token-pinning' "$TMP/nm.log" && P=1 || P=0
t P11 "反向：marker 丢失 → 校验失败" "$P" "rc=$RC"

echo
echo "----------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
