#!/usr/bin/env node
// 双通道策略离线测试（不联网；CI 的 Policy tests 步骤直接跑这个）。
// 覆盖：通道识别 / 每通道目标解析（含通道隔离）/ SSOT 归一化（新旧 schema）/ 兼容镜像字段 /
//       单通道与多通道 API / CLI 参数解析约定。
const fs = require('fs');
const os = require('os');
const path = require('path');
const policy = require('./version-policy.js');
const safeDeploy = require('./safe-deploy-policy.js');

const results = [];
function t(id, name, pass, detail) {
  results.push({ id, name, pass: !!pass, detail: detail || '' });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}  ${name}${detail ? '  | ' + detail : ''}`);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-dual-'));

function writeSsot(name, obj) {
  const f = path.join(tmp, name);
  fs.writeFileSync(f, JSON.stringify(obj, null, 2));
  return f;
}

// ── 1. 通道识别 ─────────────────────────────────────────────────────────────
t('D1', 'channelOf 基本判定', policy.channelOf('0.1.5-alpha.2') === 'alpha'
  && policy.channelOf('0.1.2-rc.1') === 'rc'
  && policy.channelOf('0.1.2') === 'stable'
  && policy.channelOf('0.1.2-beta.1') === 'beta'
  && policy.channelOf('') === 'unknown',
  ['0.1.5-alpha.2', '0.1.2-rc.1', '0.1.2', '0.1.2-beta.1'].map((v) => `${v}→${policy.channelOf(v)}`).join(' '));

t('D2', 'safe-deploy-policy 与 version-policy 共用同一 channelOf', safeDeploy.channelOf === policy.channelOf);

// ── 2. 每通道目标解析 ───────────────────────────────────────────────────────
const sources = {
  github: {
    release: { value: '0.1.5-alpha.2', status: 'ok' },
    tag: { value: '0.1.5-alpha.2', status: 'ok' },
  },
  npm: {
    latest: { value: '0.1.2-rc.1', status: 'ok' },
    next: { value: '0.1.2-rc.1', status: 'ok' },
    versions: ['0.1.2-alpha.5', '0.1.2-rc.1', '0.1.3-alpha.2', '0.1.5-alpha.1', '0.1.5-alpha.2'],
    npmError: null,
  },
};

const targets = policy.computeTargets(sources);
t('D3', 'alpha 目标 = 通道内最高可安装版本', targets.channels.alpha.target === '0.1.5-alpha.2', `target=${targets.channels.alpha.target}`);
t('D4', 'rc 目标 = 通道内最高可安装版本（不被 alpha 压过）', targets.channels.rc.target === '0.1.2-rc.1', `target=${targets.channels.rc.target}`);
t('D5', 'stable 通道无候选 → target=null', targets.channels.stable.target === null, `target=${targets.channels.stable.target}`);

// 通道隔离：GitHub 出现 rc 新版但 npm 未发布 → 只影响 rc
const sources2 = JSON.parse(JSON.stringify(sources));
sources2.github.release.value = '0.1.3-rc.1';
sources2.github.tag.value = '0.1.3-rc.1';
const targets2 = policy.computeTargets(sources2);
t('D6', 'rc 上游有新版未进 npm → rc.waitingForNpm=true 且 rc 目标仍为可安装版',
  targets2.channels.rc.waitingForNpm === true && targets2.channels.rc.target === '0.1.2-rc.1',
  `waiting=${targets2.channels.rc.waitingForNpm} target=${targets2.channels.rc.target}`);
t('D7', 'rc 的等待不影响 alpha', targets2.channels.alpha.waitingForNpm === false && targets2.channels.alpha.target === '0.1.5-alpha.2',
  `alpha waiting=${targets2.channels.alpha.waitingForNpm} target=${targets2.channels.alpha.target}`);

// ── 3. SSOT 归一化 ──────────────────────────────────────────────────────────
const newSsotFile = writeSsot('new.json', {
  schemaVersion: 2,
  primaryChannel: 'alpha',
  channels: {
    alpha: { production: '0.1.3-alpha.2', candidate: '0.1.5-alpha.2' },
    rc: { port: 3083, production: '0.1.2-rc.1', candidate: '0.1.2-rc.1' },
  },
  requiredPlugins: ['@deepseek-ai/dsh-base'],
});
const newSsot = safeDeploy.parseSSOT(newSsotFile);
t('D8', '新 schema：解析出两条通道', Object.keys(newSsot.channels).join(',') === 'alpha,rc', Object.keys(newSsot.channels).join(','));
t('D9', '新 schema：未声明的部署参数取默认值', newSsot.channels.alpha.port === 3081 && newSsot.channels.alpha.container === 'dsh-alpha'
  && newSsot.channels.alpha.project === 'dsh-alpha', `port=${newSsot.channels.alpha.port} container=${newSsot.channels.alpha.container}`);
t('D10', '新 schema：显式覆盖生效', newSsot.channels.rc.port === 3083, `rc.port=${newSsot.channels.rc.port}`);
t('D11', '兼容镜像：顶层字段 = primary 通道', newSsot.version === '0.1.3-alpha.2'
  && newSsot.productionChannel === '0.1.3-alpha.2' && newSsot.testCandidate === '0.1.5-alpha.2',
  `version=${newSsot.version} productionChannel=${newSsot.productionChannel} testCandidate=${newSsot.testCandidate}`);

const oldSsotFile = writeSsot('old.json', { version: '0.1.1-rc.2', testCandidate: '0.1.2-alpha.3', source: 'manual' });
const oldSsot = safeDeploy.parseSSOT(oldSsotFile);
t('D12', '旧 schema 自动合成单通道', oldSsot.schemaVersion === 1 && Object.keys(oldSsot.channels).length === 1
  && oldSsot.channels.alpha.production === '0.1.1-rc.2' && oldSsot.channels.alpha.candidate === '0.1.2-alpha.3',
  `channels=${Object.keys(oldSsot.channels).join(',')} prod=${oldSsot.channels.alpha.production}`);

const badSsotFile = writeSsot('bad.json', { channels: { alpha: { candidate: '1.0.0' } } });
let badThrew = false;
try { safeDeploy.parseSSOT(badSsotFile); } catch { badThrew = true; }
t('D13', '缺 production 时报错（不静默）', badThrew);

// ── 4. 策略 API ─────────────────────────────────────────────────────────────
const alphaView = safeDeploy.computeChannel(newSsot, 'alpha');
t('D14', 'computeChannel：通道与部署参数齐全', alphaView.channel === 'alpha' && alphaView.port === 3081
  && alphaView.container === 'dsh-alpha' && alphaView.project === 'dsh-alpha',
  `${alphaView.channel}/${alphaView.port}/${alphaView.container}`);
t('D15', 'computeChannel：跨核心线判 HIGH', alphaView.upgradeRisk === 'HIGH' && alphaView.candidateIsNewer === true, `risk=${alphaView.upgradeRisk}`);

const rcView = safeDeploy.computeChannel(newSsot, 'rc');
t('D16', 'computeChannel：同版本候选判 LOW', rcView.upgradeRisk === 'LOW' && rcView.candidateIsNewer === false, `risk=${rcView.upgradeRisk}`);

const all = safeDeploy.computeChannels({ ssotFile: newSsotFile });
t('D17', 'computeChannels：返回全部通道 + primaryChannel', all.primaryChannel === 'alpha'
  && Object.keys(all.channels).join(',') === 'alpha,rc', Object.keys(all.channels).join(','));

const compat = safeDeploy.computeAll({ ssotFile: newSsotFile });
t('D18', 'computeAll 兼容：缺省 channel = primary 且字段名不变',
  compat.channel === 'alpha' && compat.currentVersion === '0.1.3-alpha.2'
  && compat.productionChannel === '0.1.3-alpha.2' && compat.testCandidate === '0.1.5-alpha.2'
  && Array.isArray(compat.otherBlockers) && 'promoteBlocked' in compat,
  `channel=${compat.channel} currentVersion=${compat.currentVersion}`);

const compatRc = safeDeploy.computeAll({ ssotFile: newSsotFile, channel: 'rc' });
t('D19', 'computeAll --channel rc 生效', compatRc.channel === 'rc' && compatRc.currentVersion === '0.1.2-rc.1', `currentVersion=${compatRc.currentVersion}`);

let missingThrew = false;
try { safeDeploy.computeAll({ ssotFile: newSsotFile, channel: 'nope' }); } catch { missingThrew = true; }
t('D20', '未知通道报错', missingThrew);

// ── 5. 插件字段全局、与通道无关 ─────────────────────────────────────────────
t('D21', '插件兼容性字段跨通道一致', JSON.stringify(alphaView.pluginClass) === JSON.stringify(rcView.pluginClass),
  JSON.stringify(alphaView.pluginClass));

// ── 6. 版本页结构约定（静态检查，不启动服务）───────────────────────────────
const server = fs.readFileSync(path.join(__dirname, 'version-server.js'), 'utf8');
t('D22', '版本页支持实时 SSOT 与兜底标注', server.includes('DSH_VERSION_SSOT') && server.includes('ssotIsFallback'));
t('D23', '版本页支持 ?refresh=1 强制刷新与节流', server.includes('refresh') && server.includes('FORCE_MIN_INTERVAL_MS'));
t('D24', '版本页含构建状态（registry tags + CI）',
  server.includes("registry.js") && server.includes('loadRegistryTags') && server.includes('actions/runs'));
t('D25', '版本页未知路径返回 404 且带安全头', server.includes('notFound') && server.includes('X-Content-Type-Options'));

// D26: version-server.js 的每个本地 require 都必须在 Dockerfile 里被 COPY 进 /opt，
//      否则镜像里的版本页会 require 失败（静默挂掉）。这是易漏的集成点。
const dockerfile = fs.readFileSync(path.join(__dirname, '..', 'Dockerfile'), 'utf8');
const localReqs = [...server.matchAll(/require\(path\.join\(__dirname,\s*'([^']+)'\)\)/g)].map((m) => m[1]);
const missing = localReqs.filter((f) => !new RegExp(`COPY\\s+scripts/${f.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s+/opt/`).test(dockerfile));
t('D26', 'Dockerfile 覆盖 version-server 的全部本地依赖', localReqs.length > 0 && missing.length === 0,
  `requires=[${localReqs.join(',')}] missing=[${missing.join(',')}]`);

fs.rmSync(tmp, { recursive: true, force: true });

const failed = results.filter((r) => !r.pass);
console.log(`\n===== 双通道测试: ${results.length - failed.length}/${results.length} PASS =====`);
process.exit(failed.length ? 1 : 0);
