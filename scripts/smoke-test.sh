#!/bin/sh
# Smoke test: run the freshly built dsh image, wait for the web UI to respond.
# usage: smoke-test.sh IMAGE [HOST_PORT]
# 0.1.2-alpha.3 起 dsh web 默认启用 token 认证（URL 带 ?token=...，未认证请求被拒）。
# 探活策略：先从容器日志提取 token（若有），带 token 请求；否则裸请求。
set -eu
IMG="${1:?image required}"
PORT="${2:-13080}"
NAME="dsh-smoke-$$"

docker run -d --name "$NAME" \
  -e DSH_HOME=/tmp/dshhome \
  -e DSH_TELEMETRY_DISABLED=1 \
  -p "$PORT:3080" "$IMG"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

probe() {
  # 从日志提取 dsh web 打印的 token（`?token=<hex>`）
  local tok
  tok=$(docker logs "$NAME" 2>/dev/null | grep -oE '\?token=[0-9A-Za-z]+' | head -1 | sed 's/?token=//' || true)
  if [ -n "$tok" ]; then
    curl -sf -H "Authorization: Bearer $tok" "http://127.0.0.1:$PORT/" >/dev/null 2>&1 \
      || curl -sf "http://127.0.0.1:$PORT/?token=$tok" >/dev/null 2>&1
  else
    curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1
  fi
}

i=0
while [ "$i" -lt 40 ]; do
  i=$((i + 1))
  if probe; then
    echo "SMOKE OK (attempt $i)"
    exit 0
  fi
  sleep 5
done

echo "--- container logs (tail 120) ---"
docker logs "$NAME" 2>&1 | tail -120 || true
echo "--- final health probe ---"
curl -sv -m 5 "http://127.0.0.1:$PORT/" 2>&1 | tail -8 || true
echo "SMOKE FAILED: $IMG did not become healthy within 200s"
exit 1
