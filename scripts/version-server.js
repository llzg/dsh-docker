#!/usr/bin/env node
// dsh 版本信息页（零框架，依赖 semver，由 dsh-entrypoint 后台拉起，端口 DSH_VERSION_PORT=3082）。
// 页面：http://<NAS-IP>:3082/   JSON：http://<NAS-IP>:3082/version.json
//
// 双通道（见 docs/dual-channel.md §7）：
//   * 每条通道一个区块（alpha 3081 / rc 3083 / …），通道定义来自 SSOT
//   * SSOT 读实时工作区副本优先（$DSH_VERSION_SSOT → /root/nas_docker/dsh-version.json
//     → /opt/dsh-version-ssot.json 镜像内置兜底），并明确标注是否命中兜底
//   * 构建状态：GHCR tag 列表（目标是否已构建）+ GitHub Actions 最近一次运行结论
//   * ?refresh=1 强制刷新上游来源（30s 节流）；?channel=alpha 只看单通道
//   * 未知路径返回 404；带安全响应头；请求异常不会杀死进程
//
// 上游来源（每个源独立状态，单源失败不影响其他源）：
//   GitHub Release / GitHub Tag（api.github.com）
//   npm latest / npm next（registry.npmjs.org，10 分钟缓存）
const http = require('http');
const fs = require('fs');
const path = require('path');
const policy = require(path.join(__dirname, 'version-policy.js'));
const safeDeployPolicy = require(path.join(__dirname, 'safe-deploy-policy.js'));

const PORT = Number(process.env.DSH_VERSION_PORT || process.env.VERSION_PORT || 3082);
const CHANNEL = process.env.DSH_CHANNEL || 'alpha';
const VERSION_FILES = ['/opt/dsh-build.json', '/opt/dsh-version.json'];
const CACHE_MS = 10 * 60 * 1000;
// 强制刷新节流：一次强制刷新会打 2 个 api.github.com（releases + tags）+ 1 个 npm，
// GitHub 匿名限额 60/h → 取 120s，最坏 60/h 不越界；正常 10 分钟缓存下每小时仅 ~18 次。
const FORCE_MIN_INTERVAL_MS = 120 * 1000;
const GHCR_REPO = process.env.GHCR_REPO || 'llzg/dsh-docker';
const DOCKER_REPO = process.env.DOCKER_REPO || 'llzg/dsh-docker';
const UPSTREAM_REPO_URL = 'https://github.com/deepseek-ai/deepseek-harness';

// ── SSOT ────────────────────────────────────────────────────────────────────
// 返回 { ssot, file, isFallback }；isFallback=true 表示命中的是镜像内置快照，
// 页面上必须显式告警（否则用户会以为看到的是 NAS 上的实时值）。
function readSsoT() {
  const candidates = [
    process.env.DSH_VERSION_SSOT,
    '/root/nas_docker/dsh-version.json',
    '/opt/dsh-version-ssot.json',
  ].filter(Boolean);
  for (let i = 0; i < candidates.length; i += 1) {
    const f = candidates[i];
    try {
      const ssot = safeDeployPolicy.parseSSOT(f);
      return { ssot, file: f, isFallback: i === candidates.length - 1 };
    } catch { /* 尝试下一个 */ }
  }
  return { ssot: null, file: null, isFallback: false };
}

// 通道的测试/回滚状态（纯展示；失败不影响页面）
// 目录布局与 scripts/dsh-safe-deploy 对齐：
//   verdict: $DSH_HOME/.deploy/<channel>/last-test-verdict（旧单通道布局兜底 .deploy/last-test-verdict）
//   snapshot: $DSH_HOME/backups/<channel>/<ver>-<ts>（通道专属）或共享 $DSH_HOME/backups/<ver>-<ts>
//            —— 共享目录里按版本段过滤出属于本通道的快照，避免把另一条通道的快照算进来
function readDeployState(channel, isPrimary) {
  const home = process.env.DSH_HOME || '/data/dsh';
  const state = { testStatus: 'NOT_RUN', rollbackReady: 'NO', snapshotDir: null };
  const verdicts = [
    path.join(home, '.deploy', channel, 'last-test-verdict'),
    ...(isPrimary ? [path.join(home, '.deploy', 'last-test-verdict')] : []),
  ];
  for (const f of verdicts) {
    try {
      const v = fs.readFileSync(f, 'utf8').trim();
      if (v.includes('PASS')) { state.testStatus = 'PASS'; break; }
      if (v.includes('FAIL')) { state.testStatus = 'FAIL'; break; }
    } catch { /* 未运行过 test */ }
  }
  const scoped = path.join(home, 'backups', channel);
  const shared = path.join(home, 'backups');
  const dirs = [];
  const push = (dir, filter) => {
    try {
      for (const d of fs.readdirSync(dir)) {
        if (d === '.' || d === '..') continue;
        if (filter && !filter(d)) continue;
        dirs.push(path.join(dir, d));
      }
    } catch { /* 目录不存在 */ }
  };
  push(scoped, null);
  // 共享目录：<version>-YYYYMMDD-HHMMSS，按 version 的通道段过滤
  push(shared, (d) => {
    const m = /^(.*)-\d{8}-\d{6}$/.exec(d);
    const ver = m ? m[1] : d;
    return policy.channelOf(ver) === channel;
  });
  if (dirs.length > 0) {
    dirs.sort();
    state.rollbackReady = 'YES';
    state.snapshotDir = dirs[dirs.length - 1];
  }
  return state;
}

function readDeployed() {
  for (const f of VERSION_FILES) {
    try {
      const j = JSON.parse(fs.readFileSync(f, 'utf8'));
      return { dshVersion: j.dshVersion || '(unknown)', buildCommit: j.buildCommit || '(unknown)', builtAt: j.builtAt || '(unknown)', channel: j.channel || null };
    } catch { /* 试下一个 */ }
  }
  return { dshVersion: '(unknown)', buildCommit: '(unknown)', builtAt: '(unknown)', channel: null };
}

// ── 缓存 ────────────────────────────────────────────────────────────────────
let sourcesCache = { data: null, at: 0, inflight: null };
let ghcrCache = { data: null, at: 0, inflight: null };
let runsCache = { data: null, at: 0, inflight: null };
let lastForcedAt = 0;

function cacheFresh(entry) {
  return entry.data && Date.now() - entry.at < CACHE_MS;
}

// 并发冷启动去重：同一时刻只有一个上游查询在飞
async function memoized(entry, loader) {
  if (cacheFresh(entry)) return entry.data;
  if (entry.inflight) return entry.inflight;
  entry.inflight = (async () => {
    try {
      const data = await loader();
      entry.data = data;
      entry.at = Date.now();
      return data;
    } finally {
      entry.inflight = null;
    }
  })();
  return entry.inflight;
}

async function getSources(force) {
  if (force) {
    sourcesCache = { data: null, at: 0, inflight: sourcesCache.inflight };
  }
  return memoized(sourcesCache, () => policy.fetchAllSources());
}

// ── 构建状态（GHCR tags + 最近一次 CI 运行）─────────────────────────────────
async function loadGhcrTags() {
  const tok = await policy.fetchJson(`https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull&service=ghcr.io`);
  if (tok.error || !tok.data || !tok.data.token) {
    return { status: 'error', error: (tok.error || 'token 获取失败'), tags: [] };
  }
  const res = await policy.fetchJson(`https://ghcr.io/v2/${GHCR_REPO}/tags/list?n=1000`, {
    headers: { Authorization: `Bearer ${tok.data.token}` },
  });
  if (res.error || !res.data || !Array.isArray(res.data.tags)) {
    return { status: 'error', error: (res.error || 'tags 列表不可读'), tags: [] };
  }
  return { status: 'ok', error: null, tags: res.data.tags };
}

async function loadLastRun() {
  const headers = {};
  if (process.env.GH_API_TOKEN) headers.Authorization = `token ${process.env.GH_API_TOKEN}`;
  const res = await policy.fetchJson(
    `https://api.github.com/repos/${DOCKER_REPO}/actions/runs?per_page=1`,
    { headers },
  );
  if (res.error || !res.data || !Array.isArray(res.data.workflow_runs) || !res.data.workflow_runs.length) {
    return { status: 'error', error: (res.error || '无运行记录'), run: null };
  }
  const r = res.data.workflow_runs[0];
  return {
    status: 'ok',
    error: null,
    run: { conclusion: r.conclusion, status: r.status, event: r.event, createdAt: r.created_at, url: r.html_url, headSha: r.head_sha },
  };
}

function buildStatus(target, ghcr, runs) {
  if (!target) return { target: null, status: 'na', targetBuilt: null, builtTags: [], lastRun: null, error: null };
  const tags = (ghcr && ghcr.tags) || [];
  const builtTags = tags.filter((t) => t === target || t.startsWith(`${target}-`));
  return {
    target,
    status: ghcr && ghcr.status === 'ok' ? 'ok' : 'error',
    targetBuilt: ghcr && ghcr.status === 'ok' ? builtTags.length > 0 : null,
    builtTags,
    lastRun: (runs && runs.run) || null,
    error: (ghcr && ghcr.error) || (runs && runs.error) || null,
  };
}

// ── 组装 JSON ───────────────────────────────────────────────────────────────
async function buildInfo({ force }) {
  const deployed = readDeployed();
  const sources = await getSources(force);
  const targets = policy.computeTargets(sources);
  const { ssot, file, isFallback } = readSsoT();
  const ghcr = await memoized(ghcrCache, loadGhcrTags).catch((e) => ({ status: 'error', error: e.message, tags: [] }));
  const runs = await memoized(runsCache, loadLastRun).catch((e) => ({ status: 'error', error: e.message, run: null }));

  const channelViews = {};
  if (ssot) {
    for (const name of Object.keys(ssot.channels)) {
      const isPrimary = name === ssot.primaryChannel;
      let view;
      try {
        view = safeDeployPolicy.computeChannel(ssot, name);
      } catch (e) {
        view = { channel: name, error: e.message };
      }
      const target = (targets.channels[name] && targets.channels[name].target) || null;
      const state = readDeployState(name, isPrimary);
      channelViews[name] = {
        ...view,
        currentRunning: view.currentVersion || null,
        testStatus: state.testStatus,
        rollbackReady: state.rollbackReady,
        snapshotDir: state.snapshotDir,
        recommendedTarget: target,
        newestUpstream: (targets.channels[name] && targets.channels[name].newestUpstream) || null,
        waitingForNpm: !!(targets.channels[name] && targets.channels[name].waitingForNpm),
        currentIsTarget: target ? view.currentVersion === target : null,
        build: buildStatus(target, ghcr, runs),
      };
    }
  }

  const primary = channelViews[CHANNEL] || channelViews[(ssot && ssot.primaryChannel) || 'alpha'] || null;
  const checkedAt = sources.checkedAt;
  return {
    dshVersion: deployed.dshVersion,
    containerChannel: deployed.channel || CHANNEL,
    currentIsTarget: primary ? primary.currentIsTarget : null,
    // 兼容旧字段（单通道消费方）
    safeUpgrade: primary
      ? {
        ...primary,
        currentRunning: deployed.dshVersion,
        ssotFile: file,
        ssotIsFallback: isFallback,
      }
      : null,
    channels: channelViews,
    sources: {
      githubRelease: sources.github.release,
      githubTag: sources.github.tag,
      npmLatest: sources.npm.latest,
      npmNext: sources.npm.next,
    },
    npmInstallableVersions: sources.npm.versions.length,
    recommendedTarget: targets.target,
    newestUpstream: targets.newestUpstream,
    waitingForNpm: targets.waitingForNpm,
    npmError: sources.npm.npmError || null,
    buildCommit: deployed.buildCommit,
    builtAt: deployed.builtAt,
    checkedAt,
    cache: {
      sourcesCheckedAt: checkedAt,
      sourcesAgeSec: Math.round((Date.now() - new Date(checkedAt).getTime()) / 1000),
      cacheMs: CACHE_MS,
      ssotFile: file,
      ssotIsFallback: isFallback,
      ghcrStatus: ghcr.status,
      runsStatus: runs.status,
      lastForcedAt: lastForcedAt ? new Date(lastForcedAt).toISOString() : null,
    },
    upstreamRepo: UPSTREAM_REPO_URL,
    dockerRepo: `https://github.com/${DOCKER_REPO}`,
    commitUrl: deployed.buildCommit && /^[0-9a-f]{7,40}$/i.test(deployed.buildCommit)
      ? `https://github.com/${DOCKER_REPO}/commit/${deployed.buildCommit}` : null,
  };
}

// ── HTML ────────────────────────────────────────────────────────────────────
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function row(k, v, cls) {
  return `<div class="row"><span class="k">${esc(k)}</span><span class="v${cls ? ' ' + cls : ''}">${v}</span></div>`;
}

function sourceRow(label, src, isTarget) {
  const value = src && src.value ? esc(src.value) : '—';
  const mark = isTarget ? ' <b style="color:#60a5fa">(构建目标)</b>' : '';
  if (!src) return row(label, '—');
  if (src.status === 'error') return row(label, `查询失败 · ${esc(src.error)}`, 'err');
  return row(label, `${value}${mark}`);
}

function riskClass(risk) {
  if (risk === 'BLOCKED') return 'err';
  if (risk === 'HIGH' || risk === 'MEDIUM') return 'warn';
  if (risk === 'LOW') return 'ok';
  return '';
}

function buildRows(b) {
  if (!b || !b.target) return row('构建状态', '<span class="na">— 暂无构建目标</span>');
  let built;
  if (b.status === 'error') built = `<span class="err">GHCR 查询失败 · ${esc(b.error || '')}</span>`;
  else if (b.targetBuilt === true) built = `<span class="ok">✓ 已构建</span> <span class="na">(${esc(b.builtTags.join(', '))})</span>`;
  else built = '<span class="warn">✗ 尚未构建成功</span>';
  let last = '<span class="na">—</span>';
  if (b.lastRun) {
    const c = b.lastRun.conclusion || b.lastRun.status || '?';
    const cls = c === 'success' ? 'ok' : c === 'failure' ? 'err' : 'na';
    last = `<span class="${cls}">${esc(c)}</span> <span class="na">· ${esc(b.lastRun.event)} · ${esc(new Date(b.lastRun.createdAt).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' }))}</span>`;
  }
  return row('推荐构建目标', esc(b.target)) + row('目标镜像', built) + row('最近一次 CI', last);
}

function channelCard(name, v, isPrimary) {
  if (v.error) {
    return `<div class="card"><h1>通道 ${esc(name)}</h1>${row('错误', esc(v.error), 'err')}</div>`;
  }
  const target = v.recommendedTarget;
  let badge;
  if (v.currentIsTarget === true) badge = '<span class="ok">✓ 当前已是推荐构建目标</span>';
  else if (v.currentIsTarget === false) badge = target ? `<span class="warn">▲ 可升级至 ${esc(target)}</span>` : '<span class="warn">▲ 上游存在更新版本</span>';
  else badge = '<span class="na">— 无法判断推荐目标</span>';
  let statusLine = '';
  if (v.waitingForNpm && v.newestUpstream) {
    statusLine = `<div class="status warn">⚠️ 上游最新为 <b>${esc(v.newestUpstream)}</b>，但 npm 尚未发布该版本，自动构建暂不可用。</div>`;
  } else if (target && v.build && v.build.targetBuilt === false) {
    statusLine = `<div class="status warn">⚠️ 目标 <b>${esc(target)}</b> 在 npm 上可安装，但 GHCR 上<b>尚无对应镜像</b>（构建未成功或未触发）。</div>`;
  } else if (target) {
    statusLine = `<div class="status ok">✅ 构建目标 <b>${esc(target)}</b> 可安装，镜像已发布。</div>`;
  } else {
    statusLine = '<div class="status na">— 该通道暂无可用构建目标。</div>';
  }
  return `<div class="card">
  <h1>通道 ${esc(name)}${isPrimary ? ' <span class="tag">primary</span>' : ''} · 宿主端口 ${esc(v.port)}</h1>
  <div class="badge">${badge}</div>
  ${statusLine}
  ${row('容器 / 项目', `${esc(v.container)} / ${esc(v.project)}`)}
  ${row('当前运行 (production)', esc(v.currentVersion))}
  ${row('测试候选 (candidate)', esc(v.testCandidate))}
  ${row('候选通道', esc(v.targetChannel))}
  ${row('升级风险', esc(v.upgradeRisk), riskClass(v.upgradeRisk))}
  ${row('迁移状态', esc(v.migrationStatus))}
  ${row('隔离测试要求', v.dataIsolationRequired ? 'REQUIRED' : 'NOT_REQUIRED')}
  ${row('测试状态', esc(v.testStatus), v.testStatus === 'PASS' ? 'ok' : v.testStatus === 'FAIL' ? 'err' : 'warn')}
  ${row('回滚就绪', esc(v.rollbackReady), v.rollbackReady === 'YES' ? 'ok' : 'warn')}
  ${row('promote 阻塞', v.promoteBlocked ? `<span class="err">YES（${esc((v.otherBlockers || []).map((b) => b.kind || b.name).join(', '))}）</span>` : '<span class="ok">NO</span>')}
  <h2>构建状态</h2>
  ${buildRows(v.build)}
</div>`;
}

function html(info, opts = {}) {
  const t = info.sources;
  const cache = info.cache || {};
  const names = Object.keys(info.channels || {});
  const only = opts.onlyChannel;
  const shown = only ? names.filter((n) => n === only) : names;
  const cards = shown.map((n) => channelCard(n, info.channels[n], n === (info.safeUpgrade && info.safeUpgrade.channel) || n === 'alpha')).join('\n');
  const ssotWarn = !cache.ssotFile
    ? '<div class="status warn">⚠️ 未找到任何 SSOT 文件（已尝试 <code>$DSH_VERSION_SSOT</code> / <code>/root/nas_docker/dsh-version.json</code> / <code>/opt/dsh-version-ssot.json</code>）——通道信息不可用。</div>'
    : cache.ssotIsFallback
      ? `<div class="status warn">⚠️ SSOT 命中<b>镜像内置快照</b>（${esc(cache.ssotFile)}）——promote 后的实时值可能未生效；请检查 <code>DSH_VERSION_SSOT</code> 或 /root/nas_docker 挂载。</div>`
      : '';
  const throttleNote = opts.refreshThrottled
    ? '<div class="status na">刷新被节流（距上次强制刷新不足 30 秒），本次仍显示缓存数据。</div>' : '';
  const runFail = info.channels && Object.values(info.channels).some((c) => c.build && c.build.lastRun && c.build.lastRun.conclusion === 'failure');
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>关于版本 — DeepSeek Harness</title>
<style>
  body{font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:24px}
  .card{max-width:680px;margin:0 auto 18px;background:#1a1d24;border:1px solid #2a2e37;border-radius:12px;padding:24px}
  h1{font-size:20px;margin:0 0 16px}
  h2{font-size:14px;color:#8b93a3;margin:24px 0 8px;font-weight:600}
  .row{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid #23272f;font-size:14px}
  .row:last-child{border-bottom:none}
  .k{color:#8b93a3;flex-shrink:0}.v{font-family:ui-monospace,monospace;word-break:break-all;text-align:right}
  .v.err{color:#f87171;font-family:inherit}.v.warn{color:#facc15;font-family:inherit}.v.ok{color:#4ade80;font-family:inherit}
  .badge{margin-top:12px;font-size:14px}
  .status{margin-top:12px;padding:10px 12px;border-radius:8px;font-size:13px}
  .status.ok{background:#052e16;color:#4ade80}.status.warn{background:#2e2505;color:#facc15}.status.na{background:#1f232b;color:#8b93a3}
  .ok{color:#4ade80;font-weight:600}.warn{color:#facc15;font-weight:600}.na{color:#8b93a3}
  .tag{font-size:11px;padding:1px 6px;border:1px solid #3b4353;border-radius:999px;color:#8b93a3;vertical-align:middle}
  a{color:#60a5fa;text-decoration:none}
  .foot{margin-top:16px;font-size:12px;color:#5b6370;text-align:center}
  .btn{display:inline-block;margin-top:12px;padding:6px 14px;background:#2563eb;color:#fff;border-radius:6px;font-size:13px;cursor:pointer;border:none}
  code{background:#23272f;padding:1px 5px;border-radius:4px;font-size:12px}
</style>
</head>
<body>
${cards}
<div class="card">
  <h1>部署信息 · 数据来源</h1>
  ${ssotWarn}
  ${throttleNote}
  ${row('本容器通道', esc(info.containerChannel))}
  ${row('当前运行版本', esc(info.dshVersion))}
  ${row('构建提交', info.commitUrl ? `<a href="${info.commitUrl}" target="_blank">${esc(info.buildCommit)}</a>` : esc(info.buildCommit))}
  ${row('镜像构建时间', esc(info.builtAt))}
  ${row('检查时间', esc(new Date(info.checkedAt).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })))}
  ${row('SSOT 来源', `${esc(cache.ssotFile || '(未命中)')}${cache.ssotIsFallback ? ' <span class="warn">（镜像内置兜底）</span>' : ''}`)}
  ${row('缓存年龄', `${esc(cache.sourcesAgeSec)} 秒 / ${esc(Math.round((cache.cacheMs || 0) / 1000))} 秒`)}
  <h2>上游版本（各来源独立）</h2>
  ${sourceRow('GitHub 最新 Release', t.githubRelease, t.githubRelease && t.githubRelease.value === info.recommendedTarget)}
  ${sourceRow('GitHub 最新 Tag', t.githubTag, t.githubTag && t.githubTag.value === info.recommendedTarget)}
  ${sourceRow('npm latest', t.npmLatest, t.npmLatest && t.npmLatest.value === info.recommendedTarget)}
  ${sourceRow('npm next', t.npmNext, t.npmNext && t.npmNext.value === info.recommendedTarget)}
  ${row('npm 可安装版本数', esc(info.npmInstallableVersions))}
  <h2>相关仓库</h2>
  ${row('上游 DeepSeek Harness', `<a href="${info.upstreamRepo}" target="_blank">deepseek-ai/deepseek-harness</a>`)}
  ${row('构建仓库', `<a href="${info.dockerRepo}" target="_blank">${esc(DOCKER_REPO)}</a>`)}
  <a class="btn" href="?refresh=1">重新检查（强制刷新上游）</a>
  <div class="foot">上游来源 10 分钟缓存，强制刷新 120 秒节流（GitHub 匿名限额）；GHCR/CI 状态同为 10 分钟缓存${runFail ? '<br>⚠ 最近一次 CI 构建失败，详见 GitHub Actions。' : ''}</div>
</div>
</body>
</html>`;
}

// ── HTTP ────────────────────────────────────────────────────────────────────
const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Cache-Control': 'no-store',
};

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, ...SECURITY_HEADERS });
  res.end(body);
}

function notFound(req, res) {
  const wantsJson = req.url.endsWith('.json') || String(req.headers.accept || '').includes('application/json');
  if (wantsJson) return send(res, 404, 'application/json; charset=utf-8', JSON.stringify({ error: 'not found', path: req.url }, null, 2));
  return send(res, 404, 'text/html; charset=utf-8', '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>404</title></head><body style="font-family:sans-serif;background:#0f1115;color:#e6e6e6;padding:24px"><h1>404</h1><p>未知路径：' + esc(req.url) + '</p><p><a style="color:#60a5fa" href="/">返回版本页</a></p></body></html>');
}

const server = http.createServer(async (req, res) => {
  let u;
  try {
    u = new URL(req.url, 'http://localhost');
  } catch {
    return notFound(req, res);
  }
  const pathname = u.pathname;
  const isJson = pathname === '/version' || pathname === '/version.json';
  if (!isJson && pathname !== '/' && pathname !== '/index.html') return notFound(req, res);

  const wantForce = u.searchParams.get('refresh') === '1';
  const now = Date.now();
  let refreshThrottled = false;
  let force = false;
  if (wantForce) {
    if (now - lastForcedAt >= FORCE_MIN_INTERVAL_MS) {
      lastForcedAt = now;
      force = true;
    } else {
      refreshThrottled = true;
    }
  }

  try {
    const info = await buildInfo({ force });
    if (isJson) {
      const out = refreshThrottled ? { ...info, refreshThrottled: true } : info;
      return send(res, 200, 'application/json; charset=utf-8', JSON.stringify(out, null, 2));
    }
    const only = u.searchParams.get('channel');
    return send(res, 200, 'text/html; charset=utf-8', html(info, { onlyChannel: only, refreshThrottled }));
  } catch (e) {
    console.error(`[version-server] 处理 ${req.url} 失败: ${e && e.stack ? e.stack : e}`);
    if (isJson) return send(res, 500, 'application/json; charset=utf-8', JSON.stringify({ error: e.message }, null, 2));
    return send(res, 500, 'text/html; charset=utf-8', `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>500</title></head><body style="font-family:sans-serif;background:#0f1115;color:#f87171;padding:24px"><h1>500</h1><pre>${esc(e.message)}</pre></body></html>`);
  }
});

// 进程级兜底：任何未捕获异常只记录，不让版本页静默死亡
process.on('uncaughtException', (e) => {
  console.error(`[version-server] uncaughtException: ${e && e.stack ? e.stack : e}`);
});
process.on('unhandledRejection', (e) => {
  console.error(`[version-server] unhandledRejection: ${e && e.stack ? e.stack : e}`);
});

server.on('error', (e) => {
  console.error(`[version-server] server error: ${e && e.message}`);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[version-server] listening on http://0.0.0.0:${PORT} (channel=${CHANNEL})`);
});
