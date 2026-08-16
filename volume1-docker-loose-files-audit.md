# /volume1/docker 落单文件审计报告

> **更新（2026-08-16 清理执行）**：
> 1. 第①组 13 个文件已删除（invoice-agent-code-*.tar.gz × 10、invoice-build-147/148.log、invoice-agent.override.yml，约 58 MB）。删除前已确认无容器挂载、无 compose/脚本引用；代码本体在 `/volume1/docker/invoice-agent/`（git）与 GitHub `llzg/invoice-agent-ui`，镜像在本地 `invoice-agent-invoice-app:*-zipfix*` 与 GHCR，均可重建，无损失。
> 2. 剩余落单文件已全部清理：homelab-dashboard-compose.yml（草稿）、lidagang-homelab-nas.zip（源码包）、telegram_channel.py（旧版副本）、nas_*.sh × 4 + NAS_TASK_SCHEDULER_README.txt（运维脚本，检查确认系统 crontab/systemd 无引用、logs/ 自 8/14 后无运行记录，判定计划任务未生效/已停用）、脚本自建的 logs/ 目录。共 8 文件 + 1 目录。
> 3. **保留**：`homelab-dashboard.tar`（运行中容器 homelab-dashboard 的绑定挂载依赖，compose 卷路径 `../homelab-dashboard.tar` 决定其必须位于根目录）。

审计时间：2026-08-16（NAS 时区 +0800）
审计方式：SSH 登录 NAS（lzg 用户）读取 `/volume1/docker`；结合文件 stat（birth/mtime/ctime）、内容、Git 提交时间线、Docker 容器挂载、harness 历史会话记录交叉取证。

## 结论速览

`/volume1/docker` 根目录当前有 **22 个落单文件**，约 85 MB。全部可归因于两类活动：

1. **invoice-agent 部署 agent 的"本地构建部署"遗留**（14 个文件，8/7–8/14）——agent 每次提交代码后打代码快照、跑 docker build，产物直接丢在根目录，8/15 起切换 GHCR 自动发布后不再产生，但旧产物从未清理。
2. **NAS 运维自动化脚本**（5 个文件，8/11–8/14）——为 UGOS 计划任务按绝对路径调用而**有意**放在根目录（有 README 说明），但破坏了"一项目一文件夹"的约定。
3. **homelab-dashboard 项目文件**（3 个文件，7/22）——其中 1 个是**正在运行的容器的绑定挂载依赖**，必须保留；另外 2 个是遗留。

## 一、invoice-agent 部署遗留（14 个文件，约 58 MB）

### 1. invoice-agent-code-*.tar.gz × 11（约 57.9 MB）

| 文件 | 大小 | 对应 git commit | commit 时间 | tar 创建时间 |
|---|---|---|---|---|
| invoice-agent-code-5fe1706.tar.gz | 5.0 MB | 5fe1706 perf: 餐补 bitset 快路径 | 08-11 16:06 | 08-11 16:06 |
| invoice-agent-code-0d255bc.tar.gz | 5.0 MB | 0d255bc feat: Telegram 主动通知 | 08-11 14:36 | 08-11 14:37 |
| invoice-agent-code-032b95c.tar.gz | 5.0 MB | 032b95c feat: 运维巡检定时告警 | 08-11 14:45 | 08-11 14:46 |
| invoice-agent-code-bd993bb.tar.gz | 5.0 MB | bd993bb feat: 每日生产备份 | 08-14 09:59 | 08-14 09:59 |
| invoice-agent-code-b93b94b.tar.gz | 5.0 MB | b93b94b feat: CSV 导出 + 健康告警 | 08-14 10:43 | 08-14 10:44 |
| invoice-agent-code-a7dcdc8.tar.gz | 5.0 MB | a7dcdc8 fix: 月度报表前缀 | 08-14 10:45 | 08-14 10:45 |
| invoice-agent-code-round2.tar.gz | 5.0 MB | （"round2"重试命名） | — | 08-14 11:11 |
| invoice-agent-code-6b502df.tar.gz | 5.0 MB | 6b502df feat: 日历未确认提示 | 08-14 22:49 | 08-14 22:49 |
| invoice-agent-code-53df89f.tar.gz | 5.0 MB | 53df89f feat: 行程推荐标注 | 08-14 23:04 | 08-14 23:04 |
| invoice-agent-code-2f78fec.tar.gz | 5.0 MB | 2f78fec feat: 手动出差无餐补 | 08-14 23:22 | 08-14 23:23 |

**证据链**：tar 内是完整仓库代码（Dockerfile/api/…）；每个 tar 的创建时间与对应 git commit 提交时间**精确吻合**（秒级）；镜像 tag `invoice-agent-invoice-app:<commit>-zipfix<N>` 与构建日志 `invoice-build-<N>.log` 一一对应（build 147 → `6dcc295-zipfix147`）；同期的 `invoice-agent-build-5fe1706/`、`invoice-agent-build-bd993bb/` 目录是同一流程的 checkout 副本。

**来源**：invoice-agent 部署 agent（经 SSH 以 lzg 身份操作 NAS）在"本地构建部署"阶段，每次提交后把该 commit 的代码打成 tar.gz 放到 `/volume1/docker` 根目录，作为 docker build 上下文/快照。8/15 起项目切换到 GitHub Actions → GHCR 自动发布（`ghcr.io/llzg/invoice-agent-ui:production-candidate`，镜像 22 分钟前还在更新），此流程停止，遗留未清理。

### 2. invoice-build-147.log / invoice-build-148.log（8/14）

docker build（buildx）输出日志，重定向到了根目录（`docker build ... > /volume1/docker/invoice-build-147.log 2>&1`）。build 147 成功（产出 `6dcc295-zipfix147`），build 148 被取消（context canceled，日志尾部可见）。

### 3. invoice-agent.override.yml（8/7，204 B）

早期部署用的 compose override（`UVICORN_WORKERS`），放在根目录随 `-f` 使用。当前生产 compose 已迁到 `/volume1/docker/invoice-agent-prod/`（自带 `docker-compose.override.yml`），根目录这份已无引用，是孤儿。

## 二、NAS 运维自动化（5 个文件，8/11–8/14）

- **nas_daily_summary.sh / nas_ops_alert.sh / nas_backup.sh / nas_health_check.sh** —— 通过 `docker exec invoice-app-prod` 触发应用内调度/备份/健康检查，日志写入 `/volume1/docker/logs/`。
- **NAS_TASK_SCHEDULER_README.txt** —— 部署说明，明确写着"在 UGOS 计划任务（root）里配置绝对路径 `/volume1/docker/nas_daily_summary.sh`…"。

**来源**：与上面同一 agent，随 commit `0d255bc`（Telegram 通知）、`032b95c`（运维巡检告警）、`bd993bb`（每日备份）、`b93b94b`（健康告警）一并落地。这些脚本是**有意**放根目录的——UGOS 计划任务以 root 按绝对路径执行，放子目录会破坏计划任务配置。`logs/` 目录（8/14）也是这套脚本自建。属于"约定外但功能需要"。

- **telegram_channel.py（8/11 14:06，34 KB）** —— 修 Telegram 通知时从代码里拷到根目录的独立副本；是**旧版**（同日修好的版本在 `notify_fix/telegram_channel.py`，38 KB；容器内 `/app/invoice_agent/messaging/telegram_channel.py` 又是另一版，三者 md5 均不同）。纯遗留，可删。

## 三、homelab-dashboard 项目（3 个文件，7/22）

- **homelab-dashboard.tar（26.9 MB）—— 运行依赖，必须保留**。正在运行的 `homelab-dashboard` 容器（node:22，Up 11 天）的绑定挂载就是它：
  `/volume1/docker/homelab-dashboard.tar -> /bundle/homelab-dashboard.tar`
  项目 compose（`homelab-dashboard/docker-compose.yaml`）里写的是 `../homelab-dashboard.tar`，所以它**必须**在 `/volume1/docker` 根目录，否则容器重建会失败。
- **homelab-dashboard-compose.yml（752 B）** —— 目录内 `docker-compose.yaml`（1055 B）的早期草稿：缺少 QBITTORRENT/TRANSMISSION 环境变量。孤儿，可删。
- **lidagang-homelab-nas.zip（268 KB）** —— 项目源码包（含 app/、build/、db/、compose.yml），7/22 下载解压构建后的遗留。可删（源码另有其处）。

## 四、根因总结

1. 部署 agent 图省事把构建中间产物（代码快照、构建日志、override、脚本）直接写进 `/volume1/docker` 根目录，没有遵守"一项目一文件夹"，且流程切换（本地构建 → GHCR 自动发布）后没有清理旧产物。
2. 运维脚本因 UGOS 计划任务的绝对路径限制被有意放在根目录。
3. homelab-dashboard 的 compose 卷路径设计使 tar 固定在根目录（设计使然，不算脏文件）。

## 五、处置建议

| 文件 | 建议 |
|---|---|
| homelab-dashboard.tar | **保留**（运行依赖）。若想收进目录：改 compose 卷为 `./homelab-dashboard.tar` 并 `docker compose up -d --force-recreate` |
| nas_*.sh × 4 + NAS_TASK_SCHEDULER_README.txt | 按需保留但建议重整：迁到 `/volume1/docker/script/`（已有此目录）或独立 ops 项目，并同步更新 UGOS 计划任务路径；若计划任务已不再配置（logs/ 自 8/14 后无新日志），可一并清理 |
| telegram_channel.py | 删（旧版，修复版在 notify_fix/ 与容器内） |
| invoice-agent-code-*.tar.gz × 11 | 删（约 58 MB；无任何 compose/脚本引用；对应镜像已在本地或 GHCR） |
| invoice-build-147/148.log | 删 |
| invoice-agent.override.yml | 删（当前生产 compose 用目录内 override） |
| homelab-dashboard-compose.yml | 删（目录内有正式版） |
| lidagang-homelab-nas.zip | 删 |

清理后根目录将只剩目录（每目录一个项目）+ homelab-dashboard.tar 一个运行依赖，符合"一项目一文件夹"规划。
