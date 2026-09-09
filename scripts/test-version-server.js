#!/usr/bin/env node
// 版本页端到端契约测试：真实起进程 + 真实 HTTP 请求（不依赖外部网络断言）。
// 覆盖：双通道渲染 / 实时 SSOT 命中（非兜底）/ 404 / 安全头 / 强制刷新节流 / 未知通道过滤。
// 用法：node scripts/test-version-server.js
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const results = [];
function t(id, name, pass, detail) {
  results.push({ id, name, pass: !!pass, detail: detail || '' });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}  ${name}${detail ? '  | ' + detail : ''}`);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-vs-'));
const ssotFile = path.join(tmp, 'dsh-version.json');
fs.writeFileSync(ssotFile, JSON.stringify({
  schemaVersion: 2,
  primaryChannel: 'alpha',
  channels: {
    alpha: { port: 3081, production: '0.1.3-alpha.2', candidate: '0.1.5-alpha.2' },
    rc: { port: 3083, production: '0.1.2-rc.1', candidate: '0.1.2-rc.1' },
  },
}, null, 2));

const home = path.join(tmp, 'home');
fs.mkdirSync(path.join(home, '.deploy', 'alpha'), { recursive: true });
fs.writeFileSync(path.join(home, '.deploy', 'alpha', 'last-test-verdict'), 'TEST_VERDICT=PASS\n');
// 通道专属快照目录（alpha）
fs.mkdirSync(path.join(home, 'backups', 'alpha', '0.1.3-alpha.2-20260909'), { recursive: true });
// 共享快照目录：rc 的快照 + 一条属于 alpha 的快照（后者不得被算进 rc）
fs.mkdirSync(path.join(home, 'backups', '0.1.2-rc.1-20260909'), { recursive: true });
fs.mkdirSync(path.join(home, 'backups', '0.1.5-alpha.1-20260909'), { recursive: true });

const PORT = 13000 + Math.floor(Math.random() * 400);

function req(pathname, headers = {}) {
  return new Promise((resolve) => {
    const r = http.get({ host: '127.0.0.1', port: PORT, path: pathname, headers, timeout: 30000 }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    r.on('error', (e) => resolve({ status: 0, headers: {}, body: '', error: e.message }));
    r.on('timeout', () => { r.destroy(); resolve({ status: 0, headers: {}, body: '', error: 'timeout' }); });
  });
}

async function waitReady(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const r = await req('/version.json');
    if (r.status === 200) return true;
    await new Promise((s) => setTimeout(s, 500));
  }
  return false;
}

(async () => {
  const child = spawn(process.execPath, [path.join(__dirname, 'version-server.js')], {
    env: {
      ...process.env,
      DSH_VERSION_PORT: String(PORT),
      DSH_VERSION_SSOT: ssotFile,
      DSH_HOME: home,
      DSH_CHANNEL: 'alpha',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let log = '';
  child.stdout.on('data', (c) => { log += c; });
  child.stderr.on('data', (c) => { log += c; });

  try {
    const ready = await waitReady(40000);
    t('V1', '服务启动并就绪', ready, ready ? `port=${PORT}` : log.slice(0, 300));
    if (!ready) throw new Error('server not ready');

    const j = await req('/version.json');
    let d = null;
    try { d = JSON.parse(j.body); } catch { /* 下面断言会失败 */ }
    t('V2', '/version.json 返回可解析 JSON', j.status === 200 && !!d, `status=${j.status}`);
    t('V3', '包含两条通道', !!d && Object.keys(d.channels).join(',') === 'alpha,rc', d ? Object.keys(d.channels).join(',') : '');
    t('V4', '通道字段齐全（部署参数 + 策略 + 构建状态）',
      !!d && ['channel', 'port', 'container', 'project', 'currentVersion', 'testCandidate', 'upgradeRisk', 'testStatus', 'rollbackReady', 'build']
        .every((k) => k in d.channels.alpha),
      d ? Object.keys(d.channels.alpha).slice(0, 8).join(',') : '');
    t('V5', 'SSOT 命中实时文件（非镜像兜底）',
      !!d && d.cache.ssotFile === ssotFile && d.cache.ssotIsFallback === false,
      d ? `${d.cache.ssotFile} fallback=${d.cache.ssotIsFallback}` : '');
    t('V6', '每通道测试/回滚状态来自该通道状态目录',
      !!d && d.channels.alpha.testStatus === 'PASS' && d.channels.alpha.rollbackReady === 'YES'
      && d.channels.rc.testStatus === 'NOT_RUN' && d.channels.rc.rollbackReady === 'YES',
      d ? `alpha=${d.channels.alpha.testStatus}/${d.channels.alpha.rollbackReady} rc=${d.channels.rc.testStatus}/${d.channels.rc.rollbackReady}` : '');
    t('V6b', '共享 backups 目录按通道过滤（alpha 的快照不污染 rc）',
      !!d && String(d.channels.rc.snapshotDir).includes('0.1.2-rc.1')
      && !String(d.channels.rc.snapshotDir).includes('alpha'),
      d ? `rc.snapshotDir=${d.channels.rc.snapshotDir}` : '');
    t('V7', '兼容旧字段：safeUpgrade = primary 通道视图',
      !!d && d.safeUpgrade && d.safeUpgrade.channel === 'alpha' && d.safeUpgrade.ssotFile === ssotFile,
      d && d.safeUpgrade ? `${d.safeUpgrade.channel} ssot=${d.safeUpgrade.ssotFile}` : '');
    t('V8', '构建状态字段结构正确（GHCR 查询失败也不崩）',
      !!d && d.channels.alpha.build && 'targetBuilt' in d.channels.alpha.build && 'status' in d.channels.alpha.build,
      d ? `status=${d.channels.alpha.build.status} built=${d.channels.alpha.build.targetBuilt}` : '');

    const h = await req('/');
    t('V9', 'HTML 渲染两条通道 + 刷新按钮',
      h.status === 200 && h.body.includes('通道 alpha') && h.body.includes('通道 rc') && h.body.includes('重新检查'),
      `status=${h.status} size=${h.body.length}`);
    t('V10', 'HTML 不含镜像兜底告警（实时 SSOT）', h.status === 200 && !h.body.includes('镜像内置快照'));

    const filtered = await req('/?channel=rc');
    t('V11', '?channel=rc 只渲染该通道', filtered.status === 200 && filtered.body.includes('通道 rc') && !filtered.body.includes('通道 alpha'));

    const nf = await req('/nope');
    t('V12', '未知路径 404（HTML）', nf.status === 404, `status=${nf.status}`);
    const nfj = await req('/nope.json', { Accept: 'application/json' });
    t('V13', '未知 .json 路径 404（JSON 体）', nfj.status === 404 && (() => { try { JSON.parse(nfj.body); return true; } catch { return false; } })(), `status=${nfj.status}`);

    t('V14', '安全响应头齐全',
      h.headers['x-content-type-options'] === 'nosniff'
      && h.headers['x-frame-options'] === 'DENY'
      && h.headers['referrer-policy'] === 'no-referrer',
      JSON.stringify({ xcto: h.headers['x-content-type-options'], xfo: h.headers['x-frame-options'], rp: h.headers['referrer-policy'] }));

    const f1 = await req('/version.json?refresh=1');
    const f2 = await req('/version.json?refresh=1');
    let f1j = null; let f2j = null;
    try { f1j = JSON.parse(f1.body); f2j = JSON.parse(f2.body); } catch { /* 忽略 */ }
    t('V15', '强制刷新：首次执行、节流窗口内二次被节流',
      !!f1j && !f1j.refreshThrottled && !!f2j && f2j.refreshThrottled === true,
      `first=${f1j && f1j.refreshThrottled} second=${f2j && f2j.refreshThrottled}`);
    t('V16', '强制刷新写回 cache.lastForcedAt', !!f1j && !!f1j.cache.lastForcedAt, f1j ? String(f1j.cache.lastForcedAt) : '');
  } catch (e) {
    t('V0', '测试执行未抛异常', false, e.message);
  } finally {
    child.kill('SIGTERM');
    setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* ignore */ } }, 1000);
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  const failed = results.filter((r) => !r.pass);
  console.log(`\n===== 版本页契约测试: ${results.length - failed.length}/${results.length} PASS =====`);
  process.exit(failed.length ? 1 : 0);
})();
