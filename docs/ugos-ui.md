# 绿联 NAS（UGOS Pro）UI 显示说明（双通道）

每通道一个 compose 项目，UGOS Docker 里会同时看到两条：

## 1. 容器视图（Docker → 容器）

| 通道 | 容器名 | 镜像 | 端口 | 状态 |
|---|---|---|---|---|
| alpha | `dsh-alpha` | `ghcr.io/llzg/dsh-docker:0.1.3-alpha.2`（示例） | 3081→3080 | 运行中 + **健康**（镜像内置 HEALTHCHECK） |
| rc | `dsh-rc` | `ghcr.io/llzg/dsh-docker:0.1.2-rc.1`（示例） | 3083→3080 | 运行中 + **健康** |
| alpha（版本页） | 同 `dsh-alpha` | — | 3082→3082 | 版本页，同时渲染 alpha + rc 两条通道 |

## 2. 镜像视图（Docker → 镜像）

- `ghcr.io/llzg/dsh-docker:<version>` —— 版本标签（回滚可用）
- `ghcr.io/llzg/dsh-docker:<version>-<sha>` —— **不可变**标签（回滚首选，内容永不覆盖）
- `latest` —— 仅 stable 通道发布；**不是**自动更新指针、**不是**回滚依据
- 每个镜像带 OCI 标签：`org.opencontainers.image.version`（版本）、`revision`（构建提交）、`channel`（通道）、`description`（用途）

## 3. 项目视图（Docker → 项目）

- 项目名 = 通道名：`dsh-alpha`、`dsh-rc`（compose 项目路径 `/volume1/docker/dsh-alpha`、`/volume1/docker/dsh-rc`），UGOS 里可分别一键启动/停止。
- 部署脚本一律用显式 `-p <project> --project-directory <dir>` 调用 compose，避免 UGOS「重启项目」时把项目名/卷路径解析错。

## 4. 更新在 UI 中的表现

- DSH 容器**不再由 watchtower 更新**（`com.centurylinklabs.watchtower.enable=false`）；新版本由 `dsh-safe-deploy promote --channel <ch>` 切换。
- 回滚钉住时镜像列显示被钉住的版本，直到 `DSH_CHANNEL=<ch> sh resume-auto-update.sh` 恢复（恢复到该通道 SSOT 的 `production`，而不是 `latest`）。
- 版本页 <http://<NAS-IP>:3082/> 可看到两条通道的当前/候选/风险/测试/回滚状态，以及「推荐构建目标是否已在 GHCR 上发布」「最近一次 CI 结论」。

> 提示：UGOS 的 Docker 视图直接读取 docker daemon 状态，无需任何额外配置；容器/镜像/项目三个视图会自动同步。
