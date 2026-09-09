#!/usr/bin/env node
// registry.js 离线测试：起一个本地 http registry 替身（不联网、不碰真实 registry）。
// 覆盖：splitImage 拆分 / 匿名可读 / Basic Auth（401→带凭据 200）/ scheme 探测（https 失败回退 http）
//       / 错误结构化 / registriesFromEnv 解析。
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const reg = require('./registry.js');

const results = [];
function t(id, name, pass, detail) {
  results.push({ id, name, pass: !!pass });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}  ${name}${detail ? '  | ' + detail : ''}`);
}

const USER = 'ci-deploy';
const PASS = 'stub-password-not-real';

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, 'http://localhost');
      if (!url.pathname.startsWith('/v2/')) {
        res.writeHead(404).end('{}');
        return;
      }
      // /v2/<repo...>/tags/list
      const m = /^\/v2\/(.+)\/tags\/list$/.exec(url.pathname);
      if (!m) {
        res.writeHead(404).end('{}');
        return;
      }
      const repo = m[1];
      if (repo === 'private/repo') {
        const hdr = req.headers.authorization || '';
        const expected = `Basic ${Buffer.from(`${USER}:${PASS}`).toString('base64')}`;
        if (hdr !== expected) {
          res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Registry-Private"' }).end('{}');
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ name: repo, tags: ['0.1.3-alpha.2', '0.1.5-alpha.2'] }));
        return;
      }
      if (repo === 'broken/repo') {
        res.writeHead(500).end('boom');
        return;
      }
      if (repo === 'nulltags/repo') {
        // 真实场景：daocloud 缓存 registry 对已知仓库返回 "tags": null
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ name: repo, tags: null }));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ name: repo, tags: ['0.1.2-rc.1'] }));
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

(async () => {
  // ── splitImage ────────────────────────────────────────────────────────────
  const s1 = reg.splitImage('ghcr.io/llzg/dsh-docker');
  t('R1', 'splitImage: ghcr.io 形式', s1.registry === 'ghcr.io' && s1.repository === 'llzg/dsh-docker', JSON.stringify(s1));
  const s2 = reg.splitImage('192.168.5.35:5050/llzg/dsh-docker');
  t('R2', 'splitImage: host:port 形式', s2.registry === '192.168.5.35:5050' && s2.repository === 'llzg/dsh-docker', JSON.stringify(s2));
  const s3 = reg.splitImage('llzg/dsh-docker');
  t('R3', 'splitImage: 无 registry 段 → docker.io', s3.registry === 'docker.io' && s3.repository === 'llzg/dsh-docker', JSON.stringify(s3));
  const s4 = reg.splitImage('http://localhost:5000/a/b');
  t('R4', 'splitImage: 去掉 scheme', s4.registry === 'localhost:5000' && s4.repository === 'a/b', JSON.stringify(s4));

  const server = await startServer();
  const port = server.address().port;
  const base = `127.0.0.1:${port}`;

  // 把凭据写进临时 docker config，验证"从 config.json 取凭据"
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-reg-'));
  const cfgDir = path.join(tmp, 'cfg');
  fs.mkdirSync(cfgDir);
  fs.writeFileSync(path.join(cfgDir, 'config.json'), JSON.stringify({
    auths: { [base]: { auth: Buffer.from(`${USER}:${PASS}`).toString('base64') } },
  }));
  process.env.DOCKER_CONFIG = cfgDir;

  try {
    const anon = await reg.listTags(`${base}/public/repo`, { scheme: 'http' });
    t('R5', '匿名 registry：可列 tags', anon.status === 'ok' && anon.tags.includes('0.1.2-rc.1'), `${anon.status} ${anon.tags.join(',')}`);

    const priv = await reg.listTags(`${base}/private/repo`, { scheme: 'http' });
    t('R6', 'Basic Auth：从 docker config.json 取凭据成功', priv.status === 'ok' && priv.tags.includes('0.1.5-alpha.2') && priv.authUsed === true,
      `${priv.status} authUsed=${priv.authUsed} tags=${priv.tags.join(',')}`);

    const noAuth = await reg.listTags(`${base}/private/repo`, { scheme: 'http', username: '', password: '' });
    // 显式空凭据不应覆盖 config 里的凭据 → 仍应成功（resolveAuth 先看显式，再看环境，再看 config）
    t('R7', '无显式凭据时仍回退 config.json', noAuth.status === 'ok', `${noAuth.status}`);

    const scheme = await reg.listTags(`${base}/public/repo`);
    t('R8', 'scheme 探测：https 失败自动回退 http', scheme.status === 'ok' && scheme.scheme === 'http', `scheme=${scheme.scheme} ${scheme.error || ''}`);

    const broken = await reg.listTags(`${base}/broken/repo`, { scheme: 'http' });
    t('R9', 'HTTP 500 → 结构化错误（不抛异常）', broken.status === 'error' && broken.tags.length === 0 && /500/.test(broken.error), broken.error);

    const missing = await reg.listTags(`${base}/private/repo`, { scheme: 'http', username: 'wrong', password: 'wrong' });
    t('R10', '错误凭据 → 401 结构化错误', missing.status === 'error' && /401|403/.test(missing.error), missing.error);

    const forced = await reg.listTags(`${base}/public/repo`, { scheme: 'http' });
    t('R11', '显式 scheme 生效', forced.scheme === 'http', forced.scheme);

    const list = reg.registriesFromEnv({ DSH_REGISTRIES: 'ghcr.io/llzg/dsh-docker, 192.168.5.35:5050/llzg/dsh-docker ' });
    t('R12', 'registriesFromEnv 解析多仓库', list.length === 2 && list[1] === '192.168.5.35:5050/llzg/dsh-docker', list.join(' | '));
    const dflt = reg.registriesFromEnv({});
    t('R13', 'registriesFromEnv 默认 GHCR', dflt.length === 1 && dflt[0] === 'ghcr.io/llzg/dsh-docker', dflt.join(','));

    const nullTags = await reg.listTags(`${base}/nulltags/repo`, { scheme: 'http' });
    t('R14', '"tags": null（缓存 registry 真实行为）→ ok + 空列表，不报错',
      nullTags.status === 'ok' && Array.isArray(nullTags.tags) && nullTags.tags.length === 0,
      `status=${nullTags.status} tags=${JSON.stringify(nullTags.tags)}`);
  } finally {
    delete process.env.DOCKER_CONFIG;
    fs.rmSync(tmp, { recursive: true, force: true });
    server.close();
  }

  const failed = results.filter((r) => !r.pass);
  console.log(`\n===== registry 测试: ${results.length - failed.length}/${results.length} PASS =====`);
  process.exit(failed.length ? 1 : 0);
})();
