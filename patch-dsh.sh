#!/bin/bash
# LAN patches for DeepSeek Harness web UI (idempotent)
#
# STRICT=1 (used at image build time): after patching, verifies the *final
# behavior invariants* hold. If upstream changed the code so a patch can no
# longer be applied, the build FAILS loudly instead of silently shipping a
# broken LAN deployment.
set -e
BASE=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai
STRICT="${STRICT:-0}"

# 1) Settings pages: force "host" persistence mode so plugin/model config
#    loads when accessed from a LAN IP (upstream defaults to "memory" off-loopback).
for pkg in dsh-client-ui-settings dsh-client-ui-settings-models dsh-client-ui-settings-general; do
  f="$BASE/$pkg/lib/client.js"
  if grep -q 'connection.isLoopback ? "host" : "memory"' "$f"; then
    sed -i 's/connection.isLoopback ? "host" : "memory"/"host"/g' "$f"
    echo "settings-host-mode: patched $pkg"
  else
    echo "settings-host-mode: already patched or pattern absent in $pkg"
  fi
done

# 2) crypto.randomUUID polyfill: in a non-secure context (plain HTTP over a LAN IP)
#    browsers omit crypto.randomUUID; provide a UUIDv4 fallback via getRandomValues.
POLYFILL='if(!globalThis.crypto.randomUUID){globalThis.crypto.randomUUID=function(){var a=crypto.getRandomValues(new Uint8Array(16));a[6]=a[6]&15|64;a[8]=a[8]&63|128;return Array.from(a,function(b,i){var h=b.toString(16).padStart(2,"0");return(i===4||i===6||i===8||i===10)?"-"+h:h}).join("");};}'
for pkg in dsh-client-connection dsh-client-ui-conversation; do
  f="$BASE/$pkg/lib/client.js"
  if grep -q 'globalThis.crypto.randomUUID' "$f"; then
    echo "randomuuid-polyfill: already present in $pkg"
  else
    sed -i "1i $POLYFILL" "$f"
    echo "randomuuid-polyfill: added to $pkg"
  fi
done

# 3) Server-side: privileged methods (settings/credentials/models discovery)
#    are pinned to loopback by default. Trust the same --trusted-host list
#    so the LAN deployment can configure providers in the UI.
CONN_INDEX="$BASE/dsh-client-connection/lib/index.js"
if grep -q 'PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, trustedHosts)' "$CONN_INDEX"; then
  echo "privileged-loopback: already patched"
else
  sed -i 's/PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, \[\])/PRIVILEGED_METHODS.has(method) \&\& !isTrustedApiRequest(request, trustedHosts)/' "$CONN_INDEX"
  echo "privileged-loopback: patched"
fi

# ── STRICT verification (build-time guard) ────────────────────────────────
if [ "$STRICT" = "1" ]; then
  FAIL=0
  # 1) settings: original off-loopback "memory" fallback must be gone
  for pkg in dsh-client-ui-settings dsh-client-ui-settings-models dsh-client-ui-settings-general; do
    f="$BASE/$pkg/lib/client.js"
    if grep -q 'connection.isLoopback ? "host" : "memory"' "$f"; then
      echo "VERIFY FAIL: settings-host-mode not applied in $pkg (upstream changed?)" >&2
      FAIL=1
    fi
  done
  # 2) randomUUID polyfill marker must exist in both client bundles
  for pkg in dsh-client-connection dsh-client-ui-conversation; do
    f="$BASE/$pkg/lib/client.js"
    if ! grep -q 'crypto.randomUUID=function' "$f"; then
      echo "VERIFY FAIL: randomuuid-polyfill missing in $pkg (upstream changed?)" >&2
      FAIL=1
    fi
  done
  # 3) privileged methods must trust the --trusted-host list
  if ! grep -q 'isTrustedApiRequest(request, trustedHosts' "$CONN_INDEX"; then
    echo "VERIFY FAIL: privileged-loopback not applied in dsh-client-connection (upstream changed?)" >&2
    FAIL=1
  fi
  if [ "$FAIL" = "1" ]; then
    echo "FATAL: LAN patches could not be applied against this dsh version." >&2
    echo "Update patch-dsh.sh in github.com/llzg/dsh-docker and re-trigger the build." >&2
    exit 1
  fi
  echo "patch-verify: all LAN patch invariants OK"
fi
