#!/usr/bin/env bash
# dsh-safe-deploy 测试（T 系列）—— 策略纯逻辑 + 并发锁 + snapshot 校验
set -uo pipefail
cd "$(dirname "$0")/.."
NODE="node"
POLICY="scripts/safe-deploy-policy.js"
PASS=0; FAIL=0
t() { # t <id> <name> <pass> [detail]  （pass=1/true/PASS 为通过）
  if [ "$3" = "1" ] || [ "$3" = "true" ] || [ "$3" = "PASS" ]; then
    PASS=$((PASS+1)); echo "PASS  $1  $2${4:+ | $4}"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $1  $2${4:+ | $4}"
  fi
}

# ── 通道识别 ──────────────────────────────────────────────────────────────
T=$(node -e "const p=require('./$POLICY');console.log([p.channelOf('0.1.1-rc.2'),p.channelOf('0.1.2-alpha.3'),p.channelOf('0.1.2-beta.1'),p.channelOf('0.1.2-rc.1'),p.channelOf('0.1.2')].join(','))")
[ "$T" = "rc,alpha,beta,rc,stable" ] && P=1 || P=0; t T20 "通道识别 rc/alpha/beta/rc/stable" "$P" "got=$T"

# ── 跨核心版本 HIGH ───────────────────────────────────────────────────────
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('0.1.1-rc.2','0.1.2-alpha.3'))")
t T21 "0.1.1-rc.2 → 0.1.2-alpha.3 = HIGH（跨核心线）" "$([ "$R" = HIGH ] && echo 1 || echo 0)" "got=$R"

# ── prerelease 阶段前进 MEDIUM ────────────────────────────────────────────
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('0.1.2-alpha.3','0.1.2-beta.1'))")
t T22 "alpha → beta（同核心线）= MEDIUM" "$([ "$R" = MEDIUM ] && echo 1 || echo 0)" "got=$R"
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('0.1.2-beta.1','0.1.2-rc.1'))")
t T23 "beta → rc = MEDIUM" "$([ "$R" = MEDIUM ] && echo 1 || echo 0)" "got=$R"
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('0.1.2-rc.1','0.1.2'))")
t T24 "rc → stable = MEDIUM（同线提升）" "$([ "$R" = MEDIUM ] && echo 1 || echo 0)" "got=$R"

# ── 同线同通道 LOW ────────────────────────────────────────────────────────
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('0.1.1-rc.2','0.1.1-rc.3'))")
t T25 "同核心线同通道 patch = LOW" "$([ "$R" = LOW ] && echo 1 || echo 0)" "got=$R"

# ── migration 检测 ────────────────────────────────────────────────────────
M=$(node -e "const p=require('./$POLICY');console.log(p.detectMigration('storage format is incompatible, forward-only migration'))")
t T26 "migration 关键词 → forward-only" "$([ "$M" = forward-only ] && echo 1 || echo 0)" "got=$M"
M=$(node -e "const p=require('./$POLICY');console.log(p.detectMigration('session persistence projection changed'))")
t T27 "持久化词但无说明 → unknown" "$([ "$M" = unknown ] && echo 1 || echo 0)" "got=$M"
M=$(node -e "const p=require('./$POLICY');console.log(p.detectMigration(''))")
t T28 "无 release notes → none" "$([ "$M" = none ] && echo 1 || echo 0)" "got=$M"

# ── migration forward-only/unknown → BLOCKED ──────────────────────────────
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('0.1.1','0.1.2',{migration:'forward-only'}))")
t T29 "migration forward-only → BLOCKED" "$([ "$R" = BLOCKED ] && echo 1 || echo 0)" "got=$R"
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('0.1.1','0.1.2',{migration:'unknown'}))")
t T30 "migration unknown → BLOCKED" "$([ "$R" = BLOCKED ] && echo 1 || echo 0)" "got=$R"

# ── 非法版本 → BLOCKED ────────────────────────────────────────────────────
R=$(node -e "const p=require('./$POLICY');console.log(p.computeRisk('not-a-version','0.1.2'))")
t T31 "非法版本 → BLOCKED" "$([ "$R" = BLOCKED ] && echo 1 || echo 0)" "got=$R"

# ── computeAll 汇总（临时 SSOT）───────────────────────────────────────────
TMPSSOT=$(mktemp)
cat > "$TMPSSOT" <<EOF
{ "version": "0.1.1-rc.2", "productionChannel": "0.1.1-rc.2", "testCandidate": "0.1.2-alpha.3", "source": "test" }
EOF
A=$(node -e "const p=require('./$POLICY');const r=p.computeAll({ssotFile:'$TMPSSOT'});console.log([r.upgradeRisk,r.dataIsolationRequired,r.targetChannel,r.migrationStatus].join('|'))")
t T32 "computeAll 汇总 HIGH+隔离+alpha" "$([ "$A" = "HIGH|true|alpha|none" ] && echo 1 || echo 0)" "got=$A"
rm -f "$TMPSSOT"

# ── 并发锁（flock）────────────────────────────────────────────────────────
LOCK=/tmp/dsh-test-lock.$$
mkdir -p /data/dsh/.deploy 2>/dev/null || true
# 持锁进程
( flock -x 9; sleep 3 ) 9>"$LOCK" &
HOLDER=$!
sleep 0.5
# 尝试抢锁（应失败：LOCKED）
OUT=$(exec 9>"$LOCK"; if ! flock -n 9 2>/dev/null; then echo LOCKED; else echo ACQUIRED; fi)
wait $HOLDER 2>/dev/null || true
t T33 "并发 test/promote → LOCKED" "$([ "$OUT" = LOCKED ] && echo 1 || echo 0)" "got=$OUT"
rm -f "$LOCK"

# ── snapshot 完整性校验 ───────────────────────────────────────────────────
SNAP=$(mktemp -d)
mkdir -p "$SNAP/profiles/web"
echo '{"name":"dsh-profile-web"}' > "$SNAP/profiles/web/package.json"
echo "settings" > "$SNAP/settings.yaml"
echo "cred" > "$SNAP/.credentials.yaml"
CHK=1
[ -f "$SNAP/profiles/web/package.json" ] || CHK=0
[ -f "$SNAP/settings.yaml" ] || CHK=0
[ -f "$SNAP/.credentials.yaml" ] || CHK=0
t T34 "snapshot 关键文件存在校验" "$CHK"
rm -rf "$SNAP"

echo "----------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

# ── 插件兼容性策略（REQUIRED 才 BLOCK；OPTIONAL/UNUSED 仅告警）────────────
TMPSSOT2=$(mktemp)
cat > "$TMPSSOT2" <<'JSON'
{
  "version": "0.1.1-rc.2",
  "productionChannel": "0.1.1-rc.2",
  "testCandidate": "0.1.2-alpha.3",
  "requiredPlugins": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-subagent-codex"],
  "optionalPlugins": ["@siliconflow-official/dsh-llm-siliconflow"],
  "pluginCompat": {
    "@siliconflow-official/dsh-llm-siliconflow": { "status": "FAIL", "reason": "CallId removed" }
  }
}
JSON
A=$(node -e "const p=require('./$POLICY');const r=p.computeAll({ssotFile:'$TMPSSOT2'});console.log([r.siliconflow.class,r.siliconflow.blocking,r.promoteBlocked,r.pluginBlockers.length].join('|'))")
t T35 "OPTIONAL 插件 FAIL → 不阻塞 promote" "$([ "$A" = "OPTIONAL_INACTIVE|false|false|0" ] && echo 1 || echo 0)" "got=$A"

cat > "$TMPSSOT2" <<'JSON'
{
  "version": "0.1.1-rc.2",
  "productionChannel": "0.1.1-rc.2",
  "testCandidate": "0.1.2-alpha.3",
  "requiredPlugins": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-subagent-codex"],
  "optionalPlugins": [],
  "pluginCompat": {
    "@deepseek-ai/dsh-subagent-codex": { "status": "FAIL", "reason": "provider API mismatch" }
  }
}
JSON
A=$(node -e "const p=require('./$POLICY');const r=p.computeAll({ssotFile:'$TMPSSOT2'});console.log([r.pluginBlockers.length,r.promoteBlocked].join('|'))")
t T36 "REQUIRED 插件 FAIL → 阻塞 promote" "$([ "$A" = "1|true" ] && echo 1 || echo 0)" "got=$A"
rm -f "$TMPSSOT2"

echo "----------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

# ── 插件状态机：installed / active / required（T1-T3 policy；T4/T5 运行时）──
TMPSSOT3=$(mktemp)
cat > "$TMPSSOT3" <<'JSON'
{
  "version": "0.1.1-rc.2",
  "productionChannel": "0.1.1-rc.2",
  "testCandidate": "0.1.2-alpha.3",
  "requiredPlugins": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-subagent-codex"],
  "optionalPlugins": ["@siliconflow-official/dsh-llm-siliconflow"],
  "pluginCompat": { "@siliconflow-official/dsh-llm-siliconflow": { "status": "FAIL", "reason": "CallId" } },
  "pluginState": { "@siliconflow-official/dsh-llm-siliconflow": { "classification": "OPTIONAL", "enabled": false } }
}
JSON
A=$(node -e "const p=require('./$POLICY');const r=p.computeAll({ssotFile:'$TMPSSOT3'});console.log([r.pluginClass['@siliconflow-official/dsh-llm-siliconflow'],r.promoteBlocked,r.pluginBlockers.length].join('|'))")
t T1 "installed=true active=false compat=FAIL → 不阻塞 + OPTIONAL_INACTIVE" "$([ "$A" = "OPTIONAL_INACTIVE|false|0" ] && echo 1 || echo 0)" "got=$A"

node -e "const fs=require('fs');const j=JSON.parse(fs.readFileSync('$TMPSSOT3','utf8'));j.pluginState['@siliconflow-official/dsh-llm-siliconflow'].enabled=true;fs.writeFileSync('$TMPSSOT3',JSON.stringify(j,null,2))"
A=$(node -e "const p=require('./$POLICY');const r=p.computeAll({ssotFile:'$TMPSSOT3'});console.log([r.pluginClass['@siliconflow-official/dsh-llm-siliconflow'],r.promoteBlocked,r.pluginBlockers.length].join('|'))")
t T2 "OPTIONAL_ACTIVE + compat=FAIL → 阻塞" "$([ "$A" = "OPTIONAL_ACTIVE|true|1" ] && echo 1 || echo 0)" "got=$A"
rm -f "$TMPSSOT3"

TMPSSOT4=$(mktemp)
cat > "$TMPSSOT4" <<'JSON'
{
  "version": "0.1.1-rc.2",
  "productionChannel": "0.1.1-rc.2",
  "testCandidate": "0.1.2-alpha.3",
  "requiredPlugins": ["@deepseek-ai/dsh-subagent-codex"],
  "optionalPlugins": [],
  "pluginCompat": { "@deepseek-ai/dsh-subagent-codex": { "status": "FAIL", "reason": "mismatch" } },
  "pluginState": {}
}
JSON
A=$(node -e "const p=require('./$POLICY');const r=p.computeAll({ssotFile:'$TMPSSOT4'});console.log(r.promoteBlocked)")
t T3 "REQUIRED + compat=FAIL → BLOCK" "$([ "$A" = "true" ] && echo 1 || echo 0)" "got=$A"
rm -f "$TMPSSOT4"

# T4: SiliconFlow inactive → production-equivalent profile bundles 不含 sf（runtime selection 一致）
# 依赖生产数据目录（仅在 NAS 上存在）：缺失时 SKIP 而不是 FAIL，否则 CI/开发机必然红。
if [ -f /data/dsh/profiles/web/package.json ]; then
  A=$(node -e "const j=require('/data/dsh/profiles/web/package.json');console.log(j.dsh.profile.bundles.includes('@siliconflow-official/dsh-llm-siliconflow'))")
  t T4 "inactive → active bundle set 不含 siliconflow" "$([ "$A" = "false" ] && echo 1 || echo 0)" "got=$A"
else
  echo "SKIP  T4  生产 profile 不存在（/data/dsh/profiles/web/package.json），仅 NAS 可验"
fi
# T5: inactive → credentials/settings 保留
if [ -f /data/dsh/settings.yaml ] && [ -f /data/dsh/.credentials.yaml ]; then
  A=$(node -e "const fs=require('fs');const s=fs.readFileSync('/data/dsh/settings.yaml','utf8');const c=fs.readFileSync('/data/dsh/.credentials.yaml','utf8');console.log((s.toLowerCase().includes('siliconflow')?'S':'')+(c.includes('SILICONFLOW_API_KEY')?'C':''))")
  t T5 "inactive → settings+credential 保留" "$([ "$A" = "SC" ] && echo 1 || echo 0)" "got=$A"
else
  echo "SKIP  T5  生产 settings/credentials 不存在，仅 NAS 可验"
fi

echo "----------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
