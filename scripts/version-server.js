#!/usr/bin/env node
// dsh 版本信息页（零框架，依赖 semver，由 dsh-entrypoint 后台拉起，端口 3082）。
// 页面：http://<NAS-IP>:3082/   JSON：http://<NAS-IP>:3082/version.json
//
// 数据源（每个源独立状态，单源失败不影响其他源）：
//   GitHub Release / GitHub Tag（api.github.com，匿名，容器环境无 token）
//   npm latest / npm next（registry.npmjs.org，10 分钟缓存）
// 每个源：{ value, status: ok|error, error: 简短原因 }
// 推荐构建目标：各源候选中最高的、且真实存在于 npm 的版本（Dockerfile 用 npm install）。
const http = require('http');
const fs = require('fs');
const path = require('path');
const policy = require(path.join(__dirname, 'version-policy.js'));

const PORT = Number(process.env.VERSION_PORT || 3082);
const VERSION_FILE = '/opt/dsh-version.json';
const CACHE_MS = 10 * 60 * 1000;

let cache = { sources: null, checkedAt: 0 };

function readDeployed() {
  try {
    return JSON.parse(fs.readFileSync(VERSION_FILE, 'utf8'));
  } catch {
    return { dshVersion: '(unknown)', buildCommit: '(unknown)', builtAt: '(unknown)' };
  }
}

async function getSources() {
  const now = Date.now();
  if (cache.sources && now - cache.checkedAt < CACHE_MS) return cache.sources;
  cache.sources = await policy.fetchAllSources();
  cache.checkedAt = Date.now();
  return cache.sources;
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function buildJson(deployed, sources, target) {
  const { release, tag } = sources.github;
  const npm = sources.npm;
  const dshVersion = deployed.dshVersion || '(unknown)';
  return {
    dshVersion,
    currentIsTarget: target.target ? dshVersion === target.target : null,
    sources: {
      githubRelease: release,
      githubTag: tag,
      npmLatest: npm.latest,
      npmNext: npm.next,
    },
    npmInstallableVersions: npm.versions.length,
    recommendedTarget: target.target,
    newestUpstream: target.newestUpstream,
    waitingForNpm: target.waitingForNpm,
    npmError: npm.npmError || null,
    buildCommit: deployed.buildCommit || '(unknown)',
    builtAt: deployed.builtAt || '(unknown)',
    checkedAt: sources.checkedAt,
    upstreamRepo: 'https://github.com/deepseek-ai/deepseek-harness',
    dockerRepo: 'https://github.com/llzg/dsh-docker',
    commitUrl: deployed.buildCommit && /^[0-9a-f]{7,40}$/i.test(deployed.buildCommit)
      ? `https://github.com/llzg/dsh-docker/commit/${deployed.buildCommit}` : null,
  };
}

function sourceRow(label, src, isTarget) {
  const value = src.value ? esc(src.value) : '—';
  const mark = isTarget ? ' <b style="color:#60a5fa">(构建目标)</b>' : '';
  if (src.status === 'error') {
    return `<div class="row"><span class="k">${label}</span><span class="v err">查询失败 · ${esc(src.error)}</span></div>`;
  }
  return `<div class="row"><span class="k">${label}</span><span class="v">${value}${mark}</span></div>`;
}

function html(info) {
  const t = info.sources;
  const target = info.recommendedTarget;
  let badge;
  if (info.currentIsTarget === true) {
    badge = '<span class="ok">✓ 当前已是最新可构建版本</span>';
  } else if (info.currentIsTarget === false) {
    badge = target
      ? `<span class="warn">▲ 可升级至 ${esc(target)}</span>`
      : '<span class="warn">▲ 上游存在更新版本</span>';
  } else {
    badge = '<span class="na">— 无法判断最新版本</span>';
  }
  let statusLine;
  if (info.waitingForNpm && info.newestUpstream) {
    statusLine = `<div class="status warn">⚠️ 上游最新为 <b>${esc(info.newestUpstream)}</b>，但 npm 尚未发布该版本，自动构建暂不可用，等待 npm 发布。</div>`;
  } else if (target) {
    statusLine = `<div class="status ok">✅ 上游版本已发布到 npm，自动构建目标 <b>${esc(target)}</b> 可安装可构建。</div>`;
  } else {
    statusLine = `<div class="status na">— 暂无可用构建目标。</div>`;
  }
  const allFailed = t.githubRelease.status === 'error' && t.githubTag.status === 'error'
    && t.npmLatest.status === 'error' && t.npmNext.status === 'error';
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>关于版本 — DeepSeek Harness</title>
<style>
  body{font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:24px}
  .card{max-width:680px;margin:0 auto;background:#1a1d24;border:1px solid #2a2e37;border-radius:12px;padding:24px}
  h1{font-size:20px;margin:0 0 16px}
  h2{font-size:14px;color:#8b93a3;margin:24px 0 8px;font-weight:600}
  .row{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid #23272f;font-size:14px}
  .row:last-child{border-bottom:none}
  .k{color:#8b93a3;flex-shrink:0}.v{font-family:ui-monospace,monospace;word-break:break-all;text-align:right}
  .v.err{color:#f87171;font-family:inherit}
  .badge{margin-top:12px;font-size:14px}
  .status{margin-top:12px;padding:10px 12px;border-radius:8px;font-size:13px}
  .status.ok{background:#052e16;color:#4ade80}.status.warn{background:#2e2505;color:#facc15}.status.na{background:#1f232b;color:#8b93a3}
  .ok{color:#4ade80;font-weight:600}.warn{color:#facc15;font-weight:600}.na{color:#8b93a3}
  a{color:#60a5fa;text-decoration:none}
  .foot{margin-top:16px;font-size:12px;color:#5b6370;text-align:center}
  .btn{display:inline-block;margin-top:12px;padding:6px 14px;background:#2563eb;color:#fff;border-radius:6px;font-size:13px;cursor:pointer;border:none}
</style>
</head>
<body>
<div class="card">
  <h1>关于版本 · DeepSeek Harness（dsh）</h1>
  <div class="badge">${badge}</div>
  ${statusLine}
  <h2>上游版本（各来源独立）</h2>
  ${sourceRow('GitHub 最新 Release', t.githubRelease, t.githubRelease.value === target)}
  ${sourceRow('GitHub 最新 Tag', t.githubTag, t.githubTag.value === target)}
  ${sourceRow('npm latest', t.npmLatest, t.npmLatest.value === target)}
  ${sourceRow('npm next', t.npmNext, t.npmNext.value === target)}
  <div class="row"><span class="k">推荐构建目标</span><span class="v">${target ? esc(target) : '—'}</span></div>
  <h2>部署信息</h2>
  <div class="row"><span class="k">当前运行版本</span><span class="v">${esc(info.dshVersion)}</span></div>
  <div class="row"><span class="k">构建提交</span><span class="v">${info.commitUrl ? `<a href="${info.commitUrl}" target="_blank">${esc(info.buildCommit)}</a>` : esc(info.buildCommit)}</span></div>
  <div class="row"><span class="k">镜像构建时间</span><span class="v">${esc(info.builtAt)}</span></div>
  <div class="row"><span class="k">检查时间</span><span class="v">${new Date(info.checkedAt).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}</span></div>
  <h2>相关仓库</h2>
  <div class="row"><span class="k">上游 DeepSeek Harness</span><span class="v"><a href="${info.upstreamRepo}" target="_blank">deepseek-ai/deepseek-harness</a></span></div>
  <div class="row"><span class="k">构建仓库 dsh-docker</span><span class="v"><a href="${info.dockerRepo}" target="_blank">llzg/dsh-docker</a></span></div>
  <button class="btn" onclick="location.reload()">重新检查</button>
  <div class="foot">各来源 10 分钟缓存；GitHub API 匿名限流时仅 GitHub 来源显示失败，不影响 npm 判断<br>${allFailed ? '⚠ 所有来源均查询失败，请检查容器网络（DNS/代理/出网）。' : ''}</div>
</div>
</body>
</html>`;
}

const server = http.createServer(async (req, res) => {
  const deployed = readDeployed();
  const sources = await getSources();
  const target = policy.computeTarget(sources);
  const info = buildJson(deployed, sources, target);
  if (req.url === '/version.json' || req.url === '/version') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(info, null, 2));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(html(info));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[version-server] listening on http://0.0.0.0:${PORT}`);
});
