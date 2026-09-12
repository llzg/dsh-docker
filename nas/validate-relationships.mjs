// validate-relationships.mjs —— 用**容器内真实**的 DSH 校验函数验证会话 artifact 的轮次关系。
//
// 为什么：自己重写一遍校验逻辑容易和 DSH 的真实实现漂移（S2 就是因此误判过 v0 文件）。
// 这里直接 import DSH 自己的 assertReleasedArtifactRelationships（与迁移器同一份实现）。
//
// 用法（宿主侧把 artifact 解压后喂进去；容器内 node 需能 import 到 DSH 包）：
//   zstd -dc <session.v2.jsonl.zstd> | docker exec -i <容器> node validate-relationships.mjs
// 输出：RELATIONSHIPS_OK events=N  或  RELATIONSHIPS_FAIL <原因>（退出码 1）
//      DENSE_FAIL at <i>: seq=<n>（seq 与数组下标不一致，退出码 1）
import fs from 'node:fs';
import { assertReleasedArtifactRelationships } from '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session-format-v0-to-v1/lib/index.js';

const raw = fs.readFileSync(0, 'utf8');
const recs = raw.split('\n').filter(Boolean).map((l, i) => {
  try { return JSON.parse(l); } catch (e) { console.log(`PARSE_FAIL line ${i}: ${e.message}`); process.exit(1); }
});
const header = recs.find((r) => r.type === 'session');
const events = recs.filter((r) => r.type !== 'session');
for (const [i, e] of events.entries()) {
  if (e.seq !== i) { console.log(`DENSE_FAIL at ${i}: seq=${e.seq}`); process.exit(1); }
}
try {
  assertReleasedArtifactRelationships({ header, events }, {
    stepEvents: new Set(['assistant/attempt']),
    preservedSourceSourceTitleRequestText: true,
    preservedSourceTitleRequestText: true,
  });
  console.log(`RELATIONSHIPS_OK events=${events.length}`);
} catch (e) {
  console.log(`RELATIONSHIPS_FAIL ${e.message}`);
  process.exit(1);
}
