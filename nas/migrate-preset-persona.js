#!/usr/bin/env node
'use strict';
// migrate-preset-persona.js -- 用户 preset 的 persona.config.text -> prefix 双写迁移
//
// 背景：DSH 0.1.3 起 persona 的 config 要求 prefix（必填），旧版用 text。
// 升级是滚动的（迁移后旧版本可能还要跑到 promote 完成），所以采用**双写**：
// 新增 prefix（内容=原 text 块），并**保留 text**。新旧版本都能读，避免
// "为了升新版先把正在跑的旧版弄坏"。
//
// 只处理 <home>/.agent-presets/<id>/agent.cordis.yml 里 - id: persona 那个 entry。
// 默认 dry-run；--apply 才写回，写前备份到 <home>/_preset-backups/<ts>/<id>/。
//
// 用法:
//   node migrate-preset-persona.js --home <DSH 工作区> [--apply] [--backup-dir DIR] [--only <id>]
// 退出码: 0=无需迁移/全部成功; 1=存在无法自动迁移的 preset（调用方应停止）; 2=用法错误
const fs = require('fs');
const path = require('path');
const NL = String.fromCharCode(10);

const argv = process.argv.slice(2);
function opt(name, def) {
  const i = argv.indexOf(name);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
  return def;
}
const HOME = opt('--home', '');
const ONLY = opt('--only', '');
const APPLY = argv.indexOf('--apply') >= 0;
let BACKUP_DIR = opt('--backup-dir', '');
if (!HOME) {
  console.error('用法: node migrate-preset-persona.js --home <DSH 工作区> [--apply] [--backup-dir DIR] [--only <id>]');
  process.exit(2);
}
if (!fs.existsSync(HOME)) {
  console.error('工作区不存在: ' + HOME);
  process.exit(2);
}
if (!BACKUP_DIR) {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  BACKUP_DIR = path.join(HOME, '_preset-backups', ts);
}

function indentOf(line) {
  let n = 0;
  while (n < line.length && line[n] <= ' ') n++;
  return n;
}
function isEntryStart(line) {
  return line.trim().indexOf('- id:') === 0;
}
function isPersona(line) {
  const t = line.trim();
  if (t.indexOf('- id:') !== 0) return false;
  return t.slice(5).trim() === 'persona';
}
function valueOf(line, key) {
  const t = line.trim();
  if (t.indexOf(key + ':') !== 0) return null;
  return t.slice(key.length + 1).trim();
}

const presetsDir = path.join(HOME, '.agent-presets');
let ids = [];
try {
  ids = fs.readdirSync(presetsDir).filter(function (n) {
    try { return fs.statSync(path.join(presetsDir, n)).isDirectory(); } catch (e) { return false; }
  });
} catch (e) {
  console.log('NO_PRESETS_DIR ' + presetsDir);
  process.exit(0);
}
if (ONLY) ids = ids.filter(function (n) { return n === ONLY; });

let migrated = 0;
let already = 0;
let unrepairable = 0;
ids.forEach(function (id) {
  const file = path.join(presetsDir, id, 'agent.cordis.yml');
  if (!fs.existsSync(file)) { console.log('SKIP ' + id + ' (no agent.cordis.yml)'); return; }
  const lines = fs.readFileSync(file, 'utf8').split(NL);
  const start = lines.findIndex(isPersona);
  if (start < 0) { console.log('SKIP ' + id + ' (no persona entry)'); return; }
  const baseIndent = indentOf(lines[start]);
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (isEntryStart(lines[i]) && indentOf(lines[i]) <= baseIndent) { end = i; break; }
  }
  let prefixVal = null;
  let textIdx = -1;
  for (let i = start + 1; i < end; i++) {
    if (prefixVal === null && valueOf(lines[i], 'prefix') !== null) prefixVal = valueOf(lines[i], 'prefix');
    if (textIdx < 0 && valueOf(lines[i], 'text') !== null) textIdx = i;
  }
  if (prefixVal) { console.log('OK ' + id + ' (prefix present)'); already++; return; }
  if (textIdx < 0) {
    console.log('UNREPAIRABLE ' + id + ' (persona 既无 prefix 也无 text)');
    unrepairable++;
    return;
  }
  const textIndent = indentOf(lines[textIdx]);
  let textEnd = textIdx + 1;
  while (textEnd < end) {
    const l = lines[textEnd];
    if (l.trim() === '') { textEnd++; continue; }
    if (indentOf(l) <= textIndent) break;
    textEnd++;
  }
  const copied = lines.slice(textIdx, textEnd).map(function (l, i) {
    if (i !== 0) return l;
    const lead = l.slice(0, indentOf(l));
    return lead + 'prefix:' + l.trim().slice('text:'.length);
  });
  if (!APPLY) { console.log('WOULD_MIGRATE ' + id + ' (add prefix from text, keep text)'); migrated++; return; }
  const dst = path.join(BACKUP_DIR, id);
  fs.mkdirSync(dst, { recursive: true });
  fs.copyFileSync(file, path.join(dst, 'agent.cordis.yml'));
  const out = lines.slice(0, textIdx).concat(copied, lines.slice(textIdx));
  fs.writeFileSync(file, out.join(NL));
  console.log('MIGRATED ' + id + ' (prefix added from text; backup ' + dst + ')');
  migrated++;
});
console.log('SUMMARY migrated=' + migrated + ' already=' + already + ' unrepairable=' + unrepairable + (APPLY ? '' : ' dry-run=1'));
process.exit(unrepairable > 0 ? 1 : 0);
