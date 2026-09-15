#!/usr/bin/env bash
# test-auto-upgrade.sh -- 离线验证 auto-upgrade.sh 的决策/门禁/修复/回滚分支
# docker、dsh-safe-deploy、preflight、修复工具全部用桩；不联网、不碰真实主机。
set -u
REPO=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
t() { if [ "$3" = "1" ]; then PASS=$((PASS+1)); echo "PASS  $1  $2"; else FAIL=$((FAIL+1)); echo "FAIL  $1  $2  [$4]"; fi; }

R=$TMP/repo
mkdir -p "$R/scripts" "$R/nas" "$TMP/bin" "$TMP/fix/dsh-data"
cp "$REPO/nas/auto-upgrade.sh" "$R/nas/auto-upgrade.sh"

cat > "$R/dsh-version.json" <<J
{ "schemaVersion": 2, "primaryChannel": "alpha",
  "channels": { "alpha": { "dataDir": "$TMP/fix", "dshHome": "/data/dsh", "container": "dsh-alpha",
  "production": "1.0.0", "candidate": "1.0.1" } } }
J

cat > "$R/scripts/safe-deploy-policy.js" <<'JS'
const i = process.argv.indexOf('--channel');
const ch = i >= 0 ? process.argv[i + 1] : 'alpha';
const p = { channel: ch, currentVersion: process.env.T_CUR || '', testCandidate: process.env.T_CAND || '',
  upgradeRisk: process.env.T_RISK || 'LOW', migrationStatus: process.env.T_MIG || 'none',
  promoteBlocked: (process.env.T_BLOCKED || '') === '1', otherBlockers: [] };
process.stdout.write(JSON.stringify(p));
JS

cat > "$R/scripts/dsh-safe-deploy" <<'SH'
#!/usr/bin/env bash
echo "SAFE $*" >> "$TEST_DIR/safe-calls"
case "$1" in
  test) [ -f "$TEST_DIR/test-fail" ] && exit 1; exit 0 ;;
  promote) [ -f "$TEST_DIR/promote-fail" ] && exit 1; exit 0 ;;
esac
exit 0
SH
chmod +x "$R/scripts/dsh-safe-deploy"

cat > "$R/nas/preflight-workspace.js" <<'JS'
const fs = require('fs');
const d = process.env.TEST_DIR;
let n = 0;
try { n = Number(fs.readFileSync(d + '/pf-count', 'utf8')); } catch (e) {}
fs.writeFileSync(d + '/pf-count', String(n + 1));
const f = n > 0 ? (d + '/pf-after.json') : (d + '/pf-before.json');
process.stdout.write(fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '{"findings":[]}');
JS

cat > "$R/nas/migrate-preset-persona.js" <<'JS'
require('fs').appendFileSync(process.env.TEST_DIR + '/repair-calls', 'persona\n');
JS
cat > "$R/nas/repair-session-turns.js" <<'JS'
require('fs').appendFileSync(process.env.TEST_DIR + '/repair-calls', 'session ' + process.argv[2] + '\n');
JS

cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "inspect" ]; then
  for a in "$@"; do
    case "$a" in
      *State.Running*) if [ -n "$T_RUNNING" ]; then echo "$T_RUNNING"; else echo true; fi; exit 0 ;;
      *State.Health*) if [ -n "$T_HEALTH" ]; then echo "$T_HEALTH"; else echo healthy; fi; exit 0 ;;
    esac
  done
fi
exit 0
SH
chmod +x "$TMP/bin/docker"
# 桩 zstd：orchestrator 只用 command -v zstd 判断"宿主是否具备会话体检能力"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TMP/bin/zstd"
chmod +x "$TMP/bin/zstd"

EXTRA=""
HOOK=""
PF_AFTER='{"findings":[]}'
scenario() { # cur cand risk mig blocked built pf-before health
  SD=$(mktemp -d)
  : > "$SD/safe-calls"
  : > "$SD/repair-calls"
  printf '%s' "$7" > "$SD/pf-before.json"
  printf '%s' "$PF_AFTER" > "$SD/pf-after.json"
  printf '{"channels":{"alpha":{"build":{"target":"%s","targetBuilt":%s}}}}\n' "$2" "$6" > "$SD/version.json"
  if [ -n "$HOOK" ]; then eval "$HOOK"; fi
  TEST_DIR="$SD" PATH="$TMP/bin:$PATH" DSH_AUTO_ALLOW_NONROOT=1 DSH_AUTO_STATE="$SD/state" \
    DSH_AUTO_VERSION_JSON="$SD/version.json" DSH_AUTO_OBSERVE_CHECKS=1 DSH_AUTO_OBSERVE_INTERVAL=1 \
    T_CUR="$1" T_CAND="$2" T_RISK="$3" T_MIG="$4" T_BLOCKED="$5" T_HEALTH="$8" \
    bash "$R/nas/auto-upgrade.sh" --channel alpha --observe-secs 2 $EXTRA > "$SD/out.log" 2>&1
}

# A: 无候选（cand==cur）
EXTRA=""; HOOK=""
scenario 1.0.0 1.0.0 LOW none 0 true '{"findings":[]}' healthy
t A1 "无候选 -> 跳过" "$(grep -q '无候选' "$SD/out.log" && echo 1 || echo 0)" "$(tail -1 "$SD/out.log")"
t A2 "无候选 -> 不调用 safe-deploy" "$([ -s "$SD/safe-calls" ] && echo 0 || echo 1)" ""

# B: LOW happy path（candidate 推进 + test + promote + 观察窗）
EXTRA=""; HOOK=""
scenario 1.0.0 1.0.1 LOW none 0 true '{"findings":[]}' healthy
t B1 "happy: check/test/promote 被调用" "$(grep -q 'SAFE test --channel alpha' "$SD/safe-calls" && grep -q 'SAFE promote --channel alpha' "$SD/safe-calls" && echo 1 || echo 0)" "$(cat "$SD/safe-calls")"
t B2 "happy: 观察窗通过" "$(grep -q '观察窗通过' "$SD/out.log" && echo 1 || echo 0)" ""
t B3 "happy: 审计 success" "$(grep -q '"verdict":"success"' "$SD/state/auto-upgrade.jsonl" && echo 1 || echo 0)" ""

# C: migration forward-only -> 停
EXTRA=""; HOOK=""
scenario 1.0.0 1.0.1 LOW forward-only 0 true '{"findings":[]}' healthy
t C1 "forward-only -> STOP" "$(grep -q 'STOP: migration=forward-only' "$SD/out.log" && echo 1 || echo 0)" ""
t C2 "forward-only -> 不 promote" "$(grep -q 'promote' "$SD/safe-calls" && echo 0 || echo 1)" ""

# D: promoteBlocked -> 停
EXTRA=""; HOOK=""
scenario 1.0.0 1.0.1 MEDIUM none 1 true '{"findings":[]}' healthy
t D1 "blocked -> STOP" "$(grep -q 'STOP: promoteBlocked' "$SD/out.log" && echo 1 || echo 0)" ""

# E: HIGH 无 --allow-high -> 停；加 --allow-high -> 带 --force promote
EXTRA=""; HOOK=""
scenario 1.0.0 1.0.1 HIGH none 0 true '{"findings":[]}' healthy
t E1 "HIGH 无 allow -> STOP" "$(grep -q 'STOP: risk=HIGH' "$SD/out.log" && echo 1 || echo 0)" ""
EXTRA="--allow-high"; HOOK=""
scenario 1.0.0 1.0.1 HIGH none 0 true '{"findings":[]}' healthy
t E2 "HIGH + allow -> promote --force" "$(grep -q 'SAFE promote --channel alpha --force' "$SD/safe-calls" && echo 1 || echo 0)" "$(cat "$SD/safe-calls")"

# F: test 失败 -> 不 promote
EXTRA=""; HOOK='touch "$SD/test-fail"'
scenario 1.0.0 1.0.1 LOW none 0 true '{"findings":[]}' healthy
t F1 "test FAIL -> 不 promote" "$(grep -q 'promote' "$SD/safe-calls" && echo 0 || echo 1)" ""
t F2 "test FAIL -> 记录" "$(grep -q 'test FAIL' "$SD/out.log" && echo 1 || echo 0)" ""

# G: 观察窗不健康 -> 自动 rollback
EXTRA=""; HOOK=""
scenario 1.0.0 1.0.1 LOW none 0 true '{"findings":[]}' unhealthy
t G1 "unhealthy -> rollback" "$(grep -q 'SAFE rollback --channel alpha' "$SD/safe-calls" && echo 1 || echo 0)" "$(cat "$SD/safe-calls")"
t G2 "unhealthy -> 审计 rolled-back" "$(grep -q '"verdict":"rolled-back"' "$SD/state/auto-upgrade.jsonl" && echo 1 || echo 0)" ""

# H: preflight 有可修复项 -> 自动修复后放行
EXTRA=""; HOOK=""
scenario 1.0.0 1.0.1 LOW none 0 true '{"findings":[{"sev":"fail","code":"S2","target":"sessions/a.v2.jsonl.zstd"}]}' healthy
t H1 "repair: persona 迁移被调用" "$(grep -q persona "$SD/repair-calls" && echo 1 || echo 0)" "$(cat "$SD/repair-calls")"
t H2 "repair: session 修复被调用" "$(grep -q session "$SD/repair-calls" && echo 1 || echo 0)" ""
t H3 "repair 后 -> promote" "$(grep -q 'SAFE promote' "$SD/safe-calls" && echo 1 || echo 0)" ""

# I: 修复后仍有阻塞 -> 停
EXTRA=""; HOOK=""
PF_AFTER='{"findings":[{"sev":"fail","code":"S1","target":"sessions/b.v2.jsonl.zstd"}]}'
scenario 1.0.0 1.0.1 LOW none 0 true '{"findings":[{"sev":"fail","code":"S1","target":"sessions/b.v2.jsonl.zstd"}]}' healthy
t I1 "修复后仍阻塞 -> STOP" "$(grep -q 'STOP: 修复后仍有' "$SD/out.log" && echo 1 || echo 0)" "$(tail -2 "$SD/out.log")"
PF_AFTER='{"findings":[]}'

# ---- PART 2: 真实 migrate-preset-persona.js（不桩）--------------------------
MIG=$TMP/mig
mkdir -p "$MIG/.agent-presets/old" "$MIG/.agent-presets/modern" "$MIG/.agent-presets/broken"
cat > "$MIG/.agent-presets/old/agent.cordis.yml" <<'YML'
- id: persona
  name: '@deepseek-ai/dsh-persona'
  config:
    text: >-
      hello {{cwd}}
    suffix: 
YML
cat > "$MIG/.agent-presets/modern/agent.cordis.yml" <<'YML'
- id: persona
  config:
    prefix: >-
      hi
YML
cat > "$MIG/.agent-presets/broken/agent.cordis.yml" <<'YML'
- id: persona
  config:
    suffix: x
YML
MIGOUT=$(node "$REPO/nas/migrate-preset-persona.js" --home "$MIG" --apply 2>&1)
MIGRC=$?
t M1 "迁移输出 MIGRATED old" "$(printf '%s' "$MIGOUT" | grep -q 'MIGRATED old' && echo 1 || echo 0)" "$MIGOUT"
t M2 "双写：old 同含 prefix 与 text" "$(grep -q 'prefix: >-' "$MIG/.agent-presets/old/agent.cordis.yml" && grep -q 'text: >-' "$MIG/.agent-presets/old/agent.cordis.yml" && echo 1 || echo 0)" ""
t M3 "迁移前已备份" "$(find "$MIG/_preset-backups" -name agent.cordis.yml 2>/dev/null | grep -q . && echo 1 || echo 0)" ""
t M4 "不可修 preset -> rc=1" "$([ "$MIGRC" = "1" ] && echo 1 || echo 0)" "rc=$MIGRC"
t M5 "modern 未被改动" "$(grep -q 'prefix' "$MIG/.agent-presets/modern/agent.cordis.yml" && echo 1 || echo 0)" ""

echo
echo "----------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
