# DSH Safe Upgrade Architecture（成熟轮子优先 + 自定义安全层）

> 日期：2026-09-09（v2，双通道）· 适用：llzg/dsh-docker（DeepSeek Harness Docker 部署）
> 通道/字段/API 的**唯一契约**见 [dual-channel.md](dual-channel.md)。

## 0. v2 变更摘要（2026-09-09）

| 变更 | 原因 | 位置 |
|---|---|---|
| SSOT 升级为 `schemaVersion 2`：`channels.{alpha,rc}` 各自 `production`/`candidate` | 单通道模型无法表达 3081(alpha) 与 3083(rc) 并行 | `dsh-version.json`、`safe-deploy-policy.js:parseSSOT` |
| 每通道独立解析构建目标（通道内最高且可 npm 安装） | 旧逻辑跨通道取最高 → rc 线永不被自动构建 | `version-policy.js:computeChannelTarget/computeTargets` |
| CI 收敛判定改为"该版本是否已在 GHCR tag 列表" | 旧逻辑用 `latest` label，而 prerelease 永不打 latest → 每 30 分钟重建同一版本 | `check-new-version.js`、`build-publish.yml` |
| 版本页双通道 + 构建状态 + 实时 SSOT + 强制刷新 | 页面读镜像内置 SSOT 快照，且无法表达"构建失败" | `version-server.js` |
| 补丁 STRICT 改为 marker 正向校验 + 锚点预检 | 旧校验"原始模式消失"在锚点失配时恒真，补丁可静默失效 | `patch-dsh.sh` |
| 每通道一个 compose 项目，compose 调用显式 `-p`/`--project-directory` | watchdog 容器内 `-f /dsh-app/...` 会把项目名/卷源解析错（可能挂空数据目录） | `nas/lib.sh:compose_cmd`、`nas/watchdog-container.sh` |
| pin/rollback 事务化（`.env.pending` → 校验 → 原子 `mv` → `up --wait` → 失败还原） | 旧实现先写 `.env` 再 `up`，失败残留会让 watchdog 永久 skip | `nas/lib.sh:pin_version` |
| `prev_version` 改 semver 选版 + 未命中即报错 + 本地镜像兜底 | 旧实现未命中时返回"列表最高"→ 回滚变升级；GHCR 断网时静默失效 | `nas/lib.sh:prev_version` |
| watchdog 新鲜度改用容器 `StartedAt` | 旧实现用镜像构建时间 → 半夜构建、白天部署的镜像永不自动回滚 | `nas/watchdog.sh` |
| 移除 `CURRENT_VERSION`、移除 watchtower/latest 自动更新链路 | 该链路与代码相反且会静默降级（`latest` 实测停在 0.1.1-rc.2） | 全仓 |

## 1. 职责边界（每项唯一 authority）

| 职责 | 组件 | 说明 |
|---|---|---|
| 版本发现 / SemVer / prerelease 策略 | **Renovate**（`renovate.json` + SSOT `channels.*.candidate`） | Renovate 只更新 `alpha.candidate`（rc 候选人工维护）；不做 promote |
| 构建 immutable image | **CI**（`.github/workflows/build-publish.yml`） | 矩阵：每通道一 job；tag=`<version>-<sha>`（不可变）+ `<version>`（stable 追加 `latest`） |
| 容器级 rollout | **docker-rollout**（可用时）或 Compose + 健康门禁 | 只负责容器切换；不可用自动回退 |
| DSH 特有数据安全 | **`scripts/dsh-safe-deploy`**（薄层，按通道） | snapshot / 隔离测试 / 风险分级 / 门禁 promote / rollback；flock 互斥 |
| 镜像自动替换 | **已禁用** | DSH 退出 Watchtower（label `com.centurylinklabs.watchtower.enable=false`） |
| 版本状态可视化 | **`scripts/version-server.js`**（3082） | 每通道：当前/候选/风险/迁移/测试/回滚就绪 + 推荐构建目标是否已发布 + 最近一次 CI 结论 |

## 2. 版本 SSOT：`dsh-version.json`

```json
{
  "schemaVersion": 2,
  "primaryChannel": "alpha",
  "channels": {
    "alpha": { "port": 3081, "container": "dsh-alpha", "project": "dsh-alpha",
               "dataDir": "/volume1/docker/dsh-alpha",
               "production": "0.1.3-alpha.2", "candidate": "0.1.5-alpha.2" },
    "rc":    { "port": 3083, "container": "dsh-rc", "project": "dsh-rc",
               "dataDir": "/volume1/docker/dsh-rc",
               "production": "0.1.2-rc.1", "candidate": "0.1.2-rc.1" }
  },
  "updatedAt": "…", "source": "manual",
  "requiredPlugins": ["…"], "optionalPlugins": ["…"], "pluginCompat": {}, "pluginState": {}
}
```

- 兼容：旧格式（顶层 `version`/`productionChannel`/`testCandidate`）会被 `parseSSOT` 归一化为单通道，
  且顶层字段恒等于 primary 通道（旧脚本无需改动）。
- Renovate `regexManagers` 只匹配 `channels.alpha.candidate`；`production` 仅由 promote 提升。
- `scripts/safe-deploy-policy.js`：通道识别（stable>rc>beta>alpha）、风险分级（LOW/MEDIUM/HIGH/BLOCKED）、
  迁移检测（notes 关键词 → forward-only/unknown → BLOCKED）、插件分级（REQUIRED 才 BLOCK）。

## 3. 升级流（每通道独立）

```
Renovate 更新 channels.alpha.candidate → commit/PR
        ↓
CI（矩阵：alpha / rc）解析该通道构建目标（通道内最高且可 npm 安装）
  → 若目标版本已存在于 GHCR tag 列表 → 跳过（收敛）
  → docker build（STRICT 补丁 marker 校验）→ 冒烟 → push <version>-<sha> / <version>
        ↓
dsh-safe-deploy check   --channel alpha   （风险/通道/迁移评估）
dsh-safe-deploy test    --channel alpha   （snapshot → TEST_DSH_HOME + 独立端口容器 + smoke；flock）
        ↓
dsh-safe-deploy promote --channel alpha   （门禁：test PASS + 非 BLOCKED；HIGH 需 --force；落盘 pin+digest）
        ↓
dsh-safe-deploy rollback --channel alpha  （恢复 OLD_IMAGE + snapshot + env；幂等；flock）
```

## 4. 风险规则

- **LOW**：同核心线同通道（0.1.1-rc.2 → 0.1.1-rc.3）
- **MEDIUM**：同核心线 prerelease 阶段前进（alpha→beta→rc→stable）
- **HIGH**：跨核心版本线（0.1.1-* → 0.1.2-*）
- **BLOCKED**：版本非法 / 无候选 / migration forward-only|unknown / REQUIRED 插件 FAIL

## 5. Watchtower 政策

- DSH：`com.centurylinklabs.watchtower.enable=false` → 只允许 CI → test → promote。
- 其他容器：不受影响。
- `latest` 仅 stable 通道使用，**不是**自动更新指针、**不是**回滚依据。

## 6. 使用

```bash
# 只读评估（默认 primary 通道）
scripts/dsh-safe-deploy check
scripts/dsh-safe-deploy status --channel all
# 隔离测试（需宿主 docker；snapshot → 独立 TEST_DSH_HOME + 随机端口容器 + smoke）
scripts/dsh-safe-deploy test --channel alpha
# 门禁 promote（HIGH 需 --force；记录 old/new image digest + 更新对应通道 production + 落盘 pin）
scripts/dsh-safe-deploy promote --channel alpha [--force]
# 回滚（恢复最近 snapshot + 旧镜像 + env；幂等）
scripts/dsh-safe-deploy rollback --channel alpha
# 测试
node scripts/test-dual-channel.js && node scripts/test-version-policy.js
bash scripts/test-dsh-safe-deploy.sh && bash scripts/test-nas-deploy.sh
```

## 7. 已知限制 / 待办

- `dsh-safe-deploy test/promote/rollback` 需在 NAS 宿主执行（或容器挂载 docker.sock 后）。
- docker-rollout：宿主安装 `wowu/docker-rollout` 后自动启用；未安装时回退 Compose `up -d --force-recreate --wait`。
- 保留策略：不自动 prune；保留各通道 production/rollback/test 镜像与最近 snapshot。
- **核显直通是可选 profile**：无 `/dev/dri` 的宿主不再因 `devices:` 硬要求而 `up` 失败。
- **docker.sock 仍是宿主 root 等同面**：建议改用 docker-socket-proxy 或彻底移除；至少应把 3081/3083 收窄到内网并加认证反代。
- `stable` 通道目前只有策略与端口预留，未部署。

## 8. Isolated Test 实测状态（2026-09-01，历史）

候选镜像已构建并推送（prerelease 门控实证：latest 未动，生产安全）：

```text
TEST_CANDIDATE     0.1.2-alpha.3
IMAGE_TAG          ghcr.io/llzg/dsh-docker:0.1.2-alpha.3
IMMUTABLE_TAG      ghcr.io/llzg/dsh-docker:0.1.2-alpha.3-e478cdf21a08fdc2b7e26467672728546b53371d
```

## 9. 连接传输指标命名（canonical）

- `SESSION_TRANSPORT_RECOVERY`（canonical；替代旧 `WEBSOCKET_RECONNECT`）
  含义：会话连接丢失后，客户端指数退避重连 + cookie 会话认证（HttpOnly）下无需重新认证。
- 旧字段 `WEBSOCKET_RECONNECT` 仅作兼容别名保留。

## 10. 插件兼容性策略（REQUIRED 才 BLOCK，OPTIONAL/UNUSED 仅告警）

- **REQUIRED_PLUGIN**：实际启用/生产必需。FAIL → **BLOCK promote**。
- **OPTIONAL_PLUGIN**：已安装/已配置但未启用。FAIL → 告警（`pluginWarnings`），不 BLOCK。
- **UNUSED_PLUGIN**：未安装/无配置。不参与评估。

当前 REQUIRED_RUNTIME_DEPENDENCIES：`@deepseek-ai/dsh-base, @deepseek-ai/dsh-web-app, @deepseek-ai/dsh-subagent-codex`。

## 11. SiliconFlow Inactive（active bundle set 排除）

- 已从 `profiles/web/package.json` 的 `dsh.profile.bundles` 移除（不 autoload）；
  `dependencies` / `settings.yaml` / `.credentials.yaml` 保留。
- SSOT `pluginState.siliconflow = { classification: OPTIONAL, enabled: false, compatibility: FAIL }`。
- **重新启用路径**：上游修复 CallId → compatibility gate PASS → `enabled=true` → 恢复 bundles 条目。
