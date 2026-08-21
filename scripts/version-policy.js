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
    fetchJson(`https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=1`, { headers }),
    fetchJson(`https://api.github.com/repos/${UPSTREAM_REPO}/tags?per_page=1`, { headers }),
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

async function fetchNpm() {
  const res = await fetchJson(`https://registry.npmjs.org/${NPM_PKG}`, {
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

module.exports = { fetchAllSources, fetchGitHub, fetchNpm, computeTarget, normalizeVersion, semver, UPSTREAM_REPO, NPM_PKG };
