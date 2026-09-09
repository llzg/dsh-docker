#!/usr/bin/env node
// Resolve the per-channel build matrix and decide what actually needs building.
//
// 双通道（见 docs/dual-channel.md §8）：
//   * 每条 SSOT 通道各自解析构建目标（通道内最高且可 npm 安装的版本）
//   * **收敛判定改为"该版本是否已存在于 GHCR tag 列表"**——不再依赖 `latest` label
//     （prerelease 永不打 latest，旧逻辑导致每 30 分钟重建同一版本）
//   * 输出 GitHub Actions matrix（每通道一个 job）
//
// Inputs（env）:
//   VERSION_OVERRIDE  显式版本（workflow_dispatch）；只对与其版本段匹配的通道生效
//   FORCE             1 => 忽略"已构建"判定，重建各通道目标（push 事件：补丁变更）
//   DSH_SSOT          SSOT 文件路径（默认 ../dsh-version.json）
//   GHCR_REPO         e.g. llzg/dsh-docker（默认取同值）
//   GH_API_TOKEN      GitHub API 凭据（可选，避免匿名限流）
// Outputs（写入 $GITHUB_OUTPUT）:
//   matrix, any_build, version, decisions,
//   npm_version, npm_latest, npm_next, git_release, git_tag, last_published, waiting_for_npm
const fs = require('fs');
const path = require('path');
const policy = require('./version-policy.js');
const safeDeploy = require('./safe-deploy-policy.js');

const GHCR_REPO = process.env.GHCR_REPO || 'llzg/dsh-docker';

// 已发布的镜像 tag（匿名可读；失败返回 error 而不是抛异常）
async function ghcrTags() {
  const tok = await policy.fetchJson(`https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull&service=ghcr.io`);
  if (tok.error || !tok.data || !tok.data.token) {
    return { status: 'error', error: tok.error || 'token 获取失败', tags: [] };
  }
  const res = await policy.fetchJson(`https://ghcr.io/v2/${GHCR_REPO}/tags/list?n=1000`, {
    headers: { Authorization: `Bearer ${tok.data.token}` },
  });
  if (res.error || !res.data || !Array.isArray(res.data.tags)) {
    return { status: 'error', error: res.error || 'tags 列表不可读', tags: [] };
  }
  return { status: 'ok', error: null, tags: res.data.tags };
}

// 输出值净化：GITHUB_OUTPUT 是 key=value 行协议，值里出现换行会注入额外键
function clean(v) {
  return String(v == null ? '' : v).replace(/[\r\n]+/g, ' ').trim();
}

async function main() {
  const override = (process.env.VERSION_OVERRIDE || '').trim();
  const force = process.env.FORCE === '1' || process.env.FORCE === 'true';
  const ssotFile = process.env.DSH_SSOT || path.join(__dirname, '..', 'dsh-version.json');

  const ssot = safeDeploy.parseSSOT(ssotFile);
  const only = (process.env.DSH_CHANNELS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const channelNames = Object.keys(ssot.channels).filter((c) => !only.length || only.includes(c));

  const sources = await policy.fetchAllSources();
  const targets = policy.computeTargets(sources);
  const ghcr = await ghcrTags();
  const builtSet = new Set(ghcr.tags || []);
  const isBuilt = (v) => builtSet.has(v) || (ghcr.tags || []).some((t) => t.startsWith(`${v}-`));

  console.log(`sources: github release=${sources.github.release.status === 'ok' ? sources.github.release.value : 'ERR'} `
    + `tag=${sources.github.tag.status === 'ok' ? sources.github.tag.value : 'ERR'} `
    + `npm latest=${sources.npm.latest.status === 'ok' ? sources.npm.latest.value : 'ERR'} `
    + `next=${sources.npm.next.status === 'ok' ? sources.npm.next.value : 'ERR'}`);
  console.log(`ghcr: ${ghcr.status === 'ok' ? `${ghcr.tags.length} tags` : `ERROR ${ghcr.error}`}`);
  console.log(`ssot: ${ssotFile} primary=${ssot.primaryChannel} channels=${channelNames.join(',')}`);

  if (override && !channelNames.includes(policy.channelOf(override))) {
    throw new Error(`VERSION_OVERRIDE=${override} 的通道 "${policy.channelOf(override)}" 不在 SSOT 通道列表（${channelNames.join(',')}）中`);
  }
  if (override && !(sources.npm.versions || []).includes(override)) {
    throw new Error(`version "${override}" 不存在于 npm（不可安装），无法构建`);
  }

  const include = [];
  const decisions = [];
  for (const ch of channelNames) {
    const t = targets.channels[ch] || null;
    let version = '';
    if (override) {
      if (policy.channelOf(override) !== ch) continue;
      version = override;
    } else if (t && t.target) {
      version = t.target;
    }
    if (!version) {
      decisions.push({ channel: ch, version: null, build: false, reason: 'no target', ssotCandidate: ssot.channels[ch].candidate });
      continue;
    }
    const alreadyBuilt = isBuilt(version);
    const build = force || !alreadyBuilt;
    if (build) {
      include.push({
        channel: ch,
        version,
        is_prerelease: /^[0-9.]+-[0-9A-Za-z.-]+$/.test(version) ? '1' : '0',
      });
    }
    decisions.push({
      channel: ch,
      version,
      build,
      alreadyBuilt,
      reason: alreadyBuilt ? (force ? 'already built, rebuilt by FORCE' : 'already built') : 'new version',
      waitingForNpm: !!(t && t.waitingForNpm),
      newestUpstream: t ? t.newestUpstream : null,
      ssotCandidate: ssot.channels[ch].candidate,
    });
  }

  const primaryCh = ssot.primaryChannel;
  const primaryDecision = decisions.find((d) => d.channel === primaryCh) || decisions[0] || { version: '' };
  const builtVersions = decisions.filter((d) => d.version && d.alreadyBuilt).map((d) => d.version);

  const lines = [
    `matrix=${clean(JSON.stringify({ include }))}`,
    `any_build=${include.length ? '1' : '0'}`,
    `version=${clean((include.find((i) => i.channel === primaryCh) || include[0] || {}).version || primaryDecision.version || '')}`,
    `decisions=${clean(JSON.stringify(decisions))}`,
    `npm_version=${clean((targets.channels[primaryCh] || {}).target || '')}`,
    `npm_latest=${clean(sources.npm.latest.status === 'ok' ? sources.npm.latest.value : '')}`,
    `npm_next=${clean(sources.npm.next.status === 'ok' ? sources.npm.next.value : '')}`,
    `git_release=${clean(sources.github.release.status === 'ok' ? sources.github.release.value : '')}`,
    `git_tag=${clean(sources.github.tag.status === 'ok' ? sources.github.tag.value : '')}`,
    `last_published=${clean(builtVersions.join(',') || '')}`,
    `waiting_for_npm=${decisions.some((d) => d.waitingForNpm) ? '1' : '0'}`,
  ];

  for (const d of decisions) {
    console.log(`  [${d.channel}] target=${d.version || '(none)'} build=${d.build} (${d.reason})`
      + `${d.waitingForNpm ? ` waitingForNpm=true newest=${d.newestUpstream}` : ''}`
      + `${d.ssotCandidate && d.ssotCandidate !== d.version ? ` ssotCandidate=${d.ssotCandidate}` : ''}`);
  }
  console.log(`build matrix: ${include.map((i) => `${i.channel}@${i.version}`).join(', ') || '(空)'}`);

  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.map((l) => `${l}\n`).join(''));
  }
}

main().catch((e) => {
  console.error(`check-new-version: ${e.message}`);
  process.exit(1);
});
