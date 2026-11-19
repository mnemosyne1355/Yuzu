import fs from 'fs';
const art = JSON.parse(fs.readFileSync('out/YuzuAccount.sol/YuzuAccount.json', 'utf8'));
const hex = art.deployedBytecode.object;
console.log('runtime bytes', (hex.length - 2) / 2);
const ir = art.irOptimized || '';
if (!ir) { console.log('no irOptimized in artifact'); process.exit(0); }
const k = ir.indexOf('_deployed"');
const d = ir.slice(k);
console.log('deployed ir chars', d.length);
const match = (s, i) => { let depth = 0, j = i; for (; j < s.length; j++) { const c = s[j]; if (c === '{') depth++; else if (c === '}') { depth--; if (depth === 0) break; } } return j; };
const fns = [];
const re = /function\s+([A-Za-z0-9_$.]+)\s*\(/g;
let m;
while ((m = re.exec(d))) {
  const i = d.indexOf('{', m.index);
  const j = match(d, i);
  fns.push([m[1], j - m.index]);
  re.lastIndex = j;
}
fns.sort((a, b) => b[1] - a[1]);
const fnTotal = fns.reduce((a, b) => a + b[1], 0);
console.log('functions', fns.length, 'chars in functions', fnTotal);
for (const f of fns.slice(0, 40)) console.log('  fn', f[1], f[0].slice(0, 70));
const ids = {};
for (const [name, sel] of Object.entries(art.methodIdentifiers || {})) ids[parseInt(sel, 16)] = name;
const cs = [];
const rc = /case (0x[0-9a-f]{5,8})\s*\{/g;
while ((m = rc.exec(d))) {
  const i = d.indexOf('{', m.index);
  const j = match(d, i);
  const name = ids[parseInt(m[1], 16)];
  if (name) cs.push([name, j - m.index]);
  rc.lastIndex = j;
}
cs.sort((a, b) => b[1] - a[1]);
console.log('selector cases', cs.length, 'chars', cs.reduce((a, b) => a + b[1], 0));
for (const c of cs.slice(0, 45)) console.log('  case', c[1], c[0].slice(0, 60));
