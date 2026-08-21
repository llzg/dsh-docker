#!/usr/bin/env node
// T 系列测试（T1~T15）—— 版本检测策略验证
const policy = require('./version-policy.js');
const sv = policy.semver();
const results = [];
function t(id, name, pass, detail) {
  results.push({ id, name, pass: !!pass, detail: detail || '' });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}  ${name}${detail ? '  | ' + detail : ''}`);
}

(async () => {
  // T3/T4/T5/T6: npm registry 真实查询
  const npmRes = await policy.fetchNpm();
  const npmOK = npmRes && !npmRes.error && npmRes.latest.value && npmRes.next.value && Array.isArray(npmRes.versions);
  t('T3', 'npm registry 查询', npmOK, npmOK ? `latest=${npmRes.latest.value} next=${npmRes.next.value} versions=${npmRes.versions.length}` : JSON.stringify(npmRes && npmRes.error));
  t('T4', 'npm latest', npmOK && !!npmRes.latest.value, npmRes.latest && npmRes.latest.value);
  t('T5', 'npm next', npmOK && !!npmRes.next.value, npmRes.next && npmRes.next.value);
  t('T6', 'npm versions（含 0.1.1-rc.1）', npmOK && npmRes.versions.includes('0.1.1-rc.1'), npmRes.versions && npmRes.versions.filter(v => v.startsWith('0.1.1')).join(','));

  // T1/T2: GitHub 真实查询
  const gh = await policy.fetchGitHub();
  t('T1', 'GitHub Release 查询', gh.release.status === 'ok' && !!gh.release.value, gh.release.status === 'ok' ? `${gh.release.value} (raw=${gh.release.raw})` : gh.release.error);
  t('T2', 'GitHub Tag 查询', gh.tag.status === 'ok' && !!gh.tag.value, gh.tag.status === 'ok' ? gh.tag.value : gh.tag.error);

  // T7: semver 比较（必须用 semver 库，非字符串比较）
  t('T7a', 'semver: 1.0.0 > 0.1.0-rc.8', sv.gt('1.0.0', '0.1.0-rc.8'), 'semver.gt(1.0.0, 0.1.0-rc.8)=' + sv.gt('1.0.0', '0.1.0-rc.8'));
  t('T7b', 'semver: 1.0.0 > 1.0.0-rc.1', sv.gt('1.0.0', '1.0.0-rc.1'), 'semver.gt(1.0.0, 1.0.0-rc.1)=' + sv.gt('1.0.0', '1.0.0-rc.1'));
  t('T7c', 'semver: 0.1.1-rc.1 > 0.1.0-rc.8', sv.gt('0.1.1-rc.1', '0.1.0-rc.8'), '');
  t('T13', 'prerelease 比较 rc.10 > rc.9', sv.gt('1.0.0-rc.10', '1.0.0-rc.9'), '');

  // 构造 sources 帮助函数
  function mk({ rel, tag, latest, next, versions = ['0.1.1-rc.1', '0.1.0-rc.8', '1.0.0', '1.0.0-rc.1'] }) {
    const ok = (v) => ({ value: v, status: v ? 'ok' : 'error', error: null });
    return {
      github: { release: rel ? ok(rel) : { value: null, status: 'error', error: '模拟失败' }, tag: ok(tag || rel) },
      npm: { latest: ok(latest), next: ok(next), versions, npmError: null },
    };
  }

  // T10: GitHub 有新版本但 npm 未发布 → waitingForNpm=true, target=可安装最高
  const s10 = mk({ rel: '1.0.0', tag: '1.0.0', latest: '0.1.1-rc.1', next: '0.1.1-rc.1', versions: ['0.1.1-rc.1', '0.1.0-rc.8'] });
  const c10 = policy.computeTarget(s10);
  t('T10', 'GitHub 新版本但 npm 未发布 → 等待 + 目标=可安装最高', c10.waitingForNpm && c10.target === '0.1.1-rc.1' && c10.newestUpstream === '1.0.0', `newest=${c10.newestUpstream} target=${c10.target} waiting=${c10.waitingForNpm}`);

  // T11: GitHub/npm 都已有新版本（npm 含 1.0.0）
  const s11 = mk({ rel: '1.0.0', tag: '1.0.0', latest: '1.0.0', next: '0.1.1-rc.1', versions: ['1.0.0', '0.1.1-rc.1'] });
  const c11 = policy.computeTarget(s11);
  t('T11', 'GitHub/npm 都已发布 1.0.0 → 目标=1.0.0', c11.target === '1.0.0' && !c11.waitingForNpm, `target=${c11.target}`);

  // T12: 当前已是最新（部署 rc.8，目标 rc.8 场景：构造无更新的 sources）
  const s12 = mk({ rel: '0.1.0-rc.8', tag: '0.1.0-rc.8', latest: '0.1.0-rc.8', next: '0.1.0-rc.8', versions: ['0.1.0-rc.8'] });
  const c12 = policy.computeTarget(s12);
  t('T12', '当前版本已是最新（rc.8=rc.8）', c12.target === '0.1.0-rc.8' && !c12.waitingForNpm, `target=${c12.target}`);

  // T8: 单源失败不影响其他源（GitHub 全失败，npm 正常）
  const s8 = { github: { release: { value: null, status: 'error', error: 'HTTP 403（rate limited / forbidden）' }, tag: { value: null, status: 'error', error: '连接超时（timeout）' } }, npm: { latest: { value: '0.1.1-rc.1', status: 'ok' }, next: { value: '0.1.1-rc.1', status: 'ok' }, versions: ['0.1.1-rc.1'], npmError: null } };
  const c8 = policy.computeTarget(s8);
  t('T8', 'GitHub 失败不拖垮 npm → 目标仍=0.1.1-rc.1', c8.target === '0.1.1-rc.1' && !c8.waitingForNpm, `target=${c8.target}`);

  // T9: 全部失败 → target=null
  const s9 = { github: { release: { value: null, status: 'error', error: 'x' }, tag: { value: null, status: 'error', error: 'x' } }, npm: { latest: { value: null, status: 'error', error: 'x' }, next: { value: null, status: 'error', error: 'x' }, versions: [], npmError: 'x' } };
  const c9 = policy.computeTarget(s9);
  t('T9', '所有来源失败 → 无目标（页面整体失败提示）', c9.target === null, `target=${c9.target}`);

  // T15: 真实场景目标可 npm 安装（0.1.1-rc.1 ∈ versions）
  t('T15', '真实场景目标 0.1.1-rc.1 可安装', npmOK && npmRes.versions.includes('0.1.1-rc.1'), '');

  // T14: 页面含 viewport（移动端）——version-server html 检查
  const html = require('fs').readFileSync('./scripts/version-server.js', 'utf8');
  t('T14', '版本页含移动端 viewport', html.includes('name="viewport"'), '');

  const failed = results.filter(r => !r.pass);
  console.log(`\n===== 结果: ${results.length - failed.length}/${results.length} PASS =====`);
  process.exit(failed.length ? 1 : 0);
})();
