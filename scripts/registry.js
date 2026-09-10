#!/usr/bin/env node
// 通用 OCI/Docker registry v2 客户端（check-new-version.js / version-server.js 共用）。
//
// 支持三种现实场景：
//   1) ghcr.io 匿名 token 流（公开包，无需凭据）
//   2) 任意 registry v2 + Basic Auth（内网私有 registry，如 192.168.5.35:5050）
//   3) 无凭据的 registry（如 192.168.5.35:5051 缓存 registry）
//
// 关键现实约束：内网 registry 常常**没有 TLS**（http://192.168.5.35:5050），
// 而 ghcr.io 只有 https。因此 scheme 采用"显式 > 探测（https → http）"。
//
// 所有函数都返回结构化结果，不抛异常（调用方决定降级策略）。
const fs = require('fs');
const os = require('os');
const path = require('path');

const TIMEOUT_MS = Number(process.env.DSH_REGISTRY_TIMEOUT_MS || 8000);

// 'ghcr.io/llzg/dsh-docker'            → { registry:'ghcr.io', repository:'llzg/dsh-docker' }
// '192.168.5.35:5050/llzg/dsh-docker'  → { registry:'192.168.5.35:5050', repository:'llzg/dsh-docker' }
// 'llzg/dsh-docker'（无 registry 段）  → { registry:'docker.io', repository:'llzg/dsh-docker' }
function splitImage(ref) {
  const s = String(ref || '').trim().replace(/^https?:\/\//, '');
  const i = s.indexOf('/');
  if (i < 0) return { registry: 'docker.io', repository: s };
  const head = s.slice(0, i);
  const rest = s.slice(i + 1);
  const looksLikeRegistry = head.includes('.') || head.includes(':') || head === 'localhost';
  return looksLikeRegistry ? { registry: head, repository: rest } : { registry: 'docker.io', repository: s };
}

// 从 docker config.json 里取某个 registry 的凭据（auth base64 或 username/password）
function authFromConfigFile(file, registry) {
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    const entry = (j.auths && (j.auths[registry] || j.auths[`https://${registry}`])) || null;
    if (!entry) return null;
    if (entry.auth) {
      const raw = Buffer.from(entry.auth, 'base64').toString('utf8');
      const idx = raw.indexOf(':');
      if (idx > 0) return { username: raw.slice(0, idx), password: raw.slice(idx + 1) };
    }
    if (entry.username && entry.password) return { username: entry.username, password: entry.password };
    return null;
  } catch {
    return null;
  }
}

function resolveAuth(registry, opts = {}) {
  if (opts.username && opts.password) return { username: opts.username, password: opts.password };
  if (process.env.DSH_REGISTRY_USER && process.env.DSH_REGISTRY_PASSWORD) {
    return { username: process.env.DSH_REGISTRY_USER, password: process.env.DSH_REGISTRY_PASSWORD };
  }
  const candidates = [
    process.env.DOCKER_CONFIG ? path.join(process.env.DOCKER_CONFIG, 'config.json') : null,
    path.join(os.homedir(), '.docker', 'config.json'),
    '/home/lzg/.docker/config.json',
    '/root/.docker/config.json',
  ].filter(Boolean);
  for (const f of candidates) {
    const a = authFromConfigFile(f, registry);
    if (a) return a;
  }
  return null;
}

function basicHeader(auth) {
  return `Basic ${Buffer.from(`${auth.username}:${auth.password}`).toString('base64')}`;
}

async function getJson(url, headers) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, { headers: { 'User-Agent': 'dsh-registry-client', ...headers }, signal: ctrl.signal });
    if (res.status === 401 || res.status === 403) return { error: `HTTP ${res.status}（需要凭据）`, httpStatus: res.status };
    if (!res.ok) return { error: `HTTP ${res.status}`, httpStatus: res.status };
    const text = await res.text();
    try {
      return { data: JSON.parse(text) };
    } catch {
      return { error: '响应不是合法 JSON' };
    }
  } catch (e) {
    const code = (e && (e.code || e.name)) || 'unknown';
    const reason = code === 'AbortError' || code === 'TimeoutError' || code === 20
      ? '连接超时（timeout）'
      : `网络错误（${code}）`;
    return { error: reason };
  } finally {
    clearTimeout(timer);
  }
}

// ghcr.io 匿名 token（公开包）
async function ghcrToken(repository, auth) {
  const url = `https://ghcr.io/token?scope=repository:${repository}:pull&service=ghcr.io`;
  const headers = auth ? { Authorization: basicHeader(auth) } : {};
  const res = await getJson(url, headers);
  if (res.error || !res.data || !res.data.token) return { error: res.error || 'token 缺失' };
  return { token: res.data.token };
}

// 列出某镜像仓库的全部 tag。ref 可以是 'ghcr.io/llzg/dsh-docker' 或 'host:port/path'。
async function listTags(ref, opts = {}) {
  const { registry, repository } = splitImage(ref);
  const auth = resolveAuth(registry, opts);
  const forced = opts.scheme || process.env.DSH_REGISTRY_SCHEME || '';
  const schemes = forced ? [forced] : (registry === 'ghcr.io' ? ['https'] : ['https', 'http']);

  if (registry === 'ghcr.io') {
    let used = !!auth;
    let t = await ghcrToken(repository, auth);
    // 全局凭据（DSH_REGISTRY_USER/PASSWORD）是给**内网私有 registry** 的，但它是全局的，
    // 会被一起发给 ghcr.io → 403（实测：版本页同时查 5050 与 ghcr 时 ghcr 项报
    // "ghcr token: HTTP 403（需要凭据）"）。因此带凭据失败时**回退匿名**再试一次：
    // ghcr 上的公开包匿名可读，凭据只对私有包有意义。
    if (t.error && auth) {
      t = await ghcrToken(repository, null);
      if (!t.error) used = false;
    }
    if (t.error) return { status: 'error', registry, repository, scheme: 'https', tags: [], error: `ghcr token: ${t.error}` };
    const res = await getJson(`https://ghcr.io/v2/${repository}/tags/list?n=1000`, { Authorization: `Bearer ${t.token}` });
    if (res.error || !res.data || !Array.isArray(res.data.tags)) {
      return { status: 'error', registry, repository, scheme: 'https', tags: [], error: res.error || 'tags 列表不可读' };
    }
    return { status: 'ok', registry, repository, scheme: 'https', authUsed: used, tags: res.data.tags, error: null };
  }

  const errors = [];
  for (const scheme of schemes) {
    const headers = auth ? { Authorization: basicHeader(auth) } : {};
    const res = await getJson(`${scheme}://${registry}/v2/${repository}/tags/list?n=1000`, headers);
    // 注意：部分 registry（如 daocloud 缓存代理）对已知仓库返回 "tags": null，
    // 语义是"仓库存在但无 tag"，不能当错误处理。
    if (!res.error && res.data && typeof res.data === 'object') {
      const tags = Array.isArray(res.data.tags) ? res.data.tags : [];
      return { status: 'ok', registry, repository, scheme, authUsed: !!auth, tags, error: null };
    }
    errors.push(`${scheme}${auth ? '(带凭据)' : ''}: ${res.error}`);
    // 401/403 在 http 上不会变好（除非是 scheme 问题），但 https→http 探测仍值得继续
  }
  // 兜底：带全局凭据访问**公开** registry 会被 401/403 挡掉（凭据是给内网私有 registry 的，
  // 却是全局环境变量）→ 再匿名试一遍，只有在 "原来就没带凭据" 时才跳过。
  if (auth) {
    for (const scheme of schemes) {
      const res = await getJson(`${scheme}://${registry}/v2/${repository}/tags/list?n=1000`, {});
      if (!res.error && res.data && typeof res.data === 'object') {
        const tags = Array.isArray(res.data.tags) ? res.data.tags : [];
        return { status: 'ok', registry, repository, scheme, authUsed: false, tags, error: null };
      }
      errors.push(`${scheme}(匿名回退): ${res.error}`);
    }
  }
  return { status: 'error', registry, repository, scheme: schemes.join('→'), tags: [], error: errors.join('; ') };
}

// 从环境变量解析 registry 列表：
//   DSH_REGISTRIES='ghcr.io/llzg/dsh-docker,192.168.5.35:5050/llzg/dsh-docker'
//   未设置时返回 [DSH_IMAGE_REF || 'ghcr.io/llzg/dsh-docker']
function registriesFromEnv(env = process.env) {
  const raw = (env.DSH_REGISTRIES || env.DSH_IMAGE_REF || 'ghcr.io/llzg/dsh-docker').trim();
  return raw.split(',').map((s) => s.trim()).filter(Boolean);
}

module.exports = { splitImage, listTags, registriesFromEnv, resolveAuth, TIMEOUT_MS };
