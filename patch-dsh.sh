#!/bin/bash
# LAN patches for DeepSeek Harness web UI (idempotent, marker-verified)
#
# 契约：docs/dual-channel.md §10。每个补丁三段式，缺一不可：
#   1) 锚点预检 → 2) 应用 → 3) 写唯一 marker → STRICT 正向校验 marker 存在
# 锚点既不存在、也没有 marker → `VERIFY FAIL: anchor missing ...` 且 exit 1（构建失败）。
#
# 旧实现（fd8b3a7）的致命缺陷（已实测）：STRICT 校验的是“原始模式必须消失”，
# 锚点从未匹配时该条件恒真 → 每次构建都打印 all LAN patch invariants OK，
# 实际一个补丁都没打。现改为正向校验 marker。
#
# STRICT=1（构建期）打开最终逐条校验；STRICT=0（容器启动自愈）只做锚点预检。
set -eu
# 生产默认路径不变；DSH_PATCH_BASE 仅供本地/CI 用真实文件系统模拟上游包（无需 docker）。
BASE="${DSH_PATCH_BASE:-/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai}"
STRICT="${STRICT:-0}"
# 图标资源（构建期在 /opt；可用环境变量覆盖以便本地模拟，默认值不变）
ICON="${DSH_ICON:-/opt/dsh-icon.jpg}"
MAKE_FAVICON="${DSH_MAKE_FAVICON:-/opt/make-favicon.js}"
MARKER="dsh-docker-patch"

FAIL=0
fail() { echo "VERIFY FAIL: $*" >&2; FAIL=1; }
# 追加唯一 marker（前置换行：避免吃到“末行无换行”的文件最后一行代码）
write_marker() { printf '\n// %s:%s\n' "$MARKER" "$2" >> "$1"; }
# 契约 §10 的 YAML/文本形态 marker（当前无 YAML 补丁，保留 helper 以便扩展）
write_marker_hash() { printf '\n# %s:%s\n' "$MARKER" "$2" >> "$1"; }
has_marker() { [ -f "$1" ] && grep -qF "$MARKER:$2" "$1"; }

# 1) Settings pages: force "host" persistence mode so plugin/model config
#    loads when accessed from a LAN IP (upstream defaults to "memory" off-loopback).
#    锚点变更史（已核对 npm 包 lib/client.js）：
#      0.1.0-rc.6 / 0.1.1-rc.1        : connection.isLoopback ? "host" : "memory"   （旧文本，兼容）
#      >= 0.1.2-alpha.2（当前上游）   : ctx.remote.$host.isLoopback ? "host" : "memory"
#    语义（2026-09-10 修正）：上游把该逻辑收敛到了部分包，**不是每个包都有锚点**。
#      - 0.1.5-alpha.2 实测：dsh-client-ui-settings 有锚点；-models 已完全移除该判定；
#        -general 改成用 isLoopback 选 documentController（不再有 "host"/"memory" 三元）。
#      因此"某个包没有锚点"是**合法不适用**（SKIP），不能 FAIL；但必须守住更强的全局不变量：
#      **至少有一个包真的被打上补丁**，否则说明上游改了写法/移除了功能 → FAIL（防静默失效）。
ANCHOR_HOST_NEW='ctx.remote.$host.isLoopback ? "host" : "memory"'
ANCHOR_HOST_OLD='connection.isLoopback ? "host" : "memory"'
SETTINGS_PATCHED=0
for pkg in dsh-client-ui-settings dsh-client-ui-settings-models dsh-client-ui-settings-general; do
  f="$BASE/$pkg/lib/client.js"
  if [ ! -f "$f" ]; then
    echo "SKIP settings-host-mode: 目标不存在（上游移除 $pkg，patch 不适用）: $f"
    continue
  fi
  if has_marker "$f" settings-host-mode; then
    echo "settings-host-mode: already patched (marker present) in $pkg"
    SETTINGS_PATCHED=1
    continue
  fi
  if grep -qF "$ANCHOR_HOST_NEW" "$f"; then
    sed -i 's/ctx\.remote\.\$host\.isLoopback ? "host" : "memory"/"host"/g' "$f"
    echo "settings-host-mode: patched $pkg (new anchor)"
  elif grep -qF "$ANCHOR_HOST_OLD" "$f"; then
    sed -i 's/connection\.isLoopback ? "host" : "memory"/"host"/g' "$f"
    echo "settings-host-mode: patched $pkg (legacy anchor)"
  else
    echo "SKIP settings-host-mode: $pkg 已无 \"host\"/\"memory\" 持久化判定（上游改了实现），patch 不适用: $f"
    continue
  fi
  write_marker "$f" settings-host-mode
  SETTINGS_PATCHED=1
done
if [ "$SETTINGS_PATCHED" != "1" ]; then
  fail "settings-host-mode: 三个 settings 包都没有锚点也没有 marker —— 上游已重写该逻辑，必须更新 patch-dsh.sh（防静默失效）"
fi

# 2) crypto.randomUUID polyfill: in a non-secure context (plain HTTP over a LAN IP)
#    browsers omit crypto.randomUUID; provide a UUIDv4 fallback via getRandomValues.
POLYFILL='if(!globalThis.crypto.randomUUID){globalThis.crypto.randomUUID=function(){var a=crypto.getRandomValues(new Uint8Array(16));a[6]=a[6]&15|64;a[8]=a[8]&63|128;return Array.from(a,function(b,i){var h=b.toString(16).padStart(2,"0");return(i===4||i===6||i===8||i===10)?"-"+h:h}).join("");};}'
for pkg in dsh-client-connection dsh-client-ui-conversation; do
  f="$BASE/$pkg/lib/client.js"
  if [ ! -f "$f" ]; then
    echo "SKIP randomuuid-polyfill: 目标不存在（上游移除 $pkg，patch 不适用）: $f"
    continue
  fi
  if has_marker "$f" randomuuid-polyfill; then
    echo "randomuuid-polyfill: already patched (marker present) in $pkg"
    continue
  fi
  # 锚点预检：客户端 bundle 必须是 __ModuleLoader__ 模块（结构变了就不能安全前置注入）
  if ! grep -qF 'window.__ModuleLoader__.load(' "$f"; then
    fail "anchor missing randomuuid-polyfill: 未找到 window.__ModuleLoader__.load( 结构: $f"
    continue
  fi
  tmp="$(mktemp)"
  { printf '// %s:%s\n' "$MARKER" randomuuid-polyfill; printf '%s\n' "$POLYFILL"; cat "$f"; } > "$tmp"
  cat "$tmp" > "$f"   # 原地覆盖（保留原 inode/权限，避免 mv 掉成 0600）
  rm -f "$tmp"
  echo "randomuuid-polyfill: added to $pkg"
done

# 3) Server-side: privileged methods (settings/credentials/models discovery)
#    are pinned to loopback by default. Trust the same --trusted-host list
#    so the LAN deployment can configure providers in the UI.
#
#    上游形态核实（npm 包 lib/index.js）：
#      >= 0.1.2-alpha.5 已自带 `isTrustedApiRequest(request, this.trustedHosts)`
#      （0.1.2-alpha.5 / 0.1.3-alpha.2 / 0.1.5-alpha.1 / 0.1.5-alpha.2 逐一确认），
#      此时不再 sed，只记 `privileged-loopback:upstream-satisfied` marker；
#      老版本仍含旧锚点 `!isTrustedApiRequest(request, [])` 时照旧 sed；
#      两者都没有且无 marker → FAIL。
CONN_INDEX="$BASE/dsh-client-connection/lib/index.js"
if [ ! -f "$CONN_INDEX" ]; then
  echo "SKIP privileged-loopback: 目标不存在（上游移除 dsh-client-connection，patch 不适用）: $CONN_INDEX"
elif has_marker "$CONN_INDEX" privileged-loopback; then
  echo "privileged-loopback: already marked (patched or upstream-satisfied)"
elif grep -qF 'PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, [])' "$CONN_INDEX"; then
  sed -i 's/PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, \[\])/PRIVILEGED_METHODS.has(method) \&\& !isTrustedApiRequest(request, trustedHosts)/' "$CONN_INDEX"
  write_marker "$CONN_INDEX" privileged-loopback
  echo "privileged-loopback: patched (legacy anchor)"
elif grep -qF 'isTrustedApiRequest(request, this.trustedHosts)' "$CONN_INDEX"; then
  write_marker "$CONN_INDEX" privileged-loopback:upstream-satisfied
  echo "privileged-loopback: upstream-satisfied (no sed needed)"
else
  fail "anchor missing privileged-loopback: 既无旧锚点 !isTrustedApiRequest(request, []) 也无 isTrustedApiRequest(request, this.trustedHosts)，且无 marker: $CONN_INDEX"
fi

# 4) vision-materialize: DeepSeek 适配器是纯文本 wire，遇到用户粘贴的图片
#    直接抛 UNSUPPORTED_CONTENT 导致整轮失败。改为把每个 image block 物化成
#    一段文本指针（附件是内容寻址存储，路径可由 attachmentId 直接推出，
#    无需读写字节），智能体看到路径后可用 scripts/see.sh 看图。
LLM_DS="$BASE/dsh-llm-deepseek/lib/index.js"
python3 - "$LLM_DS" <<'PY' || fail "vision-materialize: python 补丁未完成（见上，上游结构已变）"
import os, sys
f = sys.argv[1]
if not os.path.exists(f):
    print("SKIP vision-materialize: 目标不存在（上游移除 dsh-llm-deepseek，patch 不适用）:", f)
    sys.exit(0)

def need(cond, what):
    """锚点预检：保留 assert 语义，但打印契约要求的 VERIFY FAIL 并以 exit 3 结束。"""
    if not cond:
        print("VERIFY FAIL: anchor missing vision-materialize:", what, file=sys.stderr)
        sys.exit(3)

src = open(f, encoding="utf-8").read()
if "dsh-docker-patch:vision-materialize" in src:
    print("vision-materialize: already patched (marker present)")
    sys.exit(0)
old_fn = '''/** Reject core image content before any text-flattening path can silently erase it. */
function assertTextOnly(blocks) {
	if (contentHasImage(blocks)) throw new LlmError("The DeepSeek chat-completions adapter does not support image content.", "UNSUPPORTED_CONTENT");
}'''
new_fn = '''// dsh-docker-patch:vision-materialize
/**
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
need(old_fn in src, "assertTextOnly pattern not found (upstream changed?)")
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
need(old_loop in src, "serializeMessages pattern not found (upstream changed?)")
src = src.replace(old_loop, new_loop)
old_tool = 'content: flattenText(result.content) || "(no output)"'
new_tool = 'content: flattenText(materializeImages(result.content)) || "(no output)"'
need(old_tool in src, "tool-result pattern not found (upstream changed?)")
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
python3 - "$APIPROXY" <<'PY' || fail "vision-gate: python 补丁未完成（见上，上游结构已变）"
import os, sys
f = sys.argv[1]
if not os.path.exists(f):
    print("SKIP vision-gate: 目标不存在（上游移除 dsh-host-apiproxy，patch 不适用）:", f)
    sys.exit(0)

def need(cond, what):
    """锚点预检：保留 assert 语义，但打印契约要求的 VERIFY FAIL 并以 exit 3 结束。"""
    if not cond:
        print("VERIFY FAIL: anchor missing vision-gate:", what, file=sys.stderr)
        sys.exit(3)

src = open(f, encoding="utf-8").read()
marker = "dsh-docker-patch:vision-gate"
if marker in src:
    print("vision-gate: already patched (marker present)")
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
new_gate = '''						// dsh-docker-patch:vision-gate
						// LAN patch (llzg/dsh-docker) vision-gate: pasted images pass through even
						// for text-only models; the DeepSeek adapter materializes them into
						// attachment-path text (vision-materialize) instead of erroring.'''
need(old_gate in src, "MODEL_DOES_NOT_SUPPORT_IMAGES pattern not found (upstream changed?)")
src = src.replace(old_gate, new_gate)
open(f, "w", encoding="utf-8").write(src)
print("vision-gate: patched dsh-host-apiproxy")
PY

# 5) 自定义图标：将 dsh-icon.jpg 嵌入前端 favicon.svg
#    （浏览器标签页 + PWA manifest 共用 favicon.svg，替换它即整体生效）
#    锚点预检：favicon.svg 必须存在且是 SVG；生成后补 marker（SVG 只能用 XML 注释）。
FAVICON="$BASE/dsh-web-frontend/dist/favicon.svg"
if [ ! -f "$FAVICON" ]; then
  echo "SKIP favicon-custom: 目标不存在（上游移除 dsh-web-frontend，patch 不适用）: $FAVICON"
elif [ ! -f "$ICON" ] || [ ! -f "$MAKE_FAVICON" ]; then
  echo "favicon-custom: icon assets absent (skip): $ICON / $MAKE_FAVICON"
elif has_marker "$FAVICON" favicon-custom; then
  echo "favicon-custom: already applied (marker present)"
elif ! grep -qF '<svg' "$FAVICON"; then
  fail "anchor missing favicon-custom: $FAVICON 不是 SVG（上游结构已变）"
else
  if node "$MAKE_FAVICON" "$FAVICON" "$ICON"; then
    printf '\n<!-- %s:favicon-custom -->\n' "$MARKER" >> "$FAVICON"
  else
    fail "favicon-custom: make-favicon 生成失败（$MAKE_FAVICON）"
  fi
fi

# 6) token-pinning：DSH 默认每次进程启动用 randomBytes 生成新的 launch token，
#    于是容器重启后 host 网络的代理层（dsh-proxy 用 BOOTSTRAP_TOKEN bootstrap）必须重建，
#    否则 UI 直接 401。让 DSH 认 env DSH_LAUNCH_TOKEN（base64url 43 字符）即可固定 token。
#    ⚠ 来源说明：这段补丁此前**只存在于生产容器的可写层**（/opt/patch-dsh.sh 被 workspace
#    版本覆盖过），不在仓库里 —— 2026-09-10 重建容器时因此丢了它、导致 3081 短时 401。
#    现移植回仓库，并纳入 marker 正向校验。
TOKEN_FILE="$BASE/dsh-client-connection/lib/index.js"
python3 - "$TOKEN_FILE" <<'PY' || fail "token-pinning: python 补丁未完成（见上，上游结构已变）"
import os, sys
f = sys.argv[1]
if not os.path.exists(f):
    print("SKIP token-pinning: 目标不存在（上游移除 dsh-client-connection，patch 不适用）:", f)
    sys.exit(0)

def need(cond, what):
    """锚点预检：失败即打印 VERIFY FAIL 并以 exit 3 结束。"""
    if not cond:
        print("VERIFY FAIL: anchor missing token-pinning:", what, file=sys.stderr)
        sys.exit(3)

src = open(f, encoding="utf-8").read()
if "dsh-docker-patch:token-pinning" in src:
    print("token-pinning: already patched (marker present)")
    sys.exit(0)
old_fn = '''function processLaunchToken(owner) {
	const existing = PROCESS_LAUNCH_TOKENS.get(owner);
	if (existing !== void 0) return existing;
	const created = encodeBase64Url(randomBytes(SECRET_BYTES));
	PROCESS_LAUNCH_TOKENS.set(owner, created);
	return created;
}'''
new_fn = '''function processLaunchToken(owner) {
	const existing = PROCESS_LAUNCH_TOKENS.get(owner);
	if (existing !== void 0) return existing;
	// dsh-docker-patch:token-pinning
	// honor DSH_LAUNCH_TOKEN so host-network proxies (dsh-proxy) survive backend
	// restarts without recreating their bootstrap cookie state.
	const pinned = process.env.DSH_LAUNCH_TOKEN;
	const created = pinned !== void 0 && pinned !== "" ? pinned : encodeBase64Url(randomBytes(SECRET_BYTES));
	PROCESS_LAUNCH_TOKENS.set(owner, created);
	return created;
}'''
need(old_fn in src, "processLaunchToken pattern not found (upstream changed?)")
src = src.replace(old_fn, new_fn)
open(f, "w", encoding="utf-8").write(src)
print("token-pinning: patched dsh-client-connection")
PY

# ── STRICT verification（构建期正向校验：marker 必须存在）──────────────────
# 契约 §10：正向校验 marker，替代旧的“原始模式必须消失”（锚点失配时恒真）。
verify_marker() { # file marker-name label
  if [ ! -f "$1" ]; then
    echo "verify: $2 SKIP（目标不存在，patch 不适用）: $3"
    return 0
  fi
  if grep -qF "$MARKER:$2" "$1"; then
    echo "verify: $2 OK ($3)"
  else
    fail "marker missing for $2 in $3 ($1)"
  fi
}
if [ "$STRICT" = "1" ]; then
  # settings：某个包没有锚点是**合法不适用**（上游把逻辑收敛了），
  #   但"锚点还在、补丁却没打上"必须 FAIL（这正是旧版静默失效的形态）。
  for pkg in dsh-client-ui-settings dsh-client-ui-settings-models dsh-client-ui-settings-general; do
    f="$BASE/$pkg/lib/client.js"
    if [ ! -f "$f" ]; then
      echo "verify: settings-host-mode SKIP（目标不存在，patch 不适用）: $pkg"
    elif has_marker "$f" settings-host-mode; then
      echo "verify: settings-host-mode OK ($pkg)"
    elif grep -qF "$ANCHOR_HOST_NEW" "$f" || grep -qF "$ANCHOR_HOST_OLD" "$f"; then
      fail "marker missing for settings-host-mode in $pkg（锚点仍在但补丁未生效）: $f"
    else
      echo "verify: settings-host-mode N/A（$pkg 已无该判定，上游实现变更）"
    fi
  done
  for pkg in dsh-client-connection dsh-client-ui-conversation; do
    verify_marker "$BASE/$pkg/lib/client.js" randomuuid-polyfill "$pkg"
  done
  # marker 前缀匹配：privileged-loopback 或 privileged-loopback:upstream-satisfied 都算通过
  verify_marker "$CONN_INDEX" privileged-loopback "dsh-client-connection"
  verify_marker "$LLM_DS" vision-materialize "dsh-llm-deepseek"
  verify_marker "$APIPROXY" vision-gate "dsh-host-apiproxy"
  # token-pinning 与图标无关，必须在条件块之外
  verify_marker "$TOKEN_FILE" token-pinning "dsh-client-connection"
  if [ -f "$ICON" ] && [ -f "$MAKE_FAVICON" ]; then
    verify_marker "$FAVICON" favicon-custom "dsh-web-frontend"
    if [ -f "$FAVICON" ] && ! grep -qF 'data:image/jpeg;base64' "$FAVICON"; then
      fail "favicon-custom: favicon.svg 未嵌入 base64 图标"
    fi
  else
    echo "verify: favicon-custom SKIP（镜像内无 icon 资源）"
  fi
fi

if [ "$FAIL" = "1" ]; then
  echo "FATAL: LAN patches could not be applied/verified against this dsh version." >&2
  echo "Update patch-dsh.sh in github.com/llzg/dsh-docker and re-trigger the build." >&2
  exit 1
fi
[ "$STRICT" = "1" ] && echo "patch-verify: all LAN patch invariants OK"
exit 0
