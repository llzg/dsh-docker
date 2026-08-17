#!/usr/bin/env node
// dsh 版本信息页（零依赖）。
// 启动：node /opt/version-server.js （由 dsh-entrypoint 后台拉起，端口 3082）
// 页面：http://<NAS-IP>:3082/   JSON：http://<NAS-IP>:3082/version.json
//
// 数据源：
//   /opt/dsh-version.json —— 镜像构建时写入（DSH_VERSION / GIT_REVISION / builtAt）
//   npm registry —— @deepseek-ai/dsh dist-tag "latest"（服务端拉取 + 10 分钟缓存）
const http = require('http');
const fs = require('fs');
const https = require('https');

const PORT = Number(process.env.VERSION_PORT || 3082);
const VERSION_FILE = '/opt/dsh-version.json';
const NPM_URL = 'https://registry.npmjs.org/@deepseek-ai/dsh/latest';
const CACHE_MS = 10 * 60 * 1000;

let npmCache = { latest: null, checkedAt: 0 };

function readDeployed() {
  try {
    return JSON.parse(fs.readFileSync(VERSION_FILE, 'utf8'));
  } catch {
    return {
      dshVersion: '(unknown)',
      buildCommit: '(unknown)',
      builtAt: '(unknown)',
      note: '未找到 /opt/dsh-version.json（镜像可能过旧）',
    };
  }
}

function fetchNpmLatest() {
  return new Promise((resolve) => {
    https
      .get(NPM_URL, { headers: { 'User-Agent': 'dsh-version-server' } }, (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try { resolve(JSON.parse(data).version || null); } catch { resolve(null); }
        });
      })
      .on('error', () => resolve(null));
  });
}

async function npmLatest() {
  const now = Date.now();
  if (npmCache.latest !== null && now - npmCache.checkedAt < CACHE_MS) return npmCache;
  const latest = await fetchNpmLatest();
  npmCache = { latest, checkedAt: Date.now() };
  return npmCache;
}

function buildInfo(deployed, npm) {
  const dshVersion = deployed.dshVersion || '(unknown)';
  return {
    dshVersion,
    npmLatest: npm.latest,
    isLatest: npm.latest ? dshVersion === npm.latest : null,
    buildCommit: deployed.buildCommit || '(unknown)',
    builtAt: deployed.builtAt || '(unknown)',
    checkedAt: new Date(npm.checkedAt).toISOString(),
    upstreamRepo: 'https://github.com/deepseek-ai/deepseek-harness',
    dockerRepo: 'https://github.com/llzg/dsh-docker',
    commitUrl: deployed.buildCommit && /^[0-9a-f]{7,40}$/i.test(deployed.buildCommit)
      ? `https://github.com/llzg/dsh-docker/commit/${deployed.buildCommit}` : null,
  };
}

function html(info) {
  const badge = info.isLatest === true
    ? '<span class="ok">✓ 已是最新</span>'
    : info.isLatest === false
      ? '<span class="warn">▲ 有新版本可更新</span>'
      : '<span class="na">— 无法获取最新版本</span>';
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>关于版本 — DeepSeek Harness</title>
<style>
  body{font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:24px}
  .card{max-width:640px;margin:0 auto;background:#1a1d24;border:1px solid #2a2e37;border-radius:12px;padding:24px}
  h1{font-size:20px;margin:0 0 16px}
  h2{font-size:14px;color:#8b93a3;margin:24px 0 8px;font-weight:600}
  .row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #23272f;font-size:14px}
  .row:last-child{border-bottom:none}
  .k{color:#8b93a3}.v{font-family:ui-monospace,monospace;word-break:break-all;text-align:right}
  .badge{margin-top:12px;font-size:14px}
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
  <h2>部署信息</h2>
  <div class="row"><span class="k">当前 dsh 版本（GitHub 源码/npm）</span><span class="v">${info.dshVersion}</span></div>
  <div class="row"><span class="k">npm 最新版本</span><span class="v">${info.npmLatest || '—'}</span></div>
  <div class="row"><span class="k">最新检查时间</span><span class="v">${new Date(info.checkedAt).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}</span></div>
  <h2>构建信息（dsh-docker）</h2>
  <div class="row"><span class="k">构建提交</span><span class="v">${info.commitUrl ? `<a href="${info.commitUrl}" target="_blank">${info.buildCommit}</a>` : info.buildCommit}</span></div>
  <div class="row"><span class="k">镜像构建时间</span><span class="v">${info.builtAt}</span></div>
  <h2>相关仓库</h2>
  <div class="row"><span class="k">上游 DeepSeek Harness</span><span class="v"><a href="${info.upstreamRepo}" target="_blank">deepseek-ai/deepseek-harness</a></span></div>
  <div class="row"><span class="k">构建仓库 dsh-docker</span><span class="v"><a href="${info.dockerRepo}" target="_blank">llzg/dsh-docker</a></span></div>
  <button class="btn" onclick="location.reload()">重新检查</button>
  <div class="foot">版本信息由容器内 /opt/version-server.js 提供，npm 最新版每 10 分钟缓存检查一次</div>
</div>
</body>
</html>`;
}

const server = http.createServer(async (req, res) => {
  const deployed = readDeployed();
  const npm = await npmLatest();
  const info = buildInfo(deployed, npm);
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
