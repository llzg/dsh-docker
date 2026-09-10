#!/usr/bin/env node
// 上游版本检测策略（version-server.js 与 check-new-version.js 共用）。
// 依赖：semver（版本服务器在镜像 /opt/node_modules/semver；CI 在仓库 node_modules）。
//
// 设计要点：
//   1) 多源独立查询：GitHub Release / GitHub Tag / npm latest / npm next。
//      每个源独立 try/catch，单源失败只影响该源（不会整页 "—"）。
//   2) 每个源带 status(ok|error) 与 error 原因（timeout/HTTP/限流/DNS/解析）。
//   3) 版本比较一律走 semver 库，禁止字符串比较。
//   4) 自动构建目标 = 各源候选中最高的、且真实存在于 npm 的版本
//      （Dockerfile 用 npm install，目标必须可安装）。
//   5) 若 GitHub 最新版本尚未发布到 npm → waitingForNpm=true，页面提示等待。

const https = require('https');

const UPSTREAM_REPO = 'deepseek-ai/deepseek-harness';
const NPM_PKG = '@deepseek-ai/dsh';
const REQ_TIMEOUT_MS = 8000;

function fetchJson(url, { headers = {}, timeoutMs = REQ_TIMEOUT_MS } = {}) {
  return new Promise((resolve) => {
    const req = https.get(url, { headers: { 'User-Agent': 'dsh-version-check', ...headers } }, (res) => {
      let data = '';
      const status = res.statusCode || 0;
      res.setEncoding('utf8');
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        if (status < 200 || status >= 300) {
          const reason = status === 403
            ? `HTTP 403（rate limited / forbidden）`
            : `HTTP ${status}`;
          return resolve({ error: reason, httpStatus: status });
        }
        try {
          resolve({ data: JSON.parse(data) });
        } catch {
          resolve({ error: '响应不是合法 JSON' });
        }
      });
    });
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error('timeout'));
    });
    req.on('error', (e) => {
      const code = e.code || e.message;
      const reason = code === 'ETIMEDOUT' || code === 'timeout'
        ? '连接超时（timeout）'
        : code === 'ENOTFOUND' || code === 'EAI_AGAIN'
          ? 'DNS 解析失败'
          : code === 'ECONNREFUSED' || code === 'ECONNRESET'
            ? `连接失败（${code}）`
            : `网络错误（${code}）`;
      resolve({ error: reason });
    });
  });
}

// ── 通道 ────────────────────────────────────────────────────────────────────
// 通道由 semver prerelease 段判定：0.1.3-alpha.2 → alpha；0.1.2-rc.1 → rc；
// 0.1.2 → stable；其他未知 prerelease → unknown。全仓库唯一实现，勿在别处重复。
const CHANNELS = ['stable', 'rc', 'beta', 'alpha'];

function channelOf(v) {
  const s = String(v == null ? '' : v).trim().toLowerCase();
  if (!s) return 'unknown';
  if (s.includes('-rc.')) return 'rc';
  if (s.includes('-beta')) return 'beta';
  if (s.includes('-alpha')) return 'alpha';
  if (s.includes('-')) return 'unknown';
  return 'stable';
}

// 版本字符串规范化：'dsh-v0.1.1-rc.1' / 'v1.0.0' → semver 合法串
function normalizeVersion(v) {
  if (!v || typeof v !== 'string') return null;
  let s = v.trim();
  s = s.replace(/^dsh-?/i, '');
  if (!/^\d/.test(s)) s = s.replace(/^v/i, '');
  return s || null;
}

async function fetchGitHub() {
  const headers = {};
  if (process.env.GH_API_TOKEN) headers.Authorization = `token ${process.env.GH_API_TOKEN}`;
  const [rel, tag] = await Promise.all([
    fetchJsonRetry(`https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=1`, { headers }),
    fetchJsonRetry(`https://api.github.com/repos/${UPSTREAM_REPO}/tags?per_page=1`, { headers }),
  ]);
  const out = {};
  if (rel.error) {
    out.release = { value: null, status: 'error', error: rel.error };
  } else {
    const first = Array.isArray(rel.data) ? rel.data[0] : null;
    const v = normalizeVersion(first && first.tag_name);
    out.release = first
      ? { value: v, raw: first.tag_name, prerelease: !!first.prerelease, publishedAt: first.published_at, status: 'ok' }
      : { value: null, status: 'ok', error: null };
  }
  if (tag.error) {
    out.tag = { value: null, status: 'error', error: tag.error };
  } else {
    const first = Array.isArray(tag.data) ? tag.data[0] : null;
    const v = normalizeVersion(first && first.name);
    out.tag = first
      ? { value: v, raw: first.name, status: 'ok' }
      : { value: null, status: 'ok', error: null };
  }
  return out;
}

// 网络抖动重试：公网查询偶发 ECONNRESET/超时（2026-09-10 实测：一次 ECONNRESET 直接
// 让 CI 的 Policy tests 判红、整轮构建不跑）。这里退避重试若干次，把"抖动"和"真不可达"
// 区分开；仍然失败时按原来的错误对象返回，由调用方（测试/收敛判定）决定 SKIP 还是 FAIL。
const NET_RETRIES = Number(process.env.DSH_NET_RETRIES || 3);      // 总尝试次数
const NET_BACKOFF_MS = Number(process.env.DSH_NET_BACKOFF_MS || 1500);

function isNetworkError(res) {
  return !!(res && res.error && !res.httpStatus);   // 有 httpStatus 的是服务端回答，不是链路问题
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function fetchJsonRetry(url, opts = {}) {
  let last;
  for (let i = 1; i <= Math.max(1, NET_RETRIES); i++) {
    last = await fetchJson(url, opts);
    if (!last.error) return last;
    if (!isNetworkError(last)) return last;          // 4xx/5xx 不重试（重试也不会变好）
    if (i < NET_RETRIES) await sleep(NET_BACKOFF_MS * i);
  }
  return last;
}

async function fetchNpm() {
  const res = await fetchJsonRetry(`https://registry.npmjs.org/${NPM_PKG}`, {
    headers: { Accept: 'application/vnd.npm.install-v1+json' },
  });
  if (res.error) return { error: res.error };
  const tags = (res.data['dist-tags'] || {});
  return {
    latest: { value: tags.latest || null, status: 'ok' },
    next: { value: tags.next || null, status: 'ok' },
    versions: Object.keys(res.data.versions || {}),
  };
}

// 拉取全部源。返回：
// {
//   github: { release: {value,status,error}, tag: {...} },
//   npm: { latest: {...}, next: {...}, versions: [...] },
//   npmError: string|null,   // npm 整体失败时
//   checkedAt: ISO
// }
async function fetchAllSources() {
  const [github, npm] = await Promise.all([fetchGitHub(), fetchNpm()]);
  return {
    github,
    npm: npm.error
      ? { latest: { value: null, status: 'error', error: npm.error }, next: { value: null, status: 'error', error: npm.error }, versions: [], npmError: npm.error }
      : { ...npm, npmError: null },
    checkedAt: new Date().toISOString(),
  };
}

// 计算推荐构建目标（仅取 npm 真实存在的版本）。
// 返回 { target, candidates, installable, newestUpstream, waitingForNpm }
function computeTarget(sources) {
  const sv = semver();
  const rawCandidates = [
    sources.github.release && sources.github.release.value,
    sources.github.tag && sources.github.tag.value,
    sources.npm.latest && sources.npm.latest.value,
    sources.npm.next && sources.npm.next.value,
  ].filter(Boolean);
  const versions = sources.npm.versions || [];
  const versionSet = new Set(versions);

  // 去重并过滤合法 semver
  const seen = new Set();
  const candidates = [];
  for (const c of rawCandidates) {
    const v = normalizeVersion(c);
    if (v && !seen.has(v)) {
      seen.add(v);
      try {
        candidates.push(sv.valid(v));
      } catch {
        /* 忽略非法版本 */
      }
    }
  }
  const valid = candidates.filter(Boolean);

  const installable = valid.filter((v) => versionSet.has(v));
  const sorted = sv.rsort(valid);
  const newestUpstream = sorted[0] || null;
  const target = sv.rsort(installable)[0] || null;
  const waitingForNpm = newestUpstream !== null && target !== newestUpstream;

  return { target, candidates: valid, installable, newestUpstream, waitingForNpm };
}

// ── 按通道解析构建目标（双通道核心）────────────────────────────────────────
// 与 computeTarget 的区别：候选集包含 npm 全量 versions（它们天然可安装），
// 因此每个通道都能独立拿到"该通道内最高可安装版本"，不会被其他通道压过。
// 返回 { channel, target, newestUpstream, waitingForNpm, candidates[], installable[] }
function computeChannelTarget(sources, channel) {
  const sv = semver();
  const versions = (sources.npm && sources.npm.versions) || [];
  const versionSet = new Set(versions);

  const raw = [
    sources.github && sources.github.release && sources.github.release.value,
    sources.github && sources.github.tag && sources.github.tag.value,
    sources.npm && sources.npm.latest && sources.npm.latest.value,
    sources.npm && sources.npm.next && sources.npm.next.value,
    ...versions,
  ];

  const seen = new Set();
  const candidates = [];
  for (const c of raw) {
    const v = normalizeVersion(c);
    if (!v || seen.has(v)) continue;
    seen.add(v);
    let valid = null;
    try { valid = sv.valid(v); } catch { valid = null; }
    if (!valid) continue;
    if (channel !== 'all' && channelOf(valid) !== channel) continue;
    candidates.push(valid);
  }

  const installable = candidates.filter((v) => versionSet.has(v));
  const target = sv.rsort(installable)[0] || null;
  const newestUpstream = sv.rsort(candidates)[0] || null;
  const waitingForNpm = newestUpstream !== null && target !== newestUpstream;

  return { channel, target, newestUpstream, waitingForNpm, candidates, installable };
}

// 一次算全部通道 + 兼容顶层的"跨通道最高可安装版本"
function computeTargets(sources) {
  const channels = {};
  for (const ch of CHANNELS) channels[ch] = computeChannelTarget(sources, ch);
  const legacy = computeTarget(sources);
  return {
    channels,
    target: legacy.target,
    newestUpstream: legacy.newestUpstream,
    waitingForNpm: legacy.waitingForNpm,
  };
}

let _semver = null;
function semver() {
  if (_semver) return _semver;
  // 从本项目依赖（CI: 仓库 node_modules；镜像: /opt/node_modules）解析
  const path = require('path');
  const base = __dirname;
  const tryPaths = [
    path.join(base, 'node_modules', 'semver'),
    path.join(base, '..', 'node_modules', 'semver'),
    path.join('/opt', 'node_modules', 'semver'),
  ];
  for (const p of tryPaths) {
    try {
      _semver = require(p);
      return _semver;
    } catch { /* 继续 */ }
  }
  throw new Error('semver 库不可用（镜像/CI 未安装 semver）');
}

module.exports = { fetchAllSources, fetchGitHub, fetchNpm, fetchJson, fetchJsonRetry, isNetworkError, computeTarget, computeTargets, computeChannelTarget, channelOf, CHANNELS, normalizeVersion, semver, UPSTREAM_REPO, NPM_PKG };
