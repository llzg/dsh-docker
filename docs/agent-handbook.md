# DSH CI/CD Agent Handbook

> **Audience: automation agents.** Exact commands, paths, exit codes, invariants and symptom→fix
> mappings for the `llzg/dsh-docker` build/deploy chain. No narrative — every statement is either a
> command you can run or a rule you must not break. Human-readable narrative lives in
> `docs/homelab-ci.md` (CI/CD) and `docs/dual-channel-migration.md` (ops runbooks); this file is the
> machine-actionable subset plus the invariants those docs established empirically.

---

## 0. Topology (verify before acting)

| Role | Address | Notes |
|---|---|---|
| Compute host (containers, runner, BuildKit) | `192.168.5.17` | SSH as `lzg`; sudo requires the human's password (never store it in a file/commit) |
| Storage host (Gitea, docker registry) | `192.168.5.35` | Gitea `:3000`; registry `:5050` **plain HTTP + Basic auth**; pull-through cache `:5051` |
| Egress proxy (OpenClash) | `192.168.5.36:7893` | required for GitHub/apt/npm; internal ranges must stay in `NO_PROXY` |
| Git remote | `github.com/llzg/dsh-docker` | PAT in `/home/lzg/.git-credentials` (scopes `repo, workflow, write:packages`) |
| Internal registry repo | `192.168.5.35:5050/llzg/dsh-docker` | production pulls from here |
| Public registry repo | `ghcr.io/llzg/dsh-docker` | mirror / offsite backup; anonymous read OK |

```sh
# Preflight: confirm the host you are on and that both registries answer
ssh -i ~/.ssh/dsh_deploy_ed25519 lzg@192.168.5.17 'hostname; docker ps --format "{{.Names}}" | head'
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.5.35:5050/v2/          # 401 = reachable (needs auth)
curl -s -o /dev/null -w '%{http_code}\n' -x http://192.168.5.36:7893 https://registry.npmjs.org/  # 200
```

`192.168.5.16` is **stale** — the host moved to `.17`. Never reintroduce `.16` into trusted-host /
SSOT / compose values (see §4.3).

---

## 1. Hard invariants (do not violate; each one cost a production incident)

1. **Never rewrite a DSH session `*.zstd` file without preserving zstd framing.**
   The first frame must contain **exactly the header line**; DSH asserts this. A single-frame file makes
   `dsh-workspace` throw `corrupt Zstandard session log` at boot and **the whole DSH fails to start**
   (not just that one session). Verify after any write: `zstd -l -v <file>` reports ≥2 frames **and**
   decompressed line 1 is the `{"type":"session",...}` header.
2. **Never trust "0 findings" from a workspace scan run as a non-root user.** Workspace dirs are
   `0700 root`; `fs.existsSync`/`readdirSync` silently fail and produce false negatives. Run scans
   **inside the container as root** (§5.2) or with sudo.
3. **Never use `node:zlib.zstdDecompressSync` to read multi-frame session logs** — it decodes only the
   first frame (measured: a 41035-line file yields 1 line) and silently hides every problem.
4. **Never `docker logout` the private registry from CI.** `docker/login-action` defaults to logging out
   in its post step, which deletes the `192.168.5.35:5050` entry from the **host** config and breaks
   production `docker pull` (`no basic auth credentials`). The workflow sets `logout: false`; keep it.
5. **Never put version/channel/commit-dependent `LABEL`/`ENV`, or the *declaration* of
   `DSH_VERSION`/`DSH_CHANNEL`/`GIT_REVISION`, before the stable layers** (apt, uv) in the `Dockerfile`.
   Enforced by `scripts/test-dockerfile-layers.sh`; violating it re-introduces 331s→ rebuilds and the
   "stuck in apt for 24 minutes" failure.
6. **Never set `DSH_VERSION_PORT` other than `0` on host-network containers** (`dsh-proxy`,
   `dsh-proxy-rc`). Their entrypoint would start a stale in-image version page on the host and squat
   `3082`, making the real `dsh-version` container restart-loop.
7. **`--trusted-host` must list every address users actually type.** `dsh-proxy` forwards the client's
   `Host` verbatim and DSH fences `/api/*` + WebSocket by it. Missing entry ⇒ `GET /` works but every
   API call and the socket return 403 (UI shows "reconnecting" / "cannot load agent presets").
8. **Never edit shipped presets** under the image (`.../dsh-agent-presets/presets/**`); upgrade
   overwrites them. Fix user copies under `<DSH_HOME>/.agent-presets/<id>/`.
9. **Never delete the newest `*.pre-compose-*` / `*.pre-noproxy-*` rollback container** without an
   explicit human instruction. They are the only rollback path for the current deployment.
10. **Never restart or recreate a production container without explicit authorization**, and never
    modify data under `/volume1/docker/*/dsh-data/**` outside the §6.2 procedure (backup first, verify
    after).
11. **Never touch the registry htpasswd yourself** — that host is not reachable from the agent side
    (§7.1).

---

## 2. Layout (absolute paths, host `192.168.5.17`)

| Path | What it is |
|---|---|
| `/volume1/docker/dsh-deploy/` | deploy directory: scripts, `.env`, SSOT symlink |
| `/volume1/docker/dsh-deploy/scripts/dsh-safe-deploy` | versioned promote/rollback tool (`check`/`test`/`promote`/`rollback`/`status`) |
| `/volume1/docker/dsh-deploy/.env` | deploy config, **whitelist-parsed** (`DSH_IMAGE_BASE`, `DSH_REGISTRIES`, `DSH_REGISTRY_*`), mode `600` |
| `/volume1/docker/dsh-deploy/dsh-version.json` | symlink → live SSOT |
| `/volume1/docker/dsh-alpha5/dsh-root/nas_docker/dsh-version.json` | **live SSOT** (root-owned; read via sudo/container) |
| `/volume1/docker/dsh-deploy/{realign.sh,check-image-drift.sh,preflight-workspace.js,repair-session-turns.js,rotate-registry-credential.sh,validate-relationships.mjs}` | operational tools (see §5); copies also live in `/volume1/docker/dsh-deploy/nas/` and in the repo under `nas/` |
| `/volume1/docker/dsh-deploy/state/deployed-images.json` | recorded deployment facts (version/imageRef/imageId/repoDigest) |
| `/volume1/docker/github-runner-dsh/` | self-hosted runner install (`disableUpdate=true` in `.runner` on purpose) |
| `/volume1/docker/dsh-docker-push/` | the host-side clone used to push commits to GitHub |

Channels (from the SSOT; container/project/data dir are authoritative):

| Channel | container | compose project | data dir | `DSH_HOME` (in container) | host port | loopback publish | `docker.sock` |
|---|---|---|---|---|---|---|---|
| alpha | `deepseek-harness-alpha` | `dsh-alpha` | `/volume1/docker/dsh-alpha5` | `/data/dsh/test/0.1.2-alpha.5` | 3081 | `127.0.0.1:13081` | **yes** |
| rc | `dsh-rc1` | `dsh-rc` | `/volume1/docker/deepseek-harness` | `/data/dsh` | 3083 | `127.0.0.1:13083` | no |
| (shared) | `dsh-version` | — (hand-written, host net) | — | — | 3082 | — | — |

Both channels run unprivileged proxies on the host network: `dsh-proxy` (3081) and `dsh-proxy-rc`
(3083), each forwarding `BACKEND=http://127.0.0.1:<that channel's loopback port>` with the
`BOOTSTRAP_TOKEN` (= the container's `DSH_LAUNCH_TOKEN`).

---

## 3. CI (GitHub Actions)

Workflow: `.github/workflows/build-publish.yml`. Runner: self-hosted `dsh-runner`
(labels `self-hosted,linux,x64,dsh-build`) — **one runner, so the matrix runs channels serially**.

Triggers: `schedule: */30` (convergence-gated), `workflow_dispatch` (`version`/`channel`/`force`),
`push` to `main` filtered by `paths:` (Dockerfile, `patch-dsh.sh`, `entrypoint.sh`, `profiles/**`,
`assets/**`, `scripts/**`, `dsh-version.json`, the workflow itself). **`docs/**` and `nas/**` do not
trigger builds** — keep it that way (it limits same-version tag churn).

Repo variables (expected state):

```
DSH_RUNNER          ["self-hosted","linux","x64","dsh-build"]
DSH_HTTP_PROXY      http://192.168.5.36:7893
DSH_PRIVATE_IMAGE   192.168.5.35:5050/llzg/dsh-docker
DSH_PRIVATE_REGISTRY 192.168.5.35:5050
DSH_PUSH_GHCR       1            # 0 = internal registry only (images only; source push unaffected)
DSH_REGISTRIES      ghcr.io/llzg/dsh-docker,192.168.5.35:5050/llzg/dsh-docker
```
Repo secrets: `DSH_REGISTRY_USER=ci-deploy`, `DSH_REGISTRY_PASSWORD=<rotate; see §7.1>`.

Jobs: `resolve` (policy/contract tests + `check-new-version.js`) → `build-publish (alpha|rc)`
(checkout → logins → builder select → build → smoke → push all tags → write status) → `record-status`
(merges `build-status-*.json`, commits `build-status.json` with `[skip ci]`).

```sh
# Trigger a forced rebuild of both channels (bypasses convergence)
TOKEN=$(sed -n 's#https://[^:]*:\([^@]*\)@github.com#\1#p' /home/lzg/.git-credentials | head -1)
curl -sS -X POST -H "Authorization: token $TOKEN" -H 'Accept: application/vnd.github+json' \
  -d '{"ref":"main","inputs":{"force":true}}' \
  https://api.github.com/repos/llzg/dsh-docker/actions/workflows/build-publish.yml/dispatches -o /dev/null -w '%{http_code}\n'
# Watch the newest run
curl -sS -H "Authorization: token $TOKEN" 'https://api.github.com/repos/llzg/dsh-docker/actions/runs?per_page=1' \
  | jq -r '.workflow_runs[0] | "\(.head_sha[0:7]) \(.status)/\(.conclusion // "-")"'
```

Expected durations after the cache fix: `resolve` ~25s, per-channel build 80–240s (warm cache),
`record-status` ~25s.

**Transient failures are expected to be absorbed.** `scripts/version-policy.js` retries link-level
failures (3 attempts, backoff) and `test-version-policy.js` marks npm *link* failures as SKIP (not
FAIL). If a run is red with `ECONNRESET`/timeout on the network tests, re-run it
(`POST /actions/runs/<id>/rerun-failed-jobs`) instead of "fixing" code. A genuine red is a FAIL on an
offline assertion (P*/T*/V*/R* test ids).

---

## 4. Deploy / runtime operations

### 4.1 Realign containers to the tag's current build (routine, safe)

Tags are **mutable**: CI re-pushing the same version moves the tag, so running containers fall one build
behind. Realign with one command:

```sh
cd /volume1/docker/dsh-deploy
sh realign.sh                # all channels: pull → compose up -d --wait → drift check → port probe
sh realign.sh rc             # one channel
sh realign.sh all --dry-run  # print the exact compose invocations, change nothing
```
Exit `0` = aligned. Idempotent: with no new build it returns in ~2s without recreating containers.
It reads `DSH_PROJECT`/`DSH_IMAGE` from the channel `.env` and `dataDir` from the SSOT, and appends
`docker-compose.docker-sock.yml` only where it exists (alpha yes, rc no).

### 4.2 Verify a channel end-to-end (never rely on HTTP status alone)

RPC endpoints are **envelopes**; failures arrive as `result.ok=false` with HTTP 200.

```sh
H='Host: 192.168.5.16:3083'          # MUST be an address users actually use (see §4.3)
# page + API + websocket
curl -s -o /dev/null -w 'page=%{http_code}\n' -H "$H" http://127.0.0.1:3083/
curl -s -X POST -H "$H" -H 'content-type: application/json' \
  -d '{"type":"client-request","rpcId":"p1","method":"session/modelCatalog","payload":{"args":{}}}' \
  http://127.0.0.1:3083/api/session/modelCatalog | jq -r '.result.ok, (.result.value.failures|length)'
curl -s -i -m 8 -H "$H" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:3083/api/remote.mux | head -1     # expect: HTTP/1.1 101
# model switch (triggers a session resume; args MUST be {request:{...}})
curl -s -X POST -H "$H" -H 'content-type: application/json' \
  -d '{"type":"client-request","rpcId":"p2","method":"session/selectModel","payload":{"args":{"request":{"sessionId":"<sid>","provider":"deepseek-official","model":"deepseek-v4-flash"}}}}' \
  http://127.0.0.1:3083/api/session/selectModel | jq -c '.result'
```
Errors: `gateway/arguments-invalid` = wrong payload shape; `ok:false` with `resume failed …` = workspace
problem (§6.3); 403 on `/api/*` but 200 on `/` = trusted-host fence (§4.3).

### 4.3 Symptom → diagnosis → fix

| Symptom | Diagnose | Fix |
|---|---|---|
| UI "reconnecting" / "cannot load agent presets"; `/api/*` 403, `/` 200 | `for h in 192.168.5.16:3081 192.168.5.17:3081; do curl -s -o /dev/null -w "$h=%{http_code}\n" -X POST -H "Host: $h" -H 'content-type: application/json' -d '{}' http://127.0.0.1:3081/api/agentPresets/list; done` → 403 means that Host is untrusted | set `DSH_TRUSTED_HOST="<addr1> <addr2>"` in the channel `.env` (space-separated; compose `command` deliberately leaves it unquoted) and `compose up -d` |
| Model switch fails; log/RPC says `persona … $.prefix missing required value` | `grep -A4 'id: persona' <data dir>/.agent-presets/*/agent.cordis.yml` | add `prefix:` (move the old `config.text` text into `prefix`/`suffix`, mirror the shipped `standard` preset), back up outside the workspace first |
| `Session migration from v2 to v3 refuses the transformed artifact: turn/start N does not open expected turn N-1` | `node /volume1/docker/dsh-deploy/preflight-workspace.js --home <host workspace>` | **v2+ only**: repair per §6.1. v0/v1 artifacts with the same shape are tolerated (verified) — warn only |
| `corrupt Zstandard session log: first frame is not exactly one header line` (whole DSH won't boot) | `zstd -l -v <session file>` → 1 frame | restore the `.orig` backup from `<data dir>/_session-backups/`, then repair properly per §6.1 |
| `docker pull … no basic auth credentials` | `jq -r '.auths|keys[]' /home/lzg/.docker/config.json` | ensure CI login step has `logout: false`; re-login: `printf '%s' "$PW" \| docker login 192.168.5.35:5050 -u ci-deploy --password-stdin`; run `rotate-registry-credential.sh` when rotating |
| Version page shows the old single-channel page; `dsh-version` restart-looping | `docker ps --format '{{.Names}} {{.Ports}}' \| grep 3082` is empty while `curl 127.0.0.1:3082` answers | a host-net container squats 3082: set `DSH_VERSION_PORT=0` on `dsh-proxy`/`dsh-proxy-rc` and recreate them |
| `docker ps` runs an older build than the tag | `sh check-image-drift.sh --remote` | `sh realign.sh` |
| Registry status shows both registries in the version page but ghcr 403 | `DSH_REGISTRY_USER/PASSWORD` are global and get sent to ghcr.io | `scripts/registry.js` already retries anonymously; if it regresses, keep `authUsed:false` fallback |
| CI red on `T3/T4/T5/T6/T15` with `ECONNRESET` | transient upstream | rerun the failed jobs |

---

## 5. Tool reference (all under `/volume1/docker/dsh-deploy/`)

### 5.1 `realign.sh` / `check-image-drift.sh`
```sh
sh realign.sh [alpha|rc|all] [--dry-run]        # exit 0 aligned, 1 not aligned, 2 usage
sh check-image-drift.sh [--remote] [--record] [channel...]   # 0 consistent, 1 drift/missing, 2 usage
```
`--record` writes `state/deployed-images.json` (per channel: version, imageRef, imageId, repoDigest).

### 5.2 `preflight-workspace.js` — upgrade readiness (run before every version bump)

```sh
# Preferred: inside the channel container as root (the container has no zstd CLI: copy the host's)
docker cp /usr/bin/zstd <container>:/tmp/dsh-zstd
docker cp /volume1/docker/dsh-deploy/preflight-workspace.js <container>:/tmp/pf.js
docker exec -e DSH_ZSTD_BIN=/tmp/dsh-zstd <container> node /tmp/pf.js --home /data/dsh
docker exec <container> rm -f /tmp/dsh-zstd /tmp/pf.js
# Host fallback (needs root, else it reports E1 instead of lying)
sudo node /volume1/docker/dsh-deploy/preflight-workspace.js --home /volume1/docker/<dir>/dsh-data
```
Checks / exit codes (`0` clean, `1` blockers, `2` environment):

| Code | Meaning | Severity |
|---|---|---|
| `P1` | preset persona missing `prefix` (or still using `text`) | fail |
| `P2` | preset dir missing `preset.yml` / `agent.cordis.yml` | fail |
| `S1` | session artifact has only 1 zstd frame | fail |
| `S2` | turn sequence discontinuous | **fail for v2+**, warn for v0/v1 (tolerated — verified) |
| `E1` | workspace dir unreadable (permission) → results are meaningless | fail |

Wired into `dsh-safe-deploy check` (runs it in-container; `DSH_PREFLIGHT_STRICT=1` makes findings fatal).

### 5.3 `repair-session-turns.js` — fix an unclosed turn (**v2+ only**)

```sh
node repair-session-turns.js <session.v2.jsonl.zstd>            # dry-run
node repair-session-turns.js <session.v2.jsonl.zstd> --apply    # backup outside sessions/, then write
```
Rules it enforces (do not bypass them by hand-editing):
- inserts exactly one `turn/end {turn, reason:{kind:"interrupted"}}` where the state is clean
  (`openStep === null`, no pending tool); refuses otherwise;
- renumbers `seq` densely **starting at 0** (header not counted);
- rewrites zstd as **two frames** (first = header line only) and refuses to write unless framing +
  round-trip self-checks pass;
- backup lands outside the sessions tree, and DSH writes its own `session.v3.jsonl.zstd` on first
  successful observe — that artifact appearing is your success signal.

### 5.4 `rotate-registry-credential.sh` — one command, five places

```sh
DSH_NEW_PASSWORD='…' sh rotate-registry-credential.sh --dry-run   # zero side effects
DSH_NEW_PASSWORD='…' sh rotate-registry-credential.sh             # verify login → .env → GH secrets → dsh-version
```
It **verifies the new password with `docker login` first** and aborts if it fails. It never touches the
registry host's htpasswd (that is the human's step — §7.1).

### 5.5 `dsh-safe-deploy` (versioned promote)
```sh
bash scripts/dsh-safe-deploy status  --channel all
bash scripts/dsh-safe-deploy check   --channel rc      # policy + workspace preflight
bash scripts/dsh-safe-deploy test    --channel rc      # snapshot + isolated instance + smoke
bash scripts/dsh-safe-deploy promote --channel rc      # gates → transactional pin → SSOT update
bash scripts/dsh-safe-deploy rollback --channel rc
```
Prefer `realign.sh` for "same version, newer build"; use `dsh-safe-deploy` for actual version changes.

---

## 6. Data operations (highest risk — follow exactly)

### 6.1 Session artifact repair (v2+)
1. Copy out, never edit in place without a copy:
   `sudo cp <session dir>/session.v2.jsonl.zstd /tmp/x.zstd && sudo chmod 644 /tmp/x.zstd`
2. Dry-run `repair-session-turns.js`; confirm the plan names the expected turn.
3. Apply; then validate with the container's **real** validator (not your own reimplementation):
   `zstd -dc /tmp/x.zstd | docker exec -i <container> node /tmp/validate-relationships.mjs`
   → expect `RELATIONSHIPS_OK`.
4. Install (backup outside `sessions/`), restart the container only if the session was already observed,
   then confirm the session resumes (`session/selectModel` returns `ok:true`).

### 6.2 Rules for anything under `<data dir>/`
- Backups go to `<data dir>/_session-backups/` or `_preset-backups/` — **never inside `sessions/`**
  (an extra file there can confuse the loader) and never with a `.jsonl.zstd` suffix inside a session dir.
- Preserve ownership/mode (`root:root`, `600` for session logs, `644` for preset yml).
- Keep zstd framing (invariant 1). A file that DSH cannot even read the header of takes the whole
  workspace down.

### 6.3 Preset fixes
User presets live at `<DSH_HOME>/.agent-presets/<id>/{preset.yml,agent.cordis.yml}`. Fix the
`persona` entry's `config` (`prefix` required; `suffix` optional). Back up outside the workspace,
change nothing else, then re-verify with a `session/selectModel` call (it forces a resume).

---

## 7. Escalate to the human (do not attempt)

### 7.1 Registry credential rotation
The registry host `192.168.5.35` is **not reachable** from the agent side (no key, `ci-deploy` is a
registry account only). Steps:

1. Human, on `192.168.5.35`: `docker run --rm --entrypoint htpasswd httpd:2 -Bbn ci-deploy '<new>' > /tmp/htpasswd.new`,
   back up + replace the registry's htpasswd file, `docker restart <registry container>`.
2. Agent, on `192.168.5.17`: `DSH_NEW_PASSWORD='<new>' sh rotate-registry-credential.sh --dry-run`
   then without `--dry-run`.

### 7.2 Anything that interrupts production
Restarting/recreating `deepseek-harness-alpha` / `dsh-rc1` (or their proxies) kills running DSH agent
sessions inside those containers. Realign/rollback steps each cost ~30s of downtime per channel —
get explicit approval first, then report exactly what was recreated.

### 7.3 Cleanup of rollback containers
Keep the newest `*.pre-compose-*` and the newest `*.pre-noproxy-*` per container name; older
generations may be removed **only** after confirming their images still exist
(`docker image inspect <ref>`). Report the delete list before acting if more than a couple.

---

## 8. Changing this repository (agent workflow)

1. Work from your local checkout; keep the working tree clean and generate the patch:
   `git add -N <new files> && git diff HEAD > /tmp/fix.patch`
2. Apply on the host clone and commit there (host commits get **new SHAs**, so always diff from your
   local last-pushed commit):
   `ssh … 'cd /volume1/docker/dsh-docker-push && git fetch -q origin main && git reset -q --hard origin/main && git apply /tmp/fix.patch'`
   (for multi-file changes, `tar czf - <files> | ssh … 'tar xzf -'` is simpler and avoids stale hunks;
   remember to `chmod 644` / `chmod 755` explicitly — the repo tracks modes).
3. Use a **heredoc** for the commit message (`git commit -F -`): inline quotes in `-m "…"` break the
   remote shell.
4. `git push origin main` (the push itself may trigger a build if it touches `paths:`).
5. Run the local suite before pushing anything that touches scripts/Dockerfile:
   `bash scripts/test-all.sh` (must end `ALL TESTS PASSED`).
6. Transfer notes: `scp`/SFTP are blocked — pipe through ssh (`tar czf - … | ssh … 'cat > …'`).

---

## 9. Quick verification bundle (copy-paste)

```sh
U=192.168.5.17; K=~/.ssh/dsh_deploy_ed25519
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
ssh -i $K $O lzg@$U 'bash -s' <<'EOS'
docker ps --format "{{.Names}} {{.Status}}" | grep -Ei "dsh|harness"
for p in 3081 3082 3083; do printf "%s -> %s\n" $p "$(curl -s -o /dev/null -w "%{http_code}" -m 15 http://127.0.0.1:$p/)"; done
cd /volume1/docker/dsh-deploy && sh check-image-drift.sh
curl -s -m 20 http://127.0.0.1:3082/version.json | jq -r '.channels|to_entries[]|"[\(.key)] running=\(.value.currentVersion) build=\(.value.build.status)"'
EOS
```
Green means: 5 containers healthy (`deepseek-harness-alpha`, `dsh-proxy`, `dsh-rc1`, `dsh-proxy-rc`,
`dsh-version`), three ports `200`, drift `全部一致`, both channels `build=ok`.
