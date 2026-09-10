#!/usr/bin/env bash
# Dockerfile 层顺序契约 + 构建代理参数的回归测试（不需要网络、不需要 docker）。
#
# 背景（2026-09-10 实测事故）：
#   BuildKit 的层缓存键 = 该指令**展开后**的字符串。LABEL/ENV 里一旦引用
#   ${DSH_VERSION} / ${DSH_CHANNEL} / ${GIT_REVISION}，从那一行往后的所有层
#   都会随版本/通道/commit 变化而全部失效。原先这三行 LABEL 摆在 apt 之前，导致：
#     · 每个 git push（GIT_REVISION 变）→ apt + npm + uv 三层全部重跑；
#     · alpha 与 rc 通道版本号不同 → 两通道永远互相破缓存；
#     · 实测 rc 通道重下 150MB+ apt 包，卡在 apt 层 24 分钟。
#   本测试锁死"稳定层在前、版本相关层在后"的顺序，防止回归。
set -uo pipefail
cd "$(dirname "$0")/.."

DF=Dockerfile
WF=.github/workflows/build-publish.yml
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

[ -f "$DF" ] || { echo "找不到 $DF"; exit 1; }

# ── 定位关键指令所在行号 ─────────────────────────────────────────────────────
first_line() { grep -n "$1" "$DF" | head -1 | cut -d: -f1; }

apt_line=$(grep -n 'apt-get install' "$DF" | head -1 | cut -d: -f1)
uv_line=$(grep -n 'astral.sh/uv' "$DF" | head -1 | cut -d: -f1)
npm_dsh_line=$(grep -n 'npm install -g .*@deepseek-ai/dsh@' "$DF" | head -1 | cut -d: -f1)

# 「易变引用」= 出现在指令值里的 ${DSH_VERSION}/${DSH_CHANNEL}/${GIT_REVISION}。
# 排除纯 ARG 声明行（`ARG DSH_VERSION` 这种声明本身不产生缓存键）与注释行。
vol_line=$(grep -nE '\$\{(DSH_VERSION|DSH_CHANNEL|GIT_REVISION)\}' "$DF" \
             | grep -vE '^[0-9]+:[[:space:]]*(#|ARG[[:space:]])' | head -1 | cut -d: -f1)
# commit 级易变：${GIT_REVISION} 每次 push 都变。它一旦出现在 npm 层之前，
# 每次 commit 都会让 npm 层（135s + 重下依赖）失效 —— 这是本次事故的另一半。
rev_line=$(grep -nE '\$\{GIT_REVISION\}' "$DF" \
             | grep -vE '^[0-9]+:[[:space:]]*(#|ARG[[:space:]])' | head -1 | cut -d: -f1)

# 易变 ARG 的**声明位置**同样致命（受控实验证实）：stage 内声明的 ARG，
# 即使从未被引用，其值也会进入其后所有指令的缓存键。
# 声明在 FROM 之前的全局 ARG 不影响层缓存（实验对照已验证），故只查 FROM 之后。
from_line=$(grep -nE '^FROM ' "$DF" | head -1 | cut -d: -f1)
arg_line=$(awk -v f="${from_line:-1}" 'NR>f && /^[[:space:]]*ARG[[:space:]]+(DSH_VERSION|DSH_CHANNEL|GIT_REVISION)([[:space:]]|$)/ {print NR; exit}' "$DF")

echo "  行号：apt=$apt_line uv=$uv_line npm(dsh)=$npm_dsh_line 首个易变引用=$vol_line GIT_REVISION 首用=$rev_line FROM=$from_line 首个易变 ARG 声明=$arg_line"

# ── 契约断言 ─────────────────────────────────────────────────────────────────
[ -n "$apt_line" ]     && ok "找到 apt 工具链层"                  || bad "找不到 apt-get install 层"
[ -n "$uv_line" ]      && ok "找到 uv 层"                         || bad "找不到 astral.sh/uv 层"
[ -n "$npm_dsh_line" ] && ok "找到 npm install dsh 层"            || bad "找不到 npm install -g dsh 层"
[ -n "$vol_line" ]     && ok "版本相关引用仍然存在（LABEL/ENV 没被误删）" || bad "Dockerfile 里已无 \${DSH_*}/\${GIT_REVISION} 引用"

if [ -n "$apt_line" ] && [ -n "$vol_line" ]; then
  if [ "$apt_line" -lt "$vol_line" ]; then
    ok "apt 稳定层在首个版本相关引用之前（不会每次 commit/每通道重建）"
  else
    bad "apt 层($apt_line) 不在版本引用($vol_line)之前 —— 缓存会随 commit/通道整体失效"
  fi
fi

if [ -n "$uv_line" ] && [ -n "$vol_line" ]; then
  if [ "$uv_line" -lt "$vol_line" ]; then
    ok "uv 稳定层在首个版本相关引用之前"
  else
    bad "uv 层($uv_line) 不在版本引用($vol_line)之前"
  fi
fi

if [ -n "$uv_line" ] && [ -n "$npm_dsh_line" ]; then
  if [ "$uv_line" -lt "$npm_dsh_line" ]; then
    ok "uv 在 npm install dsh 之前（跨版本/跨通道复用，此前直连 GitHub 下 uv 要 165s）"
  else
    bad "uv($uv_line) 必须在 npm install dsh($npm_dsh_line) 之前，否则每次都跟着重建"
  fi
fi

# 关键：GIT_REVISION 只在 npm 层之后出现 → 同版本的新 commit 可整层命中缓存
if [ -n "$rev_line" ] && [ -n "$npm_dsh_line" ]; then
  if [ "$rev_line" -gt "$npm_dsh_line" ]; then
    ok "\${GIT_REVISION} 首用($rev_line) 在 npm 层($npm_dsh_line) 之后 —— 新 commit 不会让 npm 层失效"
  else
    bad "\${GIT_REVISION} 在 npm 层之前出现($rev_line < $npm_dsh_line) —— 每次 commit 都会重建 npm 层"
  fi
else
  bad "找不到 \${GIT_REVISION} 的使用处（构建元数据/label 是否被误删？）"
fi

# 最容易被忽略的一条：易变 ARG 的**声明**不能在稳定层之前
if [ -n "$arg_line" ] && [ -n "$uv_line" ]; then
  if [ "$arg_line" -gt "$uv_line" ]; then
    ok "易变 ARG 声明($arg_line) 在 apt/uv 稳定层之后($uv_line) —— 声明本身不会破坏缓存"
  else
    bad "易变 ARG 在稳定层之前声明($arg_line < $uv_line) —— stage 内 ARG 声明即入缓存键，apt/uv 会随版本/通道/commit 重建"
  fi
else
  bad "stage 内找不到 DSH_VERSION/DSH_CHANNEL/GIT_REVISION 的声明（是否被搬到 FROM 之前或删掉了？）"
fi

# 更细一层：GIT_REVISION/DSH_CHANNEL 的声明也必须晚于 npm 层，
# 否则 npm 层仍会随每次 commit 重建（实测 5.4s）。
late_arg=$(awk -v f="${from_line:-1}" 'NR>f && /^[[:space:]]*ARG[[:space:]]+(DSH_CHANNEL|GIT_REVISION)([[:space:]=]|$)/ {print NR; exit}' "$DF")
if [ -n "$late_arg" ] && [ -n "$npm_dsh_line" ]; then
  if [ "$late_arg" -gt "$npm_dsh_line" ]; then
    ok "DSH_CHANNEL/GIT_REVISION 声明($late_arg) 在 npm 层($npm_dsh_line) 之后 —— npm 层不会随 commit/通道失效"
  else
    bad "DSH_CHANNEL/GIT_REVISION 在 npm 层之前声明($late_arg < $npm_dsh_line) —— npm 层会随每次 commit 重建"
  fi
else
  bad "npm 层之后找不到 DSH_CHANNEL/GIT_REVISION 声明"
fi

# LABEL 三件套必须还在（版本页/排障依赖）
for k in 'opencontainers.image.version' 'opencontainers.image.revision' 'opencontainers.image.channel'; do
  if grep -q "$k" "$DF"; then ok "LABEL $k 仍在"; else bad "LABEL $k 丢失"; fi
done

# ── workflow push 触发路径必须覆盖 Dockerfile 的所有 COPY 源 ──────────────────
# 为什么：漏一个 COPY 源 = "改了文件但镜像不重建"。实测缺口：assets/ 曾不在 paths 里，
# 改 dsh-icon.jpg 不会触发重建，favicon 补丁用的是旧图标。
copies=$(grep -E '^COPY ' "$DF" | awk '{print $2}' | grep -v '^--' | sort -u)
if [ -f "$WF" ]; then
  wpaths=$(awk '/^  push:/{f=1} f&&/^    paths:/{p=1;next} p&&/^permissions:/{exit} p&&/^      - /{gsub(/^      - /,"");print}' "$WF")
  [ -n "$wpaths" ] || wpaths=$(grep -E '^      - ' "$WF" | sed 's/^      - //')
  miss=""
  # ⚠ 必须禁用路径展开：未加引号的 `profiles/**` 会被 shell 展开成 `profiles/web`，
  #   于是 glob 条目永远匹配不上（实测踩过，测试自己误报了一个缺口）。
  set -f
  for src in $copies; do
    ok_src=0
    for wp in $wpaths; do
      [ "$wp" = "$src" ] && ok_src=1 && break
      case "$wp" in
        */'**') d="${wp%/**}"; case "$src" in "$d"/*) ok_src=1; break ;; esac ;;
      esac
    done
    [ "$ok_src" = "1" ] || miss="$miss $src"
  done
  set +f
  if [ -z "$miss" ]; then
    ok "workflow push 触发路径覆盖全部 COPY 源（$(echo "$copies" | wc -l | tr -d ' ') 个）"
  else
    bad "workflow paths 漏了 COPY 源：$miss（改了这些文件不会触发镜像重建）"
  fi
else
  bad "找不到 $WF（无法校验触发路径）"
fi

# ── workflow 的构建代理参数 ──────────────────────────────────────────────────
if [ -f "$WF" ]; then
  grep -q 'HTTP_PROXY=${{ vars.DSH_HTTP_PROXY }}' "$WF" \
    && ok "workflow 把 HTTP_PROXY 传进构建" || bad "workflow 未传 HTTP_PROXY（uv 走 GitHub releases 会卡死）"
  # apt 也必须走代理：实测同样 100 秒，直连只下到 7 个包/9MB，走代理下完 111 个包/146MB。
  # （反例：曾经为了"直连更快"把 deb.debian.org 放进 NO_PROXY，结果 apt 层卡了 911s。）
  if grep -q 'NO_PROXY=.*deb\.debian\.org' "$WF"; then
    bad "NO_PROXY 把 deb.debian.org 排除在代理外 —— 实测直连 0.09MB/s，apt 层会卡到分钟级"
  else
    ok "apt 走代理（NO_PROXY 未排除 deb.debian.org）"
  fi
  # 内网必须留在 NO_PROXY 里：私有 registry / Gitea / NAS 不能走公网代理
  grep -q 'NO_PROXY=.*192\.168\.0\.0/16' "$WF" \
    && ok "NO_PROXY 保留内网段（registry/Gitea 不走代理）" \
    || bad "NO_PROXY 丢了内网段，私有 registry 访问会走代理"
  # 代理不能漏进运行时：Dockerfile 里不允许出现把代理写成 ENV 的语句
  if grep -qiE '^\s*ENV\s+(HTTP_PROXY|HTTPS_PROXY)' "$DF"; then
    bad "Dockerfile 把代理写成了 ENV —— 会漏进运行时容器"
  else
    ok "Dockerfile 没有把代理固化成 ENV（运行时环境干净）"
  fi
else
  bad "找不到 $WF"
fi

echo ""
echo "dockerfile-layers: $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ] || exit 1
