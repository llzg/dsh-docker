#!/usr/bin/env node
// dsh-safe-deploy 纯策略逻辑：SSOT 解析、通道识别、风险分级、迁移检测。
// 只做 DSH 特有的安全判定；版本"发现"由 Renovate/SSOT 负责，不在此重新实现。
// 依赖：./version-policy.js（其 semver() 解析复用仓库/镜像中的 semver 库）。
const fs = require('fs');
const path = require('path');
const policy = require('./version-policy.js');

const CHANNEL_RANK = { stable: 4, rc: 3, beta: 2, alpha: 1, unknown: 0 };
const CHANNEL_ORDER = ['stable', 'rc', 'beta', 'alpha'];

// 通道默认部署参数（与 docs/dual-channel.md §2 一致；SSOT 里可逐字段覆盖）
const CHANNEL_DEFAULTS = {
  alpha: { port: 3081, container: 'dsh-alpha', project: 'dsh-alpha', dataDir: '/volume1/docker/dsh-alpha' },
  rc: { port: 3083, container: 'dsh-rc', project: 'dsh-rc', dataDir: '/volume1/docker/dsh-rc' },
  beta: { port: 3084, container: 'dsh-beta', project: 'dsh-beta', dataDir: '/volume1/docker/dsh-beta' },
  stable: { port: 3085, container: 'dsh-stable', project: 'dsh-stable', dataDir: '/volume1/docker/dsh-stable' },
};

// ── SSOT ──────────────────────────────────────────────────────────────────
function normalizeChannelEntry(name, entry, legacy) {
  const d = CHANNEL_DEFAULTS[name]
    || { port: 0, container: `dsh-${name}`, project: `dsh-${name}`, dataDir: `/volume1/docker/dsh-${name}` };
  const e = entry && typeof entry === 'object' ? entry : {};
  return {
    name,
    port: Number(e.port || d.port),
    container: String(e.container || d.container),
    project: String(e.project || d.project),
    dataDir: String(e.dataDir || d.dataDir),
    production: String(e.production || e.productionChannel || e.version || (legacy && legacy.production) || '').trim(),
    candidate: String(e.candidate || e.testCandidate || (legacy && legacy.candidate) || '').trim(),
  };
}

function parseSSOT(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const j = JSON.parse(raw);
  if (!j || typeof j !== 'object') throw new Error(`${file} 必须包含 JSON 对象`);

  const primaryChannel = String(j.primaryChannel || j.defaultChannel || 'alpha').trim() || 'alpha';
  const legacy = {
    production: String(j.productionChannel || j.version || '').trim(),
    candidate: String(j.testCandidate || '').trim(),
  };

  // 新 schema（schemaVersion 2）：channels 显式声明；
  // 旧 schema：用顶层 version/productionChannel/testCandidate 合成 primary 单通道。
  const rawChannels = j.channels && typeof j.channels === 'object' ? j.channels : null;
  const channels = {};
  if (rawChannels) {
    for (const [name, entry] of Object.entries(rawChannels)) {
      channels[name] = normalizeChannelEntry(name, entry, legacy);
    }
  }
  if (!Object.keys(channels).length) {
    channels[primaryChannel] = normalizeChannelEntry(primaryChannel, {}, legacy);
  }

  const primary = channels[primaryChannel] || channels[Object.keys(channels)[0]];
  if (!primary || !primary.production) {
    throw new Error(`${file}: 通道 "${primaryChannel}" 的 production 缺失（旧格式需 version 或 productionChannel）`);
  }

  return {
    schemaVersion: Number(j.schemaVersion || (rawChannels ? 2 : 1)),
    primaryChannel: primary.name,
    channels,
    // 兼容镜像：恒等于 primary 通道，旧脚本/旧页面无需改动即可继续工作
    version: primary.production,
    productionChannel: primary.production,
    testCandidate: primary.candidate,
    updatedAt: j.updatedAt || null,
    source: j.source || 'unknown',
    requiredPlugins: Array.isArray(j.requiredPlugins) ? j.requiredPlugins : [],
    optionalPlugins: Array.isArray(j.optionalPlugins) ? j.optionalPlugins : [],
    pluginCompat: j.pluginCompat && typeof j.pluginCompat === 'object' ? j.pluginCompat : {},
    pluginState: j.pluginState && typeof j.pluginState === 'object' ? j.pluginState : {},
  };
}

// 通道识别：唯一实现在 version-policy.js（避免两处漂移）
const channelOf = policy.channelOf;

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
  const state = ssot.pluginState || {};
  const out = {};
  for (const name of Object.keys(ssot.pluginCompat || {})) {
    // 状态判定：REQUIRED > OPTIONAL_ACTIVE(enabled) > OPTIONAL_INACTIVE(安装/配置但 enabled=false) > UNUSED
    const st = state[name] || {};
    if (required.has(name)) out[name] = 'REQUIRED';
    else if (st.enabled === true) out[name] = 'OPTIONAL_ACTIVE';
    else if (optional.has(name) || st.classification) out[name] = 'OPTIONAL_INACTIVE';
    else out[name] = 'UNUSED';
  }
  return out;
}

// promote blocker 判定基于 ACTIVE runtime 依赖（REQUIRED 或 OPTIONAL_ACTIVE）：
//   REQUIRED/OPTIONAL_ACTIVE + FAIL → BLOCK；OPTIONAL_INACTIVE/UNUSED + FAIL → WARN 不 BLOCK。
// 一致性要求：OPTIONAL_INACTIVE 必须同时不进入 runtime bundle set（由 profile bundles 排除 + 启动实测保证）。
function pluginBlockers(ssot) {
  const cls = classifyPlugins(ssot);
  const blockers = [];
  const warnings = [];
  const activeSet = new Set(['REQUIRED', 'OPTIONAL_ACTIVE']);
  for (const [name, info] of Object.entries(ssot.pluginCompat || {})) {
    if (info.status !== 'FAIL') continue;
    if (activeSet.has(cls[name])) blockers.push({ name, class: cls[name], reason: info.reason });
    else warnings.push({ name, class: cls[name], reason: info.reason });
  }
  return { blockers, warnings, classes: cls };
}

// 汇总**单个通道**的全部字段（含插件兼容性策略与 promote 阻塞判定）
function computeChannel(ssot, channelName, { notes = '' } = {}) {
  const name = channelName || ssot.primaryChannel;
  const ch = ssot.channels && ssot.channels[name];
  if (!ch) {
    throw new Error(`SSOT 中不存在通道 "${name}"（可用：${Object.keys((ssot && ssot.channels) || {}).join(', ') || '无'}）`);
  }
  const production = ch.production;
  const candidate = ch.candidate;
  const migration = detectMigration(notes);
  const risk = computeRisk(production, candidate, { migration, notes });
  const hasCandidate = !!candidate && candidate !== production;
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
    // 通道与部署参数（双通道新增）
    channel: name,
    port: ch.port,
    container: ch.container,
    project: ch.project,
    dataDir: ch.dataDir,
    currentVersion: production,
    productionChannel: production,
    testCandidate: candidate || '(none)',
    targetChannel: candidate ? channelOf(candidate) : 'none',
    productionChannelChannel: channelOf(production),
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

// 兼容入口：单通道（channel 缺省 = primaryChannel）
function computeAll({ ssotFile, channel, notes = '' } = {}) {
  const file = ssotFile || path.join(__dirname, '..', 'dsh-version.json');
  const ssot = parseSSOT(file);
  return computeChannel(ssot, channel || ssot.primaryChannel, { notes });
}

// 双通道入口：一次算出 SSOT 里声明的全部通道
function computeChannels({ ssotFile, notes = '' } = {}) {
  const file = ssotFile || path.join(__dirname, '..', 'dsh-version.json');
  const ssot = parseSSOT(file);
  const channels = {};
  for (const name of Object.keys(ssot.channels)) channels[name] = computeChannel(ssot, name, { notes });
  return { primaryChannel: ssot.primaryChannel, schemaVersion: ssot.schemaVersion, ssotFile: file, channels };
}

module.exports = {
  parseSSOT, channelOf, sameCore, channelStep, detectMigration, computeRisk,
  computeAll, computeChannel, computeChannels,
  classifyPlugins, pluginBlockers,
  CHANNEL_ORDER, CHANNEL_RANK, CHANNEL_DEFAULTS,
};

// CLI：node safe-deploy-policy.js [--json] [--ssot <file>] [--channel alpha|rc|all] [--notes <text>]
if (require.main === module) {
  const argv = process.argv.slice(2);
  const pick = (flag) => {
    const i = argv.indexOf(flag);
    return i >= 0 ? argv[i + 1] : undefined;
  };
  const ssotFile = pick('--ssot');
  const notes = pick('--notes');
  const channel = pick('--channel');
  const json = argv.includes('--json');
  try {
    let r;
    if (channel === 'all' || channel === '*') {
      r = computeChannels({ ssotFile, notes });
    } else {
      r = computeAll({ ssotFile, channel, notes });
    }
    if (json) {
      process.stdout.write(JSON.stringify(r, null, 2) + '\n');
    } else {
      const flat = r.channels ? { ...r, channels: Object.keys(r.channels).join(',') } : r;
      for (const [k, v] of Object.entries(flat)) process.stdout.write(`${k}=${typeof v === 'object' ? JSON.stringify(v) : v}\n`);
    }
  } catch (e) {
    process.stderr.write(`safe-deploy-policy: ${e.message}\n`);
    process.exit(1);
  }
}

