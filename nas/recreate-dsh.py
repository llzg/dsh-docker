#!/usr/bin/env python3
# recreate-dsh.py —— 用"克隆现有容器配置 + 只改 NO_PROXY"的方式重建 DSH 容器。
#
# 为什么需要它：两个 DSH 容器是 docker run 起的（非 compose），且 host 网络的 proxy 用
# **固定 IP** 反代它们（172.27.0.4/.5）。重建时必须逐字段复制（env/挂载/设备/网络/重启策略/
# 日志/资源限制）并钉住同一 IP，否则 3081/3083 会断。
#
# 用法：
#   python3 recreate-dsh.py plan  <container>     # 只打印计划（密钥脱敏）
#   python3 recreate-dsh.py apply <container>     # 执行（旧容器改名保留，可回滚）
#   python3 recreate-dsh.py rollback <container>  # 回滚到被保留的旧容器
#
# 环境变量：
#   NO_PROXY_ADD  追加到 NO_PROXY/no_proxy 的条目（默认 api.deepseek.com,172.27.0.0/16）
import json, subprocess, sys, time, os, re

NO_PROXY_ADD = os.environ.get("NO_PROXY_ADD", "api.deepseek.com,172.27.0.0/16")
SECRET_RE = re.compile(r"(TOKEN|PASSWORD|SECRET|KEY|CREDENTIAL)", re.I)


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

    for kv in cfg.get("Env") or []:
        k, _, v = kv.partition("=")
        if k in ("NO_PROXY", "no_proxy"):
            v = aug_no_proxy(v)
        argv += ["--env", f"{k}={v}"]

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
    if test:
        if test[0] == "CMD-SHELL" and len(test) == 2:
            argv += ["--health-cmd", test[1]]
        elif test[0] == "CMD":
            argv += ["--health-cmd", " ".join(test[1:])]
        elif test[0] == "NONE":
            argv += ["--no-healthcheck"]
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
    argv.append(cfg["Image"])
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
    print(f"== 重建 {name} ==")
    # 关键：生产容器 /opt/patch-dsh.sh 在**可写层**里被替换过（含 token-pinning），
    # 镜像自带的不含 → 不抢救回去，DSH 会生成新 token，proxy 的 BOOTSTRAP_TOKEN 失配 → 401。
    patch_tmp = f"/volume1/docker/dsh-deploy/.patch-rescue-{name}-{ts}.sh"
    print(f"  0) 抢救旧容器 /opt/patch-dsh.sh -> {patch_tmp}")
    r = subprocess.run(["docker", "cp", f"{name}:/opt/patch-dsh.sh", patch_tmp], capture_output=True, text=True)
    have_patch = r.returncode == 0
    if not have_patch:
        print(f"     !! 抢救失败：{r.stderr.strip()}（将不注入补丁，可能 401）")
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
    olds = d("ps", "-a", "--filter", f"name={name}.pre-noproxy-", "--format", "{{.Names}}").splitlines()
    if not olds:
        raise SystemExit("找不到被保留的旧容器（*.pre-noproxy-*）")
    old = olds[0]
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
