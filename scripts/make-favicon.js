#!/usr/bin/env node
// 生成自定义 dsh 图标 favicon.svg（将 JPEG 以 data URI 嵌入 SVG）。
// 用法: node make-favicon.js <favicon.svg 输出路径> [图片路径，默认 /opt/dsh-icon.jpg]
// 幂等：重复执行生成相同内容。无 node 依赖。
const fs = require('fs');

function jpegSize(buf) {
  // 解析 JPEG SOF marker 获取宽高
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let i = 2;
  while (i < buf.length - 9) {
    if (buf[i] !== 0xff) { i++; continue; }
    const m = buf[i + 1];
    if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(m)) {
      const h = buf.readUInt16BE(i + 5);
      const w = buf.readUInt16BE(i + 7);
      return { w, h };
    }
    i++;
  }
  return null;
}

const out = process.argv[2] || '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/favicon.svg';
const imgPath = process.argv[3] || '/opt/dsh-icon.jpg';

try {
  const buf = fs.readFileSync(imgPath);
  const size = jpegSize(buf) || { w: 512, h: 512 };
  const b64 = buf.toString('base64');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size.w}" height="${size.h}" viewBox="0 0 ${size.w} ${size.h}">
  <image href="data:image/jpeg;base64,${b64}" width="${size.w}" height="${size.h}" preserveAspectRatio="xMidYMid meet"/>
</svg>
`;
  fs.writeFileSync(out, svg);
  console.log(`favicon-custom: wrote ${out} (${size.w}x${size.h}, ${(buf.length / 1024).toFixed(0)}KB embedded)`);
} catch (e) {
  console.error(`favicon-custom: FAILED — ${e.message}`);
  process.exit(1);
}
