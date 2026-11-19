import fs from 'fs';
const lines = fs.readFileSync('patch.txt', 'utf8').split('\n');
let file = null; const edits = []; let i = 0;
while (i < lines.length) {
  const l = lines[i];
  if (l.startsWith('@@@ ')) { file = l.slice(4).trim(); i++; continue; }
  if (l.startsWith('<<<<')) {
    const range = l.includes('RANGE'); i++;
    const a = [], b = [], r = []; let cur = a;
    while (lines[i] !== '>>>>') {
      if (lines[i] === '----' && range && cur === a) cur = b;
      else if (lines[i] === '====' && cur !== r) cur = r;
      else cur.push(lines[i]);
      i++;
      if (i >= lines.length) { console.error('unterminated edit'); process.exit(1); }
    }
    edits.push({ file, range, a: a.join('\n'), b: b.join('\n'), repl: r.join('\n') });
    i++; continue;
  }
  i++;
}
const esc = (s) => s.trim().split(/\s+/).map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('\\s+');
const cache = {}; let n = 0;
for (const e of edits) {
  if (!(e.file in cache)) cache[e.file] = fs.readFileSync(e.file, 'utf8');
  const pat = '[ \\t]*' + esc(e.a) + (e.range ? '[\\s\\S]*?' + esc(e.b) : '');
  const count = (cache[e.file].match(new RegExp(pat, 'g')) || []).length;
  if (count !== 1) { console.error(`EDIT FAILED (${count} matches) in ${e.file}: ${e.a.trim().slice(0, 90)}`); process.exit(1); }
  cache[e.file] = cache[e.file].replace(new RegExp(pat), () => e.repl);
  n++;
}
for (const f of Object.keys(cache)) fs.writeFileSync(f, cache[f]);
console.log(`applied ${n} edits to ${Object.keys(cache).length} files`);
