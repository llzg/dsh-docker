#!/usr/bin/env node
// dsh-safe-deploy 纯策略逻辑：SSOT 解析、通道识别、风险分级、迁移检测。
// 只做 DSH 特有的安全判定；版本"发现"由 Renovate/SSOT 负责，不在此重新实现。
// 依赖：./version-policy.js（其 semver() 解析复用仓库/镜像中的 semver 库）。
const fs = require('fs');
const path = require('path');
const policy = require('./version-policy.js');

const CHANNEL_RANK = { stable: 4, rc: 3, beta: 2, alpha: 1, unknown: 0 };
const CHANNEL_ORDER = ['stable', 'rc', 'beta', 'alpha'];

// ── SSOT ──────────────────────────────────────────────────────────────────
function parseSSOT(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const j = JSON.parse(raw);
  if (!j || typeof j !== 'object') throw new Error(`${file} 必须包含 JSON 对象`);
  const version = String(j.version || '').trim();
  const productionChannel = String(j.productionChannel || j.version || '').trim();
  const testCandidate = String(j.testCandidate || '').trim();
  if (!version) throw new Error(`${file}: version 缺失`);
  return {
    version,
    productionChannel,
    testCandidate,
    updatedAt: j.updatedAt || null,
    source: j.source || 'unknown',
    requiredPlugins: Array.isArray(j.requiredPlugins) ? j.requiredPlugins : [],
    optionalPlugins: Array.isArray(j.optionalPlugins) ? j.optionalPlugins : [],
    pluginCompat: j.pluginCompat && typeof j.pluginCompat === 'object' ? j.pluginCompat : {},
  };
}

// 通道识别：stable / rc / beta / alpha / unknown（semver prerelease 段）
function channelOf(v) {
  const s = String(v || '').trim().toLowerCase();
  if (!s) return 'unknown';
  if (s.includes('-rc.')) return 'rc';
  if (s.includes('-beta')) return 'beta';
  if (s.includes('-alpha')) return 'alpha';
  if (s.includes('-')) return 'unknown';
  return 'stable';
}

// 同一核心版本线（0.1.1-rc.2 与 0.1.1-alpha.3 同为 0.1.1 线）
function sameCore(a, b) {
  return String(a).split('-')[0] === String(b).split('-')[0];
}

// 同线内通道是否前进（alpha→beta→rc→stable 为前进；同通道为持平；后退为降级）
function channelStep(production, candidate) {
  const pc = channelOf(production);
  const cc = channelOf(candidate);
  const d = CHANNEL_RANK[cc] - CHANNEL_RANK[pc];
  return d > 0 ? 'advance' : d < 0 ? 'regress' : 'same';
}

const MIGRATION_KEYWORDS = [
  'migration', 'session format', 'persistence', 'projection', 'storage format',
  'storage', 'settings schema', 'credentials', 'provider api', 'plugin api',
  'schema', 'database', 'forward-only', 'incompatible',
];

// 根据发布说明文本判断迁移状态：none / reversible / forward-only / unknown
// 规则：提及 incompatible / forward-only / migration / storage format → forward-only
//       提及 migration 但明确可逆 → reversible；提及任何持久化相关词但无说明 → unknown
function detectMigration(notes) {
  const s = String(notes || '').toLowerCase();
  if (!s.trim()) return 'none';
  if (/forward-only|incompatible|not compatible|无法兼容|不兼容/.test(s)) return 'forward-only';
  if (/reversible|可逆|backward/.test(s)) return 'reversible';
  if (MIGRATION_KEYWORDS.some((k) => s.includes(k))) return 'unknown';
  return 'none';
}

// 升级风险分级（生产通道 → 测试候选）
//   LOW     同核心线内、同/低通道、无持久化变化
//   MEDIUM  同核心线内 prerelease 阶段前进（alpha→beta→rc→stable）
//   HIGH    跨核心版本线（0.1.1-* → 0.1.2-*）或检出持久化/API 相关变化
//   BLOCKED snapshot 失败 / migration forward-only|unknown / 版本不可解析等
function computeRisk(production, candidate, { migration = 'none', notes = '' } = {}) {
  if (!production || !candidate) return 'BLOCKED';
  const sv = policy.semver();
  try {
    if (!sv.valid(production) || !sv.valid(candidate)) return 'BLOCKED';
  } catch {
    return 'BLOCKED';
  }
  if (sv.eq(production, candidate)) return 'LOW';
  if (migration === 'forward-only' || migration === 'unknown') return 'BLOCKED';
  if (!sameCore(production, candidate)) return 'HIGH';
  const step = channelStep(production, candidate);
  if (step === 'advance') return 'MEDIUM';
  if (step === 'same') return 'LOW';
  return 'MEDIUM'; // 阶段回退（生产 rc → 候选 alpha）视为需注意
}

// 插件兼容性分类：REQUIRED（实际启用/生产必需）→ FAIL 阻塞 promote；
// OPTIONAL/UNUSED（已配置但未启用/未使用）→ FAIL 仅告警，不阻塞。
function classifyPlugins(ssot) {
  const required = new Set(ssot.requiredPlugins || []);
  const optional = new Set(ssot.optionalPlugins || []);
  const out = {};
  for (const name of Object.keys(ssot.pluginCompat || {})) {
    out[name] = required.has(name) ? 'REQUIRED' : optional.has(name) ? 'OPTIONAL' : 'UNUSED';
  }
  return out;
}

// 仅 REQUIRED 且 FAIL 的插件构成 promote blocker；OPTIONAL/UNUSED 的 FAIL 只告警。
function pluginBlockers(ssot) {
  const cls = classifyPlugins(ssot);
  const blockers = [];
  const warnings = [];
  for (const [name, info] of Object.entries(ssot.pluginCompat || {})) {
    if (info.status !== 'FAIL') continue;
    if (cls[name] === 'REQUIRED') blockers.push({ name, class: cls[name], reason: info.reason });
    else warnings.push({ name, class: cls[name], reason: info.reason });
  }
  return { blockers, warnings, classes: cls };
}

// 汇总一次 check 的全部字段（含插件兼容性策略与 promote 阻塞判定）
function computeAll({ ssotFile, notes = '' } = {}) {
  const file = ssotFile || path.join(__dirname, '..', 'dsh-version.json');
  const ssot = parseSSOT(file);
  const migration = detectMigration(notes);
  const risk = computeRisk(ssot.productionChannel, ssot.testCandidate, { migration, notes });
  const hasCandidate = !!ssot.testCandidate && ssot.testCandidate !== ssot.productionChannel;
  const pb = pluginBlockers(ssot);
  // 版本级 BLOCKED（migration forward-only/unknown、非法版本）与 REQUIRED 插件 blocker 合并
  const versionBlocked = risk === 'BLOCKED';
  const otherBlockers = [
    ...(versionBlocked ? [{ kind: 'version', detail: migration === 'none' ? '版本不可解析/非法' : `migration=${migration}` }] : []),
    ...pb.blockers,
  ];
  // siliconflow 专项（OPTIONAL，不阻塞；保留记录）
  const sf = ssot.pluginCompat && ssot.pluginCompat['@siliconflow-official/dsh-llm-siliconflow'];
  const siliconflow = {
    inUse: false,
    compat: sf ? (sf.status === 'FAIL' ? 'FAIL' : sf.status) : 'N/A',
    blocking: false,
    class: pb.classes['@siliconflow-official/dsh-llm-siliconflow'] || 'UNUSED',
    record: sf ? sf.reason : null,
  };
  return {
    currentVersion: ssot.version,
    productionChannel: ssot.productionChannel,
    testCandidate: ssot.testCandidate || '(none)',
    targetChannel: ssot.testCandidate ? channelOf(ssot.testCandidate) : 'none',
    productionChannelChannel: channelOf(ssot.productionChannel),
    migrationStatus: migration,
    upgradeRisk: risk,
    dataIsolationRequired: risk === 'HIGH' || risk === 'BLOCKED' || migration !== 'none',
    candidateIsNewer: hasCandidate,
    ssotSource: ssot.source,
    ssotUpdatedAt: ssot.updatedAt,
    requiredRuntimeDependencies: [...(ssot.requiredPlugins || [])],
    optionalPlugins: [...(ssot.optionalPlugins || [])],
    pluginCompat: ssot.pluginCompat || {},
    pluginClass: pb.classes,
    pluginBlockers: pb.blockers,
    pluginWarnings: pb.warnings,
    otherBlockers,
    promoteBlocked: otherBlockers.length > 0,
    siliconflow,
  };
}

module.exports = {
  parseSSOT, channelOf, sameCore, channelStep, detectMigration, computeRisk, computeAll,
  classifyPlugins, pluginBlockers,
  CHANNEL_ORDER, CHANNEL_RANK,
};

// CLI：node safe-deploy-policy.js [--json] [--ssot <file>] [--notes <text>]
if (require.main === module) {
  const argv = process.argv.slice(2);
  const ssotIdx = argv.indexOf('--ssot');
  const notesIdx = argv.indexOf('--notes');
  const ssotFile = ssotIdx >= 0 ? argv[ssotIdx + 1] : undefined;
  const notes = notesIdx >= 0 ? argv[notesIdx + 1] : undefined;
  const r = computeAll({ ssotFile, notes });
  if (argv.includes('--json')) {
    process.stdout.write(JSON.stringify(r, null, 2) + '\n');
  } else {
    for (const [k, v] of Object.entries(r)) process.stdout.write(`${k}=${v}\n`);
  }
}

