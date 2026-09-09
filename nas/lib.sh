#!/bin/sh
# dsh-deploy 共享函数库
#   rollback.sh / watchdog.sh / switch.sh / resume-auto-update.sh / apply-igpu.sh
#   / scripts/dsh-safe-deploy 共用。
#
# 目标解释器：POSIX sh（dash / busybox ash / Alpine）。禁止 bash 专有语法。
# 契约：docs/dual-channel.md §9（NAS 部署契约）
#   * 所有 compose 调用统一走 compose_cmd()：显式 -p / --project-directory / -f，
#     禁止依赖当前目录推断项目名（否则 project 会解析成挂载目录名、卷源会落到容器内路径）。
#   * pin_version() 事务化：.env.pending → 校验（project/卷源断言）→ 原子 mv → up --wait
#     （不可用则健康轮询）→ 失败还原旧 .env 并回滚容器。
#   * prev_version() 用 semver 比较，排除 <ver>-<sha> 不可变标签；当前版本不在候选列表
#     时返回非 0（不得回退成"列表最高"）。GHCR 不可达时降级为本地镜像标签并告警。
#   * 所有写操作加 flock（$STATE/deploy.lock）。
#   * DSH_PIN_REASON 取值：manual（人工钉住/回滚，watchdog 跳过）| auto-rollback（watchdog 自动
#     回滚，残留可重试）| ssot-production（resume/switch 跟随 SSOT production，watchdog 仍可自动回滚）。
#     注：契约 §9 只列了 manual|auto-rollback；ssot-production 是集成方要求的第三个取值，
#     watchdog 的判定是"仅 manual 跳过"，因此新增取值不改变回滚安全性。
#
# 环境覆盖（全部可选）：
#   DSH_CHANNEL=alpha|rc|stable   通道（默认 SSOT primaryChannel，再默认 alpha）
#   DSH_DEPLOY_DIR=<dir>          compose 目录（默认 SSOT channels[ch].dataDir / 内置表）
#   DSH_DEPLOY_STATE=<dir>        状态根目录（默认 /volume1/docker/dsh-deploy/state）
#   DSH_PROJECT DSH_CONTAINER DSH_PORT DSH_VERSION_PORT DSH_IMAGE_BASE DSH_SSOT
#   DSH_TRUSTED_HOST DSH_HOME DSH_LOCK_FILE DSH_HEALTH_RETRIES DSH_HEALTH_INTERVAL
#   DSH_WATCHDOG_THRESHOLD DSH_WATCHDOG_MAX_AGE DSH_GHCR_TIMEOUT DSH_DOCKER_CFG

LIB_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)

# ── 基础工具 ──────────────────────────────────────────────────────────────
log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null || true; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; return 1; }

# .env 读取（不存在时静默返回空）
env_get() { # <KEY> [file]
  _f="${2:-$DIR/.env}"
  [ -f "$_f" ] || return 0
  sed -n "s/^$1=//p" "$_f" 2>/dev/null | head -1
}

# ── 通道配置：环境变量 > SSOT channels[ch] > 内置默认表 ────────────────────
channel_default() { # <channel> <field> → value
  case "$1:$2" in
    alpha:port)        echo 3081 ;;
    alpha:versionPort) echo 3082 ;;
    alpha:container|alpha:project) echo dsh-alpha ;;
    alpha:dataDir)     echo /volume1/docker/dsh-alpha ;;
    rc:port)           echo 3083 ;;
    rc:versionPort)    echo 0 ;;
    rc:container|rc:project) echo dsh-rc ;;
    rc:dataDir)        echo /volume1/docker/dsh-rc ;;
    stable:port)       echo 3085 ;;
    stable:versionPort) echo 0 ;;
    stable:container|stable:project) echo dsh-stable ;;
    stable:dataDir)    echo /volume1/docker/dsh-stable ;;
    *) : ;;
  esac
}

# SSOT 单通道字段读取（jq 优先，node 兜底；两者都缺 → 返回 1 由调用方用默认表）
ssot_channel_field() { # <channel> <field>
  [ -n "${SSOT:-}" ] && [ -f "$SSOT" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg ch "$1" --arg f "$2" '((.channels // {})[$ch] // {})[$f] // empty' "$SSOT" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const c=(j.channels||{})[process.argv[2]]||{};if(c[process.argv[3]]!=null)console.log(String(c[process.argv[3]]));' "$SSOT" "$1" "$2" 2>/dev/null
  else
    return 1
  fi
}

# SSOT 顶层字段读取（旧格式兼容：version / productionChannel）
ssot_top_field() { # <field>
  [ -n "${SSOT:-}" ] && [ -f "$SSOT" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$1" '.[$f] // empty' "$SSOT" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=j[process.argv[2]];if(v!=null)process.stdout.write(String(v));' "$SSOT" "$1" 2>/dev/null
  else
    return 1
  fi
}

# 该通道的 production 版本（resume/switch 的目标版本，契约：恢复跟随 SSOT 而非 latest）
# 新格式：channels.<ch>.production；旧格式（无 channels）：仅 primary 通道回退顶层 productionChannel/version
ssot_channel_production() { # <channel>
  _sp=$(ssot_channel_field "$1" production)
  if [ -z "$_sp" ]; then
    _sprim=$(ssot_primary_channel)
    if [ -z "$_sprim" ] || [ "$_sprim" = "$1" ]; then
      _sp=$(ssot_top_field productionChannel)
      [ -n "$_sp" ] || _sp=$(ssot_top_field version)
    fi
  fi
  printf '%s' "$_sp"
}

ssot_primary_channel() {
  [ -n "${SSOT:-}" ] && [ -f "$SSOT" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.primaryChannel // empty' "$SSOT" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(j.primaryChannel)console.log(j.primaryChannel);' "$SSOT" 2>/dev/null
  else
    return 1
  fi
}

# SSOT 中的通道列表（--channel all 用）
ssot_channels() {
  [ -n "${SSOT:-}" ] && [ -f "$SSOT" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.channels // {}) | keys[]' "$SSOT" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));Object.keys(j.channels||{}).forEach(k=>console.log(k));' "$SSOT" 2>/dev/null
  else
    return 1
  fi
}

# ── semver 比较（契约 §9）────────────────────────────────────────────────
# 用法: semver_cmp A B → stdout -1 | 0 | 1；A/B 非法 → exit 2
# 实现优先级（DSH_SEMVER_IMPL=auto|node|shell，默认 auto）：
#   1) node + 仓库 scripts/version-policy.js 的 semver()（契约要求复用，宿主/容器内 node 可用时）
#   2) 内置 POSIX awk 实现（watchdog 容器只装 docker-cli/jq/curl/coreutils/util-linux，无 node）
# 两种实现语义一致：core 数值比较；无 prerelease > 有 prerelease；数字标识符 < 字母标识符。
semver_impl_path() {
  for _p in "$LIB_DIR/version-policy.js" "$LIB_DIR/../scripts/version-policy.js" \
            "$LIB_DIR/scripts/version-policy.js" "${DSH_VERSION_POLICY_JS:-}"; do
    if [ -n "$_p" ] && [ -f "$_p" ]; then printf '%s' "$_p"; return 0; fi
  done
  return 1
}

semver_cmp_node() { # <version-policy.js> <a> <b>
  node -e '
    let p; try { p = require(process.argv[1]); } catch (e) { process.exit(3); }
    let sv; try { sv = p.semver(); } catch (e) { process.exit(3); }
    const a = sv.valid(process.argv[2]), b = sv.valid(process.argv[3]);
    if (!a || !b) process.exit(2);
    if (sv.lt(a, b)) process.stdout.write("-1");
    else if (sv.gt(a, b)) process.stdout.write("1");
    else process.stdout.write("0");
  ' "$1" "$2" "$3"
}

semver_cmp() {
  case "${DSH_SEMVER_IMPL:-auto}" in
    shell|awk)
      semver_cmp_shell "$1" "$2"
      return $?
      ;;
    node)
      _sp=$(semver_impl_path) || { warn "version-policy.js 不可用（DSH_SEMVER_IMPL=node）"; return 2; }
      semver_cmp_node "$_sp" "$1" "$2"
      return $?
      ;;
  esac
  if command -v node >/dev/null 2>&1; then
    _sp=$(semver_impl_path) || _sp=""
    if [ -n "$_sp" ]; then
      _out=$(semver_cmp_node "$_sp" "$1" "$2" 2>/dev/null) || _out=""
      case "$_out" in
        -1|0|1) printf '%s' "$_out"; return 0 ;;
      esac
    fi
  fi
  semver_cmp_shell "$1" "$2"
}

semver_cmp_shell() { # <a> <b>（纯 POSIX awk，无 node 依赖）
  awk -v A="$1" -v B="$2" '
    function parse(v,   i, n, core, pre, cp, np) {
      sub(/\+.*$/, "", v)
      n = index(v, "-")
      if (n > 0) { core = substr(v, 1, n - 1); pre = substr(v, n + 1) } else { core = v; pre = "" }
      np = split(core, cp, ".")
      if (np != 3) return 0
      for (i = 1; i <= 3; i++) if (cp[i] !~ /^[0-9]+$/) return 0
      g_maj = cp[1] + 0; g_min = cp[2] + 0; g_pat = cp[3] + 0; g_pre = pre
      return 1
    }
    function cmp_pre(a, b,   na, nb, i, x, y, xa, xb) {
      if (a == "" && b == "") return 0
      if (a == "") return 1
      if (b == "") return -1
      na = split(a, xa, "."); nb = split(b, xb, ".")
      for (i = 1; i <= na && i <= nb; i++) {
        x = xa[i]; y = xb[i]
        if (x == y) continue
        xn = (x ~ /^[0-9]+$/); yn = (y ~ /^[0-9]+$/)
        if (xn && yn) return (x + 0 < y + 0) ? -1 : 1
        if (xn) return -1
        if (yn) return 1
        return (x < y) ? -1 : 1
      }
      if (na == nb) return 0
      return (na < nb) ? -1 : 1
    }
    BEGIN {
      if (!parse(A)) exit 2
      amaj = g_maj; amin = g_min; apat = g_pat; apre = g_pre
      if (!parse(B)) exit 2
      bmaj = g_maj; bmin = g_min; bpat = g_pat; bpre = g_pre
      if (amaj != bmaj) { print (amaj < bmaj) ? -1 : 1; exit }
      if (amin != bmin) { print (amin < bmin) ? -1 : 1; exit }
      if (apat != bpat) { print (apat < bpat) ? -1 : 1; exit }
      print cmp_pre(apre, bpre)
    }
  '
}

# 可回滚的发布标签：x.y.z 或 x.y.z-alpha.N / -beta.N / -rc.N
# 排除 latest 与 <ver>-<sha> 不可变标签（sha 段不是 alpha/beta/rc.N）
is_release_tag() {
  case "${1:-}" in
    *[!0-9A-Za-z.-]*) return 1 ;;
  esac
  printf '%s' "${1:-}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'
}

# ── 版本候选来源 ──────────────────────────────────────────────────────────
# GHCR 标签列表（匿名 token 优先，失败再试 docker 凭据）。不可达 → 非 0。
ghcr_tags() {
  _tok=$(curl -sf --max-time "${DSH_GHCR_TIMEOUT:-10}" \
      "https://ghcr.io/token?scope=repository:llzg/dsh-docker:pull&service=ghcr.io" 2>/dev/null \
      | jq -r '.token // empty' 2>/dev/null || true)
  _hdr=""
  [ -n "$_tok" ] && _hdr="Authorization: Bearer $_tok"
  if [ -z "$_hdr" ] && [ -n "${DSH_DOCKER_CFG:-}" ] && [ -f "${DSH_DOCKER_CFG:-}" ]; then
    _auth=$(jq -r '.auths["ghcr.io"].auth // empty' "$DSH_DOCKER_CFG" 2>/dev/null || true)
    [ -n "$_auth" ] && _hdr="Authorization: Basic $_auth"
  fi
  [ -n "$_hdr" ] || { warn "GHCR 匿名 token 获取失败（无可用凭据）"; return 1; }
  _out=$(curl -sf --max-time "${DSH_GHCR_TIMEOUT:-10}" -H "$_hdr" \
      "https://ghcr.io/v2/llzg/dsh-docker/tags/list" 2>/dev/null) || return 1
  [ -n "$_out" ] || return 1
  printf '%s' "$_out" | jq -r '.tags[]? // empty' 2>/dev/null | grep -v '^latest$' || true
}

# 本地镜像标签（GHCR 降级路径）
local_tags() {
  docker image ls --format '{{.Tag}}' "$IMG" 2>/dev/null \
    | grep -v '^<none>$' | grep -v '^latest$' || true
}

# 候选版本集合（已过滤不可变/非法标签）
version_candidates() {
  _list=$(ghcr_tags 2>/dev/null) || _list=""
  if [ -z "$_list" ]; then
    warn "GHCR 不可达 → 降级使用本地镜像标签作为回滚候选（候选集可能不完整）"
    _list=$(local_tags)
    [ -n "$_list" ] || { warn "GHCR 与本地镜像均无候选标签"; return 1; }
  fi
  printf '%s\n' "$_list" | while read -r _t; do
    is_release_tag "$_t" && printf '%s\n' "$_t"
  done | sort -u
}

# 当前版本的前一个版本（严格 semver 更低者中的最高者）
# 当前版本不在候选列表 → 报错返回非 0（历史缺陷：会静默返回列表最高版本 = 回滚变升级）
prev_version() { # <current>
  _cur="${1:-}"
  [ -n "$_cur" ] || { warn "prev_version 缺少当前版本参数"; return 2; }
  if ! is_release_tag "$_cur"; then
    warn "当前版本 '$_cur' 不是可比较的发布标签（不可变 <ver>-<sha> 标签或非法版本）"
    return 2
  fi
  _cands=$(version_candidates) || return 1
  [ -n "$_cands" ] || { warn "无候选版本"; return 1; }

  _found=0
  for _v in $_cands; do
    [ "$_v" = "$_cur" ] && _found=1
  done
  if [ "$_found" -ne 1 ]; then
    warn "当前版本 $_cur 不在候选列表（GHCR/本地）中 —— 拒绝回滚，绝不回退成列表最高版本"
    return 1
  fi

  _best=""
  for _v in $_cands; do
    [ "$_v" = "$_cur" ] && continue
    _c=$(semver_cmp "$_v" "$_cur" 2>/dev/null) || continue
    [ "$_c" = "-1" ] || continue
    if [ -z "$_best" ]; then _best="$_v"; continue; fi
    _c2=$(semver_cmp "$_v" "$_best" 2>/dev/null) || continue
    [ "$_c2" = "1" ] && _best="$_v"
  done
  if [ -z "$_best" ]; then
    warn "$_cur 已是最早的已发布版本，无更早版本可回滚"
    return 1
  fi
  printf '%s\n' "$_best"
}

# ── compose 调用（唯一入口）───────────────────────────────────────────────
# 显式 -p / --project-directory / -f；可选 override：versionpage（DSH_VERSION_PORT!=0）、igpu。
compose_cmd() {
  if [ -f "$DIR/docker-compose.igpu.yml" ]; then
    set -- -f "$DIR/docker-compose.igpu.yml" "$@"
  fi
  if [ -f "$DIR/docker-compose.versionpage.yml" ] && [ "${VERSION_PORT:-0}" != "0" ]; then
    set -- -f "$DIR/docker-compose.versionpage.yml" "$@"
  fi
  set -- -f "$DIR/docker-compose.yml" --project-directory "$DIR" -p "$PROJECT" "$@"
  docker compose "$@"
}

# compose 生效配置（JSON 优先，失败退回 YAML 文本）
# DSH_IMAGE 现在是 compose 必填（${DSH_IMAGE:?...}）：校验阶段用占位 tag，
# 使"上下文断言"只关心 project/卷源，不因缺 .env 而误报；真正的 up 仍会因缺 DSH_IMAGE 而失败。
compose_config_json() {
  DSH_IMAGE="${DSH_IMAGE:-$IMG:validation-only}" compose_cmd config --format json 2>/dev/null || true
}
compose_config_yaml() {
  DSH_IMAGE="${DSH_IMAGE:-$IMG:validation-only}" compose_cmd config 2>/dev/null || true
}

cfg_get_name() { # <json>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '.name // empty' 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).name||"")}catch(e){}})'
  fi
}
cfg_get_bind_sources() { # <json>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '[.services[]?.volumes[]? | select((.type // "") == "bind") | .source] | .[]' 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const out=[];for(const svc of Object.values(j.services||{}))for(const v of (svc.volumes||[]))if((v.type||"")==="bind"&&v.source)out.push(v.source);console.log(out.join("\n"))}catch(e){}})'
  fi
}
cfg_get_container_names() { # <json>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '[.services[]?.container_name // empty] | .[]' 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const out=[];for(const svc of Object.values(j.services||{}))if(svc.container_name)out.push(svc.container_name);console.log(out.join("\n"))}catch(e){}})'
  fi
}

# 校验 compose 上下文：项目名 == PROJECT，所有 bind 卷源落在 DIR 下。
# 打印错误行（无输出 = 通过）；返回 0 通过 / 1 失败。
validate_compose_context() {
  _errs=0
  _json=$(compose_config_json)
  if [ -n "$_json" ] && printf '%s' "$_json" | grep -q '"name"'; then
    _name=$(cfg_get_name "$_json")
    _sources=$(cfg_get_bind_sources "$_json")
    _cnames=$(cfg_get_container_names "$_json")
  else
    _yaml=$(compose_config_yaml)
    if [ -z "$_yaml" ]; then
      echo "compose_config_failed: docker compose config 无输出（无法断言项目名/卷源）"
      return 1
    fi
    _name=$(printf '%s\n' "$_yaml" | awk '$1 == "name:" { print $2; exit }')
    _sources=$(printf '%s\n' "$_yaml" | awk '$1 == "source:" && $2 ~ /^\// { print $2 }')
    _cnames=$(printf '%s\n' "$_yaml" | awk '$1 == "container_name:" { print $2 }')
  fi

  if [ -z "$_name" ]; then
    echo "project_name_unresolved: compose config 未解析出 name（期望 $PROJECT）"
    _errs=1
  elif [ "$_name" != "$PROJECT" ]; then
    echo "project_name_mismatch: got=$_name expected=$PROJECT（禁止依赖 cwd 推断项目名）"
    _errs=1
  fi

  if [ -z "$_sources" ]; then
    echo "volume_source_unresolved: compose config 未解析出 bind 卷源（期望全部落在 $DIR 下）"
    _errs=1
  fi
  for _s in $_sources; do
    case "$_s" in
      "$DIR"|"$DIR"/*) : ;;
      *) echo "volume_source_outside_project: got=$_s expected_under=$DIR"; _errs=1 ;;
    esac
  done

  for _cn in $_cnames; do
    if [ "$_cn" != "$CONTAINER" ]; then
      echo "container_name_mismatch: got=$_cn expected=$CONTAINER"
      _errs=1
    fi
  done
  return $_errs
}

# ── 事务化 pin ────────────────────────────────────────────────────────────
image_digest() { # <image-ref>
  _d=$(docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || true)
  [ -n "$_d" ] || _d=$(docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true)
  printf '%s' "$_d"
}

# 通道身份行（stdout）
# DSH_HOME 写契约默认值 /data/dsh（与 docker-compose.yml 的容器 env/卷 target 一致）；
# 不使用调用者 shell 里的 DSH_HOME，避免 pin 时被外部环境意外改写数据目录。
env_identity_lines() {
  printf '# 通道身份由 nas/lib.sh 生成（契约 §6 / §9）；钉住信息由 pin_version 追加\n'
  printf 'DSH_CHANNEL=%s\n' "$CHANNEL"
  printf 'DSH_PROJECT=%s\n' "$PROJECT"
  printf 'DSH_CONTAINER=%s\n' "$CONTAINER"
  printf 'DSH_PORT=%s\n' "$PORT"
  printf 'DSH_VERSION_PORT=%s\n' "$VERSION_PORT"
  printf 'DSH_HOME=/data/dsh\n'
  printf 'DSH_TRUSTED_HOST=%s\n' "$TRUSTED_HOST"
}

write_identity_env() { # <path> —— 只写通道身份（不含 DSH_IMAGE/DSH_PIN_*）
  env_identity_lines > "$1"
}

# 写 .env（不重建容器）：pin 事务 / install 初始化 / resume 回退共用同一格式。
# 注意：image-tag 可以是 latest 这类非发布标签（install/resume 回退路径）。
write_env_image() { # <image-tag> <reason> <digest-or-empty> <path>
  {
    env_identity_lines
    printf 'DSH_IMAGE=%s:%s\n' "$IMG" "$1"
    printf 'DSH_PIN_VERSION=%s\n' "$1"
    printf 'DSH_PIN_REASON=%s\n' "$2"
    printf 'DSH_PIN_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%F %T')"
    if [ -n "$3" ]; then
      printf 'DSH_PIN_DIGEST=%s\n' "$3"
    fi
    : # 保证块退出码为 0（无 digest 时上一条 if 不执行）
  } > "$4"
}

write_pending_env() { # <version> <reason> <digest> <path>
  write_env_image "$1" "$2" "$3" "$4"
}

# 健康轮询（compose up --wait 不可用时的兜底）
health_poll() {
  _i=0
  _n=${DSH_HEALTH_RETRIES:-30}
  while [ "$_i" -lt "$_n" ]; do
    _h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo missing)
    _run=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)
    case "$_h" in
      healthy) return 0 ;;
      none) [ "$_run" = "true" ] && return 0 ;;
      unhealthy|starting) : ;;
      missing) : ;;
    esac
    _i=$((_i + 1))
    sleep "${DSH_HEALTH_INTERVAL:-5}"
  done
  warn "健康轮询超时（${_n} 次 × ${DSH_HEALTH_INTERVAL:-5}s，container=$CONTAINER）"
  return 1
}

compose_up_wait() {
  if compose_cmd up -d --force-recreate --wait >/dev/null 2>&1; then
    return 0
  fi
  # 旧 compose 不支持 --wait：普通 up + 健康轮询
  if ! compose_cmd up -d --force-recreate >/dev/null 2>&1; then
    return 1
  fi
  health_poll
}

restore_previous_env() { # <backup-file-or-empty>
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    cp -p "$1" "$DIR/.env"
  else
    write_identity_env "$DIR/.env"
  fi
  compose_cmd up -d --force-recreate >/dev/null 2>&1 || warn "还原旧 .env 后 compose up 仍失败（需人工介入）"
}

# 事务化 pin（调用方必须已持锁）
pin_version_locked() { # <version> [reason=manual] [digest]
  _v="${1:-}"
  _reason="${2:-manual}"
  _digest="${3:-}"
  [ -n "$_v" ] || { warn "pin_version 缺少版本参数"; return 2; }
  case "$CHANNEL" in
    alpha|beta|rc) : ;;
    *) warn "通道 $CHANNEL 本期不启用部署（契约 §2：stable 仅保留结构与策略支持）"; return 2 ;;
  esac
  if ! is_release_tag "$_v"; then
    warn "拒绝 pin 非法/不可变标签：$_v"
    return 2
  fi
  mkdir -p "$DIR" "$STATE" 2>/dev/null || true

  # 1) 先拉镜像（失败则完全不碰 .env）
  if ! docker pull "$IMG:$_v" >/dev/null 2>&1; then
    warn "镜像拉取失败：$IMG:$_v（.env 未改动）"
    return 1
  fi
  [ -n "$_digest" ] || _digest=$(image_digest "$IMG:$_v")

  # 2) 备份旧 .env
  _bak=""
  if [ -f "$DIR/.env" ]; then
    _bak="$STATE/env.pre-pin.$(date +%s).$_v"
    cp -p "$DIR/.env" "$_bak"
  fi

  # 3) 写 .env.pending 并校验（导出 pending 变量供 compose 插值，环境变量优先于旧 .env）
  _pending="$DIR/.env.pending"
  write_pending_env "$_v" "$_reason" "$_digest" "$_pending" || return 1
  _rc=0
  _errs=$(
    set -a
    # shellcheck disable=SC1090
    . "$_pending"
    set +a
    validate_compose_context
  ) || _rc=1
  if [ "$_rc" -ne 0 ] || [ -n "$_errs" ]; then
    warn "pin 校验失败，拒绝执行："
    printf '%s\n' "$_errs" >&2
    rm -f "$_pending"
    return 1
  fi

  # 4) 原子生效
  mv -f "$_pending" "$DIR/.env" || { rm -f "$_pending"; warn ".env 原子替换失败"; return 1; }

  # 5) 切换容器；失败还原
  if ! compose_up_wait; then
    warn "pin $_v 后容器未就绪 → 还原旧 .env 并回滚容器"
    restore_previous_env "$_bak"
    log "pin $CHANNEL -> $_v FAILED (reason=$_reason); restored ${_bak:-no-previous-env}"
    return 1
  fi
  log "pin $CHANNEL -> $_v OK (reason=$_reason digest=${_digest:-none})"
  return 0
}

# 公共入口：加锁
pin_version() { # <version> [reason=manual]
  with_lock pin_version_locked "$1" "${2:-manual}"
}

# 恢复到该通道"应有的版本"（resume-auto-update.sh / switch.sh 未钉住时使用）：
#   1) SSOT channels.<ch>.production 可用 → 事务化 pin（DSH_PIN_REASON=ssot-production）
#      —— 用 ssot-production 而不是 manual，保证 watchdog 仍能对不健康容器自动回滚；
#   2) 版本缺失/镜像不可用 → 显式钉住 latest（reason=ssot-fallback）并强告警
#      （compose 已不再提供默认镜像：${DSH_IMAGE:?…} 必填；latest 只由 stable 通道发布，
#       所以这是"明确降级"而不是"静默降级"）。
resume_to_channel_production() {
  _rt=$(ssot_channel_production "$CHANNEL")
  if [ -n "$_rt" ]; then
    echo "resume: 通道 $CHANNEL 目标版本 $_rt（来源: SSOT channels.$CHANNEL.production，SSOT=$SSOT）"
    if is_release_tag "$_rt"; then
      if pin_version_locked "$_rt" ssot-production; then
        log "resume $CHANNEL -> $_rt (source=ssot-production)"
        return 0
      fi
      warn "SSOT production 版本 $IMG:$_rt 不可用（拉取/校验/就绪失败）→ 显式回退 $IMG:latest"
    else
      warn "SSOT production '$_rt' 不是合法发布标签 → 显式回退 $IMG:latest"
    fi
  else
    warn "SSOT 未提供 channels.$CHANNEL.production（SSOT=$SSOT）→ 显式回退 $IMG:latest"
  fi
  warn "回退：显式钉住 $IMG:latest（DSH_PIN_REASON=ssot-fallback）——latest 仅由 stable 通道发布，alpha/rc 可能被降级，请人工确认目标版本"
  write_env_image "latest" "ssot-fallback" "" "$DIR/.env.pending" || return 1
  mv -f "$DIR/.env.pending" "$DIR/.env" || return 1
  compose_cmd pull >/dev/null 2>&1 || warn "compose pull 失败（继续尝试 up）"
  compose_up_wait || { warn "回退 latest 后容器未就绪"; return 1; }
  log "resume $CHANNEL -> latest (fallback, reason=ssot-fallback)"
  return 0
}

unpin_locked() { resume_to_channel_production; }

unpin() { with_lock unpin_locked; }

current_version() {
  _v=$(env_get DSH_PIN_VERSION)
  [ -n "$_v" ] || _v=$(env_get DSH_IMAGE)
  case "$_v" in *:*) _v="${_v##*:}" ;; esac
  if [ -z "$_v" ]; then
    _v=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)
  fi
  printf '%s' "$_v"
}

# ── 并发锁 ────────────────────────────────────────────────────────────────
with_lock() { # <command> [args...]
  mkdir -p "$STATE_ROOT" "$STATE" 2>/dev/null || true
  _rc=0
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock 不可用，跳过并发锁（$LOCK_FILE）—— 并发写操作有风险"
    "$@" || _rc=$?
    return $_rc
  fi
  exec 9>"$LOCK_FILE" || { warn "无法创建锁文件 $LOCK_FILE"; return 1; }
  if ! flock -n 9; then
    warn "LOCKED: 另一部署操作进行中（$LOCK_FILE）；并发 pin/rollback/promote 已阻止"
    exec 9>&-
    return 3
  fi
  "$@" || _rc=$?
  exec 9>&-
  return $_rc
}

# ── 时间工具 ──────────────────────────────────────────────────────────────
# ISO8601 → epoch 秒（GNU date / busybox+coreutils / BSD date / node 兜底）
iso_to_epoch() { # <iso8601>
  _s="${1:-}"
  [ -n "$_s" ] || return 1
  _e=""
  _e=$(date -u -d "$_s" +%s 2>/dev/null) || _e=""
  if [ -z "$_e" ]; then
    _t="${_s%%.*}"
    _e=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$_t" +%s 2>/dev/null) || _e=""
  fi
  if [ -z "$_e" ] && command -v node >/dev/null 2>&1; then
    _e=$(node -e 'const t=Date.parse(process.argv[1]);if(!isNaN(t))process.stdout.write(String(Math.floor(t/1000)))' "$_s" 2>/dev/null) || _e=""
  fi
  [ -n "$_e" ] || return 1
  printf '%s' "$_e"
}

age_seconds() { # <iso8601> → 秒
  _e=$(iso_to_epoch "$1") || return 1
  _now=$(date -u +%s)
  printf '%s' "$((_now - _e))"
}

# ── iGPU override 生成（defect 8：/dev/dri 不再硬要求，改为独立 override）──
igpu_override_write() { # [device]
  _dev="${1:-/dev/dri}"
  _f="$DIR/docker-compose.igpu.yml"
  mkdir -p "$DIR" 2>/dev/null || true
  {
    printf '# 由 apply-igpu.sh 生成：Intel 核显直通（base compose 不再硬依赖 /dev/dri）\n'
    printf '# 删除本文件即回退到无核显配置：rm %s\n' "$_f"
    printf 'services:\n'
    printf '  %s:\n' "$SERVICE"
    printf '    devices:\n'
    printf '      - %s:%s\n' "$_dev" "$_dev"
  } > "$_f"
  printf '%s\n' "$_f"
}

# ── 初始化 ────────────────────────────────────────────────────────────────
# SSOT 多路径解析（部署目录常常只拷了 nas/，仓库根的 dsh-version.json 不在旁边）：
#   $DSH_SSOT → 脚本同目录 → 脚本上级目录（仓库根）→ 容器内 /root/nas_docker
# 全部不存在时保留默认路径（调用方会退回内置默认表，并在需要时明确告警）。
lib_ssot_resolve() {
  if [ -n "${DSH_SSOT:-}" ]; then
    SSOT="$DSH_SSOT"
    return 0
  fi
  for _c in "$LIB_DIR/dsh-version.json" "$LIB_DIR/../dsh-version.json" "/root/nas_docker/dsh-version.json"; do
    if [ -f "$_c" ]; then
      _n=$(readlink -f "$_c" 2>/dev/null) || _n=""
      [ -n "$_n" ] && _c="$_n"
      SSOT="$_c"
      return 0
    fi
  done
  SSOT="$LIB_DIR/dsh-version.json"
  return 0
}

lib_init() {
  lib_ssot_resolve
  IMG="${DSH_IMAGE_BASE:-ghcr.io/llzg/dsh-docker}"
  SERVICE="${DSH_SERVICE:-dsh}"
  TRUSTED_HOST="${DSH_TRUSTED_HOST:-192.168.5.17}"

  CHANNEL="${DSH_CHANNEL:-}"
  if [ -z "$CHANNEL" ]; then
    CHANNEL=$(ssot_primary_channel) || CHANNEL=""
  fi
  [ -n "$CHANNEL" ] || CHANNEL="alpha"

  PROJECT="${DSH_PROJECT:-}"
  [ -n "$PROJECT" ] || PROJECT=$(ssot_channel_field "$CHANNEL" project)
  [ -n "$PROJECT" ] || PROJECT=$(channel_default "$CHANNEL" project)
  [ -n "$PROJECT" ] || PROJECT="dsh-$CHANNEL"

  CONTAINER="${DSH_CONTAINER:-}"
  [ -n "$CONTAINER" ] || CONTAINER=$(ssot_channel_field "$CHANNEL" container)
  [ -n "$CONTAINER" ] || CONTAINER=$(channel_default "$CHANNEL" container)
  [ -n "$CONTAINER" ] || CONTAINER="dsh-$CHANNEL"

  PORT="${DSH_PORT:-$(ssot_channel_field "$CHANNEL" port)}"
  [ -n "$PORT" ] || PORT=$(channel_default "$CHANNEL" port)

  VERSION_PORT="${DSH_VERSION_PORT:-$(ssot_channel_field "$CHANNEL" versionPort)}"
  [ -n "$VERSION_PORT" ] || VERSION_PORT=$(channel_default "$CHANNEL" versionPort)
  [ -n "$VERSION_PORT" ] || VERSION_PORT=0

  _data_dir=$(ssot_channel_field "$CHANNEL" dataDir)
  [ -n "$_data_dir" ] || _data_dir=$(channel_default "$CHANNEL" dataDir)
  DIR="${DSH_DEPLOY_DIR:-$_data_dir}"
  [ -n "$DIR" ] || DIR="/volume1/docker/$PROJECT"

  STATE_ROOT="${DSH_DEPLOY_STATE:-/volume1/docker/dsh-deploy/state}"
  # 通道隔离：$STATE_ROOT/<channel>/
  STATE="$STATE_ROOT/$CHANNEL"
  LOCK_FILE="${DSH_LOCK_FILE:-$STATE/deploy.lock}"
  LOG="$STATE/$CHANNEL-rollback.log"
  WLOG="$STATE/$CHANNEL-watchdog.log"
  mkdir -p "$STATE" 2>/dev/null || true
}

lib_init
