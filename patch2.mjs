// Second pass, applied after patch.mjs: gets YuzuAccount under the 24,576-byte limit.
//  1. the swap leg moves to YuzuAccountCompanion.swapFor (vault keeps seed reserve, NAV invariant, Loss Budget)
//  2. modifiers become internal functions (one copy of each check instead of one per use)
//  3. public constants move to the companion (copied verbatim) and unused ones are deleted from the vault
//  4. read-only getters are dropped only as far as needed to leave 1,000 bytes of room
import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
const rd = (p) => fs.readFileSync(p, 'utf8');
const wr = (p, s) => fs.writeFileSync(p, s);
const once = (s, m) => {
  const i = s.indexOf(m);
  if (i < 0) throw new Error('missing marker: ' + m);
  if (s.indexOf(m, i + 1) >= 0) throw new Error('duplicate marker: ' + m);
  return i;
};
const rep = (s, m, r) => { const i = once(s, m); return s.slice(0, i) + r + s.slice(i + m.length); };
const span = (s, a, b, r) => {
  const i = once(s, a);
  const j = s.indexOf(b, i + a.length);
  if (j < 0) throw new Error('missing end marker: ' + b);
  return s.slice(0, i) + r + s.slice(j);
};
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));

const VAULT = 'src/YuzuAccount.sol';
const COMP = 'src/YuzuAccountCompanion.sol';
const P4 = 'src/interfaces/IYuzuPhase4Interfaces.sol';
const LIMIT = 24576;
const TARGET = LIMIT - 1000;

let v = rd(VAULT);
let c = rd(COMP);

// ------------------------------------------------------------ 1. constants: copy verbatim into the companion
const constNames = new Set(['EIP712_DOMAIN_TYPEHASH', 'GUARDIAN_AUTH_TYPEHASH']);
const constLines = [];
{
  const re = /^    (?:uint\d*|bytes32) public constant (\w+) = [^;\n]*;.*$/gm;
  let m;
  while ((m = re.exec(v))) {
    constNames.add(m[1]);
    if (!new RegExp('constant ' + m[1] + '\\b').test(c)) constLines.push(m[0].replace(/\s+$/, ''));
  }
  const anchor = /^    uint256 public constant RUN_FEE_AUTHOR_BPS = 8000;.*$/m;
  if (!anchor.test(c)) throw new Error('companion constant anchor missing');
  c = c.replace(anchor, (l) => l + '\n\n    // The vault\'s limits and Tier-3 action codes, copied verbatim from YuzuAccount.sol, which keeps them internal\n    // to save bytecode. Read them here.\n' + constLines.join('\n'));
  console.log('constants copied to companion:', constLines.length);
}

// ------------------------------------------------------------ 2. companion: swap leg
c = rep(c, '    error SalvageSwapShort();\n',
  '    error SalvageSwapShort();\n    error SwapNotFunded();\n    error FenceF3ExposureCapExceeded();\n    error FenceF8OutputInsufficient();\n');
c = rep(c, 'function routeDeskFee(address asset, uint256 amount) external {', 'function routeDeskFee(address asset, uint256 amount) public {');
{
  const i = once(c, '    // 1. GUARDIAN EIP-712 (view only)');
  const j = c.lastIndexOf('    // ====', i);
  c = c.slice(0, j) + rd('wip/frag_companion_swap.txt') + c.slice(j);
}
c = rep(c, 'It holds four jobs', 'It holds five jobs');
c = rep(c, '///         plus the read-only vault telemetry view.',
  '///         5. Running the swap leg of a vault swap on tokens the vault has already sent here (Fences F2, F3, F4, F6\n///            and F8 and the 0.25% desk fee) and paying the output back to the caller.\n///         plus the read-only vault telemetry view.');
wr(COMP, c);

{
  let p4 = rd(P4);
  p4 = rep(p4, '    function routeDeskFee(address asset, uint256 amount) external;\n',
    '    function swapFor(\n        address tokenIn,\n        address tokenOut,\n        uint256 amountIn,\n        uint256 minOutBps,\n        bool chargeDeskFee,\n        uint256 navBeforeUsd\n    ) external returns (uint256 amountOut);\n    function routeDeskFee(address asset, uint256 amount) external;\n');
  wr(P4, p4);
}

// ------------------------------------------------------------ 3. vault: thin swap, dead constants, modifiers
v = span(v, '    function _swap(', '    function _chargeLossBudget(',
`    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOutBps, bool chargeDeskFee)
        internal
        returns (uint256 receivedOut)
    {
        uint256 navBefore = lens.getLiquidNavUsd(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        // The companion runs Fences F2, F3, F4, F6 and F8 and the desk fee on exactly \`amountIn\` and pays the output
        // back here. It gets a transfer, never an approval, so it cannot spend more than \`amountIn\`.
        IERC20(tokenIn).safeTransfer(address(companion), amountIn);
        companion.swapFor(tokenIn, tokenOut, amountIn, minOutBps, chargeDeskFee, navBefore);
        receivedOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;

        _requireSeedReserve();

        uint256 navAfter = lens.getLiquidNavUsd(address(this));
        if (navAfter * 10000 < navBefore * minOutBps) revert FenceF5NavSlippageExceeded();
        _chargeLossBudget(navBefore, navAfter);                                       // Fence F5
    }

`);
for (const n of ['FENCE_F3_MAX_EXPOSURE_BPS', 'DESK_FEE_BPS', 'SALVAGE_MIN_OUT_BPS']) {
  if (new RegExp('\\b' + n + '\\b').test(v.replace(new RegExp('^.*constant ' + n + ' = .*\\n', 'm'), ''))) throw new Error(n + ' is still used in the vault');
  const before = v.length;
  v = v.replace(new RegExp('^.*constant ' + n + ' = .*\\n', 'm'), '');
  if (v.length === before) throw new Error('constant not found: ' + n);
}
v = span(v, '    bytes32 public constant EIP712_DOMAIN_TYPEHASH', '    // Immutable Protocol Wiring', '');
if (/_TYPEHASH\b/.test(v)) throw new Error('typehash still referenced in the vault');
if (!/IYuzuSwapRouter\(/.test(v)) v = rep(v, '    IYuzuSwapRouter,\n', '');
v = rep(v, 'contract YuzuAccount is ReentrancyGuard {',
  '///         - Split for the 24,576-byte EIP-170 limit: the swap leg (Fences F2, F3, F4, F6, F8 and the desk fee), salvage\n///           routing, the run-fee split and Guardian signature recovery run in YuzuAccountCompanion (Contract 17), reached\n///           by plain calls only. Fence F5, the seed reserve, the Loss Budget and every authority check stay here.\n///           Limits and action codes are internal here and published by the companion.\ncontract YuzuAccount is ReentrancyGuard {');
{
  let mods = 0;
  v = v.replace(/modifier (onlyOwnerOrAi|onlyOwner|onlyGuardian|whenLive)\(\) \{([\s\S]*?)\n        _;\n    \}/g, (m, name, body) => {
    mods++;
    return `function _${name}() internal view {${body}\n    }`;
  });
  if (mods !== 4) throw new Error('expected 4 modifiers, found ' + mods);
  let uses = 0;
  v = v.replace(/function\s+\w+\([^{;]*?\{/g, (hdr) => {
    const calls = [];
    const out = hdr.replace(/\s+(onlyOwnerOrAi|onlyOwner|onlyGuardian|whenLive)\b(?!\()/g, (m, name) => { calls.push(`_${name}();`); return ''; });
    if (!calls.length) return hdr;
    uses += calls.length;
    return out + '\n        ' + calls.join('\n        ');
  });
  console.log('modifier uses turned into calls:', uses);
  if (/\b(onlyOwnerOrAi|onlyOwner|onlyGuardian|whenLive)\b(?!\()/.test(v.replace(/_(onlyOwnerOrAi|onlyOwner|onlyGuardian|whenLive)\b/g, ''))) {
    throw new Error('a modifier use was left behind');
  }
}

// ------------------------------------------------------------ 4. tests: constants now live on the companion
for (const f of ['test/YuzuPhase4.t.sol', 'test/YuzuIntegration.t.sol']) {
  let t = rd(f);
  let n = 0;
  t = t.replace(/\b(vault|v|v2|v3)\.([A-Z][A-Z0-9_]+)\(\)/g, (m, obj, name) => (constNames.has(name) ? (n++, `companion.${name}()`) : m));
  t = t.replace(/^\s*assertEq\(companion\.(\w+_TYPEHASH)\(\), companion\.\1\(\)\);\n/gm, '');
  if (f.endsWith('YuzuIntegration.t.sol')) {
    const k = t.lastIndexOf('}');
    t = t.slice(0, k) + rd('wip/frag_integration_swap_test.txt') + t.slice(k);
  }
  wr(f, t);
  console.log(f, 'constant reads moved to companion:', n);
}

// ------------------------------------------------------------ 5. getters: drop only as far as needed
const a = v.indexOf('contract YuzuAccount is');
const b = v.indexOf('    event VaultInitialized');
if (a < 0 || b < 0) throw new Error('state region markers');
const head = v.slice(0, a), region = v.slice(a, b), tail = v.slice(b);
const LINE = /\bpublic\b(?:\s+(constant|immutable))?\s+(\w+)/;
const vars = [];
for (const line of region.split('\n')) {
  if (/^\s*\/\//.test(line)) continue;
  const m = line.match(LINE);
  if (m) vars.push({ kind: m[1] || 'storage', name: m[2] });
}
const kindOf = Object.fromEntries(vars.map((x) => [x.name, x.kind]));
const variant = (keep) => head + region.split('\n').map((line) => {
  if (/^\s*\/\//.test(line)) return line;
  const m = line.match(LINE);
  if (!m) return line;
  return keep(m[1] || 'storage', m[2]) ? line : line.replace(/\bpublic\b/, 'internal');
}).join('\n') + tail;

const must = new Set(['tokenId', 'guardianNonce', 'guardianEpoch', 'queueEpoch', 'timelockQueue', 'companion', 'cartridge']);
const why = {};
for (const f of walk('src').filter((p) => p.endsWith('.sol') && p !== VAULT)) {
  const s = rd(f);
  const re = /interface\s+(\w+)\s*\{([\s\S]*?)\n\}/g;
  let m;
  while ((m = re.exec(s))) {
    for (const fm of m[2].matchAll(/function\s+(\w+)\s*\(/g)) {
      if (kindOf[fm[1]] === 'storage' && !must.has(fm[1])) { must.add(fm[1]); why[fm[1]] = m[1]; }
    }
  }
}
for (const f of walk('test').filter((p) => p.endsWith('.t.sol'))) {
  for (const m of rd(f).matchAll(/\b(vault|v|v2|v3)\.(\w+)\(/g)) {
    if (kindOf[m[2]] && !must.has(m[2])) { must.add(m[2]); why[m[2]] = path.basename(f); }
  }
}
console.log('getters that must stay:', [...must].filter((n) => kindOf[n]).join(', '));
console.log('  needed by:', JSON.stringify(why));

const TAIL = new Set(['guardianRotationEpoch', 'initialized', 'seedAssetList', 'slot4Params', 'lastSlot4RunAt']);
const variants = [
  ['V1 constants internal, every other getter kept', (k, n) => must.has(n) || k !== 'constant'],
  ['V2 V1 minus five low-value storage getters', (k, n) => must.has(n) || (k !== 'constant' && !TAIL.has(n))],
  ['V3 V2 minus wiring (immutable) getters', (k, n) => must.has(n) || (k === 'storage' && !TAIL.has(n))],
  ['V4 only what contracts and tests need', (k, n) => must.has(n)],
];
const build = (src) => {
  wr(VAULT, src);
  try {
    execSync('forge build src/YuzuAccount.sol > exp.log 2>&1', { shell: '/bin/bash' });
  } catch (e) {
    console.log(rd('exp.log').split('\n').filter((l) => /Error|-->|\^/.test(l)).slice(0, 30).join('\n'));
    throw new Error('vault build failed');
  }
  const art = JSON.parse(rd('out/YuzuAccount.sol/YuzuAccount.json'));
  return (art.deployedBytecode.object.length - 2) / 2;
};
let chosen = null, best = null;
for (const [label, keep] of variants) {
  const src = variant(keep);
  const n = build(src);
  console.log(String(n).padStart(6), 'bytes', String(LIMIT - n).padStart(6), 'room |', label);
  if (!best || n < best.n) best = { label, keep, src, n };
  if (!chosen && n <= TARGET) chosen = { label, keep, src, n };
}
if (!chosen) chosen = best;
wr(VAULT, chosen.src);
const dropped = vars.filter((x) => !chosen.keep(x.kind, x.name));
const report = [
  'chosen: ' + chosen.label + ' -> ' + chosen.n + ' bytes (' + (LIMIT - chosen.n) + ' under the limit)',
  'getters removed from the vault (constants are readable on the companion):',
  ...['constant', 'immutable', 'storage'].map((k) => '  ' + k + ': ' + (dropped.filter((x) => x.kind === k).map((x) => x.name).join(', ') || 'none')),
  'getters kept on the vault: ' + vars.filter((x) => chosen.keep(x.kind, x.name)).map((x) => x.name).join(', '),
].join('\n');
console.log(report);
wr('output/getters.txt', report + '\n');
if (chosen.n > LIMIT) throw new Error('vault still over the limit');
wr('output/patch2.ok', 'ok\n');
console.log('patch2 applied');
