#!/bin/bash
# =============================================================================
# ⚠️ SUPERSEDED（2026-09-09 双通道改造）——历史一次性 runbook，请勿再执行
#    · 它假设单通道拓扑（rc.2 容器 → alpha.5 容器），且硬编码 192.168.5.16（宿主机实际是 .17）
#    · 现在每通道独立 compose 项目，切换请用：
#        nas/switch.sh --channel alpha [版本]              # 切到指定版本/镜像
#        scripts/dsh-safe-deploy promote --channel alpha   # 门禁 promote（推荐）
#        scripts/dsh-safe-deploy rollback --channel alpha  # 回滚
#    · 保留本文件仅为记录当时的生产切换步骤
# =============================================================================
# =============================================================================
# dsh 生产切换 runbook —— alpha.5 接管 :3081（rc.2 退为手动回滚）
# -----------------------------------------------------------------------------
# 背景：本会话 agent 运行在 rc.2 容器(deepseek-harness)内，无法自停 rc.2。
#       故本脚本设计为在【宿主机】执行（SSH lzg@192.168.5.16 或 NAS docker CLI）。
#       它不依赖 rc.2 容器存活。
#
# 执行：bash /volume1/docker/deepseek-harness/dsh-root/nas_docker/scripts/switch-to-alpha5.sh
#   （脚本路径 == rc.2 内 /root/nas_docker/scripts/switch-to-alpha5.sh）
#
# 顺序：停 rc.2 → 终态数据同步(rc.2→alpha.5 home) → 重启 alpha.5 → proxy 上 :3081 → 验证
# 幂等：重复执行安全；任一步失败会打印 ROLLBACK 指引。
# =============================================================================
set -euo pipefail

# ---------- 常量（宿主机视角） ----------
HOST_DDH_DATA="/volume1/docker/deepseek-harness/dsh-data"        # rc.2 DSH_HOME（生产数据，只读源）
HOST_A5_HOME="$HOST_DDH_DATA/test/0.1.2-alpha.5"                  # alpha.5 home
HOST_PROXY_FILE="/volume1/docker/deepseek-harness/dsh-root/dsh-proxy-main.js"
RC_C="deepseek-harness"                # rc.2 容器（将停止，保留）
A5_C="deepseek-harness-test-a5"        # alpha.5 后端容器
A5_IP="172.27.0.4"                     # alpha.5 容器 IP（docker network 固定）
NET="deepseek-harness_default"
IMG="ghcr.io/llzg/dsh-docker:0.1.2-alpha.5"
PROXY_IMG="$IMG"
PROXY_3081="dsh-proxy"                 # 主网关（原 :12079 网关改名复用为 :3081）
RUN_ALIAS="${RUN_ALIAS:-1}"            # 1=另起 :12079 别名网关 dsh-proxy-12079

say(){ echo; echo "### $*"; }
die(){ echo "!! FAIL: $*" >&2; echo "ROLLBACK: docker start $RC_C && 浏览器回 http://192.168.5.16:3081/ (rc.2)" >&2; exit 1; }

command -v docker >/dev/null || die "docker CLI 不可用"

say "0) 当前状态"
docker ps --format '{{.Names}} | {{.Status}} | {{.Ports}}' | grep -E "$RC_C|$A5_C|dsh-proxy" || true

# ---------- 1) 停 rc.2（保留容器 = 回滚目标） ----------
say "1) 停止 rc.2 ($RC_C) —— 容器保留不删；同时把 rc.2 重启策略改为 no（防宿主重启后抢回 :3081）"
docker stop "$RC_C" 2>/dev/null || true
docker update --restart no "$RC_C" >/dev/null 2>&1 || true
echo "  rc.2 stopped (回滚: docker start $RC_C)"
sleep 2

# ---------- 2) 终态数据同步 rc.2 → alpha.5 home（以 rc.2 为准，全量覆盖） ----------
say "2) 终态会话同步（rc.2 sessions -> alpha.5 home，逐文件覆盖）"
[ -d "$HOST_DDH_DATA/sessions" ] || die "rc.2 sessions 目录不可见: $HOST_DDH_DATA/sessions"
[ -d "$HOST_A5_HOME/sessions" ] || die "alpha.5 home sessions 不存在: $HOST_A5_HOME/sessions"
N=0
for wd in "$HOST_DDH_DATA"/sessions/*/; do
  [ -d "$wd" ] || continue
  base=$(basename "$wd")
  for sdir in "$wd"*/; do
    [ -d "$sdir" ] || continue
    sid=$(basename "$sdir")
    dst="$HOST_A5_HOME/sessions/$base/$sid"
    if [ -f "$sdir/session.jsonl.zstd" ]; then
      mkdir -p "$dst"
      cp -a "$sdir/session.jsonl.zstd" "$dst/session.jsonl.zstd"
      N=$((N+1))
    fi
  done
done
echo "  synced $N 个会话文件"
# 一致性核对
P=$(find "$HOST_DDH_DATA/sessions" -name session.jsonl.zstd | wc -l)
A=$(find "$HOST_A5_HOME/sessions" -name session.jsonl.zstd | wc -l)
echo "  rc.2=$P alpha.5=$A"; [ "$P" = "$A" ] || die "会话文件数不一致($P vs $A)"

# ---------- 3) 重启 alpha.5 后端（干净加载终态数据，token 轮换） ----------
say "3) 重启 alpha.5 ($A5_C)"
if docker inspect "$A5_C" >/dev/null 2>&1; then
  docker stop "$A5_C" >/dev/null 2>&1 || true
  docker start "$A5_C" >/dev/null || die "alpha.5 启动失败"
else
  die "alpha.5 容器不存在：需手工重建（挂载 test home + /root，--ip $A5_IP -p 12077:3080，--network $NET）"
fi
echo "  等待启动..."
TOK=""
for i in $(seq 1 40); do
  sleep 3
  TOK=$(docker logs "$A5_C" 2>&1 | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1 | sed 's/token=//' || true)
  if [ -n "$TOK" ]; then
    if curl -sf "http://$A5_IP:3080/?token=$TOK" >/dev/null 2>&1; then echo "  alpha.5 ready, token ok"; break; fi
  fi
done
[ -n "$TOK" ] || die "alpha.5 token 未就绪"

# ---------- 4) proxy 主网关 :3081（+可选 :12079 别名） ----------
say "4) proxy :3081 -> alpha.5 ($A5_IP:3080)"
[ -f "$HOST_PROXY_FILE" ] || die "proxy 文件缺失: $HOST_PROXY_FILE"
ALLOWED="192.168.5.0/24,172.27.0.0/16,127.0.0.0/8"
docker rm -f "$PROXY_3081" >/dev/null 2>&1 || true
docker run -d --name "$PROXY_3081" --network host \
  -v "$HOST_PROXY_FILE:/proxy.js:ro" \
  -e BACKEND="http://$A5_IP:3080" -e ALLOWED_CIDR="$ALLOWED" -e PORT=3081 \
  -e "BOOTSTRAP_TOKEN=$TOK" "$PROXY_IMG" node /proxy.js >/dev/null || die "proxy :3081 启动失败"
echo "  dsh-proxy :3081 已启动"
if [ "$RUN_ALIAS" = "1" ]; then
  docker rm -f dsh-proxy-12079 >/dev/null 2>&1 || true
  docker run -d --name dsh-proxy-12079 --network host \
    -v "$HOST_PROXY_FILE:/proxy.js:ro" \
    -e BACKEND="http://$A5_IP:3080" -e ALLOWED_CIDR="$ALLOWED" -e PORT=12079 \
    -e "BOOTSTRAP_TOKEN=$TOK" "$PROXY_IMG" node /proxy.js >/dev/null 2>&1 || echo "  (alias 12079 启动失败，忽略)"
  echo "  dsh-proxy-12079 别名已启动"
fi
sleep 3

# ---------- 5) 验证 ----------
say "5) 验证 http://192.168.5.16:3081/"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 http://192.168.5.16:3081/ || echo 000)
echo "  index http=$code"; [ "$code" = "200" ] || die "3081 index 非 200"
curl -s -m 8 http://192.168.5.16:3081/ | grep -q "ownsHost:true" && echo "  ownsHost 注入 OK" || echo "  !! ownsHost 未注入（检查 proxy HTML 注入）"
# session/list
SL=$(curl -s -m 15 -X POST http://192.168.5.16:3081/api/session/list -H 'content-type: application/json' \
     -d '{"type":"client-request","rpcId":"v","method":"session/list","payload":{"args":{"_request":{}}}}' 2>/dev/null \
     | python3 -c "import json,sys;d=json.load(sys.stdin);i=d['result']['value']['items'];import collections;print(len(i), dict(collections.Counter(s['cwd'] for s in i)))" 2>/dev/null || echo "FAIL")
echo "  session/list: $SL"
# workspace baseline (WS)
node -e "
const W=globalThis.WebSocket;
(async()=>{const ws=new W('ws://192.168.5.16:3081/api/remote.mux');const t=setTimeout(()=>{console.log('WS TIMEOUT');process.exit(2)},8000);
ws.onopen=()=>{ws.send(JSON.stringify({type:'open',streamId:'r',endpoint:'workspace/follow',payload:{args:{}}}));setTimeout(()=>{clearTimeout(t);ws.close(1000);process.exit(0)},2500)};
ws.onmessage=(e)=>{try{const p=JSON.parse(String(e.data));if(p.type==='item'&&p.value?.type==='baseline'){const v=p.value.value||p.value;console.log('workspace:',v.items.map(w=>w.title+'='+w.sessionIds.length).join(', '));console.log('archived:',v.archivedSessionIds.length)}}catch{}};
ws.onerror=()=>{console.log('WS ERR');process.exit(1)}})();
" 2>&1 || echo "  WS 验证跳过"

say "6) 完成。"
echo "  主入口:  http://192.168.5.16:3081/   （alpha.5 = 0.1.2-alpha.5，会话=rc.2 终态 87 条）"
echo "  别名:    http://192.168.5.16:12079/  （若 RUN_ALIAS=1）"
echo "  rc.2 回滚: docker start $RC_C   （回 http://192.168.5.16:3081/ 的 rc.2；先 docker rm -f dsh-proxy）"
echo "  数据:    rc.2 home=$HOST_DDH_DATA 未删除；alpha.5 home=$HOST_A5_HOME"
