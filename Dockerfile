# DeepSeek Harness Web — auto-build image (GitHub Actions → GHCR → NAS watchtower)
#
# Pure source build from the official npm release channel:
#   upstream deepseek-ai/deepseek-harness publishes via npm (@deepseek-ai/dsh,
#   dist-tag "latest"); there are no GitHub Releases/tags upstream.
#
# Build args:
#   DSH_VERSION  npm version to install (e.g. 0.1.0-rc.6); default = npm dist-tag latest
#   GIT_REVISION short commit sha of the build (for traceability labels)

ARG DSH_VERSION=0.1.0-rc.6

FROM node:22-bookworm-slim AS base

ARG DSH_VERSION
ARG GIT_REVISION=unknown

LABEL org.opencontainers.image.title="DeepSeek Harness Web (dsh)"
LABEL org.opencontainers.image.description="DeepSeek Harness web UI with LAN patches — auto-built from npm release, auto-updated via watchtower"
LABEL org.opencontainers.image.source="https://github.com/llzg/dsh-docker"
LABEL org.opencontainers.image.version="${DSH_VERSION}"
LABEL org.opencontainers.image.revision="${GIT_REVISION}"
LABEL org.opencontainers.image.licenses="MIT"

# Build toolchain for native modules (e.g. node-pty) if prebuilds are unavailable.
# Vulkan 依赖：llama.cpp GGML_VULKAN 编译需要 glslc + 头文件（libvulkan-dev 自带）；
# mesa-vulkan-drivers 提供 Intel Iris Xe 的 Vulkan ICD（运行时，配合 /dev/dri 直通）。
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ git ca-certificates curl \
        libvulkan-dev libvulkan1 mesa-vulkan-drivers glslc glslang-tools spirv-tools spirv-headers \
    && rm -rf /var/lib/apt/lists/*

# Official DeepSeek Harness CLI (npm registry, published by DeepSeek).
# Version is parametric: the CI workflow resolves it from the npm dist-tag.
RUN npm install -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs "@deepseek-ai/dsh@${DSH_VERSION}"

# uv（Python 包管理器）——随镜像持久安装到 /usr/local/bin。
# 此前装在容器可写层，容器重建即丢失；烤进镜像后每次重建都在。
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
    && uv --version

ENV DSH_HOME=/data/dsh
ENV DSH_TELEMETRY_DISABLED=1
WORKDIR /data

COPY profiles/web/cordis.patch.yml /opt/dsh-profiles/web/cordis.patch.yml
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

EXPOSE 3080
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["dsh", "--profile", "web", "--trusted-host", "192.168.5.16"]

# LAN fixes (settings host mode + crypto.randomUUID polyfill + trusted hosts).
# STRICT=1 turns every patch into a verified invariant: if upstream changes the
# code so a patch can no longer be applied, the build FAILS instead of silently
# shipping a broken LAN deployment (the CI never publishes, the NAS keeps the
# last good image — this is the build-time rollback guard).
COPY patch-dsh.sh /opt/patch-dsh.sh
RUN chmod +x /opt/patch-dsh.sh && STRICT=1 /opt/patch-dsh.sh

# landlock-run 同时链接到 /usr/local/bin，方便 `which`/排障查看。
# 说明：harness 实际通过 node_modules 的 require.resolve 定位该二进制，
# 此链接仅提升 PATH 可见性，不是功能依赖。
RUN ln -sf /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/node-addon-landlock-run-linux-x64/bin/landlock-run /usr/local/bin/landlock-run && \
    ls -la /usr/local/bin/landlock-run

# 版本信息页（3082 端口）：写入构建元数据（dsh 版本 / dsh-docker 提交 / 构建时间）
RUN node -e "require('fs').writeFileSync('/opt/dsh-version.json', JSON.stringify({dshVersion: process.env.DSH_VERSION, buildCommit: process.env.GIT_REVISION, builtAt: new Date().toISOString()}, null, 2))" && \
    cat /opt/dsh-version.json
COPY scripts/version-server.js /opt/version-server.js
RUN node --check /opt/version-server.js && chmod +x /opt/version-server.js

# Healthcheck used both by the NAS watchdog (auto-rollback) and docker itself.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:3080/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
