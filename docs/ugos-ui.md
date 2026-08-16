# 绿联 NAS（UGOS Pro）UI 显示说明

切换后，deepseek-harness 智能体在 UGOS Docker 应用中的显示情况：

## 1. 容器视图（Docker → 容器）

| 项 | 切换前 | 切换后 |
|---|---|---|
| 名称 | deepseek-harness | deepseek-harness（不变） |
| 镜像 | dsh-local:latest | **ghcr.io/llzg/dsh-docker:latest** |
| 状态 | 运行中 | 运行中 + **健康**（镜像内置 HEALTHCHECK） |
| 端口 | 3081→3080 | 3081→3080（不变） |

## 2. 镜像视图（Docker → 镜像）

- `ghcr.io/llzg/dsh-docker:latest` —— 当前跟随的版本（可变标签）
- `ghcr.io/llzg/dsh-docker:0.1.0-rc.6` —— 不可变版本标签（保留用于回滚）
- 每个镜像带 OCI 标签：`org.opencontainers.image.version`（版本）、`revision`（构建提交）、`description`（用途）

## 3. 项目视图（Docker → 项目）

- 项目 `deepseek-harness`（compose 项目，路径 `/volume1/docker/deepseek-harness`）不变，UGOS 里可一键启动/停止。

## 4. 自动更新在 UI 中的表现

- watchtower 更新后，容器「镜像」列自动变为新版本标签（如 `ghcr.io/llzg/dsh-docker:0.1.0-rc.7`）。
- 回滚钉住时镜像列显示被钉住的版本（如 `…:0.1.0-rc.5`），直到 `resume-auto-update.sh` 恢复。

> 提示：UGOS 的 Docker 视图直接读取 docker daemon 状态，无需任何额外配置；容器/镜像/项目三个视图会自动同步。
