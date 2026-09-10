#!/usr/bin/env node
// preflight-workspace.js —— 升级前的"工作区体检"：找出**旧数据在新版本下会炸**的地方。
//
// 为什么需要（2026-09-10 一天之内踩到两次，各花了很久）：
//   1) agent preset 用了旧 schema → preset 挂载失败 → 该 preset 下**所有会话都无法 resume**
//      （表现为"切换模型报错"、"继续对话报错"，而 HTTP 全是 200、容器日志干净）。
//   2) 会话日志用了旧格式/分帧不对 → 轻则单条历史打不开（v2→v3 迁移被拒），
//      重则 dsh-workspace 启动即抛 `corrupt Zstandard session log`，**整个 DSH 起不来**。
// 两类问题都不在 HTTP 状态码或容器日志里体现，事前跑一次这个脚本成本极低。
//
// 用法（在宿主上，对某个 DSH 工作区跑）：
//   node preflight-workspace.js --home /volume1/docker/dsh-alpha5/dsh-data/test/0.1.2-alpha.5
//   node preflight-workspace.js --home <工作区> --json          # 机器可读
//   node preflight-workspace.js --home <工作区> --sessions-only # 只查会话
//   node preflight-workspace.js --home <工作区> --presets-only
//   node preflight-workspace.js --home <工作区> --include-test   # 连 test/ 隔离工作区一起查
//
// 检查项：
//   P1 preset 的 persona 配置是否含必填 prefix（新版 dsh-persona 要求；text 已废弃）
//   P2 preset 目录结构是否正常（preset.yml + agent.cordis.yml 都在）
//   S1 每个会话产物是不是**多帧** zstd（首帧必须只含 header 一行；单帧会让 workspace 起不来）
//   S2 会话的轮次是否连续（"轮次未闭合又开新轮次"会被迁移器拒绝 → 历史打不开）
//   S3 是否已生成 v3（未生成的说明还没被成功观察过）
//
// 退出码：0 = 干净；1 = 有发现（按输出逐条处理）；2 = 用法/环境错误。
//
// ⚠ preset 检查是**文本级**的（不引入 YAML 依赖）：只定位 `id: persona` 那个 entry 的
//   `config:` 块检查必填字段。够用、可预期；它拦的是"旧 schema 直接挂载失败"这一类。
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const argv = process.argv.slice(2);
const arg = (name, def = '') => {
  const i = argv.indexOf(name);
  return i >= 0 ? (argv[i + 1] || '') : def;
};
const has = (name) => argv.includes(name);

const HOME = arg('--home');
const JSON_OUT = has('--json');
const ONLY_PRESETS = has('--presets-only');
const ONLY_SESSIONS = has('--sessions-only');
const MAX_REPORT = Number(arg('--max-report', '20'));
const INCLUDE_TEST = has('--include-test');   // 连 test/ 隔离工作区一起查（默认只查真实会话区）

if (!HOME || !fs.existsSync(HOME)) {
  console.error('用法: node preflight-workspace.js --home <DSH 工作区目录> [--json] [--presets-only|--sessions-only] [--max-report N]');
  process.exit(2);
}

const findings = [];   // {sev:'fail'|'warn', code, target, detail, fix}
const stats = { presets: 0, sessions: 0, byVersion: {}, migrated: 0, frames: {} };
const add = (sev, code, target, detail, fix) => findings.push({ sev, code, target, detail, fix: fix || '' });
const unreadable = [];   // 读不了的目录（权限）——必须显式报出来，不能静默算 0

function sh(cmd, args, opts = {}) {
  // stdio 显式 pipe：zstd -l -v 会打横幅到 stderr，不能让子进程的输出混进本脚本的 stdout
  return execFileSync(cmd, args, { maxBuffer: 512 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'], ...opts });
}

// ⚠ 必须用 **zstd CLI**：node:zlib 的 zstdDecompressSync 只解**第一帧**，而 DSH 的会话
//   日志是多帧文件（实测某文件 41035 行只有 1 行被解出来）→ 会静默漏报所有轮次问题
//   （这个假阴性踩过）。容器内没有 zstd CLI，但可以把宿主的二进制拷进去用：
//     docker cp /usr/bin/zstd <容器>:/tmp/zstd && docker exec <容器> PATH=/tmp:$PATH node ...
const ZSTD = process.env.DSH_ZSTD_BIN || arg('--zstd', '') || 'zstd';

function zstdReady() {
  try { sh(ZSTD, ['-q', '--version']); return true; } catch { return false; }
}

function decompress(file) {
  return sh(ZSTD, ['-q', '-dc', file]).toString('utf8');
}

function framesOf(file) {
  // 注意 zstd 两种输出格式都要认（踩过）：
  //   `zstd -l -v`  → 带横幅，帧数在 "# Zstandard Frames: N"
  //   `zstd -q -l`  → 表格，帧数在表头下第一行的第一列
  try {
    const out = sh(ZSTD, ['-q', '-l', '-v', file]).toString();
    let m = out.match(/Zstandard Frames:\s*(\d+)/);
    if (!m) m = out.match(/^\s*Frames\s+Skips[^\n]*\n\s*(\d+)/m);
    return m ? Number(m[1]) : -1;
  } catch { return -1; }
}

// ── preset 检查 ─────────────────────────────────────────────────────────────
// 在 preset 的 agent.cordis.yml 里定位 `- id: persona` 那个 entry 的 config 块。
function checkPresetPersona(file) {
  const text = fs.readFileSync(file, 'utf8');
  const lines = text.split('\n');
  const idx = lines.findIndex((l) => /^\s*-\s*id:\s*persona\s*$/.test(l));
  if (idx < 0) return { hasPersona: false };
  let end = lines.length;
  for (let i = idx + 1; i < lines.length; i++) {
    if (/^\s*-\s*id:\s*\S/.test(lines[i])) { end = i; break; }
  }
  const block = lines.slice(idx, end);
  const cfgIdx = block.findIndex((l) => /^\s*config:\s*$/.test(l));
  const cfg = cfgIdx >= 0 ? block.slice(cfgIdx + 1) : [];
  const key = (name) => cfg.find((l) => new RegExp(`^\\s{4,}${name}:`).test(l));
  const prefixLine = key('prefix');
  const textLine = key('text');
  // `prefix: >-` 或 `prefix: "…"` 都算有值；`prefix:`（空）不算
  const prefixOk = !!prefixLine && !/:\s*$/.test(prefixLine.trim());
  return { hasPersona: true, prefixLine: prefixLine || null, textLine: textLine || null, prefixOk };
}

function checkPresets() {
  const dir = path.join(HOME, '.agent-presets');
  let names;
  try { names = fs.readdirSync(dir); } catch (e) {
    if (e.code === 'EACCES' || e.code === 'EPERM') unreadable.push(dir);
    return;
  }
  for (const name of names) {
    const pdir = path.join(dir, name);
    let st;
    try { st = fs.statSync(pdir); } catch { continue; }
    if (!st.isDirectory()) continue;
    stats.presets++;
    const presetYml = path.join(pdir, 'preset.yml');
    const agentYml = path.join(pdir, 'agent.cordis.yml');
    if (!fs.existsSync(presetYml) || !fs.existsSync(agentYml)) {
      add('fail', 'P2', name, `preset 目录缺少 ${!fs.existsSync(presetYml) ? 'preset.yml' : 'agent.cordis.yml'}`,
        'preset 是 <id>/preset.yml + <id>/agent.cordis.yml 两份；缺一份该 preset 就无法挂载');
      continue;
    }
    let r;
    try { r = checkPresetPersona(agentYml); } catch { continue; }
    if (!r.hasPersona || r.prefixOk) continue;
    add('fail', 'P1', name,
      r.textLine ? 'persona 用的是已废弃的 config.text，新版要求 config.prefix（必填）'
                 : 'persona 的 config 里没有 prefix（新版 dsh-persona 必填）',
      `改 ${agentYml}：persona 的 config 写成 prefix:（必填，可用 {{model}}/{{cwd}}）` +
      (r.textLine ? ' + suffix:，即把原 text 拆成 prefix/suffix' : '') +
      '。不改的话该 preset 下所有会话都无法 resume（切模型/继续对话都会报错）');
  }
}

function analyzeSession(file, home) {
  let raw;
  try {
    raw = decompress(file);
  } catch (e) {
    add('fail', 'S0', path.relative(home, file), `zstd 解压失败：${String(e.message).slice(0, 120)}`, '文件可能损坏，从备份恢复');
    return;
  }
  const recs = raw.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const header = recs.find((r) => r.type === 'session');
  const evs = recs.filter((r) => r.type !== 'session');
  const ver = header && header.version !== undefined ? String(header.version) : 'legacy';
  stats.byVersion[ver] = (stats.byVersion[ver] || 0) + 1;

  const frames = framesOf(file);
  stats.frames[frames] = (stats.frames[frames] || 0) + 1;
  if (frames === 1) {
    add('fail', 'S1', path.relative(home, file),
      '整个文件只有 1 个 zstd 帧 —— 首帧不是"恰好 header 一行"',
      'dsh-workspace 启动读会话头会抛 `corrupt Zstandard session log`，**整个 DSH 起不来**。' +
      '用 nas/repair-session-turns.js 的方式重建：首帧=header 一行，其余一帧');
  } else if (frames === 0) {
    add('warn', 'S1', path.relative(home, file), '读不到 zstd 帧信息（zstd -l -v 失败）', '确认 zstd 可用');
  }

  // 轮次连续性：turn/start 的序号必须连续（否则迁移器拒绝，历史打不开）
  let open = null, next = 1; const bad = [];
  for (const e of evs) {
    if (e.type === 'turn/start') {
      if (open !== null || e.data.turn !== next) bad.push(`turn/start ${e.data.turn}≠期望${next}(未闭合${open})`);
      open = e.data.turn; next = e.data.turn + 1;
    } else if (e.type === 'turn/end') { open = null; next = e.data.turn + 1; }
  }
  if (bad.length) {
    add('fail', 'S2', path.relative(home, file),
      `${bad.length} 处轮次不连续：${bad.slice(0, 3).join('; ')}`,
      '迁移器会拒绝这条会话（"turn/start N does not open expected turn N-1"）→ 历史打不开。' +
      '可用 nas/repair-session-turns.js 在状态干净处补一条 turn/end（先 dry-run）');
  }
}

function walkArtifacts(dir, out, depth = 0) {
  if (depth > 6) return;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) {
    // ⚠ 不能静默跳过：以普通用户跑、工作区是 root 私有目录时会读不到，
    //   静默 → "0 个产物，未发现问题" 的**假阴性**（这个坑踩过两次）。
    if (e.code === 'EACCES' || e.code === 'EPERM') unreadable.push(dir);
    return;
  }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walkArtifacts(full, out, depth + 1);
    else if (/^session(\.[a-z0-9]+)?\.jsonl\.zstd$/.test(e.name)) out.push(full);
  }
}

function checkSessions() {
  // 默认只查**真实会话区** <HOME>/sessions（那才是用户会打开的）。
  // <HOME>/test/**（safe-deploy 隔离自测工作区）与 backups/ 里的是副本，不面向用户；
  // 要看它们加 --include-test（查得更全但慢很多）。
  const roots = [path.join(HOME, 'sessions')];
  if (INCLUDE_TEST) {
    const testDir = path.join(HOME, 'test');
    try {
      for (const v of fs.readdirSync(testDir)) {
        const sd = path.join(testDir, v, 'sessions');
        if (fs.existsSync(sd)) roots.push(sd);
      }
    } catch { /* 没有 test/ 目录 */ }
  }
  const arts = [];
  for (const r of roots) walkArtifacts(r, arts);
  for (const f of arts) if (/^session\.v3\./.test(path.basename(f))) stats.migrated++;
  for (const f of arts) { stats.sessions++; analyzeSession(f, HOME); }
}

// ── main ────────────────────────────────────────────────────────────────────
if (!ONLY_PRESETS && !zstdReady()) {
  console.error(`找不到可用的 zstd CLI（当前: ${ZSTD}）—— 会话检查需要它（node:zlib 只解第一帧，会漏报）。`);
  console.error('宿主上装 zstd，或把宿主的二进制拷进容器后指定：docker cp /usr/bin/zstd <容器>:/tmp/zstd');
  console.error('然后用 DSH_ZSTD_BIN=/tmp/zstd 或在容器里 PATH=/tmp:$PATH 运行本脚本。');
  process.exit(2);
}
if (!ONLY_SESSIONS) checkPresets();
if (!ONLY_PRESETS) checkSessions();

if (unreadable.length) {
  add('fail', 'E1', unreadable[0],
    `无权限读取工作区目录（共 ${unreadable.length} 处，首个如上）`,
    '体检必须在**能读到工作区**的身份下跑：用 root（sudo）跑，或直接在容器内跑（推荐）：' +
    'docker cp /usr/bin/zstd <容器>:/tmp/zstd && docker cp <本脚本> <容器>:/tmp/ && ' +
    'docker exec -e DSH_ZSTD_BIN=/tmp/zstd <容器> node /tmp/preflight-workspace.js --home <容器内工作区>。' +
    '以普通用户跑会读不到文件并**假报"未发现问题"**（该假阴性踩过）');
}

const fails = findings.filter((f) => f.sev === 'fail');
const warns = findings.filter((f) => f.sev === 'warn');

if (JSON_OUT) {
  console.log(JSON.stringify({ home: HOME, stats, findings }, null, 2));
} else {
  console.log(`  工作区: ${HOME}`);
  console.log(`  preset: ${stats.presets} 个   会话产物: ${stats.sessions} 个（已迁移 v3: ${stats.migrated}）`);
  console.log(`  会话格式分布: ${Object.entries(stats.byVersion).map(([k, v]) => `v${k}×${v}`).join('  ') || '-'}`);
  console.log(`  zstd 帧数分布: ${Object.entries(stats.frames).map(([k, v]) => `${k}帧×${v}`).join('  ') || '-'}`);
  if (!findings.length) {
    console.log('  ✓ 未发现升级阻塞项');
  } else {
    console.log('');
    for (const f of findings.slice(0, MAX_REPORT)) {
      console.log(`  [${f.sev === 'fail' ? '✗' : '!'}] ${f.code}  ${f.target}`);
      console.log(`        ${f.detail}`);
      if (f.fix) console.log(`        修法: ${f.fix}`);
    }
    if (findings.length > MAX_REPORT) console.log(`  …… 其余 ${findings.length - MAX_REPORT} 条省略（--json 可看全）`);
    console.log('');
    console.log(`  结论: ${fails.length} 项阻塞 / ${warns.length} 项提示`);
  }
}
process.exit(fails.length ? 1 : 0);
