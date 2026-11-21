#!/usr/bin/env node
/**
 * 将主版本的改动同步到「内嵌字体版」与「网页版」。
 *
 * 自动发现：
 *   - 主版本：根目录中版本号最高的 眼师五行八识图演示工具v<版本>.html
 *   - 字体 CSS：font-family 目录下的 .css（引用 .woff2）
 *
 * 生成：
 *   - <主版本名>(内嵌字体版).html：字体 CSS 转 base64 内嵌，延迟注入
 *   - <主版本名>(网页版).html：外链字体 CSS，不内嵌
 *
 * 用法：
 *   node sync-embedded-font.js
 */

const fs = require('fs');
const path = require('path');

const ROOT = __dirname;

// ==== 结构锚点（与版本号无关） ====
const VERSION_CONST = 'const APP_VERSION';
const OPTION_PATTERN = /^([ \t]*)<option value="fangsong">[^<\r\n]*<\/option>/gm;
const MAP_PATTERN = /^([ \t]*)fangsong:[^\r\n]*,$/gm;
const EMBEDDED_FONT_ID = 'embeddedFontCss';

const BOOT_SCRIPT = `// 内嵌字体：延后到首帧之后再注入，避免大体积 CSS 阻塞加载动画
window.__eyeFontsReady = new Promise(resolve => {
  let settled = false;
  const done = () => { if (!settled) { settled = true; resolve(); } };
  setTimeout(() => {
    try {
      const source = document.getElementById('${EMBEDDED_FONT_ID}');
      if (!source) { done(); return; }
      const styleEl = document.createElement('style');
      styleEl.textContent = source.textContent;
      document.head.appendChild(styleEl);
      source.remove();
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(done);
      setTimeout(done, 2500);
    } catch (err) {
      done();
    }
  }, 80);
});`;

function fail(msg) {
  console.error('[同步失败] ' + msg);
  process.exit(1);
}

function read(file) {
  if (!fs.existsSync(file)) fail('找不到文件：' + file);
  return fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
}

function kb(n) {
  return (n / 1024).toFixed(1) + ' KB';
}

// ==== 1. 自动发现主版本 ====
const namePattern = /^眼师五行八识图演示工具v(\d+(?:\.\d+)*)\.html$/;
const candidates = fs.readdirSync(ROOT)
  .map(name => {
    const m = name.match(namePattern);
    if (!m) return null;
    return { name, version: m[1].split('.').map(Number) };
  })
  .filter(Boolean)
  .sort((a, b) => {
    for (let i = 0; i < Math.max(a.version.length, b.version.length); i++) {
      const d = (b.version[i] || 0) - (a.version[i] || 0);
      if (d) return d;
    }
    return 0;
  });
if (!candidates.length) fail('根目录中找不到主版本 HTML');
const baseName = candidates[0].name.replace(/\.html$/i, '');
const baseFile = path.join(ROOT, candidates[0].name);
const embeddedFile = path.join(ROOT, baseName + '(内嵌字体版).html');
const webFile = path.join(ROOT, baseName + '(网页版).html');

// ==== 2. 自动发现字体 CSS ====
const fontDir = path.join(ROOT, 'font-family');
if (!fs.existsSync(fontDir)) fail('找不到 font-family 目录');
const findCss = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
  const full = path.join(dir, entry.name);
  if (entry.isDirectory()) return findCss(full);
  return entry.isFile() && /\.css$/i.test(entry.name) ? [full] : [];
});
const cssFiles = findCss(fontDir);
if (!cssFiles.length) fail('font-family 目录中找不到字体 CSS');
if (cssFiles.length > 1) {
  fail('font-family 中发现多个 CSS，无法确定使用哪个：' + cssFiles.map(f => path.basename(f)).join(', '));
}
const cssFile = cssFiles[0];
const cssText = read(cssFile);
const faceCount = (cssText.match(/@font-face/g) || []).length;
if (!faceCount) fail('字体 CSS 中没有 @font-face：' + cssFile);
const fontFamily = (cssText.match(/@font-face\s*\{\s*font-family:\s*"([^"]+)"/) || [])[1];
if (!fontFamily) fail('字体 CSS 中找不到 font-family 名称');
const sealFontValue = "zt: '\"" + fontFamily + "\", KaiTi, \"Kaiti SC\", serif',";

const base = read(baseFile);
const appVersion = (base.match(/const APP_VERSION\s*=\s*'([^']+)'/) || [])[1];
if (!appVersion) fail('主版本中找不到 APP_VERSION');
if (base.includes('id="' + EMBEDDED_FONT_ID + '"')) fail('主版本中已存在内嵌字体块，请确认传入的是非内嵌字体版');
if (base.includes('<option value="zt">')) fail('主版本中已存在小篆选项，请确认传入的是非内嵌字体版/网页版');

// ==== 3. 公共：注入内嵌字体专属扩展（字体下拉选项 + 字体映射） ====
function addFontExtras(html, label) {
  let optCount = 0, mapCount = 0;
  html = html.replace(OPTION_PATTERN, (m, indent) => {
    optCount++;
    return m + '\n' + indent + '<option value="zt">' + label + '</option>';
  });
  html = html.replace(MAP_PATTERN, (m, indent) => {
    mapCount++;
    return m + '\n' + indent + sealFontValue;
  });
  if (optCount !== 2) fail('字体下拉中应找到 2 处仿宋选项，实际 ' + optCount + ' 处');
  if (mapCount !== 1) fail('字体映射中应找到 1 处仿宋配置，实际 ' + mapCount + ' 处');
  return html;
}

// ==== 4. 生成内嵌字体版：字体 CSS 转 base64，插到主脚本前 ====
const inlineCss = cssText.replace(/url\(\s*['"]?\.?\/?([^)'"\s]+\.woff2)['"]?\s*\)/g, (m, rel) => {
  const fontPath = path.join(path.dirname(cssFile), rel);
  if (!fs.existsSync(fontPath)) fail('字体文件缺失：' + rel);
  return 'url("data:font/woff2;base64,' + fs.readFileSync(fontPath).toString('base64') + '")';
});

const mainScriptIdx = base.indexOf(VERSION_CONST);
if (mainScriptIdx < 0) fail('主版本中找不到主脚本（APP_VERSION）');
const scriptOpenIdx = base.lastIndexOf('<script>', mainScriptIdx);
if (scriptOpenIdx < 0) fail('主版本中找不到主 <script> 入口');
let body = base.slice(scriptOpenIdx + '<script>'.length);
if (body.startsWith('\n')) body = body.slice(1);

const fontCssBlock = '<script type="text/plain" id="' + EMBEDDED_FONT_ID + '">\n' + inlineCss + '</script>';
let embedded = base.slice(0, scriptOpenIdx) +
  fontCssBlock + '\n' +
  '<script>\n' +
  BOOT_SCRIPT.trimEnd() + '\n\n' +
  body;
embedded = addFontExtras(embedded, '小篆（内嵌）');
if ((embedded.split(VERSION_CONST).length - 1) !== 1) {
  fail('内嵌字体版中生成了重复的业务代码（APP_VERSION 出现多次）');
}
fs.writeFileSync(embeddedFile, embedded, 'utf8');

// ==== 5. 生成网页版：外链字体 CSS，不内嵌 ====
const cssRel = path.relative(ROOT, cssFile).split(path.sep).join('/');
let web = addFontExtras(base, '小篆');
if (!web.includes('</head>')) fail('主版本中找不到 </head>');
const linkHtml = '  <!-- 网页版：外链小篆字体，不内嵌 -->\n' +
  '  <link rel="stylesheet" href="' + cssRel + '">\n</head>';
web = web.replace('</head>', linkHtml);
if ((web.split(cssRel).length - 1) !== 1) fail('网页版字体外链生成异常');
fs.writeFileSync(webFile, web, 'utf8');

// ==== 6. 输出摘要 ====
console.log('已同步：');
console.log('  主版本：' + path.basename(baseFile) + '（' + kb(base.length) + '，@font-face ' + faceCount + ' 个）');
console.log('  内嵌字体版：' + path.basename(embeddedFile) + '（' + kb(embedded.length) + '）');
console.log('  网页版：' + path.basename(webFile) + '（' + kb(web.length) + '，外链 ' + cssRel + '）');
