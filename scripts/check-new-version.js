#!/usr/bin/env node
// Resolve the dsh version to build and publish.
//
// Inputs:
//   env VERSION_OVERRIDE  explicit version (workflow_dispatch input, optional)
//   env FORCE             1 => always build (push event, e.g. patch changes)
//   file CURRENT_VERSION  last built & published version (committed to repo)
//   env GITHUB_OUTPUT     GitHub Actions output file
//
// Outputs (GITHUB_OUTPUT): version, npm_version, current
//   version == ''  => nothing to build (CI skips downstream steps)
const fs = require('fs');
const https = require('https');

function getJson(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { 'User-Agent': 'dsh-docker-ci' } }, (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
        });
      })
      .on('error', reject);
  });
}

async function main() {
  const override = (process.env.VERSION_OVERRIDE || '').trim();
  const force = process.env.FORCE === '1' || process.env.FORCE === 'true';
  let current = '';
  try { current = fs.readFileSync('CURRENT_VERSION', 'utf8').trim(); } catch (_) {}

  const pkg = await getJson('https://registry.npmjs.org/@deepseek-ai/dsh');
  const npmLatest = (pkg['dist-tags'] || {}).latest || '';
  if (!npmLatest) throw new Error('cannot resolve npm dist-tag "latest" for @deepseek-ai/dsh');

  let version = '';
  if (override) {
    if (!(override in (pkg.versions || {})))
      throw new Error(`version "${override}" is not published on npm`);
    version = override;
  } else if (force) {
    version = npmLatest;
  } else if (npmLatest !== current) {
    version = npmLatest;
  }

  const lines = [`version=${version}`, `npm_version=${npmLatest}`, `current=${current}`];
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.map((l) => l + '\n').join(''));
  }
  console.log(`npm latest=${npmLatest}  current=${current}  build=${version || '(skip, already current)'}`);
}

main().catch((e) => {
  console.error(`check-new-version: ${e.message}`);
  process.exit(1);
});
