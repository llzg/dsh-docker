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

