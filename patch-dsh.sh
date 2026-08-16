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

# 4) vision-materialize: DeepSeek 适配器是纯文本 wire，遇到用户粘贴的图片
#    直接抛 UNSUPPORTED_CONTENT 导致整轮失败。改为把每个 image block 物化成
#    一段文本指针（附件是内容寻址存储，路径可由 attachmentId 直接推出，
#    无需读写字节），智能体看到路径后可用 scripts/see.sh 看图。
LLM_DS="$BASE/dsh-llm-deepseek/lib/index.js"
python3 - "$LLM_DS" <<'PY'
import sys
f = sys.argv[1]
src = open(f, encoding="utf-8").read()
if "materializeImages" in src:
    print("vision-materialize: already patched")
    sys.exit(0)
old_fn = '''/** Reject core image content before any text-flattening path can silently erase it. */
function assertTextOnly(blocks) {
	if (contentHasImage(blocks)) throw new LlmError("The DeepSeek chat-completions adapter does not support image content.", "UNSUPPORTED_CONTENT");
}'''
new_fn = '''/**
* LAN patch (llzg/dsh-docker): the chat-completions wire is text-only; instead
* of rejecting pasted images, materialize each image block into a text pointer
* at its durable content-addressed attachment path (DSH_HOME/attachments/v1),
* so the agent can inspect it with scripts/see.sh.
*/
function materializeImages(content) {
	const out = [];
	for (const block of content) {
		if (block.type === "image" && block.attachment !== void 0 && block.attachment !== null) {
			const hex = String(block.attachment.attachmentId);
			const sha = hex.startsWith("sha256:") ? hex.slice(7) : hex;
			const root = process.env.DSH_HOME ?? "/data/dsh";
			const path = [root, "attachments", "v1", "objects", sha.slice(0, 2), sha].join("/");
			out.push({ type: "text", text: `（用户粘贴了一张图片，已保存到 ${path}；请用 scripts/see.sh 查看这张图片）` });
		} else {
			out.push(block);
		}
	}
	return out;
}'''
assert old_fn in src, "vision-materialize: assertTextOnly pattern not found (upstream changed?)"
src = src.replace(old_fn, new_fn)
old_loop = '''	for (const message of messages) {
		assertTextOnly(message.content);
		if (message.role === "system") {
			wire.push({
				role: "system",
				content: flattenText(message.content)
			});
			continue;
		}
		if (message.role === "assistant") {
			wire.push(serializeAssistant(message));
			continue;
		}
		const toolResults = message.content.filter((block) => block.type === "tool-result");
		const text = flattenText(message.content);'''
new_loop = '''	for (const message of messages) {
		const content = materializeImages(message.content);
		if (message.role === "system") {
			wire.push({
				role: "system",
				content: flattenText(content)
			});
			continue;
		}
		if (message.role === "assistant") {
			wire.push(serializeAssistant(message));
			continue;
		}
		const toolResults = content.filter((block) => block.type === "tool-result");
		const text = flattenText(content);'''
assert old_loop in src, "vision-materialize: serializeMessages pattern not found (upstream changed?)"
src = src.replace(old_loop, new_loop)
old_tool = 'content: flattenText(result.content) || "(no output)"'
new_tool = 'content: flattenText(materializeImages(result.content)) || "(no output)"'
assert old_tool in src, "vision-materialize: tool-result pattern not found (upstream changed?)"
src = src.replace(old_tool, new_tool)
open(f, "w", encoding="utf-8").write(src)
print("vision-materialize: patched dsh-llm-deepseek")
PY

# 4b) vision-gate: session.prompt 入口有一道"模型不支持图片"的闸门
#     （MODEL_DOES_NOT_SUPPORT_IMAGES），会把粘贴图片的请求在进入 agent
#     前直接拒绝（客户端 toast "当前模型不支持图片"）。去掉这道闸门，
#     让图片流进消息；是否能用交给适配器层（vision-materialize 会物化成
#     附件路径文本），而不是在入口一刀切。
APIPROXY="$BASE/dsh-host-apiproxy/lib/index.js"
python3 - "$APIPROXY" <<'PY'
import sys
f = sys.argv[1]
src = open(f, encoding="utf-8").read()
marker = "vision-gate: pasted images pass through"
if marker in src:
    print("vision-gate: already patched")
    sys.exit(0)
old_gate = '''						if (hasImage) {
							const current = selectionFor(agent).current;
							const modelInfo = await ctx.llm.resolveModelInfo(current.provider, current.model);
							if (modelInfo.inputModalities !== void 0 && !modelInfo.inputModalities.includes("image")) return err(request, {
								code: "attachment-error",
								message: `Model "${current.model}" does not support image input.`,
								details: { reason: "MODEL_DOES_NOT_SUPPORT_IMAGES" }
							});
						}'''
new_gate = '''						// LAN patch (llzg/dsh-docker) vision-gate: pasted images pass through even
						// for text-only models; the DeepSeek adapter materializes them into
						// attachment-path text (vision-materialize) instead of erroring.'''
assert old_gate in src, "vision-gate: MODEL_DOES_NOT_SUPPORT_IMAGES pattern not found (upstream changed?)"
src = src.replace(old_gate, new_gate)
open(f, "w", encoding="utf-8").write(src)
print("vision-gate: patched dsh-host-apiproxy")
PY

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
  # 4) vision-materialize marker must exist; original rejection must be gone
  if ! grep -q 'materializeImages' "$LLM_DS"; then
    echo "VERIFY FAIL: vision-materialize not applied in dsh-llm-deepseek (upstream changed?)" >&2
    FAIL=1
  fi
  if grep -q 'does not support image content' "$LLM_DS"; then
    echo "VERIFY FAIL: vision-materialize rejection still present in dsh-llm-deepseek" >&2
    FAIL=1
  fi
  # 4b) vision-gate marker must exist; MODEL_DOES_NOT_SUPPORT_IMAGES must be gone
  if ! grep -q 'vision-gate: pasted images pass through' "$APIPROXY"; then
    echo "VERIFY FAIL: vision-gate not applied in dsh-host-apiproxy (upstream changed?)" >&2
    FAIL=1
  fi
  if grep -q 'MODEL_DOES_NOT_SUPPORT_IMAGES' "$APIPROXY"; then
    echo "VERIFY FAIL: vision-gate rejection still present in dsh-host-apiproxy" >&2
    FAIL=1
  fi
  if [ "$FAIL" = "1" ]; then
    echo "FATAL: LAN patches could not be applied against this dsh version." >&2
    echo "Update patch-dsh.sh in github.com/llzg/dsh-docker and re-trigger the build." >&2
    exit 1
  fi
  echo "patch-verify: all LAN patch invariants OK"
fi
