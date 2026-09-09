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
  # 从日志提取 dsh web 打印的 token（`?token=<base64url>`；可能含 - _ 且以 - 开头）
  local tok
  tok=$(docker logs "$NAME" 2>/dev/null | grep -oE '\?token=[A-Za-z0-9_-]+' | head -1 | sed 's/?token=//' || true)
  if [ -n "$tok" ]; then
    curl -sf "http://127.0.0.1:$PORT/?token=$tok" >/dev/null 2>&1 \
      || curl -sf -H "Authorization: Bearer $tok" "http://127.0.0.1:$PORT/" >/dev/null 2>&1
  else
    curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1
  fi
}

i=0
while [ "$i" -lt 40 ]; do
  i=$((i + 1))
  if probe; then
    echo "SMOKE OK (attempt $i)"
    # 版本页（3082）也必须在真实镜像里能起来：容器内自探，不依赖宿主端口映射
    # DSH_VERSION_PORT=0 的通道（如 rc）跳过；查不到 semver 时只告警不阻塞。
    vp=$(docker exec "$NAME" sh -c 'printf %s "${DSH_VERSION_PORT:-3082}"' 2>/dev/null || echo 3082)
    if [ "$vp" != "0" ]; then
      vok=0
      j=0
      while [ "$j" -lt 10 ]; do
        j=$((j + 1))
        if docker exec "$NAME" node -e "fetch('http://127.0.0.1:${vp}/version.json').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
          vok=1
          break
        fi
        sleep 2
      done
      if [ "$vok" = "1" ]; then
        echo "SMOKE OK: version page :${vp} 可用"
      else
        echo "SMOKE WARN: 版本页 :${vp} 未就绪（检查 /opt/node_modules/semver 与 version-server.js）" >&2
        docker exec "$NAME" sh -c 'tail -20 "${DSH_HOME:-/data/dsh}/logs/version-server.log" 2>/dev/null' >&2 || true
      fi
    fi
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
