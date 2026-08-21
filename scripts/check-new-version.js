#!/usr/bin/env node
// Resolve the dsh version to build and publish.
//
// 版本检测策略（与版本页共用 scripts/version-policy.js）：
//   源：GitHub Release / GitHub Tag / npm latest / npm next（每个源独立失败处理）
//   目标：各源候选中最高的、且真实存在于 npm 的版本（Dockerfile 用 npm install，
//         因此目标必须可安装；GitHub 有新版本但 npm 未发布时等待）。
// "Last published version" 读 GHCR latest 镜像标签；失败回退 CURRENT_VERSION 文件。
//
// Inputs:
//   env VERSION_OVERRIDE  显式版本（workflow_dispatch 输入）
//   env FORCE             1 => 总是构建（push 事件，如补丁变更）
//   env GHCR_REPO         e.g. llzg/dsh-docker
//   env GHCR_USER/GHCR_TOKEN  GHCR 凭据（GITHUB_TOKEN）
//   env GH_API_TOKEN      GitHub API 凭据（GITHUB_TOKEN，避免匿名限流）
//   file CURRENT_VERSION  回退的已构建版本
//   env GITHUB_OUTPUT     输出文件
// Outputs: version(空=跳过), npm_version(目标), npm_latest, npm_next, git_release, git_tag, last_published, waiting_for_npm
const fs = require('fs');
const https = require('https');
const policy = require('./version-policy.js');

function getJson(url, auth, extraHeaders, redirects) {
  redirects = redirects || 0;
  return new Promise((resolve, reject) => {
    const headers = { 'User-Agent': 'dsh-docker-ci' };
    if (auth) headers.Authorization = auth;
    Object.assign(headers, extraHeaders || {});
    https
      .get(url, { headers }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects < 4) {
          res.resume();
          return resolve(getJson(res.headers.location, auth, extraHeaders, redirects + 1));
        }
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
        });
      })
      .on('error', reject);
  });
}

// Read org.opencontainers.image.version from the GHCR `latest` manifest config.
async function ghcrLastVersion() {
  const repo = process.env.GHCR_REPO || '';
  if (!repo) return '';
  const scope = `repository:${repo}:pull`;
  let tok = '';
  try {
    const t = await getJson(`https://ghcr.io/token?scope=${encodeURIComponent(scope)}&service=ghcr.io`);
    tok = (t && t.token) || '';
  } catch (_) { /* anonymous failed */ }
  if (!tok && process.env.GHCR_USER && process.env.GHCR_TOKEN) {
    try {
      const auth = `Basic ${Buffer.from(`${process.env.GHCR_USER}:${process.env.GHCR_TOKEN}`).toString('base64')}`;
      const t = await getJson(`https://ghcr.io/token?scope=${encodeURIComponent(scope)}&service=ghcr.io`, auth);
      tok = (t && t.token) || '';
    } catch (_) { /* auth failed */ }
  }
  if (!tok) return '';
  const accept = 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json';
  try {
    const manifest = await getJson(`https://ghcr.io/v2/${repo}/manifests/latest`, `Bearer ${tok}`, { Accept: accept });
    if (manifest.manifests && !manifest.config) {
      const first = manifest.manifests[0];
      if (!first) return '';
      const sub = await getJson(`https://ghcr.io/v2/${repo}/manifests/${first.digest}`, `Bearer ${tok}`, { Accept: accept });
      manifest.config = sub.config;
    }
    if (!manifest.config || !manifest.config.digest) return '';
    const cfg = await getJson(`https://ghcr.io/v2/${repo}/blobs/${manifest.config.digest}`, `Bearer ${tok}`, { Accept: accept });
    return (cfg.config && cfg.config.Labels && cfg.config.Labels['org.opencontainers.image.version']) || '';
  } catch (e) {
    console.error(`ghcrLastVersion: ${e.message}`);
    return '';
  }
}

async function main() {
  const override = (process.env.VERSION_OVERRIDE || '').trim();
  const force = process.env.FORCE === '1' || process.env.FORCE === 'true';
  let current = '';
  try { current = fs.readFileSync('CURRENT_VERSION', 'utf8').trim(); } catch (_) {}

  const sources = await policy.fetchAllSources();
  const target = policy.computeTarget(sources);
  const { release, tag } = sources.github;
  const npm = sources.npm;

  console.log(
    `github release=${release.status === 'ok' ? release.value : 'ERR:' + release.error} ` +
    `github tag=${tag.status === 'ok' ? tag.value : 'ERR:' + tag.error} ` +
    `npm latest=${npm.latest.status === 'ok' ? npm.latest.value : 'ERR'} ` +
    `npm next=${npm.next.status === 'ok' ? npm.next.value : 'ERR'} ` +
    `target=${target.target} waitingForNpm=${target.waitingForNpm}`
  );

  const ghcrLast = await ghcrLastVersion();
  const lastPublished = ghcrLast || current;
  console.log(`lastPublished(ghcr)=${ghcrLast || '(unavailable)'} fallbackFile=${current}`);

  let version = '';
  if (override) {
    if (override !== target.target) {
      // 显式指定版本必须真实存在于 npm（Dockerfile 走 npm install）
      const versions = npm.versions || [];
      if (!versions.includes(override)) {
        throw new Error(`version "${override}" 不存在于 npm（不可安装），无法构建`);
      }
    }
    version = override;
  } else if (force) {
    version = target.target || '';
  } else if (target.target && target.target !== lastPublished) {
    version = target.target;
  }

  const lines = [
    `version=${version}`,
    `npm_version=${target.target || ''}`,
    `npm_latest=${npm.latest.status === 'ok' ? npm.latest.value || '' : ''}`,
    `npm_next=${npm.next.status === 'ok' ? npm.next.value || '' : ''}`,
    `git_release=${release.status === 'ok' ? release.value || '' : ''}`,
    `git_tag=${tag.status === 'ok' ? tag.value || '' : ''}`,
    `last_published=${lastPublished}`,
    `waiting_for_npm=${target.waitingForNpm ? '1' : '0'}`,
  ];
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.map((l) => l + '\n').join(''));
  }
  console.log(`build=${version || '(skip, already current)'}`);
}

main().catch((e) => {
  console.error(`check-new-version: ${e.message}`);
  process.exit(1);
});
