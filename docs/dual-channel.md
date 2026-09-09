# 双通道（alpha / rc）架构与契约

> 目标：在**同一套 CI + 同一套 NAS 部署资产**下，并行维护两条 DSH 版本线——
> `alpha`（宿主端口 3081）与 `rc`（宿主端口 3083）——各自独立的 SSOT 通道、构建目标、
> 隔离测试、promote 与回滚，互不干扰。
>
> 本文是实现的**唯一契约**：所有脚本/服务都必须按此命名与语义实现，不得各自发明字段。

---

## 1. 为什么需要改

现状（`fd8b3a7`）是**单通道**模型，无法表达双通道：

| 组件 | 现状 | 问题 |
|---|---|---|
| `dsh-version.json` | 一个 `productionChannel` + 一个 `testCandidate` | 只能描述一条线 |
| `version-policy.js:computeTarget` | 跨全部来源取**唯一最高**版本 | rc 线永远不会被自动构建（恒被 alpha 线压过） |
| `version-server.js` | 单套通道字段 | 无法回答"3083 那条线该不该升" |
| `build-publish.yml` | 单次构建单版本；收敛判定用 GHCR `latest` label | 每 30 分钟重建同一版本；且 prerelease 永不打 `latest` → 永不收敛 |

---

## 2. 通道定义

| 通道 | 版本段 | 宿主端口 | 容器名 | compose 项目名 | 数据目录（宿主） |
|---|---|---|---|---|---|
| `alpha` | `-alpha.N` | 3081 | `dsh-alpha` | `dsh-alpha` | `/volume1/docker/dsh-alpha` |
| `rc` | `-rc.N` | 3083 | `dsh-rc` | `dsh-rc` | `/volume1/docker/dsh-rc` |
| `stable` | 无 prerelease 段 | 3085（预留） | `dsh-stable` | `dsh-stable` | `/volume1/docker/dsh-stable` |

- 通道由**版本的 semver prerelease 段**判定：`0.1.3-alpha.2 → alpha`、`0.1.2-rc.1 → rc`、
  `0.1.2 → stable`。判定函数唯一实现：`scripts/version-policy.js:channelOf()`。
- `stable` 通道本期只保留结构与策略支持，不启用部署（无端口映射）。

---

## 3. SSOT 新 schema（`dsh-version.json`）

```json
{
  "schemaVersion": 2,
  "primaryChannel": "alpha",
  "channels": {
    "alpha": {
      "port": 3081,
      "container": "dsh-alpha",
      "project": "dsh-alpha",
      "dataDir": "/volume1/docker/dsh-alpha",
      "production": "0.1.3-alpha.2",
      "candidate": "0.1.5-alpha.2"
    },
    "rc": {
      "port": 3083,
      "container": "dsh-rc",
      "project": "dsh-rc",
      "dataDir": "/volume1/docker/dsh-rc",
      "production": "0.1.2-rc.1",
      "candidate": "0.1.2-rc.1"
    }
  },
  "updatedAt": "2026-09-09T00:00:00.000Z",
  "source": "manual",
  "requiredPlugins": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-subagent-codex"],
  "optionalPlugins": ["@deepseek-ai/dsh-subagent-claude-code", "@siliconflow-official/dsh-llm-siliconflow"],
  "pluginCompat": { "...": { "status": "FAIL", "reason": "..." } },
  "pluginState": { "...": { "classification": "OPTIONAL", "enabled": false } }
}
```

### 兼容规则（必须实现）

1. **旧格式自动升级**：若文件没有 `channels`，则用旧字段合成单通道：
   `channels[defaultChannel] = { production: version||productionChannel, candidate: testCandidate }`，
   `defaultChannel` 取 `primaryChannel` 或 `"alpha"`。
2. **兼容镜像**：`parseSSOT()` 返回对象上，`version`/`productionChannel`/`testCandidate`
   **恒等于 primaryChannel 的 production/candidate**（运行时计算，不落盘），旧脚本无需改动即可继续工作。
3. 插件相关字段（`requiredPlugins`/`optionalPlugins`/`pluginCompat`/`pluginState`）是**全局**的，
   不随通道变化。

---

## 4. 策略层 API（`scripts/version-policy.js`）

```js
channelOf(version)                       // → 'alpha' | 'rc' | 'beta' | 'stable' | 'unknown'
fetchAllSources()                        // 不变：github/npm 各源独立
computeTargets(sources)                  // → { channels: {alpha:{...}, rc:{...}}, target, newestUpstream, waitingForNpm }
computeChannelTarget(sources, channel)   // → { channel, target, newestUpstream, installable[], candidates[], waitingForNpm }
computeTarget(sources)                   // 兼容：返回 computeTargets().target（跨通道最高可安装版本）
```

- 单通道 target 语义：**该通道内**最高且**真实存在于 npm** 的版本（Dockerfile 走 npm install）。
- `waitingForNpm`：该通道上游最高版本 > 该通道可安装最高版本 时为 `true`。

## 5. 策略层 API（`scripts/safe-deploy-policy.js`）

```js
parseSSOT(file)                    // → 归一化对象（含 channels、primaryChannel、兼容镜像字段）
computeChannel(ssot, name, opts)   // → 单通道策略结果（字段同旧 computeAll，另加 channel/port/container/project）
computeAll({ssotFile, channel})    // 兼容：channel 默认 primaryChannel
computeChannels({ssotFile, notes}) // → { primaryChannel, channels: {alpha:{...}, rc:{...}} }
```

单通道结果字段（保持旧名，新增 4 个）：

```
channel, port, container, project,
currentVersion, productionChannel, testCandidate, targetChannel,
productionChannelChannel, migrationStatus, upgradeRisk, dataIsolationRequired,
candidateIsNewer, ssotSource, ssotUpdatedAt,
requiredRuntimeDependencies, optionalPlugins, pluginCompat, pluginClass,
pluginBlockers, pluginWarnings, otherBlockers, promoteBlocked, siliconflow
```

CLI：
```
node scripts/safe-deploy-policy.js --json [--ssot FILE] [--channel alpha|rc|all] [--notes TEXT]
```

---

## 6. 环境变量契约（容器）

| 变量 | 默认 | 用途 |
|---|---|---|
| `DSH_CHANNEL` | `alpha` | 当前容器所属通道；写入 OCI label 与版本页 |
| `DSH_HOME` | `/data/dsh` | 数据目录（每通道独立卷） |
| `DSH_TRUSTED_HOST` | `192.168.5.17` | `--trusted-host` 取值；**不再硬编码在 Dockerfile CMD** |
| `DSH_VERSION_PORT` | `3082` | 版本页端口；`0` = 不启动版本页（rc 容器默认 0，由 alpha 容器统一渲染两条通道） |
| `DSH_VERSION_SSOT` | 空 | SSOT 文件绝对路径；优先级最高 |
| `DSH_IMAGE` | 无 | compose 使用的镜像（含 tag） |

容器内 SSOT 查找顺序（`version-server.js`）：
`$DSH_VERSION_SSOT` → `/root/nas_docker/dsh-version.json` → `/opt/dsh-version-ssot.json`（镜像内置兜底）。
**版本页必须显示实际命中的文件路径**（`ssotFile`），并标明是否为镜像内置兜底（`ssotIsFallback`）。

---

## 7. 版本页契约（`scripts/version-server.js`，端口 3082）

- 路由：
  - `GET /` → HTML，**每条通道一个区块**
  - `GET /version`、`/version.json` → JSON（含 `channels` map + 兼容顶层字段）
  - 其余路径 → **404**（JSON 请求返回 JSON 错误体）
- 查询参数：
  - `?refresh=1` → **强制刷新**上游来源（绕过 10 分钟缓存），节流：距上次强制刷新 <120s 时忽略并返回 `refreshThrottled: true`（120s 是为守住 GitHub 匿名 60/h 限额）
  - `?channel=alpha|rc` → 只渲染/只返回该通道（HTML 用）
- JSON 新增字段：
  - `channels: { alpha: {...策略字段..., build: {...}}, rc: {...} }`
  - `build`: `{ target, targetBuilt: true|false, builtTags: [...], lastRun: { conclusion, createdAt, url } | null, status: 'ok'|'error', error }`
    - `targetBuilt` 来自 GHCR tag 列表匿名查询（`https://ghcr.io/v2/llzg/dsh-docker/tags/list`）
    - `lastRun` 来自 GitHub Actions API（匿名）：`/repos/llzg/dsh-docker/actions/runs?per_page=1`
  - `cache: { sourcesCheckedAt, sourcesAgeSec, ssotFile, ssotIsFallback }`
- 健壮性（必须）：请求处理全程 try/catch；`uncaughtException`/`unhandledRejection` 只记录不退出；
  冷缓存并发请求做 in-flight 去重；`server.on('error')` 记录。
- 安全头：`X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`、`X-Frame-Options: DENY`。

---

## 8. CI 契约（`.github/workflows/build-publish.yml`）

- **收敛判定改为"该版本是否已存在于 GHCR tag 列表"**，不再依赖 `latest` label：
  - 已存在 `<version>` 或 `<version>-<sha>` → 视为已构建，跳过（`FORCE=1` 时仍重建）。
- **矩阵构建**：`Resolve versions` 输出 `matrix`（每个通道各自的目标版本），
  矩阵按通道并行构建；每条通道独立打 tag：
  - prerelease → `<ver>-<sha>`、`<ver>`（**不打 `latest`**）
  - stable → 追加 `latest`
- **构建状态落盘**：每通道构建结果写入仓库根 `build-status.json`（由 workflow commit 回写），
  供版本页与人工查询；同时镜像内写入 `/opt/dsh-build.json`。
- push 循环 `set -e`，任一 tag 推送失败即失败。
- Action 固定到 commit SHA（供应链）。

---

## 9. NAS 部署契约（`nas/`）

- **每通道一个 compose 项目**，项目名 = `DSH_PROJECT`，容器名 = `DSH_CONTAINER`，
  且**必须显式** `docker compose -p "$PROJECT" --project-directory "$DIR" -f "$DIR/docker-compose.yml"`，
  禁止依赖"当前目录推断项目名"。
- `pin_version()` 事务化：
  1. 写 `$DIR/.env.pending` → 校验（`docker compose config` 能解析、卷源落在 `$DIR` 下、项目名 == 期望）
  2. `mv .env.pending .env`（原子）
  3. `up -d --force-recreate --wait`（或健康轮询，超时视为失败）
  4. 失败 → 还原旧 `.env`、`up` 回旧镜像、非 0 退出
  - `.env` 内写 `DSH_PIN_REASON=manual|auto-rollback`
- `prev_version()`：**semver 比较**（复用 `scripts/version-policy.js` 的 semver），
  排除 `<ver>-<sha>` 不可变标签；**当前版本不在列表时返回错误**（不得回退成"列表最高"）；
  GHCR 不可达时降级为本地镜像标签，并明确告警。
- `watchdog.sh`：新鲜度用**容器启动时间**（`.State.StartedAt`），不是镜像构建时间；
  仅 `DSH_PIN_REASON=manual` 时跳过；`auto-rollback` 残留允许重试。
- 所有写操作加 `flock`（`$STATE/deploy.lock`）。
- 日志：`$STATE/<channel>-{rollback,watchdog}.log`。

---

## 10. 补丁层契约（`patch-dsh.sh`）

每个补丁三类标记，缺一不可：

1. **锚点预检**：锚点既不在、也没有 marker → `VERIFY FAIL: anchor missing`（上游改了）。
2. **应用后写 marker**：在被修改的文件里插入唯一标记，例如
   `// dsh-docker-patch:settings-host-mode`（JS）/ `# dsh-docker-patch:xxx`（YAML）。
3. **STRICT 校验 marker 必须存在**（正向校验），替代旧的"原始模式必须消失"（锚点失配时恒真）。

补丁 #3（privileged-loopback）：上游已自带 `isTrustedApiRequest(request, this.trustedHosts)`
（0.1.5-alpha.* 已核实），此时记 `upstream-satisfied` marker，不再 sed；两者都没有则 FAIL。

---

## 11. 验收标准

一键跑全部：`sh scripts/test-all.sh`

- `node scripts/test-dual-channel.js` 通过（SSOT 归一化 + 每通道策略 + 通道隔离，25 例）
- `node scripts/test-version-server.js` 通过（真实起进程 + HTTP：双通道 / 实时 SSOT / 404 / 安全头 / 刷新节流，16 例）
- `node scripts/test-version-policy.js` 通过（上游来源 + 跨通道目标解析，17 例）
- `bash scripts/test-dsh-safe-deploy.sh` 通过（风险分级/迁移/插件/并发锁/snapshot）
- `bash scripts/test-nas-deploy.sh` 通过（compose 上下文断言 / 事务化 pin / semver 选版 / watchdog 状态机 / 通道化 CLI）
- `node --check` 全部 JS、`sh -n` / `bash -n` 全部脚本
- 版本页在只有 alpha 容器时也能正确显示 rc 通道状态

## 12. 从单通道迁移

见 [dual-channel-migration.md](dual-channel-migration.md)（NAS 操作手册：目录规划、数据迁移、校验清单、常见问题）。
