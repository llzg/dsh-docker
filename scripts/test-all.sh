#!/bin/sh
# 一键跑全部测试（本地 / CI 通用）。
# 依赖：node（含仓库内 node_modules/semver 或镜像 /opt/node_modules/semver）、bash、curl。
# 需要联网的用例：test-version-policy.js（npm/GitHub 真实查询）、test-version-server.js（GHCR/CI 状态）。
set -eu
cd "$(dirname "$0")/.."

fails=0
run() {
  echo ""
  echo "==================================================================="
  echo ">>> $*"
  echo "==================================================================="
  if "$@"; then
    echo "--- OK: $*"
  else
    echo "--- FAILED: $*" >&2
    fails=$((fails + 1))
  fi
}

# 静态检查
run node --check scripts/version-policy.js
run node --check scripts/safe-deploy-policy.js
run node --check scripts/registry.js
run node --check scripts/version-server.js
run node --check scripts/check-new-version.js
run node --check scripts/test-dual-channel.js
run sh -n nas/lib.sh
run sh -n nas/install.sh
run sh -n nas/switch.sh
run sh -n nas/rollback.sh
run sh -n nas/resume-auto-update.sh
run sh -n nas/watchdog.sh
run sh -n nas/watchdog-container.sh
run bash -n scripts/dsh-safe-deploy
run bash -n patch-dsh.sh

# 策略/契约测试
run node scripts/test-registry.js
run node scripts/test-dual-channel.js
run node scripts/test-version-server.js
run node scripts/test-version-policy.js
run bash scripts/test-dsh-safe-deploy.sh
run bash scripts/test-nas-deploy.sh
run bash scripts/test-migration.sh

echo ""
if [ "$fails" -eq 0 ]; then
  echo "===== ALL TESTS PASSED ====="
  exit 0
fi
echo "===== $fails 个测试套件失败 =====" >&2
exit 1
