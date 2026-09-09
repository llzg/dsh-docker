# dsh-docker 接入 homelab CI/CD（2026-09-09 校准）

> 依据：《CI/CD 驱动信息手册（2026-09-05 校准）》+ 本次从 fnOS VM（192.168.5.27）实测核对。
> 目标：让 dsh-docker 的构建/发布跑在你的自建设施上（自建 runner / 代理 / 私有 registry），
> 同时**不破坏**没有这些设施时的默认行为。

---

## 0. 实况核对：手册与线上有 1 处关键偏差

| 手册 | 实测（2026-09-09） | 判定 |
|---|---|---|
| UGREEN DXP6800 Pro = `192.168.5.16`（runner/Woodpecker/BuildKit/生产） | `.16` **全部端口不通，ARP `INCOMPLETE`**（二层无应答） | ❌ **地址已变** |
| Woodpecker API `192.168.5.16:8010` | `192.168.5.17:8010` **开放**（同一台还开着 UGOS `9999`、dsh `3081/3082/3083`） | ✅ 实为 `.17` |
| Synology `192.168.5.35`：3000/5050/5051/22 | 3000 Gitea `1.22.6`、5050（Basic realm `Registry-Private`，401）、5051（匿名 200）、22 均开放 | ✅ 一致 |
| 代理 `192.168.5.36:7893` | 开放；`curl -x` 访问 npm 返回 200 | ✅ 一致 |
| Woodpecker `/api/repos/4/pipelines` | 401（需 Bearer） | ✅ 需 token |
| `invoice-agent-ui` / `homelab-ci` | GitHub 上 **404（私有）**，外部读不到 trigger.yml / releasectl | ⚠️ 无法照抄 |

**结论：UGREEN 当前 IP 是 `192.168.5.17`。** dsh 的生产容器（`dsh-alpha` 3081 / `dsh-rc` 3083 / 版本页 3082）也在这台。
`nas/docker-compose.yml` 与 `Dockerfile` 里的 `DSH_TRUSTED_HOST` 默认值已按 `.17` 设置（可用环境变量覆盖）。
如果你的 UGOS 会回到 `.16`，请改 SSOT/`.env` 里的 `DSH_TRUSTED_HOST`，并把本节表格同步更新。

## 1. ⚠️ 凭据安全（请尽快处理）

手册里 `registry 认证: ci-deploy / <明文密码>` 是**明文贴出**的——按手册自己的规则（"报告中输出凭据时一律脱敏"）这条应视为**已泄露**：

1. 轮换该 htpasswd 密码（`htpasswd -B` 重写 `registry-private` 的认证文件，滚动更新两端）；
2. 只把新凭据放进 GitHub **Secrets**（`DSH_REGISTRY_USER` / `DSH_REGISTRY_PASSWORD`）与 `/opt/homelab-ci/secrets/`；
3. 本次工作**全程没有使用该密码**，也没有把它写进任何文件。

## 2. dsh-docker 现在怎么接（全部是"不设就保持原样"的开关）

在 GitHub 仓库 `llzg/dsh-docker` → Settings → **Variables** / **Secrets** 里配置：

| 类型 | 名称 | 示例值 | 作用 |
|---|---|---|---|
| Variables | `DSH_RUNNER` | `["self-hosted","linux","x64"]` | 用 UGREEN 上的 self-hosted runner 构建（BuildKit 在那台）。不设 = `ubuntu-latest` |
| Variables | `DSH_HTTP_PROXY` | `http://192.168.5.36:7893` | 出网走 OpenClash（只对自建 runner 有意义；GitHub 托管 runner 到不了内网代理） |
| Variables | `DSH_PRIVATE_IMAGE` | `192.168.5.35:5050/llzg/dsh-docker` | 额外把镜像推到内网私有 registry（一次构建双推 GHCR + 私有） |
| Variables | `DSH_REGISTRIES` | `ghcr.io/llzg/dsh-docker,192.168.5.35:5050/llzg/dsh-docker` | **收敛判定**与**版本页构建状态**查询哪些 registry |
| Secrets | `DSH_REGISTRY_USER` / `DSH_REGISTRY_PASSWORD` | `ci-deploy` / `<新密码>` | 私有 registry 认证（Basic） |

行为细节：
- `DSH_RUNNER` 不设时三个 job 都跑 GitHub 托管 runner；设了就用自建（runner 离线时 job 会排队，不会失败）。
- 代理通过 workflow 级 `HTTP_PROXY/HTTPS_PROXY/NO_PROXY` 注入，BuildKit 会自动把它作为构建期代理参数传给 `apt-get`/`npm`（`NO_PROXY` 已含内网段，registry/Gitea 不走代理）。
- 私有 registry 若是 **http（无 TLS）**，runner 的 daemon 需配 `insecure-registries`（见下节）。
- 收敛判定现在查**多个** registry，并额外读仓库里的 `build-status.json`（CI 回写的成功构建记录）作为兜底：
  所有 registry 都不可达且没有记录时，**宁可跳过构建也不盲目重建**（这正是之前"每 30 分钟重建一次"的成因）。
- 版本页（3082）的"构建状态"同样走这套 registry 客户端：GHCR 匿名可读；私有 registry 需给容器
  `DSH_REGISTRY_USER/PASSWORD`（或在容器内挂 docker config.json），否则该项显示"查询失败"，页面其余部分不受影响。

## 3. NAS 侧从私有 registry 拉取（可选）

```sh
# 1) 宿主允许 http registry（若用 192.168.5.35:5050 这种无 TLS 的地址）
sudo vi /etc/docker/daemon.json
#   { "insecure-registries": ["192.168.5.35:5050"] }
sudo systemctl restart docker

# 2) 一次性登录（凭据只在宿主，不进版本库）
docker login 192.168.5.35:5050 -u ci-deploy

# 3) 每通道指定镜像基址（SSOT/.env，不要写进 compose 文件）
DSH_IMAGE_BASE=192.168.5.35:5050/llzg/dsh-docker
```

`nas/lib.sh` 的 registry 访问已泛化（GHCR 匿名 token 流 / 内网 Basic Auth / https→http 探测），
`prev_version`、回滚候选、`install.sh` 预拉取都会自动适配新的 `DSH_IMAGE_BASE`。

## 4. 与 Woodpecker / releasectl 的关系（**待你确认**）

现在 dsh-docker 的"发布"由 **NAS 侧 `dsh-safe-deploy`** 负责：
`check`（风险/迁移/插件策略）→ `test`（snapshot + 隔离实例 + 冒烟）→ `promote`（门禁 + 事务化 pin + 更新 SSOT）→ `rollback`。
**没有**走 Woodpecker verify + `releasectl` deployment 这条链。

两条路线：

**(a) 保持现状（推荐先用）**：GitHub Actions 负责"构建 + 发布镜像"（自建 runner + 双推 registry），
NAS 侧负责"测试 + 门禁上线 + 回滚"。dsh 的数据（会话/凭据/附件）与 app 形态跟 invoice-agent 差别大，
dsh-safe-deploy 的 snapshot/隔离测试是围绕它定制的。

**(b) 接入 homelab 发布链**：`GitHub push → trigger.yml(自建 runner) → Gitea mirror → Woodpecker verify → approve → deployment(releasectl)`。
要落地需要你提供（外部读不到，两个仓库都是私有的）：
1. `invoice-agent-ui/.github/workflows/trigger.yml` 的模板（尤其 self-hosted runner 的 **labels**）；
2. dsh-docker 对应的 **Woodpecker repo id**（invoice-agent 是 `4`）与 Gitea mirror 仓库是否要建；
3. `releasectl` 对 dsh 的支持方式：直接复用（deploy 单元如何描述 compose/健康检查），还是写一个 dsh 专用的 deployment pipeline；
4. dsh 的"migration-before-app"对应物（dsh 的 forward-only 迁移检测现在在 `safe-deploy-policy.js` 里）。

## 5. 建议同步更新的手册条目

| 条目 | 现在应写成 |
|---|---|
| §1 UGREEN IP | `192.168.5.17`（或说明 `.16` 会恢复） |
| §2 registry 认证 | 移除明文密码，改为"见 `DSH_REGISTRY_PASSWORD` secret / htpasswd 文件" |
| §7 Woodpecker API | `http://192.168.5.17:8010` |
| §5 发布链 | 注明 dsh 走 NAS 侧 `dsh-safe-deploy`，不经过 releasectl（除非按 §4(b) 接入） |
