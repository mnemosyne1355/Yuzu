import fs from 'fs';
import path from 'path';
const LIMIT = 24576;
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
const rows = [];
for (const f of walk('src').filter((p) => p.endsWith('.sol') && !p.includes('interfaces'))) {
  const dir = path.join('out', path.basename(f));
  if (!fs.existsSync(dir)) { rows.push([path.basename(f), -1]); continue; }
  for (const j of fs.readdirSync(dir).filter((x) => x.endsWith('.json'))) {
    const a = JSON.parse(fs.readFileSync(path.join(dir, j), 'utf8'));
    const hex = (a.deployedBytecode && a.deployedBytecode.object) || '0x';
    const n = (hex.length - 2) / 2;
    if (n > 0) rows.push([j.replace('.json', ''), n]);
  }
}
rows.sort((x, y) => y[1] - x[1]);
for (const [n, s] of rows) console.log(String(s).padStart(7), String(LIMIT - s).padStart(7), n);
const over = rows.filter((r) => r[1] > LIMIT || r[1] < 0);
console.log(rows.length === 0 ? 'NO_ARTIFACTS' : over.length ? 'OVER_LIMIT_OR_MISSING: ' + over.map((r) => r[0]).join(', ') : 'ALL_UNDER_LIMIT (' + rows.length + ' contracts)');
