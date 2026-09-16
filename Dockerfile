# DeepSeek Harness Web — auto-build image (GitHub Actions → GHCR → NAS watchtower)
#
# Pure source build from the official npm release channel:
#   upstream deepseek-ai/deepseek-harness publishes via npm (@deepseek-ai/dsh,
#   dist-tag "latest"); there are no GitHub Releases/tags upstream.
#
# Build args:
#   BASE_IMAGE    基础镜像（默认 Docker Hub；可指向内网拉取缓存，如
#                 192.168.5.35:5051/library/node:22-bookworm-slim，避免每次走公网）
#   DSH_VERSION   npm version to install (e.g. 0.1.3-alpha.2); default = npm dist-tag latest
#   DSH_CHANNEL   双通道契约（docs/dual-channel.md §2/§6）的通道名 alpha|rc|stable
#                 → OCI label org.opencontainers.image.channel + /opt/dsh-build.json
#   GIT_REVISION  short commit sha of the build (for traceability labels)
#
# 供应链（base image）：tag 固定为 node:22-bookworm-slim；**digest 固定（@sha256:…）
# 由 Renovate 负责自动提 PR**（renovate.json 已开 docker digest pinning），不要手工写死
# digest，否则会与上游安全更新脱节。第三方安装源（uv / semver / pnpm）一律固定版本号，
# 不用 latest，保证 CI 与 watchtower 重建可复现。

ARG DSH_VERSION=0.1.3-alpha.2
ARG DSH_CHANNEL=alpha
ARG BASE_IMAGE=node:22-bookworm-slim
# Docker CLI 来源镜像（默认走群晖 pull-through :5051，避免自建 buildkitd 无代理拉 Docker Hub）
# 用**完整版** docker:27（不是 -cli）：它同时自带 buildx + compose 两个 CLI 插件，
# 容器内因此可直接 `docker compose` / `docker buildx`（-cli 镜像只有 docker 本体，缺插件）。
ARG DOCKER_CLI_IMAGE=192.168.5.35:5051/library/docker:27

# ── Docker CLI 来源（拷 CLI 二进制 + buildx/compose 插件）──────────────────────
# 目的：容器内 agent 可用 /var/run/docker.sock 直接操作容器 / 用 compose（alpha 通道挂了 socket）。
# 烤进镜像后容器重建不丢（历史：可写层临时装的 docker/ssh 一重建就没；ssh 现由 apt 的
# openssh-client 提供）。
FROM ${DOCKER_CLI_IMAGE} AS dockercli

FROM ${BASE_IMAGE} AS base

# ══════════════════════════════════════════════════════════════════════════════
# 层顺序契约（2026-09-10 实测踩坑后固化，勿随意调整）：
#
#   BuildKit 的层缓存键 = 该指令**展开后**的字符串。而且实测（受控实验，见
#   scripts/test-dockerfile-layers.sh）：
#     ⚠ **只要 ARG 在 stage 内被"声明"，它的值就进入其后所有指令的缓存键 ——
#       哪怕这个 ARG 从未被引用。**
#     ⚠ LABEL/ENV 里引用 ${DSH_VERSION}/${DSH_CHANNEL}/${GIT_REVISION} 同理。
#   （对照实验：声明在 FROM **之前**的全局 ARG 改值不影响层缓存；声明在 stage
#     内部的 ARG 改值 → 其后所有 RUN 全部重建，实测 #5/#6 由 CACHED 变 DONE。）
#
#   反面教材（本次实测）：DSH_VERSION/DSH_CHANNEL/GIT_REVISION 三个 ARG 与
#   LABEL version/revision/channel 原先都摆在 apt 之前 →
#     · 每次 git push（GIT_REVISION 变）→ apt + npm + uv 三层全部重跑；
#     · alpha 与 rc 通道版本号不同 → 两通道之间也永远互相破缓存。
#   代价：apt 重下 150MB+（libllvm15/mesa 等）实测卡了 **911s**，rc 通道更卡到 24 分钟。
#
#   规矩：**稳定层在前，版本相关层在后；易变 ARG 的"声明"也必须靠后**。
#     1) apt 工具链     —— 只依赖 base 镜像与包列表
#     2) uv             —— 只依赖 UV_VERSION（常量）
#     3) ← 分界线：到这里才声明 DSH_VERSION/DSH_CHANNEL/GIT_REVISION
#     4) npm install dsh —— 唯一**必须**随版本重建的重层（有 /root/.npm 缓存挂载兜底）
#     5) LABEL/ENV/其余 —— 廉价层，随 commit 失效无所谓
# ══════════════════════════════════════════════════════════════════════════════

# ── 稳定层 1/2：apt 工具链 ────────────────────────────────────────────────────
# Build toolchain for native modules (e.g. node-pty) if prebuilds are unavailable.
# Vulkan 依赖：llama.cpp GGML_VULKAN 编译需要 glslc + 头文件（libvulkan-dev 自带）；
# mesa-vulkan-drivers 提供 Intel Iris Xe 的 Vulkan ICD（运行时，配合 /dev/dri 直通）。
# cache mount：apt 的包缓存与索引跨构建保留。sharing=locked 避免并行矩阵构建互踩。
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ git ca-certificates curl openssh-client \
        libvulkan-dev libvulkan1 mesa-vulkan-drivers glslc glslang-tools spirv-tools spirv-headers \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI（静态 Go 二进制；来自 docker:27）。只含 CLI，不含 daemon；配 /var/run/docker.sock 使用。
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
# buildx + compose 插件（Debian 下 docker CLI 会搜 /usr/local/libexec/docker/cli-plugins）。
# 代价约 +139MB；换取容器内可直接 `docker compose` / `docker buildx`（无需从宿主挂载二进制）。
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose

# ── 稳定层 2/2：uv（Python 包管理器）──────────────────────────────────────────
# 随镜像持久安装到 /usr/local/bin。此前装在容器可写层，容器重建即丢失；烤进镜像后每次重建都在。
# 供应链：固定版本安装（Astral 官方按版本路径分发 install.sh），不用 latest；升级改 ARG UV_VERSION。
# ARG 紧贴使用处声明（常量，不影响上层；也不让 apt 层跟着 UV_VERSION 走）。
ARG UV_VERSION=0.8.15
RUN --mount=type=cache,target=/root/.cache/uv \
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR=/usr/local/bin sh \
    && uv --version

# ══════════════════════════════════════════════════════════════════════════════
# ↓↓↓ 分界线：**从这里开始**才允许声明随版本/通道/commit 变化的 ARG ↓↓↓
#
# 声明位置是关键：这些 ARG 一旦出现在稳定层之前，apt/uv 层就会随每次 commit
# （GIT_REVISION）和每个通道（DSH_VERSION/DSH_CHANNEL）重建 —— 这正是上面
# "层顺序契约"里的事故根因（受控实验证实：stage 内声明的 ARG 即使从未被引用，
# 改值也会让其后的 RUN 全部 CACHED→DONE）。
#
# 再细分一层：**只把这一层真正用到的 DSH_VERSION 声明在这里**；
# DSH_CHANNEL / GIT_REVISION 留到 npm 之后（见下方 LABEL 前）——
# 否则每次 commit 仍会让 npm 层重建（实测：声明在 npm 之前时换 commit，
# npm 层 DONE 5.4s；挪到后面后全 CACHED，整个构建 12s → 4s 级）。
# 不写默认值 = 继承 FROM 之前全局 ARG 的默认值（Docker 语义），--build-arg 可覆盖。
# ══════════════════════════════════════════════════════════════════════════════
ARG DSH_VERSION

# Official DeepSeek Harness CLI (npm registry, published by DeepSeek).
# Version is parametric: the CI workflow resolves it from the npm dist-tag.
# npm 缓存挂载：dsh 依赖树有数百个包，仅版本号变化时靠缓存复用 tarball，
# 避免每次都从公网重下（这是本地构建从 ~100s 降到十几秒的关键之一）。
#
# ⚠ 位置契约：这一层**必须**排在 ${GIT_REVISION} / ${DSH_CHANNEL} 出现或声明之前。
#   它的缓存键只应随 base 镜像、apt/uv 层、以及 ${DSH_VERSION} 变化 —— 即"换版本才重建"。
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs "@deepseek-ai/dsh@${DSH_VERSION}"

# pnpm（Profile 插件管理器依赖）：`dsh plugin` 是 pnpm 转发器，没有 pnpm 时
# `dsh plugin --profile web add ...` 直接 exit 127（实测）。用 Node 自带
# Corepack 固化固定版本 11.22.0（已验证），不用 latest，保证 CI/watchtower
# 重建可复现。shim 落在 /usr/local/bin（镜像层，容器重建不丢）；
# 包体落在 /root/.cache/node/corepack（运行时被 /root 持久卷继承）。
# 注意：corepack 必须排在 npm install 之后 —— 它会往 PATH 里装 npm/yarn/pnpm shim。
RUN corepack enable \
    && corepack prepare pnpm@11.22.0 --activate \
    && pnpm --version

# ── 元数据标签（纯 metadata，层本身 0.0s，但会让**其后**的层随 commit 失效）──────
# 故整体放在 npm / corepack 之后：新 commit 只重建这里往下的廉价层（COPY/校验/健康检查）。
#
# DSH_CHANNEL / GIT_REVISION 的**声明**也放在这里（而不是分界线上）：这样它们既不进
# apt/uv 的缓存键，也不进 npm/corepack 的缓存键 —— 换 commit 时前四层全 CACHED。
# 不写默认值 = 继承全局 ARG 默认值；DSH_CHANNEL 显式给默认值便于单独 docker build。
ARG DSH_CHANNEL=alpha
ARG GIT_REVISION=unknown

LABEL org.opencontainers.image.title="DeepSeek Harness Web (dsh)"
LABEL org.opencontainers.image.description="DeepSeek Harness web UI with LAN patches — auto-built from npm release per channel, promoted via dsh-safe-deploy (no watchtower)"
LABEL org.opencontainers.image.source="https://github.com/llzg/dsh-docker"
LABEL org.opencontainers.image.version="${DSH_VERSION}"
LABEL org.opencontainers.image.revision="${GIT_REVISION}"
LABEL org.opencontainers.image.licenses="MIT"
# 双通道契约 §6：镜像所属通道（alpha / rc / stable），供版本页与排障读取
LABEL org.opencontainers.image.channel="${DSH_CHANNEL}"

# ── 通道身份 / 数据目录：**故意不在这里固化 ENV**（2026-09-16 P0 事故）──────────
# 这里曾写：ENV DSH_HOME=/data/dsh、DSH_CHANNEL=${DSH_CHANNEL}、
#           DSH_TRUSTED_HOST=192.168.5.17、DSH_VERSION_PORT=3082。
# docker compose 的插值规则是 **shell 环境优先于 --project-directory 下的 .env**，
# 于是任何「基于本镜像启动的进程」都会把这 4 个值泄漏给 compose，静默压掉通道 .env：
#   · 实测：docker run <dsh 镜像> sh -c 'sh realign.sh alpha'
#   · DSH_HOME 掉回 /data/dsh（alpha 真实 home 是 /data/dsh/test/0.1.2-alpha.5）
#     → DSH 去读 09-08 之后就不再写入的旧 home，界面表现为"对话记录全没了"
#     （数据没丢，只是读错了目录）；
#   · DSH_TRUSTED_HOST 只剩一个地址 → /api/* 与 WebSocket 全 403，界面空列表 + 重连。
# 结论：通道身份与数据目录**只允许来自各通道 .env**，由 compose 的 environment/command
# 在运行时注入（nas/docker-compose.yml，契约 §6）。禁止在此重新加这几个 ENV。
# 兜底：nas/realign.sh 启动即 unset 这些键，并在重建后正向断言容器 env == 通道 .env。
# 唯一保留的是全局行为开关（与通道身份无关）：
ENV DSH_TELEMETRY_DISABLED=1
WORKDIR /data

COPY profiles/web/cordis.patch.yml /opt/dsh-profiles/web/cordis.patch.yml
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# 3080 = dsh web UI；3082 = 版本信息页（entrypoint 守护拉起 version-server.js）
EXPOSE 3080 3082
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
# sh -c + exec：让 dsh 成为 PID 1，SIGTERM/SIGINT 可传（entrypoint 用 exec "$@"）。
# --trusted-host 由通道 .env / compose 在运行时注入；镜像**不带**默认值（否则又变成"固化身份"）。
# 裸跑（不经 compose）时退回 127.0.0.1：fail-closed，只信任本机，避免误把任意 Host 放进围栏。
CMD ["sh", "-c", "exec dsh --profile web --trusted-host \"${DSH_TRUSTED_HOST:-127.0.0.1}\" --no-open"]

# LAN fixes (settings host mode + crypto.randomUUID polyfill + trusted hosts).
# STRICT=1 turns every patch into a verified invariant: patch-dsh.sh 现在按契约 §10
# 做「锚点预检 → 应用 → 写 marker → 正向校验 marker」，锚点失配即构建失败
# （CI 不发布，NAS 保留上一份好镜像——构建期回滚闸门）。
COPY patch-dsh.sh /opt/patch-dsh.sh
# 自定义图标资源（favicon 嵌入用，patch-dsh.sh 构建时与容器启动自愈时读取）
COPY assets/dsh-icon.jpg /opt/dsh-icon.jpg
COPY scripts/make-favicon.js /opt/make-favicon.js
RUN chmod +x /opt/patch-dsh.sh && STRICT=1 /opt/patch-dsh.sh

# landlock-run 同时链接到 /usr/local/bin，方便 `which`/排障查看。
# 说明：harness 实际通过 node_modules 的 require.resolve 定位该二进制，
# 此链接仅提升 PATH 可见性，不是功能依赖。
RUN ln -sf /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/node-addon-landlock-run-linux-x64/bin/landlock-run /usr/local/bin/landlock-run && \
    ls -la /usr/local/bin/landlock-run

# 构建元数据：契约 §8 要求镜像内 /opt/dsh-build.json
# （dshVersion / buildCommit / builtAt / channel）；同时保留 /opt/dsh-version.json
# 旧路径（当前 version-server.js 读它，scripts/ 由并行改造负责）。
RUN node -e "const fs=require('fs');const meta={dshVersion:process.env.DSH_VERSION,buildCommit:process.env.GIT_REVISION,builtAt:new Date().toISOString(),channel:process.env.DSH_CHANNEL};for(const p of ['/opt/dsh-version.json','/opt/dsh-build.json'])fs.writeFileSync(p,JSON.stringify(meta,null,2)+'\n');console.log(meta)" && \
    cat /opt/dsh-build.json
# semver（版本检测/版本页共用，随镜像持久）——固定版本号，避免重建漂移
ARG SEMVER_VERSION=7.6.3
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    cd /opt && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund "semver@${SEMVER_VERSION}" 2>&1 | tail -1
COPY scripts/version-policy.js /opt/version-policy.js
COPY scripts/safe-deploy-policy.js /opt/safe-deploy-policy.js
COPY scripts/registry.js /opt/registry.js
COPY scripts/version-server.js /opt/version-server.js
# 版本 SSOT（镜像内置副本；运行时优先读 /root/nas_docker/dsh-version.json 工作区实时版）
COPY dsh-version.json /opt/dsh-version-ssot.json
RUN node --check /opt/version-policy.js && node --check /opt/safe-deploy-policy.js \
    && node --check /opt/registry.js && node --check /opt/version-server.js \
    && chmod +x /opt/version-server.js

# Healthcheck used both by the NAS watchdog (auto-rollback) and docker itself.
# ⚠ 必须用 **TCP 探活**，不能用 HTTP 200 探活：
#   DSH 0.1.2-alpha.3 起 web 默认启用 launch token 鉴权，未带 token 的 "/" 返回 401，
#   于是 fetch(...).then(r=>r.ok) 恒为 false → 容器永远 unhealthy
#   （2026-09-10 在 UGREEN 生产上实测：旧容器正是因为被改成了 TCP 探活才 healthy；
#     按镜像自带的 HTTP 探活重建后立刻变 unhealthy）。
# 版本页 3082 的存活由 entrypoint 的守护循环负责（契约 §6）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "const s=require('net').connect(3080,'127.0.0.1');s.on('connect',()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1))"
