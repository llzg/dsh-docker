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
| Variables | `DSH_HTTP_PROXY` | `http://192.168.5.36:7893` | 出网走 OpenClash（自建 runner 才有意义）。**同时被当作 build-arg 传进构建**，见下方"构建期代理" |
| Variables | `DSH_PRIVATE_IMAGE` | `192.168.5.35:5050/llzg/dsh-docker` | 额外把镜像推到内网私有 registry（一次构建双推 GHCR + 私有） |
| Variables | `DSH_PUSH_GHCR` | `1`（设 `0` 关闭） | 是否把镜像 tag 推到 ghcr.io。`0` = 只推内网 registry（省每通道 ~40-90s 公网推送）。**只影响镜像，不影响源码推送** |
| Variables | `DSH_REGISTRIES` | `ghcr.io/llzg/dsh-docker,192.168.5.35:5050/llzg/dsh-docker` | **收敛判定**与**版本页构建状态**查询哪些 registry |
| Secrets | `DSH_REGISTRY_USER` / `DSH_REGISTRY_PASSWORD` | `ci-deploy` / `<新密码>` | 私有 registry 认证（Basic） |

行为细节：
- `DSH_RUNNER` 不设时三个 job 都跑 GitHub 托管 runner；设了就用自建（runner 离线时 job 会排队，不会失败）。
- **源码推送与镜像推送是两条独立链路**：源码走你自己的 `git push`（`record-status` 用 `GITHUB_TOKEN` 回写 `build-status.json`），
  与 `DSH_PUSH_GHCR` / registry 凭据完全无关；那两者只管镜像 tag 推到哪儿。
- 私有 registry 若是 **http（无 TLS）**，runner 的 daemon 需配 `insecure-registries`（见下节）。
- 收敛判定现在查**多个** registry，并额外读仓库里的 `build-status.json`（CI 回写的成功构建记录）作为兜底：
  所有 registry 都不可达且没有记录时，**宁可跳过构建也不盲目重建**（这正是之前"每 30 分钟重建一次"的成因）。
- 版本页（3082）的"构建状态"同样走这套 registry 客户端：GHCR 匿名可读；私有 registry 需给容器
  `DSH_REGISTRY_USER/PASSWORD`（或在容器内挂 docker config.json），否则该项显示"查询失败"，页面其余部分不受影响。

### 构建期代理（2026-09-10 修正）

**workflow 级的 `HTTP_PROXY` 只作用于 runner 自己的步骤（checkout / API / curl），不会进到 BuildKit 的
`RUN` 里。** 构建容器用哪个代理由 **build-arg** 决定（`docker buildx` 不读客户端 env 当代理）。

因此 workflow 的构建步骤显式传了这三个预定义代理 ARG：

```yaml
HTTP_PROXY=${{ vars.DSH_HTTP_PROXY }}
HTTPS_PROXY=${{ vars.DSH_HTTP_PROXY }}
NO_PROXY=localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,.local
```

宿主实测（2026-09-10，UGREEN 192.168.5.17）：

| 目标 | 直连 | 走代理 192.168.5.36:7893 |
|---|---|---|
| github.com release 下载 | **卡死（25s 超时、0 字节）** | 0.69s |
| apt 下载（同样 100 秒窗口） | 7 个包 / 9 MB | **111 个包 / 146 MB（34 MB/s，整个包集下完）** |
| registry.npmjs.org | 1.65 MB/s | 1.87 MB/s |

结论：**apt / npm / uv 全部走代理**，`NO_PROXY` 只保留内网段（私有 registry、Gitea、NAS 不走代理）。
教训：曾有一次单点采样显示 "deb.debian.org 直连 34MB/s"，据此把 apt 排除在代理之外，结果真实 apt
工作量下直连只有 **0.09 MB/s**，apt 层实测卡了 **911 秒**。单次 curl 采样不足以判断 —— 要用真实工作量对比。

预定义代理 ARG 由 BuildKit 自动识别，Dockerfile 里**不需要** `ARG HTTP_PROXY`；
实测它们**不会**残留在镜像 `Config.Env`（运行时容器环境干净，不会把生产容器也带去走代理）。

### 层缓存顺序契约（别把版本相关的东西写在前面）

BuildKit 的层缓存键 = 该指令**展开后**的字符串。两条实测规则（受控实验验证）：

1. `LABEL/ENV` 里引用 `${DSH_VERSION}` / `${DSH_CHANNEL}` / `${GIT_REVISION}` → **从那一行往后的所有层**
   都会随版本/通道/commit 变化整体失效（包括 135s 的 `npm install`、165s 的 uv 下载）。
2. **易变 ARG 的"声明"也要靠后。** 受控实验（最小 Dockerfile：`FROM alpine` + `ARG X` + 两条 `RUN echo`，
   `X` 在 Dockerfile 里完全没被引用）显示：只改 `--build-arg X=` 的值，两条 RUN 就由 `CACHED` 变 `DONE`。
   而声明在 `FROM` **之前**的全局 ARG 改值**不影响**层缓存。
   （注：这条在真实 Dockerfile 上的表现与 BuildKit 版本/具体指令有关，我们线上曾观察到 apt 层在
   通道间仍能命中；因为"把声明放后"零成本，一律按最保守的方式排。）

2026-09-10 实测事故：`DSH_VERSION/DSH_CHANNEL/GIT_REVISION` 三个 ARG 与 `LABEL version/revision/channel`
原先都摆在 `apt` 之前，于是
- 每个 `git push`（`GIT_REVISION` 变）→ apt + npm + uv 三层全部重跑；
- alpha 与 rc 版本号不同 → 两通道之间也永远互相破缓存；
- rc 通道重建时重下 150MB+ apt 包，实测**卡在 apt 层 24 分钟**；单通道构建 331s。

现在固化为：**稳定层在前，版本/commit 相关层在后；易变 ARG 的声明也必须靠后**

```
ARG DSH_VERSION/DSH_CHANNEL   ← 全局（FROM 之前）：仅供 FROM 用默认值，不影响层缓存
FROM node:22-bookworm-slim
  apt 工具链            ← 稳定：跨通道、跨 commit 复用
  ARG UV_VERSION=0.8.15 + uv   ← 稳定：常量，紧贴使用处声明
  ──────────── 分界线 ────────────
  ARG DSH_VERSION / DSH_CHANNEL / GIT_REVISION   ← 必须在这里才声明
  npm install dsh@${DSH_VERSION}   ← 版本相关，唯一"换版本才重建"的重层
  corepack (pnpm)
  LABEL version/revision/channel   ← 纯 metadata，放最后：只让它**后面**的廉价层随 commit 失效
  ENV / COPY / patch / 校验 / HEALTHCHECK
```

`scripts/test-dockerfile-layers.sh`（已进 `test-all.sh`）会断言这个顺序：把易变 ARG/引用写在
apt/uv/npm 之前会**直接测试失败**。

#### 修复前后实测对比（同一台 UGREEN、同一个 builder、docker driver）

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 单通道首次构建（apt/uv/npm 全重建） | 331s（apt 直连 18.9s + npm 135s + uv 165s） | 301s（apt 281.7s + uv 6.6s + npm 5.2s） |
| 第二个通道（换版本） | **卡 24 分钟**（apt 重下 150MB+，最终取消） | **16s**（apt/uv 命中缓存，只重建 npm 6.8s + corepack 2.9s） |
| 同版本、新 commit（每次 push 的常态） | 331s（GIT_REVISION 变 → 三层全废） | **2s**（apt/uv/npm/corepack 全部 CACHED，只有廉价尾部层重建） |
| 换 dsh 版本（版本号变） | 同上 331s+ | ~15s 级（只有 npm 层重建，且 tarball 走 `/root/.npm` 缓存挂载） |

- 瓶颈从"网络下载"变成了"只有换版本才付一次 npm 代价"；apt/uv 只在 Dockerfile 的对应指令或 base 镜像变化时才重建。
- 冷启动里 apt 那 281.7s 是走代理后的数字（走代理前实测 911s）；这一层现在**跨通道、跨 commit 共享**，付一次即可。
- 因此"预烤 base 镜像"的方案收益已经很小（它省下的正是这块现在只付一次的 apt/uv），可以先不做。



## 3. NAS 侧从私有 registry 拉取（可选）

### 3.0 部署侧切到内网 registry（2026-09-10 已落地）

宿主 UGREEN 上的生产栈现在**全部从 `192.168.5.35:5050/llzg/dsh-docker` 拉取**（GHCR 仍双推，作为异地备份）。

- **部署配置**：`/volume1/docker/dsh-deploy/.env`（只放白名单键；`dsh-safe-deploy` 会读它）：

  ```sh
  DSH_IMAGE_BASE=192.168.5.35:5050/llzg/dsh-docker
  DSH_REGISTRIES=ghcr.io/llzg/dsh-docker,192.168.5.35:5050/llzg/dsh-docker
  DSH_REGISTRY_USER=ci-deploy
  DSH_REGISTRY_PASSWORD=***
  ```

  `dsh-safe-deploy` 只解析**白名单键**（`DSH_IMAGE_BASE` / `DSH_REGISTRIES` / `DSH_REGISTRY_*`），
  不做整文件 `source` —— 避免 `.env` 里混进 `PATH`/`DSH_HOME` 之类的变量静默改变部署行为。
  已有同名环境变量时以环境变量为准（命令行显式指定优先）。

- **⚠ CI 不能登出私有 registry**：`docker/login-action` 默认在 post 步骤 `docker logout`，
  会把该 registry 的条目从**宿主** `~/.docker/config.json` 删掉 → 之后生产 `docker pull`
  报 `no basic auth credentials`（这正是 2026-09-10 反复出现、且"手工 login 后过一会儿又失效"
  的原因）。workflow 里该步已加 `logout: false`；GHCR 的登录仍在 post 步骤登出。

- **版本页同时展示两个 registry 的构建状态**：给 `dsh-version` 容器传
  `DSH_REGISTRIES` + `DSH_REGISTRY_USER/PASSWORD`。注意全局凭据会被一起发给 ghcr.io → 403，
  所以 `scripts/registry.js` 现在**带凭据失败时匿名回退重试**（ghcr 公开包匿名可读，
  内网 registry 用凭据），两边的 tag 列表都能正常列出。

- **⚠ 宿主网络容器会抢版本页端口**：`dsh-proxy`/`dsh-proxy-rc` 用 `network_mode: host`，
  若它们的 `DSH_VERSION_PORT` 不是 `0`，entrypoint 会在**宿主机**上另起一个镜像内置的
  版本页（旧代码），把 3082 占掉 → 真正的 `dsh-version` 绑不上 3082 而反复重启
  （现象：页面显示的是旧版单通道页面）。现在两个 proxy 容器都显式设 `DSH_VERSION_PORT=0`。

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
