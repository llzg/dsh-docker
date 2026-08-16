# 构建流程审计报告 —— DeepSeek Harness 智能体（deepseek-harness 容器）

审计时间：2026-08-16　|　审计对象：绿联 NAS（192.168.5.16，UGOS Pro / DXP6800PRO，Docker 29.4.3）上自构建的 `deepseek-harness` 容器（本智能体运行环境）

---

## 1. 现状全貌

### 1.1 部署拓扑

```
GitHub（上游 deepseek-ai/deepseek-harness）
   └─ 发布通道 = npm registry（@deepseek-ai/dsh，dist-tag "latest"；仓库本身无 GitHub Release/tag）
        │
        ▼  手动：npm install -g @deepseek-ai/dsh@<版本>
NAS /volume1/docker/deepseek-harness/   ← 用户自建 Dockerfile + compose
        │  docker compose build → dsh-local:latest（纯本地镜像）
        ▼
容器 deepseek-harness（3081:3080，data 卷持久化 /data/dsh）
        ▲
watchtower（轮询 300s，监控全部容器，GHCR 凭据 + 代理 192.168.5.36:7893）
   └─ 只能更新有 registry 的镜像（invoice-app-prod 走 ghcr.io/llzg/invoice-agent-ui 正常自动更新）
```

### 1.2 现有构建资产（NAS 上）

| 文件 | 作用 |
|---|---|
| `Dockerfile` | `node:22-bookworm-slim` → apt 工具链 → `npm install -g @deepseek-ai/dsh@0.1.0-rc.6`（**版本硬编码**）→ 打 LAN 补丁 → 启动 dsh |
| `docker-compose.yml` | `image: dsh-local:latest`、端口 3081:3080、挂载 `./dsh-data:/data/dsh`、`DSH_HOME`/`DSH_TELEMETRY_DISABLED` |
| `patch-dsh.sh` | 三个 LAN 补丁（幂等）：① settings 强制 host 持久化 ② crypto.randomUUID polyfill ③ 特权方法信任 `--trusted-host` |
| `entrypoint.sh` | 初始化 profile 补丁后 exec 原命令 |
| `profiles/web/cordis.patch.yml` | web UI 绑定 0.0.0.0:3080 |

### 1.3 镜像内容（dsh-local:latest，2026-08-16 08:07 构建，1.11GB）

- Node v22.23.2 / Debian bookworm slim / npm 10.9.8
- `@deepseek-ai/dsh@0.1.0-rc.6`（含全部 dsh-* 插件包）
- 三个 LAN 补丁已生效（本审计逐项验证：settings 原始模式已消失、`trustedHosts` 已注入、randomUUID polyfill 标记存在）

### 1.4 运行配置（容器 deepseek-harness）

- ID `3eb9c7d0c964…`（本会话所在容器），`restart: unless-stopped`
- 端口 `3081 → 3080`，卷 `./dsh-data:/data/dsh`
- **无 healthcheck**
- 由 compose 项目管理（UGOS Docker UI 可见「项目/容器/镜像」）

---

## 2. 断点与风险（本次要解决的问题）

| # | 断点 | 影响 | 修复 |
|---|---|---|---|
| 1 | 镜像 `dsh-local:latest` **纯本地、不进 registry** | watchtower 无法自动更新 → 每次升级**全手动**（今天 08:07 手动 rebuild） | 推 GHCR + watchtower 自动拉取 |
| 2 | Dockerfile **版本硬编码** `0.1.0-rc.6` | 升级要手改文件 | 版本参数化（ARG DSH_VERSION） |
| 3 | 无 GitHub Release 触发机制 | 上游发布（npm）→ 无自动构建 | GitHub Actions 每 30 分钟轮询 npm dist-tag |
| 4 | **无 healthcheck** | 更新后是否正常完全靠人肉 | 镜像内置 HEALTHCHECK（node 探活 /health） |
| 5 | **无回滚机制** | 新版异常无法快速回退；`WATCHTOWER_CLEANUP=true` 还会清旧镜像 | GHCR 保留版本标签 + NAS 回滚脚本 + watchdog 自动回滚 |
| 6 | `patch-dsh.sh` 用字符串 sed，上游改代码时**静默失效**（只打印提示不报错） | 新版可能"能装上但 LAN 功能坏了"且无人察觉 | STRICT 构建期校验：补丁不满足不变量 → **构建失败**，坏镜像不进 latest |
| 7 | 绿联 UI 里镜像显示为 `dsh-local:latest` | 无版本信息，无法从 UI 判断部署版本 | 改用 `ghcr.io/llzg/dsh-docker:<版本>` + OCI 标签，UI 直接显示版本 |

### 附注（非阻断观察）

- `/root` 位于容器可写层（非持久卷）：容器重建后工作区丢失。仓库内容全部进 GitHub，可随时重拉。
- NAS 的 watchtower `WATCHTOWER_LABEL_ENABLE=false` 表示**监控全部容器**（compose 注释写反了），新镜像推送后 5 分钟内自动更新。
- 上游 `deepseek-ai/deepseek-harness`（约 12.6 万 star，default branch `master`）通过 `release(dsh): 0.1.0-rc.X` 提交发布 npm 包，近 3 天发 6 个 rc 版，发布频繁 —— 轮询必须轻量（30 分钟一次 HTTP）。
- 参考：发票智能体（invoice-app-prod）已有 push→production-candidate→watchtower 自动更新链路，但**只在 push 时发布、无版本标签、无回滚**；本方案补齐了 release 语义与回滚。

---

## 3. 目标架构（本次交付）

```
npm registry（@deepseek-ai/dsh dist-tag latest）── 轮询 30min ──┐
                                                              ▼
GitHub Actions（llzg/dsh-docker）: 解析版本 → docker build（STRICT 补丁校验）
   → 冒烟测试（/health 200）→ 通过才 push → ghcr.io/llzg/dsh-docker:{版本} + latest
   → 提交 CURRENT_VERSION
                                                              ▼
NAS watchtower（已有，监控全部容器）: 每 5 分钟发现 ghcr latest 变化
   → 拉取 → 重建 deepseek-harness（数据卷不变，会话持续）
                                                              ▼
回滚保护:
   ① 构建期：补丁校验失败 → 不发布（NAS 保持旧版本）
   ② 部署期：HEALTHCHECK 失败 → NAS watchdog（cron 每 5 分钟）连续 15 分钟不健康
            且镜像是刚更新（≤3h）→ 自动回滚到上一版本并暂停自动更新
   ③ 手动：rollback.sh [版本] 一键回退；resume-auto-update.sh 恢复自动更新
                                                              ▼
UGOS Docker UI: 容器 deepseek-harness 显示 ghcr.io/llzg/dsh-docker:latest，
                镜像列表显示带版本号的标签，compose「项目」视图不变
```

关键安全设计：**坏镜像永远不会进入 latest**（先本地构建冒烟、通过才推送）；**回滚钉住后自动更新暂停**，避免 watchtower 立刻又拉回坏版本。
