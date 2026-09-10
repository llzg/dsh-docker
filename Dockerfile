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

FROM ${BASE_IMAGE} AS base

ARG DSH_VERSION
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

# Build toolchain for native modules (e.g. node-pty) if prebuilds are unavailable.
# Vulkan 依赖：llama.cpp GGML_VULKAN 编译需要 glslc + 头文件（libvulkan-dev 自带）；
# mesa-vulkan-drivers 提供 Intel Iris Xe 的 Vulkan ICD（运行时，配合 /dev/dri 直通）。
# cache mount：apt 的包缓存与索引跨构建保留。sharing=locked 避免并行矩阵构建互踩。
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ git ca-certificates curl \
        libvulkan-dev libvulkan1 mesa-vulkan-drivers glslc glslang-tools spirv-tools spirv-headers \
    && rm -rf /var/lib/apt/lists/*

# Official DeepSeek Harness CLI (npm registry, published by DeepSeek).
# Version is parametric: the CI workflow resolves it from the npm dist-tag.
# npm 缓存挂载：dsh 依赖树有数百个包，仅版本号变化时靠缓存复用 tarball，
# 避免每次都从公网重下（这是本地构建从 ~100s 降到十几秒的关键之一）。
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs "@deepseek-ai/dsh@${DSH_VERSION}"

# pnpm（Profile 插件管理器依赖）：`dsh plugin` 是 pnpm 转发器，没有 pnpm 时
# `dsh plugin --profile web add ...` 直接 exit 127（实测）。用 Node 自带
# Corepack 固化固定版本 11.22.0（已验证），不用 latest，保证 CI/watchtower
# 重建可复现。shim 落在 /usr/local/bin（镜像层，容器重建不丢）；
# 包体落在 /root/.cache/node/corepack（运行时被 /root 持久卷继承）。
RUN corepack enable \
    && corepack prepare pnpm@11.22.0 --activate \
    && pnpm --version

# uv（Python 包管理器）——随镜像持久安装到 /usr/local/bin。
# 此前装在容器可写层，容器重建即丢失；烤进镜像后每次重建都在。
# 供应链：固定版本安装（Astral 官方按版本路径分发 install.sh），不用 latest；
# 升级 uv 改 ARG UV_VERSION 即可。
ARG UV_VERSION=0.8.15
RUN --mount=type=cache,target=/root/.cache/uv \
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR=/usr/local/bin sh \
    && uv --version

ENV DSH_HOME=/data/dsh
ENV DSH_TELEMETRY_DISABLED=1
# ── 双通道契约 §6 的容器默认值（运行时均可被 compose/.env 覆盖）──────────────
# DSH_CHANNEL：镜像所属通道（构建 ARG 决定，默认 alpha）
ENV DSH_CHANNEL=${DSH_CHANNEL}
# DSH_TRUSTED_HOST：--trusted-host 取值。宿主机 IP 会变（实测 192.168.5.17），
# 故不再硬编码进 CMD，改为运行时环境变量（见下方 CMD）。
ENV DSH_TRUSTED_HOST=192.168.5.17
# DSH_VERSION_PORT：版本页端口；0 = 不启动（rc 容器默认 0，由 alpha 容器统一渲染）
ENV DSH_VERSION_PORT=3082
WORKDIR /data

COPY profiles/web/cordis.patch.yml /opt/dsh-profiles/web/cordis.patch.yml
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# 3080 = dsh web UI；3082 = 版本信息页（entrypoint 守护拉起 version-server.js）
EXPOSE 3080 3082
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
# sh -c + exec：让 dsh 成为 PID 1，SIGTERM/SIGINT 可传（entrypoint 用 exec "$@"）。
# --trusted-host 从环境变量取值（契约 §6，不再硬编码宿主机 IP）。
CMD ["sh", "-c", "exec dsh --profile web --trusted-host \"$DSH_TRUSTED_HOST\" --no-open"]

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
