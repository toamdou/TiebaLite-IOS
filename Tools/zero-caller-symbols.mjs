// zero-caller-symbols.mjs —— 零调用方盘点（逐符号口径）。
//
// 用法：node Tools/zero-caller-symbols.mjs
// 输出 Tier A（全仓无任何代码引用）/ Tier B（只在声明文件内被引用）/ Tier C（有跨文件引用）。
// 口径：排除声明行自身、排除注释、排除 #if DEBUG 自检块。
import fs from 'node:fs';
import path from 'node:path';
const ROOT = '/Users/xingtong/Desktop/tieba/TiebaLite-RN-Swift/Sources/TiebaNative';
function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name === 'out' || e.name === '.zcode') continue; walk(p, out); }
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}
function mask(src) {
  const out = []; let inBlockComment = false; let debugDepth = 0; let ifStack = [];
  for (const raw of src.split('\n')) {
    const t = raw.trim();
    if (/^#if\b/.test(t)) {
      if (debugDepth > 0) ifStack.push(1);
      else if (/^#if\s+DEBUG\b/.test(t)) { debugDepth = 1; ifStack = []; }
      out.push(''); continue;
    }
    if (/^#elseif\b/.test(t) || /^#else\b/.test(t)) { out.push(''); continue; }
    if (/^#endif\b/.test(t)) {
      if (debugDepth > 0) { if (ifStack.length > 0) ifStack.pop(); else debugDepth = 0; }
      out.push(''); continue;
    }
    if (debugDepth > 0) { out.push(''); continue; }
    let line = ''; let i = 0; let inString = false;
    while (i < raw.length) {
      const c = raw[i], c2 = raw.slice(i, i + 2);
      if (inBlockComment) { if (c2 === '*/') { inBlockComment = false; i += 2; } else i++; continue; }
      if (inString) { if (c === '\\') { i += 2; continue; } if (c === '"') { inString = false; line += '"'; i++; continue; } i++; continue; }
      if (c2 === '//') break;
      if (c2 === '/*') { inBlockComment = true; i += 2; continue; }
      if (c === '"') { inString = true; line += '"'; i++; continue; }
      line += c; i++;
    }
    out.push(line);
  }
  return out;
}
const files = walk(ROOT).sort();
const data = new Map();
for (const f of files) { const src = fs.readFileSync(f, 'utf8'); data.set(f, { src, masked: mask(src), rel: path.relative(ROOT, f) }); }
const declRe = /^(?:@[A-Za-z_][\w.]*(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|open|final|indirect|nonisolated|@unchecked)\s+)*(class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)/;
const funcRe = /^(?:@[A-Za-z_][\w.]*(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|open|final|static|nonisolated|mutating)\s+)*func\s+([A-Za-z_]\w*)/;
const decls = [];
for (const [f, d] of data) {
  d.masked.forEach((line, idx) => {
    if (!line || /^\s/.test(line)) return;
    let m = declRe.exec(line); if (m) { decls.push({ name: m[2], kind: m[1], file: f, line: idx + 1 }); return; }
    m = funcRe.exec(line); if (m) decls.push({ name: m[1], kind: 'func', file: f, line: idx + 1 });
  });
}
const joint = new Map(); for (const [f,x] of data) joint.set(f, x.masked.join('\n'));
const results = [];
for (const d of decls) {
  const re = new RegExp('(?<![A-Za-z0-9_])' + d.name + '(?![A-Za-z0-9_])');
  let own = 0, external = 0; const extFiles = new Set(); let rawAll = 0;
  for (const [f, x] of data) {
    const rawHits = (x.src.match(re) || []).length; rawAll += rawHits;
    if (f === d.file) {
      const ownText = x.masked.filter((l, ix) => ix !== d.line - 1).join('\n');
      own += (ownText.match(re) || []).length;
    } else {
      const hits = (joint.get(f).match(re) || []).length;
      external += hits; if (hits) extFiles.add(x.rel);
    }
  }
  results.push({ name: d.name, kind: d.kind, rel: data.get(d.file).rel, line: d.line, own, external, total: own + external, extFiles: [...extFiles], rawAll, commentOnly: rawAll - (own + external) });
}
const tierA = results.filter(r => r.total === 0);
const tierB = results.filter(r => r.total > 0 && r.external === 0);
const tierC = results.filter(r => r.external > 0);
console.log('DECLS', results.length, 'TIER_A_truly_dead', tierA.length, 'TIER_B_own_file_only', tierB.length, 'TIER_C_module_api', tierC.length);
console.log('=== TIER A: no code reference anywhere (comments/DEBUG excluded) ===');
for (const z of tierA.sort((a,b)=> a.rel.localeCompare(b.rel) || a.line-b.line)) console.log([z.kind, z.name, z.rel+':'+z.line, 'rawMentions='+z.rawAll].join('\t'));
console.log('=== TIER B: referenced only inside declaring file ===');
for (const z of tierB.sort((a,b)=> a.rel.localeCompare(b.rel) || a.line-b.line)) console.log([z.kind, z.name, z.rel+':'+z.line, 'own='+z.own, 'rawMentions='+z.rawAll].join('\t'));
fs.writeFileSync('/tmp/audit/audit2.json', JSON.stringify(results, null, 1));