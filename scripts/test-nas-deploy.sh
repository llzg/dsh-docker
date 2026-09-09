#!/usr/bin/env bash
# test-nas-deploy.sh —— 双通道 NAS 部署资产测试（无 docker daemon 依赖）
#
# 独立运行：bash scripts/test-nas-deploy.sh
# 全部通过时退出码 0，并逐项打印 PASS/FAIL。
#
# 覆盖（对应修复的既有缺陷编号）：
#   P0-1  compose 上下文：compose_cmd 显式 -p/--project-directory/-f；pin 校验 project name 与卷源
#   P0-2  事务化 pin：.env.pending → 校验 → 原子 mv → up --wait/健康轮询 → 失败还原
#   #3    prev_version：semver 比较 + 排除 <ver>-<sha> + 当前版本缺失必须报错
#   #4    GHCR 不可达 → 本地镜像标签降级 + 告警
#   #5    watchdog 新鲜度用 .State.StartedAt（非镜像 .Created）
#   #6    flock 互斥（$STATE/deploy.lock）
#   #7    install.sh 每次覆盖前时间戳备份 + mkdir -p
#   #8    /dev/dri 可选（override 文件；base compose 无 devices）
#   #9    dsh-safe-deploy 通道化：--channel、SSOT/状态隔离、promote 原子 pin+digest、rollback 路径对称
#
# 所有外部依赖（docker / curl）均用 stub 替身，不接触真实 daemon、不联网。
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAS="$REPO_DIR/nas"
SAFE_DEPLOY="$REPO_DIR/scripts/dsh-safe-deploy"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dsh-nas-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BIN="$TMP/bin"
STUB_LOG="$TMP/docker.log"
STATE_ROOT="$TMP/state"
ALPHA_DIR="$TMP/dsh-alpha"
RC_DIR="$TMP/dsh-rc"
SSOT="$TMP/dsh-version.json"
mkdir -p "$BIN" "$STATE_ROOT" "$ALPHA_DIR" "$RC_DIR"

# ── 环境自净化 ────────────────────────────────────────────────────────────
# 调用者 shell 里若导出过 DSH_* / STUB_*（例如 DSH_SSOT、DSH_WATCHDOG_THRESHOLD、DSH_STATE_DIR），
# 会让本套件产生与实现无关的 FAIL。启动时统一清除，保证可重复、可在他机运行。
for _v in $(env | sed -n 's/^\(DSH_[A-Za-z0-9_]*\)=.*/\1/p' 2>/dev/null); do
  unset "$_v" 2>/dev/null || true
done
for _v in $(env | sed -n 's/^\(STUB_[A-Za-z0-9_]*\)=.*/\1/p' 2>/dev/null); do
  unset "$_v" 2>/dev/null || true
done

PASS=0; FAIL=0
t() { # <id> <desc> <ok 0|1> [detail]
  if [ "$3" = "1" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-7s %s%s\n' "$1" "$2" "${4:+ | $4}"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-7s %s%s\n' "$1" "$2" "${4:+ | $4}"
  fi
}
has() { printf '%s' "$1" | grep -qF -- "$2"; }          # 包含子串
hasre() { printf '%s' "$1" | grep -qE -- "$2"; }       # 正则
log_has() { grep -qF -- "$1" "$STUB_LOG" 2>/dev/null; }
log_hasre() { grep -qE -- "$1" "$STUB_LOG" 2>/dev/null; }

# ── stub: docker ──────────────────────────────────────────────────────────
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  info) exit 0 ;;
  pull)
    if [ "${STUB_PULL_FAIL:-0}" = "1" ]; then echo "${STUB_PULL_ERR:-stub: pull failed}" >&2; exit 1; fi
    exit 0 ;;
  image)
    sub="${1:-}"; [ $# -gt 0 ] && shift
    case "$sub" in
      ls) printf '%s\n' ${STUB_LOCAL_TAGS:-}; exit 0 ;;
      inspect)
        fmt=""
        while [ $# -gt 0 ]; do case "$1" in -f|--format) fmt="$2"; shift 2;; *) shift;; esac; done
        case "$fmt" in
          *RepoDigests*) printf '%s\n' "${STUB_DIGEST-sha256:aaaaaaaa}" ;;
          *Created*) printf '%s\n' "${STUB_IMAGE_CREATED:-2026-09-09T00:00:00Z}" ;;
          *) printf '%s\n' "${STUB_DIGEST-sha256:aaaaaaaa}" ;;
        esac
        exit 0 ;;
    esac
    exit 0 ;;
  inspect)
    fmt=""
    while [ $# -gt 0 ]; do case "$1" in -f|--format) fmt="$2"; shift 2;; *) shift;; esac; done
    case "$fmt" in
      *State.Health*)
        if [ -n "${STUB_HEALTH_SEQ:-}" ]; then
          n=0; [ -f "${STUB_HEALTH_COUNTER:-}" ] && n=$(cat "$STUB_HEALTH_COUNTER" 2>/dev/null || echo 0)
          n=$((n + 1)); printf '%s' "$n" > "$STUB_HEALTH_COUNTER"
          printf '%s\n' "$STUB_HEALTH_SEQ" | tr ' ' '\n' | sed -n "${n}p"
        else printf '%s\n' "${STUB_HEALTH:-healthy}"; fi ;;
      *State.StartedAt*) printf '%s\n' "${STUB_STARTED_AT:-2026-09-09T00:00:00Z}" ;;
      *State.Running*) printf '%s\n' "${STUB_RUNNING:-true}" ;;
      *HostConfig.Binds*) printf '%s\n' "${STUB_BINDS:-/host/dsh-data:/data/dsh}" ;;
      *NetworkSettings.Networks*) printf '%s\n' "${STUB_NET:-10.0.0.9}" ;;
      *org.opencontainers.image.version*) printf '%s\n' "${STUB_LABEL_VERSION:-0.1.2-alpha.5}" ;;
      *Image*) printf '%s\n' "${STUB_IMAGE_ID:-sha256:imageid}" ;;
      *) : ;;
    esac
    exit 0 ;;
  compose)
    proj=""; pdir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) proj="$2"; shift 2 ;;
        --project-directory) pdir="$2"; shift 2 ;;
        -f) shift 2 ;;
        *) break ;;
      esac
    done
    sub="${1:-}"; [ $# -gt 0 ] && shift
    case "$sub" in
      config)
        if [ "${STUB_NO_JSON:-0}" = "1" ]; then
          printf 'name: %s\nservices:\n  dsh:\n    container_name: %s\n    volumes:\n      - type: bind\n        source: %s\n      - type: volume\n        source: namedvol\n' \
            "${STUB_CONFIG_NAME:-$proj}" "${STUB_CONFIG_CNAME:-${DSH_CONTAINER:-$proj}}" \
            "${STUB_CONFIG_VOLUME:-$pdir/dsh-data}"
          exit 0
        fi
        if [ "${1:-}" = "--format" ] && [ "${2:-}" = "json" ]; then
          printf '{"name":"%s","services":{"dsh":{"container_name":"%s","image":"%s","volumes":[{"type":"bind","source":"%s","target":"/data/dsh"},{"type":"volume","source":"namedvol","target":"/x"}]}}}\n' \
            "${STUB_CONFIG_NAME:-$proj}" "${STUB_CONFIG_CNAME:-${DSH_CONTAINER:-$proj}}" \
            "${DSH_IMAGE:-img}" "${STUB_CONFIG_VOLUME:-$pdir/dsh-data}"
        else
          printf 'name: %s\nservices:\n  dsh:\n    container_name: %s\n    volumes:\n      - type: bind\n        source: %s\n' \
            "${STUB_CONFIG_NAME:-$proj}" "${STUB_CONFIG_CNAME:-${DSH_CONTAINER:-$proj}}" \
            "${STUB_CONFIG_VOLUME:-$pdir/dsh-data}"
        fi
        exit 0 ;;
      up)
        if [ "${STUB_UP_FAIL:-0}" = "1" ]; then echo "stub: up failed" >&2; exit 1; fi
        case " $* " in
          *" --wait "*) [ "${STUB_WAIT_SUPPORT:-1}" = "0" ] && { echo "stub: unknown flag: --wait" >&2; exit 1; } ;;
        esac
        exit 0 ;;
      pull)
        if [ "${STUB_COMPOSE_PULL_FAIL:-0}" = "1" ]; then echo "${STUB_COMPOSE_PULL_ERR:-stub: compose pull failed}" >&2; exit 1; fi
        exit 0 ;;
    esac
    exit 0 ;;
  run|rm|ps|logs|exec) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"

# ── stub: curl（GHCR token/tags）──────────────────────────────────────────
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# 记录完整参数 + scheme/auth 摘要（auth 只记“有/无”，不落明文）
printf 'curl %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
url=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) auth="$2"; shift 2 ;;
    -H*) auth="${1#-H}"; shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
scheme=""
case "$url" in
  https://*) scheme=https ;;
  http://*) scheme=http ;;
esac
printf 'curl-meta scheme=%s auth=%s url=%s\n' "${scheme:-none}" "${auth:-none}" "$url" >> "${STUB_LOG:-/dev/null}"

# GHCR 专用流（匿名 token → tags）
case "$url" in
  *ghcr.io/token*)
    [ "${STUB_GHCR_DOWN:-0}" = "1" ] && exit 22
    printf '{"token":"stub-token"}\n'; exit 0 ;;
  *ghcr.io/v2/*tags/list*)
    [ "${STUB_GHCR_DOWN:-0}" = "1" ] && exit 22
    printf '%s\n' "${STUB_GHCR_TAGS:-{\"tags\":[\"latest\"]}}"; exit 0 ;;
esac

# 通用 registry v2
case "$url" in
  */v2/*/tags/list*)
    if [ "${STUB_HTTPS_FAIL:-0}" = "1" ] && [ "$scheme" = "https" ]; then exit 7; fi
    if [ "${STUB_REG_401:-0}" = "1" ]; then exit 22; fi
    if [ "${STUB_REQUIRE_BASIC:-0}" = "1" ] && [ -z "$auth" ]; then exit 22; fi
    printf '%s\n' "${STUB_REG_TAGS:-{\"tags\":[\"0.1.2-alpha.5\",\"0.1.3-alpha.2\",\"latest\"]}}"
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/curl"

# 真实 docker CLI（用于 `docker compose config`——本地操作，不需要 daemon；绕过 stub）
REAL_DOCKER="$(command -v docker 2>/dev/null || true)"
export PATH="$BIN:$PATH"
export STUB_LOG STATE_ROOT SSOT

# ── SSOT fixture（schema v2 双通道）───────────────────────────────────────
cat > "$SSOT" <<JSON
{
  "schemaVersion": 2,
  "primaryChannel": "alpha",
  "channels": {
    "alpha": {
      "port": 3081, "container": "dsh-alpha", "project": "dsh-alpha",
      "dataDir": "$ALPHA_DIR", "production": "0.1.2-alpha.5", "candidate": "0.1.3-alpha.2"
    },
    "rc": {
      "port": 3083, "container": "dsh-rc", "project": "dsh-rc",
      "dataDir": "$RC_DIR", "production": "0.1.2-rc.1", "candidate": "0.1.2-rc.1"
    }
  },
  "updatedAt": "2026-09-09T00:00:00.000Z",
  "source": "test"
}
JSON

# 通道 compose 目录（install.sh / watchdog-container.sh 需要真实 compose 文件）
cp "$NAS/docker-compose.yml" "$ALPHA_DIR/docker-compose.yml"
cp "$NAS/docker-compose.yml" "$RC_DIR/docker-compose.yml"

# 运行 lib.sh 片段：run_lib <dir> <channel> <body> [额外 env...]
run_lib() {
  local d="$1" ch="$2" body="$3"; shift 3
  env "$@" DSH_CHANNEL="$ch" DSH_DEPLOY_DIR="$d" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
    sh -c ". '$NAS/lib.sh'; $body"
}

echo "== test-nas-deploy.sh（REPO=$REPO_DIR）=="
echo

# ── P0-1 / #3 / #4：prev_version 选版 ─────────────────────────────────────
export STUB_GHCR_TAGS='{"tags":["latest","0.1.1-rc.2","0.1.2-alpha.3","0.1.2-alpha.4","0.1.2-alpha.5","0.1.3-alpha.2-e478cdf21a08fdc2b7e26467672728546b53371d"]}'
OUT=$(run_lib "$ALPHA_DIR" alpha 'prev_version 0.1.2-alpha.5' 2>/dev/null)
t D1-prev "prev_version 取严格更低者中的最高（排除 <ver>-<sha>）" "$([ "$OUT" = "0.1.2-alpha.4" ] && echo 1 || echo 0)" "got=$OUT"

CMP=$(run_lib "$ALPHA_DIR" alpha 'semver_cmp "$(prev_version 0.1.2-alpha.5)" 0.1.2-alpha.5' 2>/dev/null)
t D1-notup "prev_version 结果必为降级（semver_cmp = -1，绝不回滚变升级）" "$([ "$CMP" = "-1" ] && echo 1 || echo 0)" "cmp=$CMP"

OUT=$(run_lib "$ALPHA_DIR" alpha 'prev_version 0.1.9-alpha.9' 2>&1); RC=$?
NOTMAX=1; has "$OUT" "0.1.3-alpha.2" && NOTMAX=0; has "$OUT" "0.1.2-alpha.5" && NOTMAX=0
t D3-missing "当前版本不在候选列表 → 非 0 且不返回列表最高" "$([ "$RC" -ne 0 ] && [ "$NOTMAX" = "1" ] && echo 1 || echo 0)" "rc=$RC"
has "$OUT" "拒绝回滚" && t D3-msg "缺失当前版本时打印明确拒绝原因" 1 || t D3-msg "缺失当前版本时打印明确拒绝原因" 0 "$OUT"

OUT=$(run_lib "$ALPHA_DIR" alpha 'prev_version 0.1.3-alpha.2-e478cdf21a08fdc2b7e26467672728546b53371d' 2>&1); RC=$?
t D3-sha "不可变 <ver>-<sha> 标签不可作为回滚基准（报错）" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "rc=$RC"

OUT=$(STUB_GHCR_DOWN=1 STUB_LOCAL_TAGS="0.1.2-alpha.4 0.1.2-alpha.5" run_lib "$ALPHA_DIR" alpha 'prev_version 0.1.2-alpha.5' 2>"$TMP/degraded.err")
t D4-degrade "GHCR 不可达 → 降级本地镜像标签并选出 0.1.2-alpha.4" "$([ "$OUT" = "0.1.2-alpha.4" ] && echo 1 || echo 0)" "got=$OUT"
grep -q "降级使用本地镜像标签" "$TMP/degraded.err" && t D4-warn "降级时输出明确告警" 1 || t D4-warn "降级时输出明确告警" 0 "$(cat "$TMP/degraded.err")"

# ── P0-2：事务化 pin ──────────────────────────────────────────────────────
: > "$STUB_LOG"
rm -f "$ALPHA_DIR/.env" "$ALPHA_DIR/.env.pending"
run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.4 manual' >/dev/null 2>&1; RC=$?
ENV_TXT=$(cat "$ALPHA_DIR/.env" 2>/dev/null || true)
OK=1
[ "$RC" -eq 0 ] || OK=0
has "$ENV_TXT" "DSH_IMAGE=ghcr.io/llzg/dsh-docker:0.1.2-alpha.4" || OK=0
has "$ENV_TXT" "DSH_PIN_REASON=manual" || OK=0
has "$ENV_TXT" "DSH_PIN_VERSION=0.1.2-alpha.4" || OK=0
has "$ENV_TXT" "DSH_PIN_DIGEST=sha256:" || OK=0
[ ! -f "$ALPHA_DIR/.env.pending" ] || OK=0
t D2-pin "pin 成功：原子落盘 .env（含 reason/version/digest），pending 已消费" "$OK" "rc=$RC"

: > "$STUB_LOG"
STUB_DIGEST="" run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.3 manual' >/dev/null 2>&1; RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'DSH_PIN_VERSION=0.1.2-alpha.3' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q '^DSH_PIN_DIGEST=' "$ALPHA_DIR/.env" 2>/dev/null && OK=0
t D2-nodigest "无 digest（本地构建镜像）时 pin 仍成功且不写空 digest 行" "$OK" "rc=$RC"

OK=1
log_hasre 'compose -f .*--project-directory .* -p dsh-alpha up -d --force-recreate --wait' || OK=0
log_has "$ALPHA_DIR/docker-compose.yml" || OK=0
t P0-1-compose "compose 调用显式带 -p/--project-directory/-f 与 --wait" "$OK"

: > "$STUB_LOG"
cp "$ALPHA_DIR/.env" "$TMP/env.before-mismatch"
STUB_CONFIG_NAME=dsh-app run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' >/dev/null 2>&1; RC=$?
OK=1
[ "$RC" -ne 0 ] || OK=0
cmp -s "$TMP/env.before-mismatch" "$ALPHA_DIR/.env" || OK=0
log_hasre 'compose .* up -d' && OK=0
[ ! -f "$ALPHA_DIR/.env.pending" ] || OK=0
t P0-1-name "project name 断言失败 → 拒绝执行，.env 不变、不 up" "$OK" "rc=$RC"

: > "$STUB_LOG"
STUB_CONFIG_VOLUME=/dsh-app/dsh-data run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' >/dev/null 2>&1; RC=$?
OK=1
[ "$RC" -ne 0 ] || OK=0
cmp -s "$TMP/env.before-mismatch" "$ALPHA_DIR/.env" || OK=0
log_hasre 'compose .* up -d' && OK=0
t P0-1-vol "卷源落在项目目录外 → 拒绝执行（P0-1 复现防线）" "$OK" "rc=$RC"

: > "$STUB_LOG"
cp "$ALPHA_DIR/.env" "$TMP/env.before-restore"
STUB_UP_FAIL=1 run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' >/dev/null 2>&1; RC=$?
UPCOUNT=$(grep -c 'compose .* up -d' "$STUB_LOG" 2>/dev/null || true)
OK=1
[ "$RC" -ne 0 ] || OK=0
cmp -s "$TMP/env.before-restore" "$ALPHA_DIR/.env" || OK=0
[ "${UPCOUNT:-0}" -ge 2 ] || OK=0
t P0-2-restore "up 失败 → 还原旧 .env 并再 up 回旧镜像（非 0 退出）" "$OK" "rc=$RC upAttempts=$UPCOUNT"

: > "$STUB_LOG"
rm -f "$TMP/health.cnt"
OUT=$(STUB_WAIT_SUPPORT=0 STUB_HEALTH_SEQ="starting starting healthy" STUB_HEALTH_COUNTER="$TMP/health.cnt" \
      DSH_HEALTH_INTERVAL=0 \
      run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' 2>&1); RC=$?
ENV_TXT=$(cat "$ALPHA_DIR/.env" 2>/dev/null || true)
OK=1
[ "$RC" -eq 0 ] || OK=0
has "$ENV_TXT" "DSH_PIN_VERSION=0.1.2-alpha.5" || OK=0
t P0-2-wait "compose 不支持 --wait → 健康轮询兜底成功" "$OK" "rc=$RC"

: > "$STUB_LOG"
rm -f "$TMP/health2.cnt"
# 先建立已知基线（成功 pin 到 0.1.2-alpha.4），再用健康失败的方式 pin 0.1.2-alpha.5
STUB_HEALTH=healthy run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.4 manual' >/dev/null 2>&1
: > "$STUB_LOG"
OUT=$(STUB_WAIT_SUPPORT=0 STUB_HEALTH_SEQ="starting unhealthy unhealthy" STUB_HEALTH_COUNTER="$TMP/health2.cnt" \
      DSH_HEALTH_RETRIES=3 DSH_HEALTH_INTERVAL=0 \
      run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' 2>&1); RC=$?
ENV_TXT=$(cat "$ALPHA_DIR/.env" 2>/dev/null || true)
OK=1
[ "$RC" -ne 0 ] || OK=0
has "$ENV_TXT" "DSH_PIN_VERSION=0.1.2-alpha.4" || OK=0
t P0-2-pollfail "健康轮询超时 → 还原到旧版本 .env" "$OK" "rc=$RC"

# 老版 compose 无 `config --format json` → YAML 断言路径（项目名/卷源仍必须校验）
: > "$STUB_LOG"
cp "$ALPHA_DIR/.env" "$TMP/env.before-yaml"
STUB_NO_JSON=1 run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.4 manual' >/dev/null 2>&1; RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'DSH_PIN_VERSION=0.1.2-alpha.4' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
STUB_NO_JSON=1 STUB_CONFIG_VOLUME=/dsh-app/dsh-data run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' >/dev/null 2>&1; RC2=$?
[ "$RC2" -ne 0 ] || OK=0
t P0-1-yaml "老版 compose（无 --format json）走 YAML 断言：卷源越界仍被拒绝" "$OK" "rc=$RC rc_vol=$RC2"

# ── #6 flock 互斥 ─────────────────────────────────────────────────────────
LOCK="$STATE_ROOT/alpha/deploy.lock"
mkdir -p "$(dirname "$LOCK")"
( flock -x 9; sleep 2 ) 9>"$LOCK" &
HOLDER=$!
sleep 0.4
OUT=$(run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' 2>&1); RC=$?
wait "$HOLDER" 2>/dev/null || true
t D6-flock "并发写操作被 flock 阻止（exit 3 + LOCKED）" "$([ "$RC" -eq 3 ] && has "$OUT" "LOCKED" && echo 1 || echo 0)" "rc=$RC"

# ── #5 watchdog 计数 / 跳过 / 新鲜度 ──────────────────────────────────────
WCH="$STATE_ROOT/alpha/unhealthy_count"
WLOG="$STATE_ROOT/alpha/alpha-watchdog.log"
mkdir -p "$STATE_ROOT/alpha"

rm -f "$WCH" "$WLOG"; echo 2 > "$WCH"
STUB_HEALTH=healthy env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/watchdog.sh" >/dev/null 2>&1
t D5-healthy "watchdog：健康 → 重置不健康计数" "$([ ! -f "$WCH" ] && echo 1 || echo 0)"

: > "$STUB_LOG"; rm -f "$WCH" "$WLOG"
STUB_HEALTH=unhealthy env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/watchdog.sh" >/dev/null 2>&1
t D5-count "watchdog：未达阈值 → 仅计数不动手" "$([ "$(cat "$WCH" 2>/dev/null)" = "1" ] && ! log_hasre 'compose .* up -d' && echo 1 || echo 0)" "count=$(cat "$WCH" 2>/dev/null)"

rm -f "$WCH" "$WLOG"; echo 2 > "$WCH"; : > "$STUB_LOG"
STUB_HEALTH=unhealthy env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/watchdog.sh" >/dev/null 2>&1
OK=1
log_hasre 'compose .* up -d' && OK=0
grep -q "manual pin" "$WLOG" 2>/dev/null || OK=0
t D2-manual "watchdog：DSH_PIN_REASON=manual → 跳过（不自动回滚）" "$OK" "env=$(grep -c DSH_PIN_REASON=manual "$ALPHA_DIR/.env" 2>/dev/null)"

rm -f "$WCH" "$WLOG"; echo 2 > "$WCH"; : > "$STUB_LOG"
# 基线：.env 钉在 0.1.2-alpha.5 且 reason=auto-rollback（上次自动回滚残留）
STUB_HEALTH=healthy run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 auto-rollback' >/dev/null 2>&1
: > "$STUB_LOG"
STUB_HEALTH=unhealthy STUB_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/watchdog.sh" >/dev/null 2>&1; RC=$?
ENV_TXT=$(cat "$ALPHA_DIR/.env" 2>/dev/null || true)
OK=1
has "$ENV_TXT" "DSH_PIN_VERSION=0.1.2-alpha.4" || OK=0
has "$ENV_TXT" "DSH_PIN_REASON=auto-rollback" || OK=0
grep -q "AUTO-ROLLBACK" "$WLOG" 2>/dev/null || OK=0
[ ! -f "$WCH" ] || OK=0
t D2-auto "watchdog：auto-rollback 残留允许重试并完成自动回滚" "$OK" "rc=$RC"

rm -f "$WCH" "$WLOG"; echo 2 > "$WCH"; : > "$STUB_LOG"
OLD_START="$(date -u -d '4 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 2020-01-01T00:00:00Z)"
STUB_HEALTH=unhealthy STUB_STARTED_AT="$OLD_START" STUB_IMAGE_CREATED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/watchdog.sh" >/dev/null 2>&1
OK=1
log_hasre 'compose .* up -d' && OK=0
grep -q "container started" "$WLOG" 2>/dev/null || OK=0
t D5-started "watchdog：新鲜度用 .State.StartedAt（4h 前）而非镜像 .Created（刚构建）" "$OK" "$(tail -1 "$WLOG" 2>/dev/null)"

# ── rollback.sh / resume-auto-update.sh（CLI 层防回滚变升级 + 解除钉住）──────
STUB_HEALTH=healthy run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 manual' >/dev/null 2>&1
cp "$ALPHA_DIR/.env" "$TMP/env.before-guard"
: > "$STUB_LOG"
OUT=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
      sh "$NAS/rollback.sh" 0.1.9-alpha.9 2>&1); RC=$?
OK=1
[ "$RC" -ne 0 ] || OK=0
has "$OUT" "拒绝" || OK=0
cmp -s "$TMP/env.before-guard" "$ALPHA_DIR/.env" || OK=0
log_hasre 'compose .* up -d' && OK=0
t D3-guard "rollback.sh 拒绝高于当前的版本（回滚不允许变升级）" "$OK" "rc=$RC"

: > "$STUB_LOG"
OUT=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
      sh "$NAS/rollback.sh" 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'DSH_PIN_VERSION=0.1.2-alpha.4' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PIN_REASON=manual' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
t D3-auto "rollback.sh 无参数 → 自动选 semver 更低版本并钉住（reason=manual）" "$OK" "rc=$RC"

: > "$STUB_LOG"
OUT=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
      sh "$NAS/resume-auto-update.sh" 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'DSH_PIN_VERSION=0.1.2-alpha.5' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PIN_REASON=ssot-production' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_IMAGE=ghcr.io/llzg/dsh-docker:0.1.2-alpha.5' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_CHANNEL=alpha' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
has "$OUT" "SSOT channels.alpha.production" || OK=0
has "$OUT" "0.1.2-alpha.5" || OK=0
log_hasre 'compose .* up -d' || OK=0
t D2-unpin "resume-auto-update.sh → 钉到 SSOT production（reason=ssot-production，非 latest）" "$OK" "rc=$RC $(grep -m1 DSH_PIN_VERSION "$ALPHA_DIR/.env" 2>/dev/null)"

# SSOT production 镜像不可用 → 回退 compose 默认镜像并显式告警
: > "$STUB_LOG"
OUT=$(STUB_PULL_FAIL=1 env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
      sh "$NAS/resume-auto-update.sh" 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'DSH_IMAGE=ghcr.io/llzg/dsh-docker:latest' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PIN_REASON=ssot-fallback' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_CHANNEL=alpha' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
has "$OUT" "显式回退" || OK=0
has "$OUT" "ssot-fallback" || OK=0
t D2-unpin-fallback "SSOT production 不可用 → 显式钉 latest（reason=ssot-fallback）+ 强告警" "$OK" "rc=$RC"

# ssot-production 钉住不得阻止 watchdog 自动回滚（区别于 manual）
STUB_HEALTH=healthy run_lib "$ALPHA_DIR" alpha 'pin_version 0.1.2-alpha.5 ssot-production' >/dev/null 2>&1
rm -f "$WCH" "$WLOG"; echo 2 > "$WCH"; : > "$STUB_LOG"
STUB_HEALTH=unhealthy STUB_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/watchdog.sh" >/dev/null 2>&1; RC=$?
OK=1
grep -q 'DSH_PIN_VERSION=0.1.2-alpha.4' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PIN_REASON=auto-rollback' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'AUTO-ROLLBACK' "$WLOG" 2>/dev/null || OK=0
t D2-ssot-watchdog "reason=ssot-production 不阻止 watchdog 自动回滚（仅 manual 跳过）" "$OK" "rc=$RC"

# switch.sh：未钉住（身份 .env）→ 跟随 SSOT production 而非 compose 默认 latest
: > "$STUB_LOG"
run_lib "$ALPHA_DIR" alpha 'write_identity_env "$DIR/.env"' >/dev/null 2>&1
OUT=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
      sh "$NAS/switch.sh" 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'DSH_PIN_VERSION=0.1.2-alpha.5' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PIN_REASON=ssot-production' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
t D2-switch "switch.sh 未钉住 → 跟随 SSOT production（不是 latest）" "$OK" "rc=$RC"

# ── 真实 docker compose config（config 是本地操作，不需要 daemon）──────────
if [ -n "$REAL_DOCKER" ] && "$REAL_DOCKER" compose version >/dev/null 2>&1; then
  REAL="$TMP/real-compose"; mkdir -p "$REAL"
  cp "$NAS/docker-compose.yml" "$REAL/"
  OUT=$(env -u DSH_IMAGE "$REAL_DOCKER" compose -p dsh-alpha --project-directory "$REAL" \
        -f "$REAL/docker-compose.yml" config 2>&1); RC=$?
  OUT2=$(DSH_IMAGE=ghcr.io/llzg/dsh-docker:0.1.2-alpha.5 DSH_PROJECT=dsh-alpha DSH_CONTAINER=dsh-alpha \
         "$REAL_DOCKER" compose -p dsh-alpha --project-directory "$REAL" -f "$REAL/docker-compose.yml" config 2>&1); RC2=$?
  OK=1
  [ "$RC" -ne 0 ] || OK=0
  has "$OUT" "required variable DSH_IMAGE" || OK=0
  [ "$RC2" -eq 0 ] || OK=0
  has "$OUT2" "name: dsh-alpha" || OK=0
  has "$OUT2" "source: $REAL/dsh-data" || OK=0
  has "$OUT2" "driver: json-file" || OK=0
  has "$OUT2" "max-size: 10m" || OK=0
  has "$OUT2" "max-file:" || OK=0
  t REAL-compose "真实 compose config：缺 DSH_IMAGE 报错 + 日志轮转 + 卷源在项目目录下" "$OK" "rc_noimg=$RC rc_ok=$RC2"
else
  echo "SKIP  REAL-compose 真实 docker compose 不可用（跳过真实 config 校验）"
fi

# ── compose 静态契约：image 必填（无 latest 兜底）+ 日志轮转 ─────────────
OK=1
grep -qE 'image:.*\$\{DSH_IMAGE:\?' "$NAS/docker-compose.yml" || OK=0
# 注释里可以提到旧写法，但生效配置中不得再有 DSH_IMAGE:- 兜底
grep -v '^[[:space:]]*#' "$NAS/docker-compose.yml" | grep -q 'DSH_IMAGE:-' && OK=0
t COMPOSE-image "compose image 必填 \${DSH_IMAGE:?…}（无静默 latest 兜底）" "$OK"

OK=1
grep -qE '^[[:space:]]*logging:' "$NAS/docker-compose.yml" || OK=0
grep -q 'driver: json-file' "$NAS/docker-compose.yml" || OK=0
grep -q 'max-size' "$NAS/docker-compose.yml" || OK=0
grep -q 'max-file' "$NAS/docker-compose.yml" || OK=0
t COMPOSE-logging "compose 配置 json-file 日志轮转（max-size/max-file）" "$OK"

# ── #8 /dev/dri 可选 + override 生成 ─────────────────────────────────────
OUT=$(run_lib "$ALPHA_DIR" alpha 'igpu_override_write /dev/dri' 2>&1)
OK=1
[ -f "$ALPHA_DIR/docker-compose.igpu.yml" ] || OK=0
grep -q 'devices:' "$ALPHA_DIR/docker-compose.igpu.yml" 2>/dev/null || OK=0
grep -q '/dev/dri:/dev/dri' "$ALPHA_DIR/docker-compose.igpu.yml" 2>/dev/null || OK=0
t D8-override "igpu override 生成（devices 直通进独立文件）" "$OK"

grep -qE '^[[:space:]]*devices:' "$NAS/docker-compose.yml" && OK=0 || OK=1
t D8-base "base compose 不再硬依赖 /dev/dri（无 devices: 键）" "$OK"

: > "$STUB_LOG"
OUT=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
      sh "$NAS/apply-igpu.sh" 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
log_has "-f $ALPHA_DIR/docker-compose.igpu.yml" || OK=0
log_hasre 'compose .* -p dsh-alpha' || OK=0
t D8-apply "apply-igpu 通过 compose_cmd 追加 override（不改 base compose）" "$OK" "rc=$RC"
rm -f "$ALPHA_DIR/docker-compose.igpu.yml"

# ── #7 install.sh 时间戳备份 + mkdir -p ──────────────────────────────────
FRESH_DIR="$TMP/dsh-fresh"
printf 'LOCAL-CUSTOM-MARKER\n' > "$TMP/pre-compose.yml"
mkdir -p "$FRESH_DIR"
cp "$TMP/pre-compose.yml" "$FRESH_DIR/docker-compose.yml"
rm -rf "$FRESH_DIR/.env"
env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$FRESH_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/install.sh" >/dev/null 2>&1
sleep 1
env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$FRESH_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/install.sh" >/dev/null 2>&1
BAKS=$(ls "$FRESH_DIR"/docker-compose.yml.bak-* 2>/dev/null | wc -l)
t D7-backup "install.sh 每次覆盖都做时间戳备份（两次运行 → 2 份）" "$([ "$BAKS" -eq 2 ] && echo 1 || echo 0)" "backups=$BAKS"
grep -q 'LOCAL-CUSTOM-MARKER' "$FRESH_DIR"/docker-compose.yml.bak-* 2>/dev/null && OK=1 || OK=0
t D7-content "备份保留本地定制内容（不被静默覆盖）" "$OK"
t D7-mkdir "install.sh 对缺失目录 mkdir -p" "$([ -f "$FRESH_DIR/docker-compose.yml" ] && [ -f "$FRESH_DIR/.env" ] && echo 1 || echo 0)"
OK=1
grep -q 'DSH_CHANNEL=alpha' "$FRESH_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PROJECT=dsh-alpha' "$FRESH_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_CONTAINER=dsh-alpha' "$FRESH_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_IMAGE=ghcr.io/llzg/dsh-docker:0.1.2-alpha.5' "$FRESH_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PIN_REASON=ssot-production' "$FRESH_DIR/.env" 2>/dev/null || OK=0
t D7-identity "install.sh 用 SSOT production 初始化 .env（身份 + 必填 DSH_IMAGE）" "$OK"

# install.sh 预拉的是 SSOT production，而不是 latest
: > "$STUB_LOG"
env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$FRESH_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/install.sh" >/dev/null 2>&1
OK=1
log_has "pull ghcr.io/llzg/dsh-docker:0.1.2-alpha.5" || OK=0
log_has "pull ghcr.io/llzg/dsh-docker:latest" && OK=0
t INSTALL-pull "install.sh 预拉 SSOT production（不再预拉 latest）" "$OK"

# install.sh 把仓库根的 dsh-version.json 同步到部署目录（否则部署目录读不到 SSOT）
DEP_SRC="$TMP/deploy-src"
mkdir -p "$DEP_SRC"
cp "$NAS"/*.sh "$DEP_SRC/" 2>/dev/null
cp "$NAS/docker-compose.yml" "$NAS/docker-compose.versionpage.yml" "$DEP_SRC/"
cp "$SSOT" "$TMP/dsh-version.json"   # 部署目录的上级（$DEP_SRC/../dsh-version.json）
rm -f "$DEP_SRC/dsh-version.json"
OUT=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$TMP/dsh-dep" DSH_DEPLOY_STATE="$STATE_ROOT" \
      sh "$DEP_SRC/install.sh" 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
[ -f "$DEP_SRC/dsh-version.json" ] || OK=0
grep -q '"primaryChannel": "alpha"' "$DEP_SRC/dsh-version.json" 2>/dev/null || OK=0
grep -q 'DSH_PIN_REASON=ssot-production' "$TMP/dsh-dep/.env" 2>/dev/null || OK=0
t INSTALL-ssot-sync "install.sh 把上级 dsh-version.json 同步到部署目录并据此初始化" "$OK" "rc=$RC"

# lib.sh SSOT 多路径搜索（未设 DSH_SSOT 时）：脚本同目录优先，其次上级目录
DEP2="$TMP/dep2"
mkdir -p "$DEP2"
cp "$NAS/lib.sh" "$DEP2/lib.sh"
printf '. "%s/lib.sh"\nprintf %%s "$SSOT"\n' "$DEP2" > "$DEP2/probe.sh"
SSOT_SAME=$(env -u DSH_SSOT DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$TMP/dsh-dep" DSH_DEPLOY_STATE="$STATE_ROOT" \
            sh "$DEP2/probe.sh" 2>/dev/null)
cp "$TMP/dsh-version.json" "$DEP2/dsh-version.json"
SSOT_PRIO=$(env -u DSH_SSOT DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$TMP/dsh-dep" DSH_DEPLOY_STATE="$STATE_ROOT" \
            sh "$DEP2/probe.sh" 2>/dev/null)
rm -f "$DEP2/dsh-version.json"
t SSOT-search "lib.sh 未设 DSH_SSOT 时按 同目录→上级目录 搜索 SSOT" \
  "$([ "$SSOT_SAME" = "$TMP/dsh-version.json" ] && [ "$SSOT_PRIO" = "$DEP2/dsh-version.json" ] && echo 1 || echo 0)" \
  "parent=$SSOT_SAME same=$SSOT_PRIO"

# ── #1 宿主同路径挂载（watchdog 容器）────────────────────────────────────
: > "$STUB_LOG"
env DSH_CHANNELS="alpha" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
  sh "$NAS/watchdog-container.sh" >/dev/null 2>&1; RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
log_has "$ALPHA_DIR:$ALPHA_DIR" || OK=0
grep -q '/dsh-app' "$STUB_LOG" && OK=0
grep -q "DSH_CHANNEL=alpha" "$STATE_ROOT/watchdog.crontab" 2>/dev/null || OK=0
t P0-1-wd "watchdog 容器按宿主同路径挂载 + 每通道 cron 行" "$OK" "rc=$RC"

# ── #9 dsh-safe-deploy 通道化 ─────────────────────────────────────────────
SAFE_REPO="$TMP/repo"
mkdir -p "$SAFE_REPO/scripts" "$SAFE_REPO/nas"
cp "$SAFE_DEPLOY" "$SAFE_REPO/scripts/dsh-safe-deploy"
cp "$NAS/lib.sh" "$SAFE_REPO/nas/lib.sh"
cat > "$SAFE_REPO/scripts/safe-deploy-policy.js" <<'STUB'
// 策略层替身：按 --channel 返回对应通道策略（契约 §5 CLI 形状）
const fs = require('fs');
const argv = process.argv.slice(2);
const get = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
fs.appendFileSync(process.env.STUB_LOG || '/dev/null', 'policy ' + argv.join(' ') + '\n');
const ch = get('--channel') || 'alpha';
const ssot = JSON.parse(fs.readFileSync(get('--ssot'), 'utf8'));
const primary = ssot.primaryChannel || 'alpha';
const c = (ssot.channels || {})[ch] || {};
const prod = c.production || (ch === primary ? (ssot.productionChannel || ssot.version) : '');
const cand = c.candidate || (ch === primary ? ssot.testCandidate : '');
process.stdout.write(JSON.stringify({
  channel: ch, port: c.port, container: c.container, project: c.project,
  currentVersion: prod, productionChannel: prod, testCandidate: cand || '(none)',
  targetChannel: '', upgradeRisk: process.env.STUB_RISK || 'LOW', migrationStatus: 'none',
  dataIsolationRequired: false, candidateIsNewer: !!cand && cand !== prod,
  promoteBlocked: false, otherBlockers: [], pluginBlockers: [], pluginWarnings: [], pluginClass: {},
  requiredRuntimeDependencies: [], optionalPlugins: [], pluginCompat: {},
  ssotSource: ssot.source, ssotUpdatedAt: ssot.updatedAt,
}, null, 2) + '\n');
STUB

SAFE_STATE="$TMP/safe-state"
# sd：以测试 SSOT/状态目录调用被测脚本（REPO_DIR 由脚本位置推断）
sd() { DSH_SSOT="$SSOT" DSH_STATE_DIR="$SAFE_STATE" DSH_LIB_SH="$SAFE_REPO/nas/lib.sh" \
       bash "$SAFE_REPO/scripts/dsh-safe-deploy" "$@"; }
sd_ssot() { local f="$1"; shift; DSH_SSOT="$f" DSH_STATE_DIR="$SAFE_STATE" DSH_LIB_SH="$SAFE_REPO/nas/lib.sh" \
       bash "$SAFE_REPO/scripts/dsh-safe-deploy" "$@"; }

: > "$STUB_LOG"
OUT=$(sd check --channel rc 2>&1)
t D9-channel "check --channel rc → 策略层收到 --channel rc，输出 rc 通道字段" \
  "$(has "$OUT" '"channel": "rc"' && has "$OUT" '"port": 3083' && log_has "policy --json --ssot $SSOT --channel rc" && echo 1 || echo 0)"

OUT=$(sd check 2>&1)
t D9-default "无 --channel → 默认取 SSOT primaryChannel（alpha）" \
  "$(has "$OUT" '"channel": "alpha"' && echo 1 || echo 0)"

SSOT_RC_PRIMARY="$TMP/ssot-rc-primary.json"
sed 's/"primaryChannel": "alpha"/"primaryChannel": "rc"/' "$SSOT" > "$SSOT_RC_PRIMARY"
OUT=$(sd_ssot "$SSOT_RC_PRIMARY" check 2>&1)
t D9-primary "primaryChannel=rc 的 SSOT → 默认通道为 rc" "$(has "$OUT" '"channel": "rc"' && echo 1 || echo 0)"

OUT=$(sd status --channel all 2>&1)
t D9-all "check/status --channel all → 逐通道输出" \
  "$(has "$OUT" '"channel": "alpha"' && has "$OUT" '"channel": "rc"' && echo 1 || echo 0)"

OUT=$(sd test --channel all 2>&1); RC=$?
t D9-allwrite "写操作 --channel all → 明确拒绝（必须单一通道）" "$([ "$RC" -ne 0 ] && has "$OUT" "必须指定单一" && echo 1 || echo 0)" "rc=$RC"

sd check --channel alpha >/dev/null 2>&1
sd check --channel rc >/dev/null 2>&1
t D9-state "状态目录按通道隔离（\$STATE_DIR/<channel>/）" \
  "$([ -d "$SAFE_STATE/alpha" ] && [ -d "$SAFE_STATE/rc" ] && echo 1 || echo 0)"

# rollback 路径与 SOURCE_HOME 对称（不再硬编码 /data/dsh）
RC_SRC="$TMP/rc-src"
mkdir -p "$RC_SRC/profiles/web" "$RC_SRC/backups/0.1.2-rc.1-20260101-000000/profiles/web"
for f in settings.yaml .credentials.yaml; do
  printf 'RESTORED-%s\n' "$f" > "$RC_SRC/backups/0.1.2-rc.1-20260101-000000/$f"
done
printf '{"name":"dsh-profile-web"}\n' > "$RC_SRC/backups/0.1.2-rc.1-20260101-000000/profiles/web/package.json"
printf 'CURRENT\n' > "$RC_SRC/settings.yaml"
printf 'CURRENT\n' > "$RC_SRC/.credentials.yaml"
printf '{"name":"dsh-profile-web"}\n' > "$RC_SRC/profiles/web/package.json"
: > "$STUB_LOG"
OUT=$(DSH_SOURCE_HOME_RC="$RC_SRC" DSH_ROLLBACK_VERSION=0.1.2-rc.1 \
      sd rollback --channel rc 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'RESTORED-settings.yaml' "$RC_SRC/settings.yaml" 2>/dev/null || OK=0
ls -d "$RC_SRC".pre-rollback-* >/dev/null 2>&1 || OK=0
grep -q 'DSH_PIN_VERSION=0.1.2-rc.1' "$RC_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PROJECT=dsh-rc' "$RC_DIR/.env" 2>/dev/null || OK=0
log_hasre "compose .* -p dsh-rc up -d" || OK=0
log_has "--project-directory $RC_DIR" || OK=0
t D9-rollback "rollback 恢复到 SOURCE_HOME（非硬编码 /data/dsh）+ 通道项目隔离" "$OK" "rc=$RC"

grep -qE 'tar -C /data/dsh' "$SAFE_DEPLOY" && OK=0 || OK=1
t D9-nohard "dsh-safe-deploy 无硬编码 /data/dsh 恢复路径" "$OK"

# promote：门禁 + 原子 pin（含 digest）+ 原子更新 SSOT production
ALPHA_SRC="$TMP/alpha-src"
mkdir -p "$ALPHA_SRC/profiles/web"
printf '{"name":"dsh-profile-web"}\n' > "$ALPHA_SRC/profiles/web/package.json"
printf 's\n' > "$ALPHA_SRC/settings.yaml"; printf 'c\n' > "$ALPHA_SRC/.credentials.yaml"
mkdir -p "$SAFE_STATE/alpha"; echo "TEST_VERDICT=PASS" > "$SAFE_STATE/alpha/last-test-verdict"
: > "$STUB_LOG"
OUT=$(DSH_SOURCE_HOME_ALPHA="$ALPHA_SRC" \
      sd promote --channel alpha 2>&1); RC=$?
OK=1
[ "$RC" -eq 0 ] || OK=0
grep -q 'DSH_PIN_VERSION=0.1.3-alpha.2' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
grep -q 'DSH_PIN_DIGEST=sha256:' "$ALPHA_DIR/.env" 2>/dev/null || OK=0
[ ! -f "$ALPHA_DIR/.env.pending" ] || OK=0
PROD=$(node -e "const j=require('$SSOT');console.log(j.channels.alpha.production)")
[ "$PROD" = "0.1.3-alpha.2" ] || OK=0
TOP=$(node -e "const j=require('$SSOT');console.log(j.version+'|'+j.productionChannel)")
[ "$TOP" = "0.1.3-alpha.2|0.1.3-alpha.2" ] || OK=0
t D9-promote "promote：事务化 pin（含 digest）+ 原子更新 SSOT channels.alpha.production" "$OK" "rc=$RC prod=$PROD"

OUT=$(DSH_SOURCE_HOME_ALPHA="$ALPHA_SRC" \
      sd promote --channel rc 2>&1); RC=$?
t D9-gate "promote 门禁：test 未 PASS → BLOCKED" "$([ "$RC" -ne 0 ] && has "$OUT" "BLOCKED" && echo 1 || echo 0)" "rc=$RC"

# ── semver 实现一致性（契约 §9：复用 version-policy.js 的 semver；无 node 时 awk 兜底）──
SEM_OK=1
for impl in auto node shell; do
  for pair in "0.1.2-alpha.10:0.1.2-alpha.9:1" "0.1.2:0.1.2-rc.1:1" "0.1.2-alpha.2:0.1.2-alpha.2:0" "0.1.2-beta.1:0.1.2-rc.1:-1"; do
    IFS=: read -r a b want <<< "$pair"
    got=$(run_lib "$ALPHA_DIR" alpha "semver_cmp $a $b" \
          DSH_SEMVER_IMPL="$impl" DSH_VERSION_POLICY_JS="$REPO_DIR/scripts/version-policy.js" 2>/dev/null)
    [ "$got" = "$want" ] || { SEM_OK=0; echo "  semver mismatch impl=$impl $a vs $b got=$got want=$want"; }
  done
done
t D3-semver "semver_cmp 三实现（auto/node+semver/shell-awk）结果一致" "$SEM_OK"

# ── 与真实策略层（契约 §5）集成：不使用 stub policy ───────────────────────
OUT=$(DSH_STATE_DIR="$SAFE_STATE/real" bash "$SAFE_DEPLOY" check --channel rc 2>&1)
t D9-realpolicy "真实 safe-deploy-policy.js --channel rc 集成" "$(has "$OUT" '"channel": "rc"' && echo 1 || echo 0)" "$(printf '%s' "$OUT" | grep -m1 '"channel"')"
OUT=$(DSH_STATE_DIR="$SAFE_STATE/real" bash "$SAFE_DEPLOY" check --channel all 2>&1)
t D9-realall "真实策略层 --channel all 同时返回 alpha+rc" \
  "$(has "$OUT" '"channel": "alpha"' && has "$OUT" '"channel": "rc"' && echo 1 || echo 0)"

# ── CLI 约定：nas 脚本只认 DSH_CHANNEL 环境变量，不接受 --channel 位置参数 ──
CLI_OK=1
cli_case() { # <脚本> <参数...>；断言 exit 2 且提示 DSH_CHANNEL
  local script="$1"; shift
  local out rc
  out=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT" \
        sh "$NAS/$script" "$@" 2>&1); rc=$?
  if [ "$rc" -ne 2 ] || ! printf '%s' "$out" | grep -q "DSH_CHANNEL"; then
    CLI_OK=0; echo "  CLI 约定不符：$script $* → rc=$rc out=$out"
  fi
}
cli_case rollback.sh --channel rc
cli_case install.sh --channel rc
cli_case switch.sh --channel rc
cli_case resume-auto-update.sh --channel rc
cli_case watchdog.sh --channel rc
cli_case watchdog-container.sh --channel rc
cli_case apply-igpu.sh /volume1/docker/dsh-alpha
t CLI-nas "nas/*.sh 拒绝 --channel/位置参数，并提示用 DSH_CHANNEL" "$CLI_OK"

# dsh-safe-deploy 是唯一接受 --channel 的入口；非法值必须报错
OUT=$(sd check --channel nope 2>&1); RC=$?
t CLI-safe "dsh-safe-deploy --channel 非法值 → 报错" "$([ "$RC" -ne 0 ] && has "$OUT" "非法 --channel" && echo 1 || echo 0)" "rc=$RC"
OUT=$(sd check --channel rc 2>&1); RC=$?
t CLI-safe-ok "dsh-safe-deploy --channel rc 正常" "$([ "$RC" -eq 0 ] && has "$OUT" '"channel": "rc"' && echo 1 || echo 0)" "rc=$RC"

# 旧格式 SSOT（无 channels）→ ssot_channel_production 回退顶层 productionChannel
SSOT_LEGACY="$TMP/ssot-legacy.json"
cat > "$SSOT_LEGACY" <<'JSON'
{"version":"0.1.2-alpha.5","productionChannel":"0.1.2-alpha.5","testCandidate":"0.1.3-alpha.2","source":"test"}
JSON
PROD=$(env DSH_CHANNEL=alpha DSH_DEPLOY_DIR="$ALPHA_DIR" DSH_DEPLOY_STATE="$STATE_ROOT" DSH_SSOT="$SSOT_LEGACY" \
       sh -c ". '$NAS/lib.sh'; ssot_channel_production alpha" 2>/dev/null)
t D2-legacy-ssot "旧格式 SSOT（无 channels）→ production 回退顶层 productionChannel" \
  "$([ "$PROD" = "0.1.2-alpha.5" ] && echo 1 || echo 0)" "got=$PROD"

# ── registry 泛化（任意 registry v2：ghcr 匿名 token / 内网 Basic / http 探测）──
OUT=$(run_lib "$ALPHA_DIR" alpha 'printf "%s|%s|%s|%s" "$(registry_of ghcr.io/llzg/dsh-docker)" "$(repo_of ghcr.io/llzg/dsh-docker)" "$(registry_of 192.168.5.35:5050/llzg/dsh-docker)" "$(repo_of 192.168.5.35:5050/llzg/dsh-docker)"' 2>/dev/null)
t REG-split "registry_of/repo_of 正确拆分 host 与 host:port" \
  "$([ "$OUT" = "ghcr.io|llzg/dsh-docker|192.168.5.35:5050|llzg/dsh-docker" ] && echo 1 || echo 0)" "got=$OUT"

: > "$STUB_LOG"
OUT=$(run_lib "$ALPHA_DIR" alpha 'registry_tags ghcr.io/llzg/dsh-docker' STUB_GHCR_TAGS='{"tags":["0.1.3-alpha.2","latest"]}' 2>&1)
t REG-ghcr "ghcr.io 仍走匿名 token 流（且过滤 latest）" \
  "$(has "$OUT" "0.1.3-alpha.2" && log_has 'ghcr.io/token' && echo 1 || echo 0)" "out=$(printf '%s' "$OUT" | tr '\n' ',')"

: > "$STUB_LOG"
OUT=$(run_lib "$ALPHA_DIR" alpha 'registry_tags 192.168.5.35:5050/llzg/dsh-docker' \
      DSH_REGISTRY_SCHEME=http DSH_REGISTRY_USER=ci-deploy DSH_REGISTRY_PASSWORD=stub-secret STUB_REQUIRE_BASIC=1 2>&1)
t REG-basic "http + Basic Auth 私有 registry 可列 tags" \
  "$(has "$OUT" "0.1.3-alpha.2" && log_has 'scheme=http' && log_has 'auth=Authorization: Basic' && echo 1 || echo 0)" "out=$(printf '%s' "$OUT" | tr '\n' ',')"

: > "$STUB_LOG"
OUT=$(run_lib "$ALPHA_DIR" alpha 'registry_tags 192.168.5.35:5050/llzg/dsh-docker' DSH_REGISTRY_SCHEME=http 2>&1)
t REG-anon "无凭据 registry 匿名可读" \
  "$(has "$OUT" "0.1.3-alpha.2" && log_has 'auth=none' && echo 1 || echo 0)" "out=$(printf '%s' "$OUT" | tr '\n' ',')"

: > "$STUB_LOG"
OUT=$(run_lib "$ALPHA_DIR" alpha 'registry_tags 192.168.5.35:5050/llzg/dsh-docker' STUB_HTTPS_FAIL=1 2>&1)
t REG-scheme "https 失败自动回退 http" \
  "$(has "$OUT" "0.1.3-alpha.2" && log_has 'scheme=http' && echo 1 || echo 0)" "out=$(printf '%s' "$OUT" | tr '\n' ',')"

OUT=$(run_lib "$ALPHA_DIR" alpha 'registry_tags 192.168.5.35:5050/llzg/dsh-docker' DSH_REGISTRY_SCHEME=http STUB_REG_401=1 2>&1); RC=$?
t REG-401 "401 → 非 0 且明确告警（不静默）" \
  "$([ "$RC" -ne 0 ] && has "$OUT" "registry 不可达或鉴权失败" && echo 1 || echo 0)" "rc=$RC"

OUT=$(run_lib "$ALPHA_DIR" alpha 'pull_image 192.168.5.35:5050/llzg/dsh-docker:0.1.3-alpha.2' \
      STUB_PULL_FAIL=1 STUB_PULL_ERR='Error response from daemon: unauthorized: authentication required' 2>&1); RC=$?
t REG-401-hint "pull 鉴权失败 → 提示 docker login / insecure-registries" \
  "$(has "$OUT" 'docker login 192.168.5.35:5050' && has "$OUT" 'insecure-registries' && echo 1 || echo 0)" "rc=$RC"

# 私有 registry 的镜像基址要能被 prev_version 消费（候选来自新 registry）
: > "$STUB_LOG"
OUT=$(run_lib "$ALPHA_DIR" alpha 'version_candidates' DSH_IMAGE_BASE=192.168.5.35:5050/llzg/dsh-docker DSH_REGISTRY_SCHEME=http 2>&1)
t REG-candidates "version_candidates 从私有 registry 取候选（过滤 latest）" \
  "$(has "$OUT" "0.1.2-alpha.5" && ! has "$OUT" "latest" && echo 1 || echo 0)" "out=$(printf '%s' "$OUT" | tr '\n' ',')"

# ── 语法门禁 ──────────────────────────────────────────────────────────────
SYNTAX_OK=1
for f in "$NAS"/lib.sh "$NAS"/install.sh "$NAS"/switch.sh "$NAS"/rollback.sh \
         "$NAS"/resume-auto-update.sh "$NAS"/watchdog.sh "$NAS"/watchdog-container.sh "$NAS"/apply-igpu.sh; do
  sh -n "$f" || SYNTAX_OK=0
  dash -n "$f" 2>/dev/null || SYNTAX_OK=0
done
bash -n "$SAFE_DEPLOY" || SYNTAX_OK=0
t SYNTAX "sh -n / dash -n / bash -n 全部通过" "$SYNTAX_OK"

echo
echo "----------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
