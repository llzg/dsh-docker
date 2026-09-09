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
const registry = require('./registry.js');

// 收敛判定用的镜像仓库列表（可多个）：
//   DSH_REGISTRIES='ghcr.io/llzg/dsh-docker,192.168.5.35:5050/llzg/dsh-docker'
//   未设置时 = DSH_IMAGE_REF / 默认 GHCR。内网 registry 凭据走 DSH_REGISTRY_USER/PASSWORD
//   或 docker config.json（见 scripts/registry.js）。
function registryRefs() {
  return registry.registriesFromEnv();
}

// 二级收敛源：CI 回写的 build-status.json（只认成功的构建）。
// 用途：所有 registry 都不可达时仍能判断"这个版本是否已经构建过"，避免退回"每 30 分钟重建"。
function versionsFromBuildStatus() {
  const file = process.env.DSH_BUILD_STATUS || path.join(__dirname, '..', 'build-status.json');
  const out = new Set();
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const c of Object.values(j.channels || {})) {
      if (c && c.conclusion === 'success' && c.version) out.add(String(c.version));
    }
  } catch { /* 文件不存在/损坏 → 空 */ }
  return out;
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

  // 收敛判定：目标版本是否已存在于任一 registry 的 tag 列表（或 build-status.json 的成功记录）
  const refs = registryRefs();
  const regResults = await Promise.all(refs.map((r) => registry.listTags(r).catch((e) => ({ status: 'error', registry: r, tags: [], error: e.message }))));
  const builtSet = new Set();
  for (const r of regResults) if (r.status === 'ok') for (const tg of r.tags) builtSet.add(tg);
  const statusVersions = versionsFromBuildStatus();
  const registryOk = regResults.some((r) => r.status === 'ok');
  const canDecide = registryOk || statusVersions.size > 0;
  const isBuilt = (v) => statusVersions.has(v) || builtSet.has(v) || [...builtSet].some((t) => t.startsWith(`${v}-`));

  for (const r of regResults) {
    console.log(`registry ${r.registry}/${r.repository}: ${r.status === 'ok' ? `${r.tags.length} tags (${r.scheme}${r.authUsed ? ', auth' : ', anonymous'})` : `ERROR ${r.error}`}`);
  }
  console.log(`build-status.json 成功记录: ${statusVersions.size ? [...statusVersions].join(',') : '(无)'}`);

  console.log(`sources: github release=${sources.github.release.status === 'ok' ? sources.github.release.value : 'ERR'} `
    + `tag=${sources.github.tag.status === 'ok' ? sources.github.tag.value : 'ERR'} `
    + `npm latest=${sources.npm.latest.status === 'ok' ? sources.npm.latest.value : 'ERR'} `
    + `next=${sources.npm.next.status === 'ok' ? sources.npm.next.value : 'ERR'}`);
  console.log(`ssot: ${ssotFile} primary=${ssot.primaryChannel} channels=${channelNames.join(',')}`);

  if (override && !channelNames.includes(policy.channelOf(override))) {
    const all = Object.keys(ssot.channels);
    const why = all.includes(policy.channelOf(override))
      ? `（通道 "${policy.channelOf(override)}" 存在于 SSOT，但被 DSH_CHANNELS=${process.env.DSH_CHANNELS} 过滤掉了）`
      : `（SSOT 通道：${all.join(',')}）`;
    throw new Error(`VERSION_OVERRIDE=${override} 的通道 "${policy.channelOf(override)}" 不在本次构建的通道列表中 ${why}`);
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
    // 收敛信息不可用（所有 registry 都查不到 且 没有 build-status 记录）：
    // 宁可跳过也不盲目重建——旧实现正是"判定不出就每 30 分钟重建一次"。
    // FORCE（push 事件）仍然构建，因为那是"补丁/脚本变了必须重发"的语义。
    if (!canDecide && !force) {
      decisions.push({ channel: ch, version, build: false, alreadyBuilt: null, reason: 'convergence unknown (no registry reachable, no build-status record)' });
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
