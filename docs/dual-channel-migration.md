# 从单通道迁移到双通道（NAS 操作手册）

> 目标：把原来"一个 `deepseek-harness` 容器（3081）"的部署，迁移成
> **`dsh-alpha`（3081）+ `dsh-rc`（3083）两条互不干扰的通道**，并让版本页（3082）同时展示两条通道。
>
> 前置阅读：[dual-channel.md](dual-channel.md)（契约）、[safe-upgrade-architecture.md](safe-upgrade-architecture.md)（升级流程）。

---

## 0. 迁移前现状（三种起点，先确认你属于哪种）

**起点 C（2026-09-10 实测的 UGREEN 现状，最复杂）**

| 组件 | 实况 |
|---|---|
| alpha DSH | 容器 `deepseek-harness-alpha`（0.1.3-alpha.2，bridge 172.27.0.4），`DSH_HOME=/data/dsh/test/0.1.2-alpha.5`，数据 `/volume1/docker/dsh-alpha5/` |
| rc DSH | 容器 `dsh-rc1`（0.1.2-rc.1，bridge 172.27.0.5），`DSH_HOME=/data/dsh`，数据 `/volume1/docker/deepseek-harness/` |
| 对外入口 | **不是端口映射**：host 网络的 `dsh-proxy`(3081→172.27.0.4:3080) 与 `dsh-proxy-rc`(3083→172.27.0.5:3080) 反代（含 cookie bootstrap / `ownsHost` 注入 / CIDR 白名单 / WS mux） |
| 版本页 3082 | 旧实现跑在 `dsh-proxy-12079` 容器内（镜像内置 `node /opt/version-server.js`），只读得到 `/opt/dsh-version-ssot.json` 兜底快照 |
| 实时 SSOT | `/volume1/docker/dsh-alpha5/dsh-root/nas_docker/dsh-version.json`（旧单通道格式） |
| 遗留 | `deepseek-harness`（0.1.1-rc.2）容器已 Exited |

> 起点 C 的迁移**分两阶段**（见 §8/§9）：Phase 1 零中断，Phase 2 需要维护窗口。

**起点 A：单容器旧拓扑**

| 项 | 值 |
|---|---|
| 容器 | `deepseek-harness` |
| compose 项目 / 目录 | `deepseek-harness` / `/volume1/docker/deepseek-harness` |
| 数据 | `/volume1/docker/deepseek-harness/dsh-data`（DSH_HOME） |
| workspace | `/volume1/docker/deepseek-harness/dsh-root`（容器内 `/root`，含 `/root/nas_docker`） |
| 端口 | 3081→3080、3082（版本页） |

**起点 B：已经在跑两个容器（例如 alpha 3081 + rc 3083，但 compose/脚本是手写的、未纳入本仓库）**

```sh
# 先看清现状：容器名、项目名、镜像、端口、数据目录
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
docker inspect <容器名> --format '{{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.project.working_dir"}}'
docker inspect <容器名> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```
把结果与下面第 1 节的规划表对齐；**容器名/项目名/数据目录不一致时，要么改 SSOT，要么改容器**——两者必须一致，否则
`nas/lib.sh` 的 `validate_compose_context` 会在 pin 时直接拒绝（这是有意的防线）。

## 1. 规划

| 通道 | 容器/项目 | 宿主端口 | 数据目录 | 版本页 |
|---|---|---|---|---|
| `alpha` | `dsh-alpha` | 3081 | `/volume1/docker/dsh-alpha/dsh-data` | 3082（渲染两条通道） |
| `rc` | `dsh-rc` | 3083 | `/volume1/docker/dsh-rc/dsh-data` | 0（不启动） |

- **alpha 承接原生产数据**（迁移旧 `dsh-data`）。
- **rc 从空数据开始**（或按需从 alpha 的 snapshot 复制一份只读副本）。
- ⚠️ **绝对不要两个容器共享同一份 `DSH_HOME`**：会话、settings、凭据会互相覆盖。

## 2. 安装部署资产（每通道一次，幂等）

```sh
# 把仓库里的 nas/ 放到 NAS 上（示例）
#   git clone https://github.com/llzg/dsh-docker.git /volume1/docker/dsh-deploy-src
#   cp -a /volume1/docker/dsh-deploy-src/nas /volume1/docker/dsh-deploy
#   cp -a /volume1/docker/dsh-deploy-src/dsh-version.json /volume1/docker/dsh-deploy/   # SSOT：脚本要读
cd /volume1/docker/dsh-deploy

DSH_CHANNEL=alpha sh install.sh    # 建目录 + 装 compose/.env + watchdog + 预拉镜像
DSH_CHANNEL=rc    sh install.sh
```

> SSOT 位置：`nas/lib.sh` 默认读 `$DSH_SSOT`，未设置时读**脚本同目录**的 `dsh-version.json`；
> 所以要么按上面把 SSOT 一起放过来，要么显式 `export DSH_SSOT=/path/to/dsh-version.json`。
> 容器内的版本页另有一条查找链：`$DSH_VERSION_SSOT → /root/nas_docker/dsh-version.json → 镜像内置兜底`。

`install.sh` 做的事：`mkdir -p` 通道目录 → **每次覆盖前时间戳备份** → 安装 compose（base + versionpage override）
→ 写通道身份 `.env` → 创建/更新 watchdog 守护容器（宿主同路径挂载）→ 预拉镜像 → compose 上下文自检。

## 3. 迁移 alpha 数据

```sh
# 1) 停旧容器（数据静止，避免边复制边写）
docker stop deepseek-harness

# 2) 复制旧数据到 alpha 通道目录（保留权限/owner/符号链接）
mkdir -p /volume1/docker/dsh-alpha
cp -a /volume1/docker/deepseek-harness/dsh-data /volume1/docker/dsh-alpha/dsh-data
cp -a /volume1/docker/deepseek-harness/dsh-root /volume1/docker/dsh-alpha/dsh-root

# 3) 起 alpha 容器
DSH_CHANNEL=alpha sh switch.sh
```

`dsh-root` 里若含 `/root/nas_docker/dsh-version.json`，版本页会优先读它（实时 SSOT）；
也可以显式设置 `DSH_VERSION_SSOT=/root/nas_docker/dsh-version.json`。

## 4. rc 通道初始化

```sh
# 空数据起步
DSH_CHANNEL=rc sh switch.sh

# 若希望 rc 带一份 alpha 的会话/配置做对照（可选，务必是副本，不要共享）
mkdir -p /volume1/docker/dsh-rc/dsh-data
tar -C /volume1/docker/dsh-alpha/dsh-data -cf - \
    --exclude='profiles/web/node_modules' --exclude='.pnpm-store' --exclude='test' --exclude='backups' . \
  | tar -C /volume1/docker/dsh-rc/dsh-data -xf -
DSH_CHANNEL=rc sh switch.sh
```

## 5. 校验清单

```sh
# 1) 容器健康
docker ps --filter name=dsh-alpha --filter name=dsh-rc --format '{{.Names}} {{.Status}} {{.Ports}}'

# 2) 通道状态（策略层）
scripts/dsh-safe-deploy status --channel all

# 3) 版本页：应显示两条通道，且 SSOT 不是"镜像内置快照"
curl -s http://127.0.0.1:3082/version.json | head -40
#   关注 cache.ssotFile（应为 /root/nas_docker/dsh-version.json 或 $DSH_VERSION_SSOT）
#   关注 cache.ssotIsFallback（应为 false）

# 4) 各通道 UI 可访问
curl -sf -o /dev/null -w 'alpha=%{http_code}\n' http://127.0.0.1:3081/
curl -sf -o /dev/null -w 'rc=%{http_code}\n'    http://127.0.0.1:3083/

# 5) watchdog 守护容器在跑
docker ps --filter name=dsh-watchdog --format '{{.Names}} {{.Status}}'
```

## 6. 收尾

- **旧容器 `deepseek-harness` 先别删**：保留 1 周作为人工回滚副本，确认稳定后再 `docker rm`。
- 确认 DSH 容器已退出 watchtower 自动更新（compose 里 `com.centurylinklabs.watchtower.enable=false`）。
- 首次 `promote` 前，先跑一次隔离测试：`scripts/dsh-safe-deploy test --channel alpha`。

## 7. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 版本页显示"SSOT 命中镜像内置快照" | 容器内既没有 `$DSH_VERSION_SSOT` 也没有 `/root/nas_docker/dsh-version.json` | 检查 `dsh-root` 挂载与 `DSH_VERSION_SSOT`；`docker exec dsh-alpha ls /root/nas_docker` |
| watchdog 没有自动回滚 | 容器"已部署超过 3h"（按 `StartedAt` 判定）、或没有更早版本、或 GHCR/本地都没有候选 | 看 `state/<ch>/<ch>-watchdog.log`；`docker logs dsh-watchdog` |
| 回滚报"当前版本不在候选列表" | 该版本镜像 tag 已被清理，或 `.env` 里是 `<ver>-<sha>` 不可变标签 | 手动指定版本：`DSH_CHANNEL=alpha sh rollback.sh 0.1.3-alpha.2` |
| `compose up` 报 project/卷源断言失败 | 用错了项目名或部署目录（例如在 watchdog 容器里用 `/dsh-app` 路径） | 统一用 `nas/lib.sh:compose_cmd`；watchdog 容器必须宿主同路径挂载 |
| 端口 3083 被占 | 旧容器或其他应用占用 | 改 SSOT `channels.rc.port` 与 `.env` 的 `DSH_PORT` |

## 8. 起点 C 的 Phase 1（零中断，2026-09-10 已执行）

目标：不重启任何 DSH 容器，先把"版本真相 + 可视 + 通道化资产管理"落地。

1. **升级实时 SSOT 为 schemaVersion 2**（先备份）：
   `/volume1/docker/dsh-alpha5/dsh-root/nas_docker/dsh-version.json`
   - `channels.alpha` = port 3081 / container `deepseek-harness-alpha` / dataDir `/volume1/docker/dsh-alpha5` / production `0.1.3-alpha.2`（实际运行版本）/ candidate `0.1.5-alpha.2`
   - `channels.rc` = port 3083 / container `dsh-rc1` / dataDir `/volume1/docker/deepseek-harness` / production `0.1.2-rc.1`
   - 旧顶层字段由 `parseSSOT` 归一化，向后兼容。
2. **替换版本页**：停掉 `dsh-proxy-12079` 里的旧 version-server，改用独立容器
   `dsh-version`（host 网络 + `--no-healthcheck` + 挂载新脚本与实时 SSOT），见
   [../nas/version-page/docker-compose.yml](../nas/version-page/docker-compose.yml)。
   验收：`/version.json` 的 `cache.ssotIsFallback=false`、`channels` 同时含 alpha/rc、
   alpha 的目标 0.1.5-alpha.2 显示 `targetBuilt=false`（CI 从未构建成功）。
3. **安装通道化管理资产**到 `/volume1/docker/dsh-deploy`（旧文件自动 `.bak-<ts>`），
   并把 `dsh-deploy/dsh-version.json` 做成指向实时 SSOT 的符号链接，
   使 `scripts/dsh-safe-deploy status --channel all` 直接读实时值。
   宿主缺 semver → 把 `semver` 包放到 `dsh-deploy/scripts/node_modules/`。
4. **不动**：两个 DSH 容器、两个 proxy 容器、`deepseek-harness` 遗留容器。

回滚 Phase 1：
```sh
# SSOT
sudo cp -p <SSOT>.bak-<ts> <SSOT>
# 版本页：删新容器，旧版页随 dsh-proxy-12079 重启自动回来
docker rm -f dsh-version && docker restart dsh-proxy-12079
# 资产
cd /volume1/docker/dsh-deploy && for f in *.bak-<ts>; do mv -f "$f" "${f%.bak-<ts>}"; done
```


## 8b. ⚠️ 重建容器的两个坑（2026-09-10 实测踩到，代价：3081 短时 401）

生产容器把**状态存在可写层**里，重建就会丢。重建任何 dsh 容器前必须做这两件事，
否则会出现"容器起来了、UI 却 401 / 永远 unhealthy"。

### 坑 1：`/opt/patch-dsh.sh` 被替换过（含 token-pinning）
- 现象：重建后 DSH 生成了**新的 launch token**（日志 `dsh web: ...?token=<新>`），
  而 host 网络的 `dsh-proxy` 仍用旧的 `BOOTSTRAP_TOKEN` 去 bootstrap → **3081 返回 401**。
- 原因：镜像自带的 `/opt/patch-dsh.sh` **没有** token-pinning；运行中的容器里它是
  **可写层**里被 workspace 版本覆盖过的（`md5` 与 `<workspace>/nas_docker/patch-dsh.sh` 相同）。
  token-pinning 让 DSH 认 `DSH_LAUNCH_TOKEN`，从而与 proxy 的 `BOOTSTRAP_TOKEN` 对齐。
- 正确做法（`nas/recreate-dsh.py` 已自动做）：
  1. 停旧容器前 `docker cp <old>:/opt/patch-dsh.sh <host>` 抢救出来；
  2. 起新容器后 `docker cp <host-file> <new>:/opt/patch-dsh.sh`；
  3. `docker restart <new>`，让 entrypoint 重新应用补丁；
  4. 校验 `docker logs <new> | grep -o 'token=...' | tail -1` 与 proxy 的 `BOOTSTRAP_TOKEN` **一致**。

### 坑 2：HEALTHCHECK 被改成了 TCP 探活
- 现象：重建后容器永远 `unhealthy`。
- 原因：镜像自带的 HEALTHCHECK 用 `fetch('http://127.0.0.1:3080/')` 判 `r.ok`，
  而 DSH 0.1.2-alpha.3+ 起 `"/"` 无 token 返回 **401** → 恒失败；生产容器在创建时用
  `--health-cmd` 覆盖成了 `net.connect(3080)`（TCP 通即健康）。
- 正确做法：克隆容器时必须一并克隆 `Config.Healthcheck`（`recreate-dsh.py` 已实现）；
  仓库 `Dockerfile` 的 HEALTHCHECK 也已改为 TCP 探活。

### 重建的正确姿势（工具已就绪）
```sh
# 在 /volume1/docker/dsh-deploy 下
python3 recreate-dsh.py plan  <container>          # 只读计划（密钥脱敏，含 healthcheck）
python3 recreate-dsh.py apply <container>          # 执行：抢救补丁 → 改名保留旧容器 → 停 → 起 → 注入补丁 → 重启
python3 recreate-dsh.py rollback <container>       # 一键回滚到被保留的旧容器
```
旧容器命名为 `<name>.pre-noproxy-<ts>`（只停不删），确认稳定后再手工 `docker rm`。
（可能存在多代救援容器 → `rollback` 按 CreatedAt **取最近一代**，不会滚错版本。）

### 版本升级（2026-09-10 实战验证：0.1.3-alpha.2/0.1.2-rc.1 → 0.1.5-alpha.2/0.1.5-rc.1）

```sh
cd /volume1/docker/dsh-deploy
# 换镜像升级：NEW_IMAGE 指定新 tag；RESCUE_PATCH=0 表示信任新镜像内置补丁
NEW_IMAGE=192.168.5.35:5050/llzg/dsh-docker:0.1.5-alpha.2 RESCUE_PATCH=0 \
  python3 recreate-dsh.py apply deepseek-harness-alpha
```

四个开关（都是环境变量，缺省保持旧行为）：

| 变量 | 作用 |
|---|---|
| `NEW_IMAGE` | 用指定镜像替换原镜像（**版本升级用它**）；不设 = 原地重建同一镜像 |
| `RESCUE_PATCH=0` | 跳过"从旧容器可写层抢救 `/opt/patch-dsh.sh`"。**跨版本升级必须设 0**：旧补丁是照旧版本 `node_modules` 写的，注入到新版本会打错补丁。新镜像构建时已 STRICT 应用全部补丁（镜像内可验 `dsh-docker-patch:*` marker） |
| `ENV_SET` / `ENV_SET_<N>` | 新增/覆盖容器环境变量，如 `ENV_SET='DSH_VERSION_PORT=0'`；含逗号的值用 `ENV_SET_1='DSH_REGISTRIES=a,b'` |
| `HEALTH_CMD` | 覆盖探活命令（仅用于修正本就写错的探活，如 dsh-proxy 的探活误指 3080） |

两条实战教训：

1. **克隆容器时不要克隆 `org.opencontainers.image.*` 标签**（工具已改为跳过）：
   那是旧镜像的版本/commit 元数据，换镜像后会变成假信息（版本页/排障会读到错的 version）。
2. **`--no-healthcheck` 与 `--health-*` 互斥**（工具已修）：同时输出会直接导致
   `docker run` 失败、新容器建不起来（版本页容器就这么踩过一次，旧容器已被改名停掉 →
   必须先把名字改回来再重试）。


## 9. 起点 C 的 Phase 2（需维护窗口，每通道约 1–2 分钟中断）把每通道改造成**独立 compose 项目**（含其 proxy），让 pin/rollback/watchdog 走统一入口：

1. `nas/docker-compose.yml` 增加两处能力（**2026-09-10 已实现并 `docker compose config` 验证**）：
   - `DSH_HOME` 由环境变量注入（`${DSH_HOME:-/data/dsh}`）—— alpha 现在是 `/data/dsh/test/0.1.2-alpha.5`，写死会让它换掉工作区、设置/插件全部"消失"；
   - 可选 `proxy` 服务（`profiles: ["proxy"]`，默认不参与）：`network_mode: host` + `PORT=${DSH_PORT}` +
     `BACKEND=http://127.0.0.1:${DSH_INTERNAL_PORT}` + `BOOTSTRAP_TOKEN=${DSH_LAUNCH_TOKEN}` +
     `ALLOWED_CIDR=...` + **`DSH_VERSION_PORT=0`**（host 网络容器起版本页会抢宿主 3082，实测踩过），
     挂载 `./dsh-root:/dsh-root:ro`，探活跟着 `PORT` 走（生产上那台 proxy 的探活误指 3080，长期 unhealthy）；
     与之配套，`dsh` 服务的端口发布支持 `DSH_BIND_IP`（proxy 模式下沉到 `127.0.0.1`）。
2. 每通道：`install.sh` → 停旧容器 → `switch.sh`（compose 接管）→ 健康验证。
3. 安装 watchdog（按通道管理 compose 项目）。
4. 观察一周后再删除遗留 `deepseek-harness` 容器与旧 `dsh-deploy` 备份。

风险与回滚：容器名/项目名会变（`deepseek-harness-alpha` → `dsh-alpha`），
旧容器在验证通过前**只停不删**；回滚 = 停新容器、`docker start <旧容器>`。

> 切换前的现实约束（2026-09-10 实测）：compose 里 `ports: ${DSH_PORT}:3080` 与当前
> "host 网络 proxy 抢同一个宿主端口"的形态**互斥** —— 直接 `compose up` 会因端口被
> dsh-proxy 占用而起不来。所以切换顺序必须是"先起 proxy profile 并确认回代可用，
> 再停掉手写的 proxy 容器"，或者先用 `DSH_BIND_IP=127.0.0.1` 让 dsh 容器让出宿主端口。

### 9.1 切换手册（2026-09-10 已在隔离项目里彩排通过）

**模式 B（推荐，保留 proxy 的 CIDR 白名单 + 令牌注入）** 的关键变量：

| 变量 | alpha | rc | 说明 |
|---|---|---|---|
| `DSH_BIND_IP` | `127.0.0.1` | `127.0.0.1` | dsh 容器只绑回环，宿主端口留给 proxy |
| `DSH_PUBLISH_PORT` | `13081` | `13083` | dsh 容器 → 宿主回环端口 |
| `DSH_INTERNAL_PORT` | `13081` | `13083` | proxy 的 `BACKEND=http://127.0.0.1:<这个>` |
| `DSH_PORT` | `3081` | `3083` | proxy 对外端口 |
| `DSH_PROXY_CONTAINER` | `dsh-proxy` | `dsh-proxy-rc` | proxy 容器名 |
| `DSH_VERSION_PORT` | `0` | `0` | 通道容器不起版本页（3082 由 `dsh-version` 统一提供） |

> ⚠ **回环端口必须每通道不同**（这条是踩过才写下的，2026-09-10 实测事故）：
> 手册初版让两个通道都用 `3080` → 先起 rc 的 compose 项目占住了 `127.0.0.1:3080`，
> 再起 alpha 时 `Bind for 127.0.0.1:3080 failed: port is already allocated`，**alpha 容器根本没起来**；
> 更糟的是 alpha 的 proxy 已经启动，它回代 `127.0.0.1:3080` → **3081 端口上服务的是 rc 实例**。
> 教训有两层：(1) 每通道独立回环端口；(2) 只验 "HTTP 200" 会漏判 —— 200 也可能来自**别的通道**。


**彩排结论（隔离项目 dsh-rehearsal，端口 3181→3180，空工作区）**：
`dsh` 与 `proxy` 两个服务都 healthy，`http://127.0.0.1:3181/?token=…` 返回 **200**
（27786 字节，标题 `DeepSeek Harness`），proxy 日志可见 `303 → 200` 的令牌注入链路。
即：compose 化的 dsh+proxy 组合是**可用**的，不是纸面方案。

切换步骤（每通道 1–2 分钟中断；先在 rc 上做，再动 alpha）：

```sh
# 0) 前置：通道目录要有 compose 文件与 .env（本仓库 nas/docker-compose.yml + 上表变量）
#    已为两个通道生成：/volume1/docker/dsh-alpha5/.env、/volume1/docker/deepseek-harness/.env
cp /volume1/docker/dsh-deploy/nas-docker-compose.yml.new /volume1/docker/dsh-rc/docker-compose.yml

# 1) 先校验（不创建任何容器）——config 输出的端口/挂载/env 必须与手写容器逐项一致
cd /volume1/docker/dsh-deploy
docker compose -p dsh-rc --project-directory /volume1/docker/deepseek-harness \
  -f /volume1/docker/deepseek-harness/docker-compose.yml --profile proxy config

# 2) 停旧的手写容器（只停不删 = 回滚点；proxy 必须停，否则端口被占）
docker stop dsh-proxy-rc dsh-rc1

# 3) 起 compose 项目（--wait 会等两个服务 healthcheck 通过）
docker compose -p dsh-rc --project-directory /volume1/docker/deepseek-harness \
  -f /volume1/docker/deepseek-harness/docker-compose.yml --profile proxy up -d --wait

# 4) 验证：**不能只看 HTTP 200** —— 200 也可能来自另一个通道。逐项核身份（下面是 rc 的例子）：
docker exec dsh-rc1 cat /opt/dsh-build.json               # channel 必须是 rc
docker port dsh-rc1                                        # 必须独占 127.0.0.1:13083
docker inspect dsh-proxy-rc --format '{{range .Config.Env}}{{println .}}{{end}}' | grep BACKEND  # 必须=http://127.0.0.1:13083
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3083/     # 200
sh check-image-drift.sh rc                                 # 运行镜像与 tag 一致

# 回滚（任一步不通过）：停 compose 项目，恢复手写容器
docker compose -p dsh-rc --project-directory /volume1/docker/deepseek-harness \
  -f /volume1/docker/deepseek-harness/docker-compose.yml --profile proxy down
docker rename dsh-rc1.pre-compose-<ts> dsh-rc1
docker rename dsh-proxy-rc.pre-compose-<ts> dsh-proxy-rc
docker start dsh-rc1 dsh-proxy-rc
```

**2026-09-10 执行结果**：两个通道均已由 compose 接管（项目 `dsh-alpha` / `dsh-rc`），
容器名保持不变（`deepseek-harness-alpha` / `dsh-rc1` / `dsh-proxy` / `dsh-proxy-rc`），
数据目录与工作区完全沿用（alpha 的 `/root/nas_docker` 与 SSOT 都在），
alpha 仍挂 `docker.sock`、rc 不挂。回滚点：`*.pre-compose-20260910-184531`（rc）、
`*.pre-compose-20260910-184611`（alpha）。

### 9.2 Phase 2 之后：重建/对齐/回滚都走 compose（`recreate-dsh.py` 不再适用）

`recreate-dsh.py` 是给"docker run 起的手写容器"用的（克隆配置、抢救可写层补丁、保留救援容器）。
Phase 2 之后容器归 compose 管，再用它会出现两套管理方式打架。正确姿势：

```sh
# 1) 对齐"同版本 tag 被重推"的最新构建
docker pull 192.168.5.35:5050/llzg/dsh-docker:<通道版本>
cd /volume1/docker/dsh-alpha5 && docker compose -p dsh-alpha \
  --project-directory /volume1/docker/dsh-alpha5 \
  -f docker-compose.docker-sock.yml -f docker-compose.yml --profile proxy up -d --wait

# 2) 校验（身份 + 漂移，不要只看 200）
docker exec deepseek-harness-alpha cat /opt/dsh-build.json
sh /volume1/docker/dsh-deploy/check-image-drift.sh

# 3) 终极兜底：回滚到迁移前的手写容器（回滚点仍在）
docker compose -p dsh-alpha --project-directory /volume1/docker/dsh-alpha5 \
  -f docker-compose.docker-sock.yml -f docker-compose.yml --profile proxy down
docker rename deepseek-harness-alpha.pre-compose-20260910-184611 deepseek-harness-alpha
docker rename dsh-proxy.pre-compose-20260910-184611 dsh-proxy
docker start deepseek-harness-alpha dsh-proxy
```

> **漂移是预期现象，不是故障**：CI 用同一版本号重建会重推同一个 tag，运行中的容器于是
> 比 tag "落后一次构建"（同版本、行为一致）。workflow 的 `paths:` 过滤已把**文档/nas 改动**
> 排除在重建之外 —— 只有真正影响镜像的改动（Dockerfile / 补丁 / 脚本 / SSOT / 资产）
> 才会产生漂移。想彻底消除就改为按 digest 部署。


**切换前必须敲定的两个决定**（都影响生产行为，别默认）：

1. **rc 是否也挂 `docker.sock`**：当前手写的 rc 容器**没有**挂（只有 alpha 挂），
   而 compose 基座里是统一挂的 —— 直接切换等于给 rc 容器开了 host root 等价权限。
   要保持现状就得给 rc 一个不挂 socket 的 override，或把 socket 那行也做成可选 override。
2. **容器名保不保**：保持 `deepseek-harness-alpha` / `dsh-rc1` 可以不动 SSOT 与
   `check-image-drift.sh` 的映射（上面 .env 就是这么写的）；若要按 §9 改成
   `dsh-alpha` / `dsh-rc`，必须同步改 `dsh-version.json` 的 `channels.<ch>.container`，
   否则版本页与漂移检查会找不到容器。

### 9.3 ⚠ `--trusted-host` 必须覆盖"用户实际输入的地址"（2026-09-10 真实事故）

DSH 的 `/api/*`（含 WebSocket `/api/remote.mux`）有一道**按请求 Host 匹配**的浏览器信任围栏；
而 `dsh-proxy` 会**保留客户端的 Host** 转发（不改成 backend host）。因此：

- `GET /` 仍能 200（页面打得开）；
- 但 Host 不在 `--trusted-host` 列表里时，`/api/*` 与 WebSocket 全部 **403** →
  界面表现为 **"一直重连" / "无法加载 Agent 预设（transport failure ... HTTP 403）"**。

本次事故：把容器 CMD 从写死的 `--trusted-host 192.168.5.16` 改成 env 驱动的 `192.168.5.17`
（误以为 .16 是过期值），而用户实际是用 **192.168.5.16** 访问 → 全线 403。
`--trusted-host` 是 **`<authority...>` 变参**，所以正确做法是**把所有入口地址都列上**：

```sh
# .env（空格分隔多个地址；compose 的 command 对 $DSH_TRUSTED_HOST 故意不加引号，
#        让多值展开成多个 --trusted-host）
DSH_TRUSTED_HOST="192.168.5.16 192.168.5.17"
```

不用浏览器就能复现围栏（403 = 不受信；415/200 = 已过围栏，415 只是缺 body/content-type）：

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 192.168.5.16:3081' \
  -H 'content-type: application/json' -d '{}' http://127.0.0.1:3081/api/agentPresets/list
# WebSocket：应看到 101 Switching Protocols
curl -s -i -m 6 -H 'Host: 192.168.5.16:3081' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:3081/api/remote.mux | head -1
```

**只验 `GET /` 返回 200 不足以证明链路可用** —— 与 §9.1 的"回环端口撞车"是同一类教训：
状态码 200 不能证明"这条路真的通对了"。凡是经 proxy 的改动，验收都要包含
`/api/*` 与 WebSocket 两项。

### 9.4 升级后旧会话打不开：v2 → v3 迁移被拒（2026-09-10 实测并修复）

**症状**（界面「历史加载失败」）：

```
failed to observe session "session-…": Session migration from v2 to v3 refuses the
transformed artifact: turn/start 3 does not open expected turn 2; source v2 artifact
remains unchanged (raw log: …/session.v2.jsonl.zstd)（gateway/internal）
```

**根因**：DSH 读取旧会话时把 v2 artifact 迁移到 v3，而 v2 的关系校验很严
（`dsh-session-persistence-jsonl` 里 `RELEASED_V2_RELATIONSHIP_EXTENSIONS` **不含**
`legacyInterruptedTurnRestart`）：`turn/start` 的轮次号必须严格连续，`turn/end` 还要求
"无未闭合 step、无未结束 tool"。老版本写入的会话存在**轮次开了但没写 `turn/end` 就直接开下一轮**
的形态 → 整条会话拒绝加载。好消息：迁移器**不改动源文件**（报错里明确写
"source v2 artifact remains unchanged"），所以数据没坏，只是读不了。

**修复**：`nas/repair-session-turns.js` —— 最小补齐，不做任何编造：

```sh
# 1) 扫描哪些会话有问题（在**宿主**上跑；容器里没有 zstd 命令，别在里面扫）
#    判据：解压后逐事件走状态机，turn/start 的轮次号必须等于期望值
# 2) dry-run（默认不改动）
node nas/repair-session-turns.js /path/to/session.v2.jsonl.zstd
# 3) 应用：原文件先备份到 sessions 目录**之外**，再写回
node nas/repair-session-turns.js /path/to/session.v2.jsonl.zstd --apply
```

它只做两件事：在**状态干净**（无未闭合 step / 无未结束 tool）的位置，为那个未闭合轮次补一条
`turn/end {turn, reason:{kind:"interrupted"}}`，并把其后事件的 `seq` 重新压紧
（校验器要求 `seq === 数组下标`，且**事件从 0 开始、header 不计入**）。
状态不干净的位置一律**拒绝修复**并报告（那种情况补 `turn/end` 会被判 "crosses an open step"）。

**验收方式**（不用浏览器，用容器里**真实**的校验函数跑一遍）：

```sh
# artifact 解压后喂给容器的 assertReleasedArtifactRelationships（与迁移器同一份实现）
zstd -dc session.v2.jsonl.zstd | docker exec -i <容器> node /tmp/validate-relationships.mjs
# 修复前：RELATIONSHIPS_FAIL  turn/start 3 does not open expected turn 2
# 修复后：RELATIONSHIPS_OK    events=4799
```

本次实测：alpha 工作区 17 个 v2 会话里仅 1 个受影响，已修（原文件备份在
`/volume1/docker/dsh-alpha5/dsh-data/_session-backups/`），修复后工作区全部自洽；rc 工作区无 v2 会话。

> ⚠⚠ **zstd 分帧是格式的一部分，不是实现细节**（2026-09-10 血泪教训）：
> DSH 读取会话时断言 "first frame is not exactly one header line" —— 会话日志是**多帧**文件
> （生产文件实测 2135 帧，每个写入批次一帧），**首帧必须只含 header 那一行**。
> 若用 `zstd -19` 把整个 JSONL 压成**一帧**：`dsh-workspace` 在启动时读会话头就会抛
> `corrupt Zstandard session log` → **整个 DSH 起不来**（不是只坏这一条会话！）。
> `repair-session-turns.js` 现在按"首帧=header 一行 + 其余一帧"重建，并自带分帧自检
> （帧数 ≥2、解压回读逐行一致），自检不过就**不写回**。

> 排查小坑（踩过两次）：用 `sudo cp` 把会话文件拷到 /tmp 后**必须 chmod 644**，
> 否则以普通用户跑 `zstd -dc` 会 Permission denied，脚本拿到空输入 → 假阴性"全部 OK"。
> 另外 `execFileSync` 读几十 MB 的解压内容要显式给 `maxBuffer`（默认 1MB 会直接抛错）。

### 9.5 升级后"切换模型报错"：旧工作区的 agent preset 不满足新 schema（2026-09-10 实测）

**症状**：在 rc 通道（3083）切换模型报错；HTTP 全是 200、容器日志无报错、模型目录正常。
把服务端返回体打出来才看到真正的错误（**RPC 用 200 带错误体**）：

```
resume failed for session "session-…": RemoteError: agent-presets: preset "code-subagents"
failed to mount: failed to apply loader entry persona (@deepseek-ai/dsh-persona):
invalid config: - $.prefix missing required value (at prefix)
(/data/dsh/.agent-presets/code-subagents/agent.cordis.yml)
```

**根因**：DSH 0.1.5 的 `dsh-persona` 把 persona 配置改成了 `prefix`（必填）+ `suffix`，
而 rc 工作区里的 `code-subagents` preset 是**旧版本写的**，只有 `persona.config.text`：

```yaml
# 旧（rc，会挂载失败）        # 新（alpha / 镜像自带 standard preset，正确）
config:                        config:
  text: >-                       prefix: >-
    You are a coding agent …       You are a coding agent …
                                   suffix: Your working directory is {{cwd}}.
```

**为什么切模型会撞上它**：切换模型要先 **resume 会话**，而 resume 要挂载该会话的 preset →
preset 挂载失败 → 整个请求失败。所以它不只影响"切模型"，**继续对话、恢复旧会话同样会失败**
（rc 通道当时所有用这个 preset 的会话都受影响）。

**诊断手法（不用浏览器，直接打 RPC）**：DSH 的 Web API 是 RPC 信封，路径即端点、错误在响应体里，
所以光看 HTTP 状态码会把问题漏掉：

```sh
H='Host: 192.168.5.16:3083'      # 必须带用户实际访问的 Host（见 §9.3）
# 1) 模型目录（看 provider 加载是否正常）
curl -s -X POST -H "$H" -H 'content-type: application/json' \
  -d '{"type":"client-request","rpcId":"p1","method":"session/modelCatalog","payload":{"args":{}}}' \
  http://127.0.0.1:3083/api/session/modelCatalog
# 2) 复现"切模型"：args 里必须是 {request:{…}}（少了会被判 arguments-invalid）
curl -s -X POST -H "$H" -H 'content-type: application/json' \
  -d '{"type":"client-request","rpcId":"p2","method":"session/selectModel","payload":{"args":{"request":{"sessionId":"<sid>","provider":"deepseek-official","model":"deepseek-v4-flash"}}}}' \
  http://127.0.0.1:3083/api/session/selectModel
# 成功: {"result":{"ok":true,...}}   失败: {"result":{"ok":false,"error":{"code":…,"message":…}}}
```

**修法**：把工作区 preset 的 `persona.config.text` 改成 `prefix`（+ `suffix`），与镜像自带
`standard` preset 或另一通道已验证可用的那份保持一致：

```sh
# 备份到工作区**之外**，改完立即用上面的 selectModel 复测（成功即 ok:true）
cp <工作区>/.agent-presets/code-subagents/agent.cordis.yml <备份目录>/agent.cordis.yml.bak-$(date +%Y%m%d-%H%M%S)
```

本次实测：rc 修好后 `selectModel` 对 `deepseek-official` 与 `xiaomi-token-plan-cn` 都返回 `ok:true`，
容器日志不再出现 resume failed。alpha 那份 preset 早先已有 `prefix`，所以 3081 一直正常。

> 与 §9.4 是同一类问题的两个面：**升级后，旧工作区的数据（会话文件、agent preset）都要满足
> 新版本的 schema 才能用**。区别是 §9.4 坏的是历史会话读取，这里坏的是 preset 挂载（影响面更大：
> 该 preset 下的所有会话都无法 resume）。升级大版本前值得先做一遍这两项体检。
