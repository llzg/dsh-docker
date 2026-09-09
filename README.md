# dsh-docker —— DeepSeek Harness 双通道自构建 / 安全升级 / 回滚

在绿联 NAS 上并行维护两条 DeepSeek Harness（dsh）版本线：

| 通道 | 版本段 | 宿主端口 | 容器 / compose 项目 | 数据目录 |
|---|---|---|---|---|
| `alpha` | `-alpha.N` | 3081 | `dsh-alpha` | `/volume1/docker/dsh-alpha` |
| `rc` | `-rc.N` | 3083 | `dsh-rc` | `/volume1/docker/dsh-rc` |

版本状态页：<http://<NAS-IP>:3082/>（由 alpha 容器统一渲染**两条通道**）。

> 设计契约（字段、API、环境变量、验收标准）见 [docs/dual-channel.md](docs/dual-channel.md)。
> 升级流程与安全边界见 [docs/safe-upgrade-architecture.md](docs/safe-upgrade-architecture.md)。

## 架构一览

```
上游（npm @deepseek-ai/dsh + GitHub Release/Tag）
        │  每 30 分钟解析「每个通道各自」的构建目标
        ▼
GitHub Actions（本仓库，矩阵：alpha / rc）
   ├─ 收敛判定：目标版本是否已存在于 GHCR tag 列表 → 已存在则跳过
   │            （旧逻辑用 latest label 判定，prerelease 永不打 latest → 每 30 分钟白重建）
   ├─ docker build（DSH_VERSION / GIT_REVISION / DSH_CHANNEL）+ STRICT 补丁校验
   ├─ 冒烟测试（dsh web 探活）→ 通过才 push
   └─ push：<version>-<sha>（不可变）、<version>；stable 才追加 latest
        │  build-status-<channel>.json → 汇总回写 build-status.json
        ▼
ghcr.io/llzg/dsh-docker:<version>
        │  每通道一个 compose 项目（显式 -p / --project-directory；不依赖 watchtower）
        ▼
NAS：dsh-alpha(3081) / dsh-rc(3083)   ←── dsh-safe-deploy check/test/promote/rollback
        │
        └─ watchdog（每 5 分钟）：容器不健康且**刚部署** → 自动回滚上一版本并钉住
```

**关键语义**

- 自动**构建**是自动的；自动**上线**是**不**做的——上生产只走 `dsh-safe-deploy promote`（隔离测试 PASS + 非 BLOCKED）。
- DSH 容器**不使用 watchtower**（`com.centurylinklabs.watchtower.enable=false`），避免未验证的跨版本替换。
- `latest` 标签**不是回滚依据**，也不再是自动更新的指针：只有 stable 通道会打 `latest`；回滚一律用不可变 `<version>-<sha>` 或 `<version>`。
- 每条通道有独立的 SSOT `production` / `candidate`；插件兼容性字段是全局的。

## 目录结构

```
.
├── Dockerfile                     # 版本/通道参数化 + STRICT 补丁校验 + HEALTHCHECK + OCI 标签
├── patch-dsh.sh                   # LAN 补丁（锚点预检 + marker 正向校验，失败即构建失败）
├── entrypoint.sh                  # 入口：profile 初始化 + 版本页守护进程
├── dsh-version.json               # SSOT（schemaVersion 2：channels.alpha / channels.rc）
├── build-status.json              # CI 回写的各通道最近一次构建结论（自动生成）
├── profiles/web/cordis.patch.yml
├── .github/workflows/build-publish.yml
├── scripts/
│   ├── version-policy.js          # 上游来源查询 + 通道识别 + 每通道目标解析
│   ├── safe-deploy-policy.js      # SSOT 归一化 + 风险/迁移/插件策略（单通道 & 全通道）
│   ├── check-new-version.js       # CI：解析各通道构建矩阵 + GHCR 收敛判定
│   ├── version-server.js          # 3082 版本页（双通道 + 构建状态 + 强制刷新）
│   ├── dsh-safe-deploy            # 安全升级薄层（check/test/promote/rollback/status，按通道）
│   ├── smoke-test.sh              # 构建后冒烟测试
│   ├── test-dual-channel.js       # 双通道离线单测（CI 必跑）
│   └── test-version-policy.js     # 版本检测策略测试
└── nas/                           # NAS 侧部署资产（每通道一个 compose 项目）
    ├── docker-compose.yml         # 通道参数化（DSH_CHANNEL/DSH_PORT/DSH_DATA_DIR…）
    ├── .env.example               # 每通道 .env 模板
    ├── install.sh                 # 一次性部署（幂等，覆盖前必定备份）
    ├── switch.sh                  # 切换到指定镜像/版本
    ├── rollback.sh                # 一键回滚（semver 选版，可指定版本）
    ├── resume-auto-update.sh      # 恢复到该通道 SSOT 的 production（不是 latest）
    ├── watchdog.sh                # 健康自动回滚守护（容器内 cron 每 5 分钟）
    ├── watchdog-container.sh      # 守护容器（宿主同路径挂载 + 显式项目名）
    ├── apply-igpu.sh              # 可选：核显直通（profile）
    └── lib.sh                     # 共享函数库（compose_cmd / pin_version / prev_version …）
```

## 日常操作

```sh
# 只读评估（默认 primary 通道；也可 --channel rc / --channel all）
scripts/dsh-safe-deploy check
scripts/dsh-safe-deploy status --channel all

# 隔离测试（snapshot → 独立 TEST_DSH_HOME + 随机端口容器 + smoke）
scripts/dsh-safe-deploy test --channel alpha

# 门禁 promote（test 未 PASS 一律拒绝；HIGH 风险需显式 --force）
scripts/dsh-safe-deploy promote --channel alpha [--force]

# 回滚（恢复最近 snapshot + 上一版本镜像；幂等）
scripts/dsh-safe-deploy rollback --channel alpha

# NAS 侧脚本用 DSH_CHANNEL 环境变量指定通道（默认取 SSOT primaryChannel）
DSH_CHANNEL=rc sh /volume1/docker/dsh-deploy/rollback.sh          # 回滚到上一版本
DSH_CHANNEL=rc sh /volume1/docker/dsh-deploy/rollback.sh 0.1.2-rc.1  # 回滚到指定版本
DSH_CHANNEL=rc sh /volume1/docker/dsh-deploy/resume-auto-update.sh   # 恢复到该通道 SSOT production
```

日志：`/volume1/docker/dsh-deploy/state/<channel>/<channel>-{rollback,watchdog}.log`

## 运维要点

- **上游改代码导致补丁失效**：构建会**失败**并给出 `VERIFY FAIL: anchor missing …`；更新 `patch-dsh.sh` 后 push 到 main 即可重发。补丁通过后会写入 `dsh-docker-patch:<name>` marker，STRICT 校验 marker 必须存在（旧版"原始模式已消失"的校验在锚点失配时恒真，会静默放行）。
- **版本页读的是实时 SSOT**：命中镜像内置快照时页面会显式告警（`ssotIsFallback`）。容器内查找顺序 `$DSH_VERSION_SSOT → /root/nas_docker/dsh-version.json → /opt/dsh-version-ssot.json`。
- **构建状态**：版本页每通道显示「推荐构建目标 / 目标镜像是否已发布 / 最近一次 CI 结论」，可直接看出"npm 有版本但镜像没构建成功"。
- **数据安全**：容器重建只换镜像；每通道的 `DSH_HOME`（会话、配置、凭据）独立持久化。promote/rollback 前 `dsh-safe-deploy` 会 snapshot，回滚是"镜像 + 数据 + env"三件套一起回。
- **NAS 侧凭据**：包为 public，匿名可拉；脚本优先复用 `/home/lzg/.docker/config.json`（可用 `DOCKER_CONFIG` 覆盖）。
- **不再使用 watchtower 自动更新**：旧 README 的 watchtower/latest 链路已废弃（watchtower 只管理其他无状态容器）。

## 接入自建设施（自建 runner / 代理 / 私有 registry）

全部通过仓库 Variables/Secrets 开关，**不配置时行为不变**（GitHub 托管 runner + GHCR 单推）：

| 类型 | 名称 | 作用 |
|---|---|---|
| Variables | `DSH_RUNNER` | 如 `["self-hosted","linux","x64"]`；不设 = `ubuntu-latest` |
| Variables | `DSH_HTTP_PROXY` | 如 `http://192.168.5.36:7893`（仅自建 runner 有意义） |
| Variables | `DSH_PRIVATE_IMAGE` | 如 `192.168.5.35:5050/llzg/dsh-docker`（一次构建双推） |
| Variables | `DSH_REGISTRIES` | 收敛判定与版本页查询的仓库列表（逗号分隔） |
| Secrets | `DSH_REGISTRY_USER` / `DSH_REGISTRY_PASSWORD` | 私有 registry Basic 认证 |

详见 [docs/homelab-ci.md](docs/homelab-ci.md)（含实况核对：UGREEN 现为 `192.168.5.17`）。

## 本地识图（可选组件）
dsh 智能体/命令行可用的本地"看图"工具：Qwen2.5-VL-3B 纯 CPU 推理，支持图片描述、问答、中英文 OCR，图片不离开本机。安装与用法见 [docs/vision.md](docs/vision.md)。

```sh
bash scripts/vision-setup.sh    # 一次性安装（约 8GB）
scripts/see.sh 图片.jpg --question "这张图里有什么？"   # 注意：默认是 OCR，问答需 --mode vision
```
