#!/usr/bin/env node
// Resolve the dsh version to build and publish.
//
// "Last published version" is read from the GHCR `latest` image's
// org.opencontainers.image.version label (no repo write-back needed, no races).
// Falls back to the committed CURRENT_VERSION file if the GHCR query fails.
//
// Inputs:
//   env VERSION_OVERRIDE  explicit version (workflow_dispatch input, optional)
//   env FORCE             1 => always build (push event, e.g. patch changes)
//   env GHCR_REPO         e.g. llzg/dsh-docker
//   env GHCR_USER/GHCR_TOKEN  optional GHCR credentials (GITHUB_TOKEN)
//   file CURRENT_VERSION  fallback last-built version (committed)
//   env GITHUB_OUTPUT     GitHub Actions output file
//
// Outputs (GITHUB_OUTPUT): version, npm_version, last_published
//   version == ''  => nothing to build (CI skips downstream steps)
const fs = require('fs');
const https = require('https');

function getJson(url, auth, extraHeaders, redirects) {
  redirects = redirects || 0;
  return new Promise((resolve, reject) => {
    const headers = { 'User-Agent': 'dsh-docker-ci' };
    if (auth) headers.Authorization = auth;
    Object.assign(headers, extraHeaders || {});
    https
      .get(url, { headers }, (res) => {
        // GHCR may 307-redirect manifest/blob fetches to a regional registry
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
    // manifest list/index -> pick first platform manifest
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

  const pkg = await getJson('https://registry.npmjs.org/@deepseek-ai/dsh');
  const npmLatest = (pkg['dist-tags'] || {}).latest || '';
  if (!npmLatest) throw new Error('cannot resolve npm dist-tag "latest" for @deepseek-ai/dsh');

  const ghcrLast = await ghcrLastVersion();
  const lastPublished = ghcrLast || current;
  console.log(`npm latest=${npmLatest}  lastPublished(ghcr)=${ghcrLast || '(unavailable)'}  fallbackFile=${current}`);

  let version = '';
  if (override) {
    if (!(override in (pkg.versions || {})))
      throw new Error(`version "${override}" is not published on npm`);
    version = override;
  } else if (force) {
    version = npmLatest;
  } else if (npmLatest !== lastPublished) {
    version = npmLatest;
  }

  const lines = [`version=${version}`, `npm_version=${npmLatest}`, `last_published=${lastPublished}`];
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.map((l) => l + '\n').join(''));
  }
  console.log(`build=${version || '(skip, already current)'}`);
}

main().catch((e) => {
  console.error(`check-new-version: ${e.message}`);
  process.exit(1);
});
