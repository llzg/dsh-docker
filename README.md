# dsh-docker —— DeepSeek Harness 智能体自动构建 / 自动更新 / 回滚

让绿联 NAS 上自构建的 `deepseek-harness` 智能体（dsh web UI）实现：

> **GitHub（上游 npm）发布新版本 → 自动构建 → 自动更新 → 失败自动/手动回滚 → 绿联 NAS UI 正常显示**

## 架构一览

```
npm dist-tag latest ──(30min 轮询)──► GitHub Actions（本仓库）
                                        │ 构建（含 LAN 补丁 STRICT 校验）
                                        │ 冒烟测试（/health）→ 通过才推送
                                        ▼
                                 ghcr.io/llzg/dsh-docker:{版本} + latest
                                        │
NAS watchtower（已有）──5min 轮询──► 拉取并重建 deepseek-harness
                                        │
                HEALTHCHECK 失败 ──► NAS watchdog 自动回滚到上一版本
                手动：rollback.sh / resume-auto-update.sh
```

## 目录结构

```
.
├── Dockerfile                 # 版本参数化 + STRICT 补丁校验 + HEALTHCHECK + OCI 标签
├── patch-dsh.sh               # LAN 补丁（STRICT=1 时验证不变量，失败即构建失败）
├── entrypoint.sh              # 入口（初始化 profile 补丁）
├── profiles/web/cordis.patch.yml
├── CURRENT_VERSION            # 最近一次已发布版本（由 CI 回写）
├── .github/workflows/build-publish.yml
├── scripts/
│   ├── check-new-version.js   # npm dist-tag 解析 / 版本比对
│   └── smoke-test.sh          # 构建后冒烟测试
└── nas/                       # NAS 侧部署资产
    ├── docker-compose.yml     # 新 compose（GHCR 镜像 + 回滚钉住支持）
    ├── install.sh             # 一次性部署（幂等）
    ├── switch.sh              # 切换容器到 GHCR 镜像（重启一次）
    ├── rollback.sh            # 一键回滚（默认上一版本，可指定版本）
    ├── resume-auto-update.sh  # 恢复自动更新
    ├── watchdog.sh            # 健康检查自动回滚守护（cron 每 5 分钟）
    └── lib.sh                 # 共享函数库
```

## 工作原理

### 自动构建（GitHub Actions）
- **npm 轮询**：每 30 分钟查 `@deepseek-ai/dsh` 的 dist-tag `latest`（上游 deepseek-harness 无 GitHub Release，npm 才是发布通道）；与 `CURRENT_VERSION` 不同则构建。
- **手动触发**：仓库 Actions 页 → `build-publish` → Run workflow（可填指定版本）。
- **补丁/构建文件变更**：push 到 main 触发重建（重新发布同版本号标签，watchtower 感知 digest 变化更新）。
- 流程：`解析版本 → docker build（DSH_VERSION/GIT_REVISION 参数）→ 冒烟测试 → 通过才 push GHCR（版本标签 + latest）→ 回写 CURRENT_VERSION`。**构建失败/冒烟失败 = 不发布**，NAS 永远停在最后一个好版本。

### 自动更新（NAS watchtower，已存在）
- watchtower 每 5 分钟检查所有容器的 registry 镜像；`ghcr.io/llzg/dsh-docker:latest` 有变化即拉取重建 `deepseek-harness`（`./dsh-data` 卷不变，会话/数据持续）。

### 回滚（三层保护）
1. **构建期**：`patch-dsh.sh` 以 `STRICT=1` 运行，LAN 补丁不变量不满足 → 构建失败，坏镜像进不了 GHCR。
2. **部署期自动**：镜像内置 HEALTHCHECK；NAS cron（每 5 分钟）检测到连续 3 次（约 15 分钟）不健康、且镜像是刚更新（构建 ≤3h）→ 自动拉取上一版本、钉住并重建。回滚后自动更新暂停（防 watchtower 拉回坏版本）。
3. **手动**：`rollback.sh`（默认回上一版本 / `rollback.sh 0.1.0-rc.5` 指定版本）；`resume-auto-update.sh` 恢复自动更新。

### 绿联 NAS UI 显示
- 容器 `deepseek-harness` 继续以 compose「项目」形式显示；镜像名变为 `ghcr.io/llzg/dsh-docker:latest`，镜像列表可见带版本号的标签（如 `0.1.0-rc.6`），OCI 标签含版本/提交信息。详见 [docs/ugos-ui.md](docs/ugos-ui.md)。

## 使用手册

### 首次部署（NAS，一次性）
```sh
# 1) 把 nas/ 目录放到 NAS（例）：
#    scp -r nas/ lzg@192.168.5.16:/volume1/docker/dsh-deploy/

# 2) 安装（备份旧 compose、装新 compose、装 watchdog cron、预拉镜像）：
sh /volume1/docker/dsh-deploy/install.sh

# 3) 切换容器到 GHCR 镜像（会重启 deepseek-harness 一次，约 1 分钟）：
sh /volume1/docker/dsh-deploy/switch.sh
```

### 日常操作
```sh
# 手动回滚到上一版本：
sh /volume1/docker/dsh-deploy/rollback.sh
# 或指定版本：
sh /volume1/docker/dsh-deploy/rollback.sh 0.1.0-rc.5
# 恢复自动更新：
sh /volume1/docker/dsh-deploy/resume-auto-update.sh
# 回滚/守护日志：
tail -f /volume1/docker/dsh-deploy/state/rollback.log
tail -f /volume1/docker/dsh-deploy/state/watchdog.log
```

### 手动触发构建
GitHub → llzg/dsh-docker → Actions → **build-publish** → Run workflow（可选填版本号）。

## 运维要点

- **上游改代码导致补丁失效**：构建会失败并在日志给出明确提示（`VERIFY FAIL … update patch-dsh.sh`）。更新 `patch-dsh.sh` 后 push 到 main 即可重发。
- **NAS 侧凭据**：watchtower 已在用 `/home/lzg/.docker/config.json`（GHCR 凭据）拉私有/公共包；本仓库脚本优先复用该凭据，包本身设为 public，无凭据也能匿名拉取。
- **数据安全**：容器重建只换镜像，`/volume1/docker/deepseek-harness/dsh-data`（DSH_HOME、会话、配置）全程持久化。
- **上游无 Release 的说明**：deepseek-ai/deepseek-harness 仓库没有 GitHub Releases/tags，正式发布即 npm publish；因此本方案以 npm dist-tag 轮询作为"GitHub 发布新版本"的检测方式。
