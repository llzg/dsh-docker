#!/bin/sh
# Smoke test: run the freshly built dsh image, wait for /health to return 200.
# usage: smoke-test.sh IMAGE [HOST_PORT]
set -eu
IMG="${1:?image required}"
PORT="${2:-13080}"
NAME="dsh-smoke-$$"

docker run -d --name "$NAME" \
  -e DSH_HOME=/tmp/dshhome \
  -e DSH_TELEMETRY_DISABLED=1 \
  -p "$PORT:3080" "$IMG"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

i=0
while [ "$i" -lt 40 ]; do
  i=$((i + 1))
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "SMOKE OK (attempt $i)"
    exit 0
  fi
  sleep 5
done

echo "--- container logs (tail 120) ---"
docker logs "$NAME" 2>&1 | tail -120 || true
echo "--- final health probe ---"
curl -sv -m 5 "http://127.0.0.1:$PORT/health" 2>&1 | tail -8 || true
echo "SMOKE FAILED: $IMG did not become healthy within 200s"
exit 1
