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

## 9. 起点 C 的 Phase 2（需维护窗口，每通道约 1–2 分钟中断）

把每通道改造成**独立 compose 项目**（含其 proxy），让 pin/rollback/watchdog 走统一入口：

1. `nas/docker-compose.yml` 增加两处能力（尚未实施）：
   - `DSH_HOME` 由环境变量注入（alpha 现在是 `/data/dsh/test/0.1.2-alpha.5`，不能写死 `/data/dsh`）；
   - 可选 `proxy` 服务：`network_mode: host` + `PORT=<通道端口>` + `BACKEND=http://127.0.0.1:<内部端口>`，
     DSH 服务把 3080 发布到 `127.0.0.1:<内部端口>`，对外仍只暴露 proxy（保留 CIDR 白名单等特性）。
2. 每通道：`install.sh` → 停旧容器 → `switch.sh`（compose 接管）→ 健康验证。
3. 安装 watchdog（按通道管理 compose 项目）。
4. 观察一周后再删除遗留 `deepseek-harness` 容器与旧 `dsh-deploy` 备份。

风险与回滚：容器名/项目名会变（`deepseek-harness-alpha` → `dsh-alpha`），
旧容器在验证通过前**只停不删**；回滚 = 停新容器、`docker start <旧容器>`。
