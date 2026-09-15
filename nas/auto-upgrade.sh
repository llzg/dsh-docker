#!/usr/bin/env bash
# auto-upgrade.sh -- 带门禁的全自动升级编排（alpha / rc）
#
# 定位：把已有成熟工具按安全顺序串起来，不重复实现它们的能力：
#   check/preflight -> 自动修复（可安全修的那部分）-> test（隔离实例）
#   -> 门禁判定 -> promote -> 观察窗 -> 失败自动 rollback -> 审计
#
# 唯一 authority：
#   版本发现：Renovate（或本脚本 --advance 从版本页 3082 的 build.target/targetBuilt 推进 candidate）
#   构建    ：CI（不可变镜像 + build-status.json）
#   数据安全：scripts/dsh-safe-deploy（snapshot / 隔离测试 / 事务化 promote / rollback）
#   本脚本  ：只做编排 + 门禁 + 自动修复 + 观察窗，绝不自己实现 compose/pin/snapshot。
#
# 必须 root 运行：工作区目录多为 0700 root，普通用户跑 preflight 会假报干净。
#
# 用法：sudo bash auto-upgrade.sh [--channel alpha|rc|all] [--dry-run] [--allow-high]
#                                [--no-repair] [--no-advance] [--observe-secs N]
# 退出码：0=正常（含无事可做）；2=用法/环境错误；3=已有实例在跑
#
# 安全边界（遇到即停、不自动上线）：
#   * migration = forward-only / unknown（数据不可逆）
#   * promoteBlocked = true（版本级阻塞或 REQUIRED 插件 FAIL）
#   * risk = HIGH 且未显式 --allow-high
#   * 自动修复后 preflight 仍有 fail
#   * test 未 PASS
set -eo pipefail

SELF_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_DIR=$(CDPATH= cd "$SELF_DIR/.." && pwd)
SAFE=scripts/dsh-safe-deploy
PREFLIGHT=nas/preflight-workspace.js
PERSONA=nas/migrate-preset-persona.js
REPAIR=nas/repair-session-turns.js

CH=all
DRY=0
ALLOW_HIGH=0
DO_REPAIR=1
DO_ADVANCE=1
OBSERVE=180
while [ $# -gt 0 ]; do
  case "$1" in
    --channel)      CH="$2"; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    --allow-high)   ALLOW_HIGH=1; shift ;;
    --no-repair)    DO_REPAIR=0; shift ;;
    --no-advance)   DO_ADVANCE=0; shift ;;
    --observe-secs) OBSERVE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" != "0" ] && [ "$DSH_AUTO_ALLOW_NONROOT" != "1" ]; then
  echo "ERROR: 必须以 root 运行（preflight/修复需读 0700 root 的工作区；普通用户会假报干净）" >&2
  exit 2
fi

SSOT=$DSH_SSOT
[ -n "$SSOT" ] || SSOT=$REPO_DIR/dsh-version.json
IMAGE_BASE=$DSH_IMAGE_BASE
[ -n "$IMAGE_BASE" ] || IMAGE_BASE=ghcr.io/llzg/dsh-docker
STATE=$DSH_AUTO_STATE
[ -n "$STATE" ] || STATE=$REPO_DIR/state
VERSION_URL=$DSH_AUTO_VERSION_URL
[ -n "$VERSION_URL" ] || VERSION_URL=http://127.0.0.1:3082/version.json

[ -f "$SSOT" ] || { echo "ERROR: SSOT 不存在：$SSOT" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: 找不到 docker（需在 NAS 宿主上运行）" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "ERROR: 找不到 node" >&2; exit 2; }

mkdir -p "$STATE"
LOG=$STATE/auto-upgrade.log
log() { local m; m="$(date -Is) $*"; echo "$m"; echo "$m" >> "$LOG"; }

exec 9>"$STATE/auto-upgrade.lock"
if ! flock -n 9; then log "已有 auto-upgrade 实例在跑，退出"; exit 3; fi

# ---- node 小工具（读 JSON 字段）--------------------------------------------
jget() {
  printf '%s' "$1" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const j=JSON.parse(s);const v=j[process.argv[1]];process.stdout.write(v==null?'':(typeof v==='object'?JSON.stringify(v):String(v)))}catch(e){process.exit(1)}})" "$2"
}
vfield() { # <version-json> <channel> <dotted>
  printf '%s' "$1" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{let j={};try{j=JSON.parse(s)}catch(e){}const c=(j.channels||{})[process.argv[1]]||{};let v=c;const parts=process.argv[2].split('.');for(const p of parts){if(v==null){v='';break}v=v[p]}process.stdout.write(v==null?'':String(v))})" "$2" "$3"
}
findings_summary() { # <preflight-json> -> "fails codes"
  printf '%s' "$1" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{let j={};try{j=JSON.parse(s)}catch(e){}const f=(j.findings||[]).filter(x=>x.sev==='fail');process.stdout.write(String(f.length)+' '+f.map(x=>x.code).join(','))})"
}
repair_targets() { # <preflight-json>
  printf '%s' "$1" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{let j={};try{j=JSON.parse(s)}catch(e){};(j.findings||[]).filter(x=>x.sev==='fail'&&(x.code==='S1'||x.code==='S2')).forEach(x=>process.stdout.write(String(x.target)+String.fromCharCode(10)))})"
}
policy_json() {
  node "$REPO_DIR/scripts/safe-deploy-policy.js" --json --ssot "$SSOT" --channel "$1" 2>/dev/null || true
}
channel_list() {
  if [ "$CH" = "all" ]; then
    node -e "const j=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));process.stdout.write(Object.keys(j.channels||{}).join(String.fromCharCode(10)))" "$SSOT"
  else
    printf '%s' "$CH"
  fi
}
ssot_field() { # <ch> <field>
  node -e "const j=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));const c=(j.channels||{})[process.argv[2]]||{};process.stdout.write(String(c[process.argv[3]]||''))" "$SSOT" "$1" "$2"
}
ssot_set_candidate() { # <ch> <ver>
  node -e "
const fs=require('fs');
const f=process.argv[1],ch=process.argv[2],v=process.argv[3];
const j=JSON.parse(fs.readFileSync(f,'utf8'));
j.schemaVersion=j.schemaVersion||2;
j.channels=j.channels||{};
j.channels[ch]=Object.assign({},j.channels[ch],{candidate:v});
j.updatedAt=new Date().toISOString();
j.source='auto-upgrade';
const real=fs.realpathSync(f);
const tmp=real+'.tmp.'+process.pid;
fs.writeFileSync(tmp,JSON.stringify(j,null,2)+String.fromCharCode(10));
fs.renameSync(tmp,real);
process.stdout.write('candidate '+ch+'='+v);
" "$SSOT" "$1" "$2"
}
host_workspace() { # <ch>
  local dd dh rel
  dd=$(ssot_field "$1" dataDir)
  dh=$(ssot_field "$1" dshHome)
  [ -n "$dh" ] || dh=/data/dsh
  if [ -z "$dd" ]; then printf '%s' "$dh"; return; fi
  case "$dh" in
    /data/dsh)   printf '%s/dsh-data' "$dd" ;;
    /data/dsh/*) rel=$(printf '%s' "$dh" | cut -c11-); printf '%s/dsh-data/%s' "$dd" "$rel" ;;
    *)           printf '%s' "$dh" ;;
  esac
}
preflight_json() { # <home>
  local z
  z=$(command -v zstd || true)
  if [ -z "$z" ]; then echo '{"findings":[{"sev":"fail","code":"E0","target":"zstd","detail":"宿主缺 zstd"}]}'; return 1; fi
  DSH_ZSTD_BIN="$z" node "$REPO_DIR/$PREFLIGHT" --home "$1" --json || true
}
version_json() {
  if [ -n "$DSH_AUTO_VERSION_JSON" ]; then cat "$DSH_AUTO_VERSION_JSON"; return; fi
  curl -s -m 20 "$VERSION_URL" || true
}
observe_channel() { # <ch> <secs>
  local c n need iv end running health
  c=$(ssot_field "$1" container)
  [ -n "$c" ] || c=dsh-$1
  n=0
  need=$DSH_AUTO_OBSERVE_CHECKS
  [ -n "$need" ] || need=3
  iv=$DSH_AUTO_OBSERVE_INTERVAL
  [ -n "$iv" ] || iv=10
  end=$((SECONDS+$2))
  while [ $SECONDS -lt $end ]; do
    running=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)
    if [ "$running" = "true" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
      n=$((n+1))
    else
      n=0
    fi
    [ $n -ge $need ] && return 0
    sleep "$iv"
  done
  return 1
}
audit() { # <ch> <from> <to> <risk> <verdict>
  node -e "const fs=require('fs');const o={ts:new Date().toISOString(),channel:process.argv[1],from:process.argv[2],to:process.argv[3],risk:process.argv[4],verdict:process.argv[5]};fs.appendFileSync(process.argv[6],JSON.stringify(o)+String.fromCharCode(10));fs.writeFileSync(process.argv[7],JSON.stringify(o,null,2)+String.fromCharCode(10))" "$1" "$2" "$3" "$4" "$5" "$STATE/auto-upgrade.jsonl" "$STATE/auto-upgrade-last.json"
}
repair_workspace() { # <home> <preflight-json>
  local home pj rel
  home=$1; pj=$2
  log "repair: persona 双写迁移（text->prefix，保留 text）"
  if [ "$DRY" = "1" ]; then
    node "$REPO_DIR/$PERSONA" --home "$home" 2>&1 | while IFS= read -r l; do log "  persona $l"; done || true
  else
    node "$REPO_DIR/$PERSONA" --home "$home" --apply 2>&1 | while IFS= read -r l; do log "  persona $l"; done || true
  fi
  repair_targets "$pj" > "$STATE/repair-list.txt" || true
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ "$DRY" = "1" ]; then log "  would repair session $rel"; continue; fi
    if node "$REPO_DIR/$REPAIR" "$home/$rel" --apply >>"$LOG" 2>&1; then
      log "  repaired session $rel"
    else
      log "  repair FAILED: $rel（保持原状，交由门禁停止）"
    fi
  done < "$STATE/repair-list.txt"
}

log "== auto-upgrade 开始 (channel=$CH dry=$DRY allowHigh=$ALLOW_HIGH repair=$DO_REPAIR advance=$DO_ADVANCE observe=$OBSERVE seconds) =="

for ch in $(channel_list); do
  log "----- channel $ch -----"
  pj=$(policy_json "$ch")
  if [ -z "$pj" ]; then log "策略层失败，跳过"; continue; fi
  cur=$(jget "$pj" currentVersion)
  cand=$(jget "$pj" testCandidate); [ "$cand" = "(none)" ] && cand=""
  migration=$(jget "$pj" migrationStatus)
  risk=$(jget "$pj" upgradeRisk)
  blocked=$(jget "$pj" promoteBlocked)
  vj=$(version_json)
  vtarget=$(vfield "$vj" "$ch" build.target)
  vbuilt=$(vfield "$vj" "$ch" build.targetBuilt)
  log "current=$cur candidate=$cand risk=$risk migration=$migration blocked=$blocked versionPageTarget=$vtarget built=$vbuilt"

  if [ "$DO_ADVANCE" = "1" ] && [ -n "$vtarget" ] && [ "$vbuilt" = "true" ] && [ "$vtarget" != "$cur" ] && [ "$vtarget" != "$cand" ]; then
    if [ "$DRY" = "1" ]; then
      log "DRY: would advance candidate $cand -> $vtarget"
    else
      log "$(ssot_set_candidate "$ch" "$vtarget")"
      pj=$(policy_json "$ch")
      cand=$(jget "$pj" testCandidate)
      migration=$(jget "$pj" migrationStatus)
      risk=$(jget "$pj" upgradeRisk)
      blocked=$(jget "$pj" promoteBlocked)
      log "advanced: candidate=$cand risk=$risk migration=$migration blocked=$blocked"
    fi
  fi

  if [ -z "$cand" ] || [ "$cand" = "$cur" ]; then log "无候选 / 已是最新，跳过"; continue; fi

  case "$migration" in
    forward-only|unknown) log "STOP: migration=$migration（不可逆/未知）转人工"; continue ;;
  esac
  if [ "$blocked" = "true" ]; then log "STOP: promoteBlocked=true 转人工"; continue; fi

  force=""
  case "$risk" in
    LOW|MEDIUM) : ;;
    HIGH)
      if [ "$ALLOW_HIGH" = "1" ]; then force="--force"; else log "STOP: risk=HIGH 需 --allow-high"; continue; fi ;;
    *) log "STOP: risk=$risk"; continue ;;
  esac

  home=$(host_workspace "$ch")
  if [ ! -d "$home" ]; then log "STOP: 工作区不存在 $home"; continue; fi
  # dsh-safe-deploy 在宿主上跑时，路径必须全部是**宿主视角**，且 TEST_ROOT 必须落在数据卷源下：
  #   工具内部 test_home=<bind 源>/test/<target>，而 test_home_cont=$TEST_ROOT/<target>，
  #   然后 -v test_home:test_home_cont —— 只有 test_home == test_home_cont 时，测试容器
  #   才真的看得到刚解包的隔离 HOME（否则 preset/会话全空，gate 报 not-found / unauthorized）。
  #   DSH_SOURCE_HOME_<CH> = 该通道 DSH_HOME 的宿主路径（snapshot 的 tar -C 在宿主上执行）
  #   DSH_TEST_ROOT_<CH>   = <数据卷源>/test 的宿主路径（= test_home 的父目录）
  #   DSH_BACKUP_ROOT/STATE = 落宿主 state，别写进数据卷
  CH_UP=$(printf '%s' "$ch" | tr 'a-z' 'A-Z')
  hd=$(ssot_field "$ch" dataDir)/dsh-data
  export "DSH_SOURCE_HOME_$CH_UP=$home"
  export "DSH_TEST_ROOT_$CH_UP=$hd/test"
  export "DSH_BACKUP_ROOT_$CH_UP=$STATE/backups/$ch"
  export "DSH_STATE_DIR_$CH_UP=$STATE"
  log "safe-deploy env: SOURCE_HOME=$home TEST_ROOT=$hd/test"
  pf=$(preflight_json "$home" || true)
  log "preflight(before): $(findings_summary "$pf")"
  if [ "$DO_REPAIR" = "1" ]; then
    repair_workspace "$home" "$pf"
    pf=$(preflight_json "$home" || true)
  fi
  summary=$(findings_summary "$pf")
  fails=$(printf '%s' "$summary" | cut -d' ' -f1)
  log "preflight(after): $summary"
  if [ "$fails" != "0" ]; then
    log "STOP: 修复后仍有 $fails 项阻塞，转人工"
    printf '%s' "$pf" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{let j={};try{j=JSON.parse(s)}catch(e){};(j.findings||[]).filter(x=>x.sev==='fail').forEach(x=>process.stdout.write('  '+x.code+' '+x.target+String.fromCharCode(10)))})" >>"$LOG" 2>&1 || true
    continue
  fi

  if [ "$DRY" = "1" ]; then log "DRY: would test then promote $ch -> $cand (force=$force)"; continue; fi
  if bash "$REPO_DIR/$SAFE" test --channel "$ch" >>"$LOG" 2>&1; then
    log "test PASS"
  else
    # 兜底：dsh-safe-deploy 的 EXIT trap 历史 bug 可能让 PASS 也返回非零 —— 以 verdict 文件为准
    verdict=$(cat "$STATE/$ch/last-test-verdict" 2>/dev/null || true)
    if [ "$verdict" = "TEST_VERDICT=PASS" ]; then
      log "test 退出码非零但 verdict=PASS（按 PASS 继续）"
    else
      log "test FAIL（见日志），不上线"; audit "$ch" "$cur" "$cand" "$risk" "test-fail"; continue
    fi
  fi

  if ! bash "$REPO_DIR/$SAFE" promote --channel "$ch" $force >>"$LOG" 2>&1; then
    log "promote FAIL（见日志）"; audit "$ch" "$cur" "$cand" "$risk" "promote-fail"; continue
  fi
  log "promoted $ch: $cur -> $cand"

  if observe_channel "$ch" "$OBSERVE"; then
    log "观察窗通过（running+healthy），完成"
    audit "$ch" "$cur" "$cand" "$risk" "success"
  else
    log "观察窗失败 -> 自动回滚"
    if bash "$REPO_DIR/$SAFE" rollback --channel "$ch" >>"$LOG" 2>&1; then
      log "已回滚到 snapshot + 旧镜像"
      audit "$ch" "$cur" "$cand" "$risk" "rolled-back"
    else
      log "回滚失败，需人工介入"
      audit "$ch" "$cur" "$cand" "$risk" "rollback-failed"
    fi
  fi
done
log "== auto-upgrade 结束 =="
