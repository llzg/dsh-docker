# DSH Safe Upgrade Architecture（成熟轮子优先 + 自定义安全层）

> 日期：2026-09-01 · 适用：llzg/dsh-docker（DeepSeek Harness Docker 部署）

## 1. 职责边界（每项唯一 authority）

| 职责 | 组件 | 说明 |
|---|---|---|
| 版本发现 / SemVer / prerelease 策略 | **Renovate**（`renovate.json` + `dsh-version.json` SSOT） | Renovate 只更新 SSOT 的 `testCandidate`；不做生产 promote |
| 构建 immutable image | **现有 CI**（`.github/workflows/build-publish.yml`） | 按 SSOT/显式版本构建；tag=`<version>-<sha7>`（immutable）+ `<version>` + `latest`（别名，非回滚依据） |
| 容器级 rollout | **docker-rollout**（可用时）或 Compose + health gate | 只负责 container 切换；不可用自动回退 |
| DSH 特有数据安全 | **`scripts/dsh-safe-deploy`**（薄层） | snapshot / data isolation / 风险分级 / 门禁 promote / rollback；flock 互斥 |
| 镜像自动替换 | **已禁用** | DSH 退出 Watchtower（label `com.centurylinklabs.watchtower.enable=false`）；watchtower 已归档（2025-12），可保留给无状态容器 |

## 2. 版本 SSOT：`dsh-version.json`

```json
{
  "version": "0.1.1-rc.2",          // 当前生产运行版本（promote 时更新）
  "productionChannel": "0.1.1-rc.2", // 生产通道（仅 promote 提升）
  "testCandidate": "0.1.2-alpha.3",  // 测试候选（Renovate 更新）
  "source": "manual", "updatedAt": "..."
}
```

- Renovate `regexManagers` 只匹配 `testCandidate` → **alpha/beta/rc 更新只进候选，绝不自动 promote**。
- `scripts/safe-deploy-policy.js`：通道识别（stable>rc>beta>alpha）、风险分级（LOW/MEDIUM/HIGH/BLOCKED）、迁移检测（release notes 关键词 → forward-only/unknown → BLOCKED）。
- `scripts/version-server.js`（3082 版本页）展示：当前运行 / 生产通道 / 测试候选 / 候选通道 / 升级风险 / 迁移状态 / 隔离测试要求 / 测试状态 / 回滚就绪。

## 3. 升级流

```
Renovate 发现上游版本 → 更新 dsh-version.json testCandidate → commit/PR
        ↓
CI 按 SSOT 构建 immutable image（<version>-<sha7>）
        ↓
dsh-safe-deploy check   （风险/通道/迁移评估）
dsh-safe-deploy test    （snapshot DSH_HOME → TEST_DSH_HOME + 独立端口容器 + smoke；flock）
        ↓
dsh-safe-deploy promote （门禁：test PASS + 非 BLOCKED；prerelease 需显式 --force；docker-rollout/compose）
        ↓
dsh-safe-deploy rollback（恢复 OLD_IMAGE + snapshot + env；幂等；flock）
```

## 4. 风险规则

- **LOW**：同核心线同通道 patch（0.1.1-rc.2 → 0.1.1-rc.3）
- **MEDIUM**：同核心线 prerelease 阶段前进（alpha→beta→rc→stable）
- **HIGH**：跨核心版本线（0.1.1-* → 0.1.2-*）
- **BLOCKED**：snapshot 失败 / migration forward-only|unknown / 版本非法 / 无 rollback 镜像

## 5. Watchtower 政策

- DSH：`com.centurylinklabs.watchtower.enable=false`（本 compose 已加）→ 只允许 Renovate→CI→test→promote。
- 其他容器：不受影响。
- 注：Watchtower 上游已归档（discussion #2135），长期应迁移其替代品（Renovate/CI 已覆盖 DSH；其他容器可评估自建 cron pull + digest 对比）。

## 6. 使用

```bash
# 只读评估
scripts/dsh-safe-deploy check
scripts/dsh-safe-deploy status
# 隔离测试（需宿主 docker；snapshot → 独立 TEST_DSH_HOME + 随机端口容器 + smoke）
scripts/dsh-safe-deploy test
# 门禁 promote（prerelease 需 --force；记录 old/new image digest + 更新 SSOT）
scripts/dsh-safe-deploy promote [--force]
# 回滚（恢复最近 snapshot + 旧镜像；幂等）
scripts/dsh-safe-deploy rollback
# 测试
bash scripts/test-dsh-safe-deploy.sh && node scripts/test-version-policy.js
```

## 7. 已知限制 / 待办

- `dsh-safe-deploy test/promote/rollback` 需在 NAS 宿主执行（或容器重建挂载 docker.sock 后）。
- Renovate：GitHub App 安装后自动接管 `testCandidate` 更新；安装前 SSOT 由 `scripts/check-new-version.js` 的多源检测人工确认后手动更新。
- docker-rollout：宿主安装 `wowu/docker-rollout` 插件后自动启用；未安装时回退 Compose `up -d --force-recreate` + health gate。
- 保留策略：不自动 prune；保留 production/rollback/test 镜像与最近 snapshot（`/data/dsh/backups/<version>-<ts>`）。

## 8. Isolated Test 实测状态（2026-09-01）

候选镜像已构建并推送（prerelease 门控实证：latest 未动，生产安全）：

```text
TEST_CANDIDATE     0.1.2-alpha.3
IMAGE_TAG          ghcr.io/llzg/dsh-docker:0.1.2-alpha.3
IMMUTABLE_TAG      ghcr.io/llzg/dsh-docker:0.1.2-alpha.3-e478cdf21a08fdc2b7e26467672728546b53371d
DIGEST             sha256:f7112e0b3158eb291d158cbb5b4d171e9fe315779b99796fa649f7da0d53386e
PRODUCTION_LATEST  sha256:67fc4c76...（未变 = 0.1.1-rc.2，prerelease 门控生效）
```

宿主执行隔离测试（容器挂载 docker.sock 后，或直接 NAS 宿主）：

```bash
# 1) 只读评估
scripts/dsh-safe-deploy check
# 2) 隔离测试：snapshot → /data/dsh/test/0.1.2-alpha.3（独立端口容器 + smoke）
scripts/dsh-safe-deploy test
# 3) 通过后如需 promote（alpha 为 HIGH 风险，需显式 --force）
scripts/dsh-safe-deploy promote --force
# 4) 回滚
scripts/dsh-safe-deploy rollback
```

0.1.2-alpha.3 注意：dsh web 默认启用 token 认证（URL 带 ?token=，base64url 含 -/_）；
smoke 已适配；promote 前需决策认证策略（LAN trusted-host 是否保持认证）。

## 9. 连接传输指标命名（canonical）

DSH 连接载体随版本可能变化（实测 alpha.3 用 HTTP fetch RPC/streaming，非传统 WebSocket）。
指标命名使用 transport 中性的 canonical 字段，避免锁死实现：

- `SESSION_TRANSPORT_RECOVERY`（canonical；替代旧 `WEBSOCKET_RECONNECT`）
  含义：会话连接丢失后，客户端指数退避重连 + cookie 会话认证（HttpOnly）下无需重新认证。
- 旧字段 `WEBSOCKET_RECONNECT` 仅作兼容别名保留，新报告一律使用 `SESSION_TRANSPORT_RECOVERY`。

## 10. 插件兼容性策略（REQUIRED 才 BLOCK，OPTIONAL/UNUSED 仅告警）

插件分三类（SSOT `requiredPlugins` / `optionalPlugins` 声明；其余 = UNUSED）：

- **REQUIRED_PLUGIN**：实际启用/生产必需（内置 bundle + 已启用子代理）。其 compatibility FAIL → **BLOCK promote**。
- **OPTIONAL_PLUGIN**：已安装/已配置但未启用或非默认使用。其 FAIL → **告警（pluginWarnings），不 BLOCK**。
- **UNUSED_PLUGIN**：未安装/无配置。不参与评估。

当前 REQUIRED_RUNTIME_DEPENDENCIES（生产实际使用，2026-09-01 确认）：
`@deepseek-ai/dsh-base, @deepseek-ai/dsh-web-app, @deepseek-ai/dsh-subagent-codex`
（claude-code 子代理 preset 中 disabled → OPTIONAL；siliconflow 默认模型为 deepseek-official、非默认使用 → OPTIONAL）

兼容性记录（保留，不删除）：
- `@siliconflow-official/dsh-llm-siliconflow@0.2.0-rc.1` 与 DSH 0.1.2-alpha.3 的 `@deepseek-ai/dsh-llm` **CallId 导出不兼容**（上游 main 分支亦未修复）。
- 归类 OPTIONAL、`SILICONFLOW_BLOCKING=NO`：**不阻塞 alpha.3 promote**。
- **重新启用 SiliconFlow 前必须重新执行 compatibility gate**（更新 SSOT pluginCompat + 重跑 check）。

promote verdict 规则：`otherBlockers`（版本级 BLOCKED + REQUIRED 插件 FAIL）为空 → 不 BLOCK；
LAN_ACCESS / MOBILE_VPN 未人工验证前 → `TEST_ONLY`；两项 PASS 且 docker isolated test / rollback gate 正常 → `PROMOTE_OK`。

## 11. SiliconFlow Inactive（active bundle set 排除，2026-09-01）

- **AUTOLOAD_TRIGGER**：`profiles/web/package.json` 的 `dsh.profile.bundles` 列表条目（loader 按 bundles import）。
- **最小修改**：从 `dsh.profile.bundles` 移除 `@siliconflow-official/dsh-llm-siliconflow`（active set 不含）；
  `dependencies` / `settings.yaml`（llm-siliconflow）/ `.credentials.yaml`（SILICONFLOW_API_KEY）全部保留。
  生产 manifest 备份：`/data/dsh/profiles/web/package.json.bak-sf-inactive-20260901-131516`。
- **SSOT 状态**：`pluginState.siliconflow = { classification: OPTIONAL, enabled: false, compatibility: FAIL }`。
- **验证（production-equivalent alpha.3）**：bundles 无 sf + 包物理存在 → 启动 PASS、plugin tree 无 siliconflow、
  CallId error 消失、DeepSeek smoke PASS、Codex smoke PASS、old/new session、restart cookie 持久 PASS。
- **重新启用路径**：上游修复 CallId → compatibility gate PASS → `enabled=true` → 恢复 bundles 条目（credential/settings 无需重建）。
- **policy**：OPTIONAL_INACTIVE + FAIL → WARN 不 BLOCK；OPTIONAL_ACTIVE/REQUIRED + FAIL → BLOCK。
