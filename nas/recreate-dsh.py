#!/usr/bin/env python3
# recreate-dsh.py —— 用"克隆现有容器配置 + 换镜像/改 NO_PROXY"的方式重建 DSH 容器。
#
# 为什么需要它：两个 DSH 容器是 docker run 起的（非 compose），且 host 网络的 proxy 用
# **固定 IP** 反代它们（172.27.0.4/.5）。重建时必须逐字段复制（env/挂载/设备/网络/重启策略/
# 日志/资源限制）并钉住同一 IP，否则 3081/3083 会断。
#
# （compose 化的 Phase 2 尚未落地：dsh-deploy/docker-compose.yml 里是 ports: 3081:3080 的
#   目标形态，与当前"host 网络 proxy + 固定 IP 反代"并存会抢 3081 端口，故升级仍走本脚本。）
#
# 用法：
#   python3 recreate-dsh.py plan  <container>     # 只打印计划（密钥脱敏）
#   python3 recreate-dsh.py apply <container>     # 执行（旧容器改名保留，可回滚）
#   python3 recreate-dsh.py rollback <container>  # 回滚到被保留的旧容器
#
# 环境变量：
#   NO_PROXY_ADD  追加到 NO_PROXY/no_proxy 的条目（默认 api.deepseek.com,172.27.0.0/16；
#                 容器里已有这些条目时是 no-op）
#   NEW_IMAGE     用指定镜像替换原镜像（**版本升级用这个**）。
#                 例：NEW_IMAGE=192.168.5.35:5050/llzg/dsh-docker:0.1.5-alpha.2
#   RESCUE_PATCH  默认 1：把旧容器**可写层**里的 /opt/patch-dsh.sh 抢救并注入新容器。
#                 仅当新镜像**没有**内置补丁时才需要（历史上生产容器的补丁是手工塞进
#                 可写层的，镜像自带的没有 token-pinning → 不抢救就会 401）。
#                 现在 CI 构建时已 STRICT 应用全部补丁，**跨版本升级必须设 RESCUE_PATCH=0**：
#                 旧补丁是照旧版本 node_modules 写的，注入到新版本上反而会打错补丁。
#   ENV_SET       新增/覆盖环境变量，逗号分隔的 KEY=VALUE（例：给版本页加 DSH_REGISTRIES）。
#                 值里不能有逗号。用法：
#                   ENV_SET='DSH_REGISTRIES=ghcr.io/llzg/dsh-docker,192.168.5.35:5050/llzg/dsh-docker'
#                 ⚠ 逗号是分隔符 → 含逗号的值请改用 ENV_SET_<N>（见下）或先写成文件。
#   HEALTH_CMD    覆盖探活命令（仅用于修正本就写错的探活）。例：
#                   HEALTH_CMD="node -e \"fetch('http://127.0.0.1:3081/').then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))\""
#                 背景：dsh-proxy 的探活是从 dsh 容器抄来的 127.0.0.1:3080，但 proxy 监听
#                 的是 3081/3083 → 永远 unhealthy（状态失真，会误导看门狗/人工判断）。
import json, subprocess, sys, time, os, re

NO_PROXY_ADD = os.environ.get("NO_PROXY_ADD", "api.deepseek.com,172.27.0.0/16")
NEW_IMAGE = (os.environ.get("NEW_IMAGE") or "").strip()
RESCUE_PATCH = os.environ.get("RESCUE_PATCH", "1") != "0"
HEALTH_CMD = (os.environ.get("HEALTH_CMD") or "").strip()
SECRET_RE = re.compile(r"(TOKEN|PASSWORD|SECRET|KEY|CREDENTIAL)", re.I)


def parse_env_set():
    """ENV_SET='K1=V1,K2=V2'（值不含逗号）；ENV_SET_1='K=V' 可传含逗号的值。"""
    out = {}
    for name, raw in os.environ.items():
        if name != "ENV_SET" and not re.fullmatch(r"ENV_SET_\d+", name):
            continue
        for item in (raw or "").split(",") if name == "ENV_SET" else [raw]:
            item = (item or "").strip()
            if not item:
                continue
            k, sep, v = item.partition("=")
            if sep:
                out[k.strip()] = v
    return out


ENV_SET = parse_env_set()


def d(*args, check=True):
    r = subprocess.run(["docker", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"docker {' '.join(args)} 失败: {r.stderr.strip()}")
    return r.stdout.strip()


def inspect(name):
    return json.loads(d("inspect", name))[0]


def redact(kv):
    k, sep, v = kv.partition("=")
    if sep and SECRET_RE.search(k):
        return f"{k}=<redacted:{len(v)}B>"
    return kv


def aug_no_proxy(v):
    parts = [p for p in v.split(",") if p]
    for extra in NO_PROXY_ADD.split(","):
        if extra and extra not in parts:
            parts.append(extra)
    return ",".join(parts)


def build_argv(c):
    cfg, hc = c["Config"], c["HostConfig"]
    img_cfg = json.loads(d("image", "inspect", cfg["Image"]))[0]["Config"]
    net = hc.get("NetworkMode", "bridge")
    argv = ["run", "-d", "--name", c["Name"].lstrip("/")]

    rp = hc.get("RestartPolicy") or {}
    if rp.get("Name"):
        spec = rp["Name"]
        if rp.get("Name") == "on-failure" and rp.get("MaximumRetryCount"):
            spec += f":{rp['MaximumRetryCount']}"
        argv += ["--restart", spec]

    argv += ["--network", net]
    for _, n in ((c.get("NetworkSettings") or {}).get("Networks") or {}).items():
        if n.get("IPAddress") and net != "host":
            argv += ["--ip", n["IPAddress"]]

    seen = set()
    for kv in cfg.get("Env") or []:
        k, _, v = kv.partition("=")
        seen.add(k)
        if k in ("NO_PROXY", "no_proxy"):
            v = aug_no_proxy(v)
        # ENV_SET 里显式指定的键，稍后统一覆盖（这里先跳过旧值）
        if k in ENV_SET:
            continue
        argv += ["--env", f"{k}={v}"]
    # ENV_SET：新增/覆盖环境变量（例如给版本页加 DSH_REGISTRIES/凭据）
    for k, v in ENV_SET.items():
        argv += ["--env", f"{k}={v if v != '' else ''}"]
        if k not in seen:
            print(f"     + 新增 env: {k}={redact(f'{k}={v}').partition('=')[2][:40]}")

    for m in c.get("Mounts") or []:
        spec = f"{m['Source']}:{m['Destination']}"
        if m.get("Mode"):
            spec += f":{m['Mode']}"
        argv += ["-v", spec]
    for dev in hc.get("Devices") or []:
        argv += ["--device", f"{dev['PathOnHost']}:{dev['PathInContainer']}:{dev.get('CgroupPermissions', 'rwm')}"]
    if hc.get("Privileged"):
        argv.append("--privileged")
    for cap in hc.get("CapAdd") or []:
        argv += ["--cap-add", cap]
    for cap in hc.get("CapDrop") or []:
        argv += ["--cap-drop", cap]
    for so in hc.get("SecurityOpt") or []:
        argv += ["--security-opt", so]
    # HEALTHCHECK：必须克隆！生产容器把镜像自带的 HTTP 探活改成了 TCP 探活
    # （DSH 0.1.2-alpha.3+ 起 "/" 无 token 返回 401，镜像自带的 fetch(...r.ok) 恒失败）
    health = cfg.get("Healthcheck") or {}
    test = health.get("Test") or []
    if HEALTH_CMD:
        # 显式覆盖探活命令（用于修正本来就写错的探活：例如 dsh-proxy 的探活去戳
        # 127.0.0.1:3080，但 proxy 监听的是 3081/3083 → 永远 unhealthy）。
        argv += ["--health-cmd", HEALTH_CMD]
        for flag, key in (("--health-interval", "Interval"), ("--health-timeout", "Timeout"),
                          ("--health-start-period", "StartPeriod")):
            if health.get(key):
                argv += [flag, f"{health[key]}ns"]
        if health.get("Retries"):
            argv += ["--health-retries", str(health["Retries"])]
        test = []
    if test:
        # ⚠ Docker 语义：--no-healthcheck 与 --health-* 互斥（同时给会直接报
        #   "conflicts with --health-* options" 且容器创建失败——版本页容器就踩过）。
        #   所以 Test==["NONE"] 时只输出 --no-healthcheck，其余 health-* 全部跳过。
        if test[0] == "NONE":
            argv += ["--no-healthcheck"]
        else:
            if test[0] == "CMD-SHELL" and len(test) == 2:
                argv += ["--health-cmd", test[1]]
            elif test[0] == "CMD":
                argv += ["--health-cmd", " ".join(test[1:])]
            for flag, key in (("--health-interval", "Interval"), ("--health-timeout", "Timeout"),
                              ("--health-start-period", "StartPeriod")):
                if health.get(key):
                    argv += [flag, f"{health[key]}ns"]
            if health.get("Retries"):
                argv += ["--health-retries", str(health["Retries"])]

    lc = hc.get("LogConfig") or {}
    if lc.get("Type"):
        argv += ["--log-driver", lc["Type"]]
        for k, v in (lc.get("Config") or {}).items():
            argv += ["--log-opt", f"{k}={v}"]
    if hc.get("Memory"):
        argv += ["--memory", str(hc["Memory"])]
    if hc.get("NanoCpus"):
        argv += ["--cpus", str(hc["NanoCpus"] / 1e9)]
    for k, v in (cfg.get("Labels") or {}).items():
        # 不克隆 org.opencontainers.image.* —— 那是**旧镜像**的版本/commit 元数据，
        # 换镜像后会变成假信息（版本页/排障会读到错的 version/revision）。
        # 这些标签新镜像自己带（Dockerfile 里 LABEL），让它们自然生效。
        # 其余标签（如 watchtower.enable=false）必须保留。
        if k.startswith("org.opencontainers.image."):
            continue
        argv += ["--label", f"{k}={v}"]
    if cfg.get("Hostname") and net != "host":
        argv += ["--hostname", cfg["Hostname"]]
    if cfg.get("User"):
        argv += ["--user", cfg["User"]]
    if cfg.get("WorkingDir"):
        argv += ["--workdir", cfg["WorkingDir"]]

    # entrypoint / cmd：只有与镜像默认不同才显式传（避免破坏默认语义）
    ep = cfg.get("Entrypoint") or None
    if ep != (img_cfg.get("Entrypoint") or None) and ep:
        if len(ep) != 1:
            raise SystemExit(f"暂不支持多元素 entrypoint 克隆: {ep}")
        argv += ["--entrypoint", ep[0]]
    argv.append(NEW_IMAGE or cfg["Image"])
    cmd = cfg.get("Cmd") or []
    if cmd and cmd != (img_cfg.get("Cmd") or []):
        argv += cmd
    return argv


def show(argv):
    out, skip = [], False
    for i, a in enumerate(argv):
        if skip:
            skip = False
            continue
        if a == "--env":
            out += [a, redact(argv[i + 1])]
            skip = True
        else:
            out.append(a)
    return "docker " + " ".join(out)


def plan(name):
    c = inspect(name)
    cfg, hc = c["Config"], c["HostConfig"]
    nets = (c.get("NetworkSettings") or {}).get("Networks") or {}
    print(f"== 计划：重建 {name} ==")
    print(f"  image      : {cfg['Image']}")
    print(f"  network    : {hc.get('NetworkMode')}  ip={[n.get('IPAddress') for n in nets.values()]}")
    print(f"  restart    : {(hc.get('RestartPolicy') or {}).get('Name')}")
    print(f"  entrypoint : {cfg.get('Entrypoint')}  cmd={cfg.get('Cmd')}")
    print("  env:")
    for kv in cfg.get("Env") or []:
        k = kv.split("=", 1)[0]
        mark = f"   ← 追加 {NO_PROXY_ADD}" if k in ("NO_PROXY", "no_proxy") else ""
        print(f"    {redact(kv)}{mark}")
    print("  mounts:")
    for m in c.get("Mounts") or []:
        print(f"    {m['Source']} -> {m['Destination']} ({m.get('Mode')})")
    print("  devices    :", [f"{x['PathOnHost']}:{x['PathInContainer']}" for x in (hc.get('Devices') or [])])
    print("  privileged :", hc.get("Privileged"), "| cap_add:", hc.get("CapAdd"), "| log:", (hc.get('LogConfig') or {}).get('Type'))
    hchk = (cfg.get("Healthcheck") or {}).get("Test")
    print("  healthcheck:", (hchk[1][:70] + "...") if hchk and len(hchk) > 1 else hchk)
    print()
    print("  等价命令（密钥已脱敏）：")
    print("    " + show(build_argv(c)))


def apply(name):
    c = inspect(name)
    ts = time.strftime("%Y%m%d-%H%M%S")
    old = f"{name}.pre-noproxy-{ts}"
    argv = build_argv(c)
    ips = [n.get("IPAddress") for n in ((c.get("NetworkSettings") or {}).get("Networks") or {}).values()]
    old_image = c["Config"]["Image"]
    print(f"== 重建 {name} ==")
    print(f"  镜像: {old_image}" + (f"  ->  {NEW_IMAGE}" if NEW_IMAGE else "  (未指定 NEW_IMAGE，沿用原镜像)"))
    if NEW_IMAGE and NEW_IMAGE == old_image:
        print("  !! NEW_IMAGE 与原镜像相同，等于原地重建（没有版本变化）")
    patch_tmp = f"/volume1/docker/dsh-deploy/.patch-rescue-{name}-{ts}.sh"
    have_patch = False
    if RESCUE_PATCH:
        # 历史背景：生产容器 /opt/patch-dsh.sh 曾在**可写层**里被替换过（含 token-pinning），
        # 老镜像自带的不含 → 不抢救回去，DSH 会生成新 token，proxy 的 BOOTSTRAP_TOKEN 失配 → 401。
        # 现在 CI 构建已 STRICT 应用全部补丁（镜像内可选 dsh-docker-patch:* marker），
        # 跨版本升级请用 RESCUE_PATCH=0，否则会把旧版本的补丁打到新版本上。
        print(f"  0) 抢救旧容器 /opt/patch-dsh.sh -> {patch_tmp}")
        r = subprocess.run(["docker", "cp", f"{name}:/opt/patch-dsh.sh", patch_tmp], capture_output=True, text=True)
        have_patch = r.returncode == 0
        if not have_patch:
            print(f"     !! 抢救失败：{r.stderr.strip()}（将不注入补丁，可能 401）")
    else:
        print("  0) 跳过补丁抢救（RESCUE_PATCH=0）—— 前提：新镜像构建时已 STRICT 应用补丁")
    print(f"  1) 旧容器改名保留：{name} -> {old}")
    d("rename", name, old)
    print(f"  2) 停旧容器（释放 IP {ips}）")
    d("stop", old)
    print("  3) 起新容器")
    cid = d(*argv)
    print(f"     new id={cid[:12]}")
    if have_patch:
        print("  3b) 注入抢救出的补丁并重启（让 entrypoint 重新应用 token-pinning）")
        d("cp", patch_tmp, f"{name}:/opt/patch-dsh.sh")
        d("chmod", "755", f"{name}:/opt/patch-dsh.sh", check=False)
        d("restart", name)
    for i in range(1, 31):
        st = d("inspect", name, "--format",
               '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', check=False)
        print(f"     [{i}] {st}")
        if st.startswith("running|healthy") or st.startswith("running|none"):
            break
        time.sleep(4)
    print(f"  完成。回滚：python3 {sys.argv[0]} rollback {name}")


def rollback(name):
    # ⚠ 可能同时存在多代救援容器（例如 132330 与刚才这代）→ 必须回滚到**最近一代**，
    #   否则会滚到更早的版本。按 CreatedAt 倒序取第一个。
    rows = d("ps", "-a", "--filter", f"name={name}.pre-noproxy-",
             "--format", "{{.Names}}\t{{.CreatedAt}}").splitlines()
    if not rows:
        raise SystemExit("找不到被保留的旧容器（*.pre-noproxy-*）")
    old = sorted(rows, key=lambda r: r.split("\t")[1], reverse=True)[0].split("\t")[0]
    if len(rows) > 1:
        print(f"  注意：存在 {len(rows)} 代救援容器，选最近一代 {old}")
        for r in rows:
            print(f"    - {r.split(chr(9))[0]}")
    print(f"== 回滚：删新容器 {name}，恢复 {old} ==")
    d("rm", "-f", name, check=False)
    d("rename", old, name)
    d("start", name)
    print("已回滚。")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd, name = sys.argv[1], sys.argv[2]
    {"plan": plan, "apply": apply, "rollback": rollback}[cmd](name)
