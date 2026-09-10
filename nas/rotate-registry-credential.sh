#!/bin/sh
# rotate-registry-credential.sh —— 私有 registry 凭据轮换：把新密码同步到所有使用它的地方。
#
# 为什么需要：这套凭据散落在 **4 个地方**，漏掉任何一处都会在几小时后以
# "no basic auth credentials" / 403 / CI 推送失败的形式炸出来（2026-09-10 实测）：
#   1) registry 主机上的 htpasswd（**本脚本不碰**，需要你在 registry 主机上先改）
#   2) 宿主 ~/.docker/config.json（docker login）
#   3) /volume1/docker/dsh-deploy/.env（dsh-safe-deploy / 版本页查询用）
#   4) GitHub 仓库 secrets DSH_REGISTRY_USER / DSH_REGISTRY_PASSWORD（CI 推送用）
#   5) dsh-version 容器的 env（版本页查内网 registry 用）
#
# 用法（在宿主 UGREEN 的 dsh-deploy 目录下）：
#   DSH_NEW_PASSWORD='新密码' sh rotate-registry-credential.sh
#   DSH_NEW_PASSWORD='新密码' sh rotate-registry-credential.sh --user ci-deploy --dry-run
#
# 参数：
#   --user <名字>            用户名（默认 DSH_REGISTRY_USER 或 ci-deploy）
#   --registry <host:port>   私有 registry（默认 DSH_PRIVATE_REGISTRY 或 192.168.5.35:5050）
#   --dry-run                只做验证与打印，不改任何东西
#   --skip-github            不更新 GitHub secrets
#   --skip-container         不重建 dsh-version 容器
#   --skip-login             不执行 docker login
#
# 退出码：0 = 全部完成；1 = 失败（并在失败处停下，不做半套）。
#
# ⚠ 密码只通过环境变量传入，脚本内部一律走 stdin / 0600 临时文件，不进 argv（ps 看不到）。
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/.env" ] || [ -f "$SELF_DIR/recreate-dsh.py" ]; then
  DEPLOY_DIR="$SELF_DIR"
else
  DEPLOY_DIR="$(cd "$SELF_DIR/.." && pwd)"
fi

REG="${DSH_PRIVATE_REGISTRY:-192.168.5.35:5050}"
USER_="${DSH_REGISTRY_USER:-ci-deploy}"
DRY=0; DO_GH=1; DO_CONTAINER=1; DO_LOGIN=1; VER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_="$2"; shift 2 ;;
    --registry) REG="$2"; shift 2 ;;
    --version) VER="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --skip-github) DO_GH=0; shift ;;
    --skip-container) DO_CONTAINER=0; shift ;;
    --skip-login) DO_LOGIN=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ -z "${DSH_NEW_PASSWORD:-}" ]; then
  echo "ERROR: 请用 DSH_NEW_PASSWORD='新密码' 传入新密码（避免进 shell 历史/ps）" >&2
  exit 1
fi

ENV_FILE="$DEPLOY_DIR/.env"
say() { printf '  %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "部署目录: $DEPLOY_DIR"
say "registry : $REG   用户名: $USER_"
say "dry-run  : $DRY   (1=不改动)"
echo

# ── 1) 先验证新密码真的能用：密码错就立刻停，绝不把坏密码铺开 ────────────────
say "[1/5] 验证新凭据（docker login）"
if [ "$DO_LOGIN" = "1" ]; then
  # dry-run 时把 docker login 写到一个临时 DOCKER_CONFIG，绝不碰宿主的 ~/.docker/config.json
  if [ "$DRY" = "1" ]; then
    _dc="$(mktemp -d)"; _rc=0
    printf '%s' "$DSH_NEW_PASSWORD" | DOCKER_CONFIG="$_dc" docker login "$REG" -u "$USER_" --password-stdin >/dev/null 2>&1 || _rc=$?
    rm -rf "$_dc"
    [ "$_rc" = "0" ] && say "      docker login 成功 ✓（dry-run：凭据只写临时目录，宿主 config 未改动）" \
                     || die "docker login 失败 —— 新密码在 registry 侧还没生效？先确认 registry 的 htpasswd 已更新"
  elif printf '%s' "$DSH_NEW_PASSWORD" | docker login "$REG" -u "$USER_" --password-stdin >/dev/null 2>&1; then
    say "      docker login 成功 ✓"
  else
    die "docker login 失败 —— 新密码在 registry 侧还没生效？先确认 registry 的 htpasswd 已更新"
  fi
else
  say "      （--skip-login，跳过）"
fi
if ! curl -sS -u "$USER_:$DSH_NEW_PASSWORD" -o /dev/null -w '' "http://$REG/v2/" 2>/dev/null; then
  say "      ⚠ registry API 探测失败（可能是 scheme/网络问题，继续）"
fi

# ── 2) 更新 .env ────────────────────────────────────────────────────────────
say "[2/5] 更新 $ENV_FILE"
if [ "$DRY" = "1" ]; then
  say "      （dry-run，不写）"
else
  [ -f "$ENV_FILE" ] && cp "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)" && say "      已备份旧 .env"
  _tmp="$(mktemp)"; umask 077
  if [ -f "$ENV_FILE" ]; then
    grep -vE '^DSH_REGISTRY_(USER|PASSWORD)=' "$ENV_FILE" > "$_tmp" || true
  fi
  printf 'DSH_REGISTRY_USER=%s\nDSH_REGISTRY_PASSWORD=%s\n' "$USER_" "$DSH_NEW_PASSWORD" >> "$_tmp"
  cat "$_tmp" > "$ENV_FILE"; rm -f "$_tmp"; chmod 600 "$ENV_FILE"
  say "      已写入（权限 600）"
fi

# ── 3) 更新 GitHub secrets（CI 推送用）──────────────────────────────────────
say "[3/5] 更新 GitHub secrets"
if [ "$DO_GH" = "0" ]; then
  say "      （--skip-github，跳过）"
elif [ "$DRY" = "1" ]; then
  say "      （dry-run，不写）"
else
  CRED="${DSH_GIT_CREDENTIALS:-/home/lzg/.git-credentials}"
  TOKEN="$(sed -n 's#https://[^:]*:\([^@]*\)@github.com#\1#p' "$CRED" 2>/dev/null | head -1)"
  if [ -z "$TOKEN" ]; then
    say "      ⚠ 读不到 GitHub token（$CRED）→ 跳过；请手工更新 secrets"
  else
    _py="$(mktemp)"; _pw="$(mktemp)"; chmod 600 "$_pw"
    printf '%s' "$DSH_NEW_PASSWORD" > "$_pw"
    cat > "$_py" <<'PY'
import json, base64, urllib.request, sys
try:
    import nacl.public, nacl.encoding
except Exception:
    print('PyNaCl 缺失'); sys.exit(3)
token, repo, user = sys.argv[1], 'llzg/dsh-docker', sys.argv[2]
pw = open(sys.argv[3]).read()
def api(path, data=None, method='GET'):
    req = urllib.request.Request(f'https://api.github.com{path}', method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Authorization': f'token {token}', 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json', 'User-Agent': 'dsh-rotate'})
    return json.load(urllib.request.urlopen(req))
pk = api(f'/repos/{repo}/actions/secrets/public-key')
box = nacl.public.SealedBox(nacl.public.PublicKey(pk['key'].encode(), nacl.encoding.Base64Encoder()))
for name, value in (('DSH_REGISTRY_USER', user), ('DSH_REGISTRY_PASSWORD', pw)):
    enc = base64.b64encode(box.encrypt(value.encode())).decode()
    api(f'/repos/{repo}/actions/secrets/{name}', {'encrypted_value': enc, 'key_id': pk['key_id']}, 'PUT')
print('secrets 已更新')
PY
    # 宿主没有 PyNaCl → 用一次性容器装（密码经只读临时文件传入，不进 argv）
    if docker run --rm -v "$_py:/r.py:ro" -v "$_pw:/pw:ro" python:3-slim \
         sh -c 'pip install --quiet pynacl >/dev/null 2>&1 && python /r.py "$1" "$2" /pw' _ "$TOKEN" "$USER_" 2>&1 | tail -2 | sed 's/^/      /'; then
      :
    fi
    rm -f "$_py" "$_pw"
  fi
fi

# ── 4) 重建 dsh-version 容器（版本页查 registry 用新凭据）───────────────────
say "[4/5] 更新 dsh-version 容器 env"
if [ "$DO_CONTAINER" = "0" ]; then
  say "      （--skip-container，跳过）"
elif [ "$DRY" = "1" ]; then
  say "      （dry-run，不写）"
elif [ ! -x "$DEPLOY_DIR/../recreate-dsh.py" ] && [ ! -f "$DEPLOY_DIR/recreate-dsh.py" ]; then
  say "      ⚠ 找不到 recreate-dsh.py → 请手工重建 dsh-version"
else
  RD="$DEPLOY_DIR/recreate-dsh.py"; [ -f "$RD" ] || RD="$DEPLOY_DIR/../recreate-dsh.py"
  ( cd "$(dirname "$RD")" && \
    ENV_SET="DSH_REGISTRY_USER=$USER_,DSH_REGISTRY_PASSWORD=$DSH_NEW_PASSWORD" \
    ENV_SET_1="DSH_REGISTRIES=${DSH_REGISTRIES:-ghcr.io/llzg/dsh-docker,$REG/llzg/dsh-docker}" \
    python3 "$RD" apply dsh-version 2>&1 | grep -E "新增 env|running|完成|失败" | sed 's/^/      /' ) \
    || say "      ⚠ 重建失败，可用 python3 recreate-dsh.py rollback dsh-version 回滚"
fi

# ── 5) 收尾提示 ────────────────────────────────────────────────────────────
echo
say "[5/5] 完成。剩余人工动作："
say "      · CI 下次跑会验证 GitHub secrets（推送镜像到 $REG）"
say "      · 旧密码如果曾出现在聊天/日志里，轮换后即失效"
say "      · 本次改动的地方：$ENV_FILE / ~/.docker/config.json / GitHub secrets / dsh-version 容器"
exit 0
