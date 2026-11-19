import fs from 'fs';
import { execSync } from 'child_process';
const P = 'src/YuzuAccount.sol';
const base = fs.readFileSync(P, 'utf8');
const size = (env = '', flags = '') => {
  try {
    execSync(`${env} forge build src/YuzuAccount.sol ${flags} > exp.log 2>&1`, { shell: '/bin/bash' });
  } catch (e) {
    return 'BUILD FAILED: ' + fs.readFileSync('exp.log', 'utf8').split('\n').filter((l) => /Error|-->/.test(l)).slice(0, 8).join(' | ');
  }
  const a = JSON.parse(fs.readFileSync('out/YuzuAccount.sol/YuzuAccount.json', 'utf8'));
  return (a.deployedBytecode.object.length - 2) / 2;
};
const run = (label, src, env, flags) => {
  fs.writeFileSync(P, src);
  console.log(label.padEnd(52), size(env, flags));
};

const getters = (s) => {
  const a = s.indexOf('contract YuzuAccount');
  const b = s.indexOf('    event VaultInitialized');
  return s.slice(0, a) + s.slice(a, b).replace(/\bpublic\b/g, 'internal') + s.slice(b);
};

const modsToFns = (s) => {
  s = s.replace(
    /modifier (onlyOwnerOrAi|onlyOwner|onlyGuardian|whenLive)\(\) \{([\s\S]*?)\n        _;\n    \}/g,
    (m, name, body) => `function _${name}() internal {${body}\n    }`
  );
  let n = 0;
  s = s.replace(/function\s+\w+\([^{;]*?\{/g, (hdr) => {
    const calls = [];
    const out = hdr.replace(/\s+(onlyOwnerOrAi|onlyOwner|onlyGuardian|whenLive)\b(?!\()/g, (m, name) => {
      calls.push(`_${name}();`);
      return '';
    });
    if (!calls.length) return hdr;
    n += calls.length;
    return out + '\n        ' + calls.join(' ');
  });
  console.log('  modifier uses rewritten:', n);
  return s;
};

const thinSwap = (s) => {
  const i = s.indexOf('    function _swap(');
  const j = s.indexOf('    function _routeDeskFee(');
  if (i < 0 || j < 0) throw new Error('swap markers');
  const body = `    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOutBps, bool chargeDeskFee)
        internal
        returns (uint256 receivedOut)
    {
        uint256 navBefore = lens.getLiquidNavUsd(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).safeTransfer(address(companion), amountIn);
        ISwapDeskX(address(companion)).swapFor(tokenIn, tokenOut, amountIn, minOutBps, chargeDeskFee, navBefore);
        receivedOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        _requireSeedReserve();
        uint256 navAfter = lens.getLiquidNavUsd(address(this));
        if (navAfter * 10000 < navBefore * minOutBps) revert FenceF5NavSlippageExceeded();
        _chargeLossBudget(navBefore, navAfter);
    }

`;
  return s.slice(0, i) + body + s.slice(j)
    + '\ninterface ISwapDeskX { function swapFor(address,address,uint256,uint256,bool,uint256) external returns (uint256); }\n';
};

const pythStub = (s) => {
  const i = s.indexOf('    function _updatePyth(');
  const j = s.indexOf('    receive() external payable');
  if (i < 0 || j < 0) throw new Error('pyth markers');
  return s.slice(0, i) + '    function _updatePyth(bytes[] calldata) internal {}\n\n' + s.slice(j);
};

try {
  run('base (patched vault)', base);
  const g = getters(base);
  run('A  all getters internal', g);
  run('B  modifiers as functions (alone)', modsToFns(base));
  run('C  thin swap (alone)', thinSwap(base));
  const gm = modsToFns(g);
  run('A+B', gm);
  const gms = thinSwap(gm);
  run('A+B+C', gms);
  run('A+B+C + pyth update stubbed (bound)', pythStub(gms));
  run('A+B+C optimizer runs=1', gms, '', '--optimizer-runs 1');
  run('A+B+C legacy pipeline (via_ir off)', gms, 'FOUNDRY_VIA_IR=false', '');
  run('A+B+C legacy runs=1', gms, 'FOUNDRY_VIA_IR=false', '--optimizer-runs 1');
} finally {
  fs.writeFileSync(P, base);
}
