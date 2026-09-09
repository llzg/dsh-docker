# 从单通道迁移到双通道（NAS 操作手册）

> 目标：把原来"一个 `deepseek-harness` 容器（3081）"的部署，迁移成
> **`dsh-alpha`（3081）+ `dsh-rc`（3083）两条互不干扰的通道**，并让版本页（3082）同时展示两条通道。
>
> 前置阅读：[dual-channel.md](dual-channel.md)（契约）、[safe-upgrade-architecture.md](safe-upgrade-architecture.md)（升级流程）。

---

## 0. 迁移前现状（旧拓扑）

| 项 | 值 |
|---|---|
| 容器 | `deepseek-harness` |
| compose 项目 / 目录 | `deepseek-harness` / `/volume1/docker/deepseek-harness` |
| 数据 | `/volume1/docker/deepseek-harness/dsh-data`（DSH_HOME） |
| workspace | `/volume1/docker/deepseek-harness/dsh-root`（容器内 `/root`，含 `/root/nas_docker`） |
| 端口 | 3081→3080、3082（版本页） |

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
cd /volume1/docker/dsh-deploy

DSH_CHANNEL=alpha sh install.sh    # 建目录 + 装 compose/.env + watchdog + 预拉镜像
DSH_CHANNEL=rc    sh install.sh
```

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
