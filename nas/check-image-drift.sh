#!/bin/sh
# check-image-drift.sh —— 检查"运行中的 DSH 容器"与"它引用的镜像 tag"是否已经漂移。
#
# 为什么需要（2026-09-10 实测踩到）：
#   DSH 的镜像 tag 是**可变**的 —— CI 用同一个版本号重建时会重推同一个 tag
#   （例：`:0.1.5-alpha.2` 在容器创建之后又被重推过一次）。容器一旦创建就固定在
#   当时的镜像 ID 上，tag 却会被后来的构建改写，于是 `docker ps` 里还写着
#   0.1.5-alpha.2，实际跑的却是更早/更晚的一次构建 —— 版本号对不上真实内容。
#
# 用法（在 dsh-deploy 目录下）：
#   sh check-image-drift.sh                 # 全部通道（容器名从 SSOT 读）；只看本地
#   sh check-image-drift.sh --remote        # 先 docker pull 各 tag 再比（能发现 registry 上的新构建）
#   sh check-image-drift.sh alpha rc        # 指定通道
#   sh check-image-drift.sh --record        # 把当前部署事实写入 state/deployed-images.json
#
# 退出码：0 = 一致；1 = 存在漂移；2 = 用法/环境错误。
#
# 环境变量：
#   DSH_SSOT        SSOT 路径（默认 $REPO_DIR/dsh-version.json）
#   DSH_STATE_DIR   记录输出目录（默认 $REPO_DIR/state）
set -u

# 定位部署目录：脚本在仓库里是 nas/（上一层是仓库根），在宿主上是平铺的 dsh-deploy/
# （与 dsh-version.json、.env 同级）—— 两种布局都要认，否则 SSOT 找不到。
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/dsh-version.json" ] || [ -f "$SELF_DIR/.env" ] || [ -f "$SELF_DIR/dsh-deploy" ]; then
  REPO_DIR="$SELF_DIR"
else
  REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"
fi
SSOT="${DSH_SSOT:-$REPO_DIR/dsh-version.json}"
STATE_DIR="${DSH_STATE_DIR:-$REPO_DIR/state}"

REMOTE=0
RECORD=0
CHANNELS=""
for arg in "$@"; do
  case "$arg" in
    --remote) REMOTE=1 ;;
    --record) RECORD=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    --*) echo "未知参数: $arg" >&2; exit 2 ;;
    *) CHANNELS="$CHANNELS $arg" ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "需要 node 解析 SSOT" >&2; exit 2; }
[ -f "$SSOT" ] || { echo "找不到 SSOT: $SSOT" >&2; exit 2; }

# 通道 → 容器名（支持 legacy 顶层字段，交给 node 归一化）
pairs="$(node -e '
  const fs=require("fs");
  let j; try { j=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch(e){ process.exit(2); }
  let ch=j.channels;
  if(!ch){ // legacy：单通道顶层字段
    ch={ [j.channel||"alpha"]: { container: j.container || "deepseek-harness-alpha", production: j.production || j.version } };
  }
  const want=process.argv.slice(2);
  for (const [k,v] of Object.entries(ch)) {
    if (want.length && !want.includes(k)) continue;
    console.log(`${k}\t${v.container || ("dsh-"+k)}`);
  }
' "$SSOT" $CHANNELS 2>/dev/null)" || { echo "解析 SSOT 失败（需要 .channels.<ch>.container）" >&2; exit 2; }

[ -n "$pairs" ] || { echo "SSOT 里没有匹配的通道" >&2; exit 2; }

drift=0
records=""

printf '%s\n' "$pairs" | while IFS="$(printf '\t')" read -r ch container; do
  [ -n "$container" ] || continue
  if ! docker inspect "$container" >/dev/null 2>&1; then
    printf '  [%-5s] %-24s 容器不存在\n' "$ch" "$container"
    echo "MISSING $ch" >> /tmp/.dsh-drift.$$
    continue
  fi
  running_id=$(docker inspect "$container" --format '{{.Image}}')
  ref=$(docker inspect "$container" --format '{{.Config.Image}}')
  state=$(docker inspect "$container" --format '{{.State.Status}}')

  if [ "$REMOTE" = "1" ]; then
    docker pull -q "$ref" >/dev/null 2>&1 || true
  fi
  tag_id=$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null || echo "")

  if [ -z "$tag_id" ]; then
    printf '  [%-5s] %-24s 本地无此 tag（%s）—— 无法比较\n' "$ch" "$container" "$ref"
    continue
  fi

  if [ "$running_id" = "$tag_id" ]; then
    printf '  [%-5s] %-24s ✓ 一致  %s  %s\n' "$ch" "$container" "${running_id#sha256:}" "$state"
  else
    printf '  [%-5s] %-24s ✗ 漂移  运行=%s  tag=%s  (%s)\n' \
      "$ch" "$container" "$(echo "$running_id" | cut -c8-19)" "$(echo "$tag_id" | cut -c8-19)" "$ref"
    echo "DRIFT $ch" >> /tmp/.dsh-drift.$$
  fi

  if [ "$RECORD" = "1" ]; then
    digest=$(docker image inspect "$ref" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null)
    ver=$(docker inspect "$container" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
    [ -n "$ver" ] || ver=$(node -e '
      const fs=require("fs");let j;try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){process.exit(0)}
      const c=(j.channels&&j.channels[process.argv[2]])||{};process.stdout.write(c.production||"")' "$SSOT" "$ch" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ch" "$container" "$ver" "$ref" "$running_id" "$digest" >> /tmp/.dsh-rec.$$
  fi
done

[ -f /tmp/.dsh-drift.$$ ] && drift=1
if grep -q DRIFT /tmp/.dsh-drift.$$ 2>/dev/null; then drift=1; fi
if grep -q MISSING /tmp/.dsh-drift.$$ 2>/dev/null; then drift=1; fi

if [ "$RECORD" = "1" ] && [ -f /tmp/.dsh-rec.$$ ]; then
  mkdir -p "$STATE_DIR"
  node -e '
    const fs=require("fs");
    const lines=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean);
    const out={ schemaVersion:1, updatedAt:new Date().toISOString(),
                note:"部署事实记录：容器实际运行镜像与它引用的 tag。tag 可变，故同时记 imageId。",
                channels:{} };
    for (const l of lines) {
      const [ch,container,version,ref,id,digest]=l.split("\t");
      out.channels[ch]={ channel:ch, container, version, imageRef:ref, imageId:id, repoDigest:digest||null };
    }
    const p=process.argv[2];
    fs.writeFileSync(p, JSON.stringify(out,null,2)+"\n");
    console.log("  已写入 "+p);
  ' /tmp/.dsh-rec.$$ "$STATE_DIR/deployed-images.json"
fi

rm -f /tmp/.dsh-drift.$$ /tmp/.dsh-rec.$$
if [ "$drift" = "1" ]; then
  echo "  结果：存在漂移/缺失 —— tag 指向的构建与运行中的不一致（重建容器即可对齐）"
  exit 1
fi
echo "  结果：全部一致"
exit 0
