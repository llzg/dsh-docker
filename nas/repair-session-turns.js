#!/usr/bin/env node
// repair-session-turns.js —— 修复 v2 会话里的"未闭合轮次"（turn/start 找不到匹配的 turn/end）。
//
// 背景（2026-09-10 实测）：
//   DSH 0.1.5 读取旧会话时会把 v2 artifact 迁移到 v3。迁移器对 v2 的校验很严：
//     · turn/start 的 turn 号必须严格连续（`turn/start 3 does not open expected turn 2`）；
//     · turn/end 必须与当前打开的轮次匹配、且**不能跨未闭合的 step、不能有未结束的 tool**。
//   存量会话里存在"轮次 2 开了但没写 turn/end，紧接着就 turn/start 3"的形态（旧版本写入的），
//   于是整条会话在 UI 里报：
//     history load failed: Session migration from v2 to v3 refuses the transformed artifact ...
//   源文件**不会被 DSH 改动**（它明确拒绝并保留原文），所以要么放弃这条会话，要么补齐边界。
//
// 本工具做的是**最小、可审计的补齐**：在"状态干净"（无未闭合 step、无未结束 tool）的位置，
// 为那个未闭合的轮次补一条 `turn/end {turn, reason:{kind:"interrupted"}}`，并把其后所有
// 事件的 `seq` 重新压紧（校验器要求 seq 与数组下标一致）。任何**不干净**的位置一律拒绝修复
// （那种情况补 turn/end 会被校验器以 "crosses an open step" / 未结束 tool 拒绝），只报告。
//
// 用法：
//   node repair-session-turns.js <session.v2.jsonl.zstd>            # dry-run，只报告
//   node repair-session-turns.js <session.v2.jsonl.zstd> --apply    # 备份后原地写回
//   可选：--backup-dir <dir>（默认 <session目录>/../../../_session-backups）
//
// 退出码：0 = 无需修复或修复成功；1 = 拒绝但有问题（需要人工）；2 = 用法/IO 错误。
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const file = process.argv[2];
const apply = process.argv.includes('--apply');
const bi = process.argv.indexOf('--backup-dir');
const backupDirArg = bi >= 0 ? process.argv[bi + 1] : '';

if (!file || !fs.existsSync(file)) {
  console.error('用法: node repair-session-turns.js <session.v2.jsonl.zstd> [--apply] [--backup-dir DIR]');
  process.exit(2);
}

function readJsonl(file) {
  const raw = execFileSync('zstd', ['-dc', file], { maxBuffer: 512 * 1024 * 1024 }).toString('utf8');
  return raw.split('\n').filter(Boolean).map((l, i) => {
    try { return JSON.parse(l); } catch (e) { throw new Error(`第 ${i} 行不是合法 JSON: ${e.message}`); }
  });
}

// 复刻校验器的状态机：找出"未闭合轮次"，并判断插入 turn/end 的位置是否干净。
function analyze(records) {
  const events = records.filter((r) => r.type !== 'session');
  const header = records.find((r) => r.type === 'session') || null;
  let openTurn = null, openStep = null, nextTurn = 1;
  const pendingTools = new Map();
  const fixes = [];   // { atIndex, turn, reason }
  const blockers = [];

  for (let i = 0; i < events.length; i++) {
    const e = events[i];
    const d = e.data || {};
    if (e.type === 'turn/start') {
      if (openTurn !== null || d.turn !== nextTurn) {
        if (openTurn === null || openStep !== null || pendingTools.size > 0) {
          blockers.push(`seq ${e.seq}: turn/start ${d.turn} 但未闭合=${openTurn} openStep=${openStep} 未结束 tool=${pendingTools.size} —— 状态不干净，拒绝自动修复`);
        } else {
          fixes.push({ atIndex: i, turn: openTurn, reason: { kind: 'interrupted' } });
        }
        // 视为新轮次开始，继续走（便于发现多处问题）
        openTurn = d.turn; openStep = null; pendingTools.clear(); nextTurn = d.turn + 1;
        continue;
      }
      openTurn = d.turn; openStep = null; pendingTools.clear(); nextTurn = d.turn + 1;
      continue;
    }
    if (e.type === 'turn/end') {
      if (openTurn !== d.turn) blockers.push(`seq ${e.seq}: turn/end ${d.turn} 与未闭合轮次 ${openTurn} 不匹配`);
      openTurn = null; nextTurn = d.turn + 1;
      continue;
    }
    if (e.type === 'step/start') openStep = e.seq;
    if (e.type === 'step/end') openStep = null;
    if (e.type === 'tool/call') pendingTools.set(d.id || d.callId || `seq${e.seq}`, e.seq);
    if (e.type === 'tool/result') {
      const key = d.id || d.callId;
      if (key && pendingTools.has(key)) pendingTools.delete(key);
      else if (pendingTools.size === 1) pendingTools.clear();
    }
  }
  return { header, events, fixes, blockers, turns: nextTurn - 1 };
}

const records = readJsonl(file);
const { header, events, fixes, blockers, turns } = analyze(records);

console.log(`  文件: ${file}`);
console.log(`  版本: ${header ? header.version : '?'}   事件数: ${events.length}   完整轮次: ${turns}`);
if (!fixes.length && !blockers.length) {
  console.log('  ✓ 轮次序列自洽，无需修复');
  process.exit(0);
}
for (const b of blockers) console.log(`  ✗ ${b}`);
for (const f of fixes) {
  const before = events[f.atIndex];
  console.log(`  → 计划：在 seq ${before.seq}（turn/start ${before.data.turn}）之前补 turn/end {turn:${f.turn}, reason:{kind:"interrupted"}}`);
}
if (!fixes.length) {
  console.log('  存在无法自动修复的问题，未改动任何文件');
  process.exit(1);
}
if (!apply) {
  console.log('  （dry-run：未改动；加 --apply 才会写回）');
  process.exit(0);
}

// 插入 + 重新压紧 seq（校验器要求 seq 与数组下标一致）
const out = [];
if (header) out.push(header);
let shift = 0;
for (let i = 0; i < events.length; i++) {
  const fix = fixes.find((f) => f.atIndex === i);
  if (fix) {
    const prev = events[i - 1] || events[i];
    out.push({ type: 'turn/end', seq: prev.seq + 1, time: (prev.time || Date.now()), data: { turn: fix.turn, reason: fix.reason } });
  }
  const e = { ...events[i], seq: events[i].seq + (fix ? 1 : 0) + shift };
  if (fix) shift += 1;
  out.push(e);
}
// 再统一压紧：**header 不计入序号**，事件从 0 开始且 seq === 数组下标
// （校验器：`if (record["seq"] !== index) throw ... is not dense`）
{
  let seq = 0;
  for (const e of out) { if (e.type === 'session') continue; e.seq = seq++; }
}

// ⚠ zstd 分帧是**格式的一部分**，不是实现细节（2026-09-10 血泪教训）：
//   DSH 读取会话时断言 "first frame is not exactly one header line" —— 首帧必须**只含 header 一行**，
//   其余内容跟在后续帧里（生产文件实测 2135 帧，每个写入批次一帧）。
//   若用 `zstd -19` 把整个 JSONL 压成**一帧**，workspace 插件会在启动时直接抛
//   `corrupt Zstandard session log`，导致整个 DSH 起不来（不是只坏这一条会话！）。
const tmp = `${file}.repaired`;
const f1 = `${file}.f1.zst`;
const f2 = `${file}.f2.zst`;
const p1 = `${file}.p1.txt`;
const p2 = `${file}.p2.txt`;
const lines = out.map((e) => JSON.stringify(e));
fs.writeFileSync(p1, lines[0] + '\n');                      // 首帧：只有 header 一行
fs.writeFileSync(p2, lines.slice(1).join('\n') + '\n');     // 其余：一帧装完
execFileSync('zstd', ['-q', '-19', '-f', '-o', f1, p1]);
execFileSync('zstd', ['-q', '-19', '-f', '-o', f2, p2]);
fs.writeFileSync(tmp, Buffer.concat([fs.readFileSync(f1), fs.readFileSync(f2)]));
for (const f of [f1, f2, p1, p2]) fs.unlinkSync(f);
// 分帧自检：>=2 帧，且整体解压内容与预期逐行一致
// 注意 `zstd -l` 是表格输出、`zstd -l -v` 才是 "# Zstandard Frames: N"（踩过）
const zl = execFileSync('zstd', ['-l', '-v', tmp], { maxBuffer: 32 * 1024 * 1024 }).toString();
const frames = Number((zl.match(/Zstandard Frames:\s*(\d+)/) || zl.match(/Frames:\s*(\d+)/) || [])[1] || 0);
if (frames < 2) { fs.unlinkSync(tmp); console.error(`  ✗ 分帧自检失败：只有 ${frames} 帧（首帧必须只含 header）`); process.exit(1); }
const round = execFileSync('zstd', ['-dc', tmp], { maxBuffer: 512 * 1024 * 1024 }).toString();
if (round !== lines.join('\n') + '\n') { fs.unlinkSync(tmp); console.error('  ✗ 解压回读与预期内容不一致，已放弃'); process.exit(1); }
console.log(`  分帧自检：${frames} 帧，首帧=header 一行 ✓`);

// 自检：修完必须自洽
const check = analyze(readJsonl(tmp));
if (check.fixes.length || check.blockers.length) {
  fs.unlinkSync(tmp);
  console.error('  ✗ 修复后自检仍未通过，已放弃（原文件未改动）');
  process.exit(1);
}

const sessionDir = path.dirname(file);
const backupRoot = backupDirArg || path.join(sessionDir, '..', '..', '..', '_session-backups');
const backup = path.join(backupRoot, `${path.basename(sessionDir)}-${path.basename(file)}.bak-${Date.now()}`);
fs.mkdirSync(path.dirname(backup), { recursive: true });
fs.copyFileSync(file, backup);
fs.renameSync(tmp, file);
console.log(`  ✓ 已修复写回；原文件备份: ${backup}`);
console.log('  提示：让 DSH 重新加载该会话（刷新页面）；若仍报错，把备份文件改回原名即可回滚。');
