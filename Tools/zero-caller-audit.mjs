// zero-caller-audit.mjs —— 零调用方盘点（可达性口径）。
//
// 用法：node Tools/zero-caller-audit.mjs
// 输出：文件数 / 可达 / 不可达 + 每个不可达文件的行数。
// 口径：
//   · 符号 = 顶层类型 + 顶层函数 + 类型成员（排除函数内局部变量：靠“名字出现在 <=3 个文件”过滤）；
//   · 引用 = 去掉注释、字符串、#if DEBUG 块后的标识符匹配（自检不算生产引用）；
//   · 根   = Sources/TiebaNative/App/** + TiebaLite/（App 壳），沿 file→file 引用做 BFS。
//   · 已知盲区：只被扩展成员（extension 里的 var/func）引用的文件可能被误判为不可达，
//     删除前必须再 grep 一次该文件的独有符号（本轮据此救回 TiebaViewVisibility / TiebaURLQueryValue 等）。
import fs from 'node:fs'; import path from 'node:path';
const ROOT='/Users/xingtong/Desktop/tieba/TiebaLite-RN-Swift/Sources/TiebaNative';
function walk(dir,out=[]){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,e.name);if(e.isDirectory()){if(['out','.zcode'].includes(e.name))continue;walk(p,out);}else if(e.name.endsWith('.swift'))out.push(p);}return out;}
function mask(src){const out=[];let inBlock=false,d0=0,st=[];for(const raw of src.split('\n')){const t=raw.trim();
 if(/^#if\b/.test(t)){if(d0>0)st.push(1);else if(/^#if\s+DEBUG\b/.test(t)){d0=1;st=[];}out.push('');continue;}
 if(/^#elseif\b/.test(t)||/^#else\b/.test(t)){out.push('');continue;}
 if(/^#endif\b/.test(t)){if(d0>0){if(st.length>0)st.pop();else d0=0;}out.push('');continue;}
 if(d0>0){out.push('');continue;}
 let line='',i=0,inStr=false;while(i<raw.length){const c=raw[i],c2=raw.slice(i,i+2);
  if(inBlock){if(c2==='*/'){inBlock=false;i+=2;}else i++;continue;}
  if(inStr){if(c==='\\'){i+=2;continue;}if(c==='"'){inStr=false;line+='"';i++;continue;}i++;continue;}
  if(c2==='//')break; if(c2==='/*'){inBlock=true;i+=2;continue;} if(c==='"'){inStr=true;line+='"';i++;continue;} line+=c;i++;} out.push(line);} return out;}
const files=walk(ROOT).sort();
const data=new Map(); for(const f of files){const src=fs.readFileSync(f,'utf8');data.set(f,{src,masked:mask(src),rel:path.relative(ROOT,f)});}
const TYPE=/(?:^|[\s(])(class|struct|enum|protocol|actor|extension)\s+[A-Za-z_]\w*/;
const FUNC=/\bfunc\s+[A-Za-z_]\w*/;
const DECLNAME=/(?:^|[\s(])(class|struct|enum|protocol|actor|typealias|func)\s+([A-Za-z_]\w*)/;
const DECLNAME_VAR=/^(?=[ \t])(?=[^\n]*\b(?:public|internal|private|fileprivate|open|static|class|lazy|weak|unowned|override|nonisolated)\b)[^\n]*\b(?:var|let)\s+([A-Za-z_]\w*)/;
const varNames=new Set();
for(const [,d] of data){ d.masked.forEach(line=>{ const m=/\b(?:var|let)\s+([A-Za-z_]\w*)/.exec(line); if(m) varNames.add(m[1]); }); }
const varFreq=new Map();
for(const n of varNames){ let c=0; for(const [,x] of data){ if(new RegExp('(?<![A-Za-z0-9_])'+n+'(?![A-Za-z0-9_])').test(x.masked.join('\n'))) c++; } varFreq.set(n,c); }
const own=new Map(); // name -> file
const dup=new Set();
for(const [f,d] of data){
  const frames=[]; // kinds: 'type'|'func'|'other'
  d.masked.forEach((line,idx)=>{
    if(!line.trim())return;
    const lead=(line.match(/^\s*\}+/)||[''])[0].length;
    for(let k=0;k<lead;k++){if(frames.length)frames.pop();}
    const rest=line.slice(lead);
    const enclosing=frames.length?frames[frames.length-1]:'top';
    const isTypeLine=TYPE.test(rest);
    let m=DECLNAME.exec(rest);
    if(!m){ const mv=/^[ \t][^\n]*\b(?:var|let)\s+([A-Za-z_]\w*)/.exec(rest); if(mv && varFreq.get(mv[1])<=3) m=[null,'var',mv[1]]; }
    if(m){const kind=m[1],name=m[2];
      const isMemberTypeDecl=(kind==='class'||kind==='struct'||kind==='enum'||kind==='protocol'||kind==='actor'||kind==='typealias');
      const record=(kind==='class'||kind==='struct'||kind==='enum'||kind==='protocol'||kind==='actor'||kind==='typealias'||kind==='func') ? true : (enclosing==='type'||enclosing==='top');
      if(record && name!=='init'){ if(own.has(name)){ if(own.get(name)!==f) dup.add(name);} else own.set(name,f); }
    }
    const opens=(line.match(/\{/g)||[]).length, closes=(line.match(/\}/g)||[]).length;
    if(opens>closes){ let kind='other'; if(isTypeLine)kind='type'; else if(FUNC.test(rest)||/\binit\s*[?!(]/.test(rest)||/=\s*\{/.test(rest)||/\bin\s*$/.test(rest)||/\b(in|throws|rethrows)\s*$/.test(rest))kind='func'; frames.push(kind); }
    else if(opens===closes && opens>0 && frames.length){ }
  });
}
const symToFile=new Map(); for(const [n,f] of own){ if(!dup.has(n)) symToFile.set(n,f); }
console.log('SYMBOLS',symToFile.size,'DUP',dup.size);
console.log('ctx-owned:',[...symToFile].filter(([n,f])=>/UI\/Context\//.test(f)).map(([n])=>n).join(', '));
const joint=new Map(); for(const [f,x] of data) joint.set(f,x.masked.join('\n'));
const RE=new Map(); for(const n of symToFile.keys()) RE.set(n,new RegExp('(?<![A-Za-z0-9_])'+n.replace(/[$]/g,'\\$')+'(?![A-Za-z0-9_])'));
const APP='/Users/xingtong/Desktop/tieba/TiebaLite-RN-Swift/TiebaLite';
function walk2(dir,out=[]){if(!fs.existsSync(dir))return out;for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,e.name);if(e.isDirectory())walk2(p,out);else if(e.name.endsWith('.swift'))out.push(p);}return out;}
const rootSrc=walk2(APP).map(f=>fs.readFileSync(f,'utf8')).join('\n');
const live=new Set(); let queue=[];
for(const f of files){ if(/Sources\/TiebaNative\/App\//.test(f)){live.add(f);queue.push(f);} }
for(const [n,f] of symToFile){ if(RE.get(n).test(rootSrc)&&!live.has(f)){live.add(f);queue.push(f);} }
let g=0;
while(queue.length&&g++<500){ const snap=queue; queue=[]; for(const f of snap){ const text=joint.get(f); for(const [n,g2] of symToFile){ if(live.has(g2))continue; if(RE.get(n).test(text)){live.add(g2);queue.push(g2);} } } }
const dead=files.filter(f=>!live.has(f));
let tot=0; console.log('FILES',files.length,'LIVE',live.size,'UNREACHABLE',dead.length);
for(const f of dead){const n=data.get(f).src.split('\n').length;tot+=n;console.log([data.get(f).rel,n].join('\t'));}
console.log('TOTAL_UNREACHABLE_LINES',tot);
fs.writeFileSync('/tmp/audit/dead6.json',JSON.stringify(dead.map(f=>path.relative(ROOT,f)),null,1));