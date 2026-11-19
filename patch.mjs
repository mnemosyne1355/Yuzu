import fs from 'fs';
const rd = (p) => fs.readFileSync(p, 'utf8');
const wr = (p, s) => fs.writeFileSync(p, s);
const once = (s, m) => {
  const i = s.indexOf(m);
  if (i < 0) throw new Error('missing marker: ' + m);
  if (s.indexOf(m, i + 1) >= 0) throw new Error('duplicate marker: ' + m);
  return i;
};
const rep = (s, m, r) => { const i = once(s, m); return s.slice(0, i) + r + s.slice(i + m.length); };
// replace [a, b) with r (b is kept)
const span = (s, a, b, r) => {
  const i = once(s, a);
  const j = s.indexOf(b, i + a.length);
  if (j < 0) throw new Error('missing end marker: ' + b);
  return s.slice(0, i) + r + s.slice(j);
};
const HDR = '    // ====';
const headerBefore = (s, m) => { const i = once(s, m); const j = s.lastIndexOf(HDR, i); if (j < 0) throw new Error('no header before ' + m); return j; };
const spanToHeader = (s, a, sectionMarker, r) => {
  const i = once(s, a);
  const j = headerBefore(s, sectionMarker);
  if (j <= i) throw new Error('bad order for ' + a);
  return s.slice(0, i) + r + s.slice(j);
};
const insertAtHeader = (s, sectionMarker, r) => { const j = headerBefore(s, sectionMarker); return s.slice(0, j) + r + s.slice(j); };

// ---------------------------------------------------------------- interfaces
{
  const p = 'src/interfaces/IYuzuPhase4Interfaces.sol';
  let s = rd(p);
  s += `
interface IYuzuAccountCompanion {
    function recoverGuardianSigner(
        address vault,
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData,
        uint256 guardianNonce,
        uint256 guardianEpoch,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (address);
    function routeDeskFee(address asset, uint256 amount) external;
    function routeSalvage(address asset, uint256 amount) external;
    function routeRunFee(uint256 authorTokenId, uint256 runFee) external;
}

interface IYuzuCartridgePolicy {
    function setPolicyFromVaultTier3(
        uint256 tokenId,
        address[] calldata allowedAssets,
        uint16 minStrikeBps,
        uint16 minPremiumBps,
        uint32 maxExpirySeconds,
        uint16 maxExposureShareBps
    ) external;
}
`;
  wr(p, s);
}
{
  const p = 'src/interfaces/IYuzuPhase5Interfaces.sol';
  let s = rd(p);
  s = rep(s, '    function receiveFeeEscrow(address asset, uint256 amount) external;\n}',
    '    function receiveFeeEscrow(address asset, uint256 amount) external;\n    function receiveSkimEscrow(address asset, uint256 amount) external;\n}');
  wr(p, s);
}
{
  const p = 'src/interfaces/IYuzuV4Interfaces.sol';
  let s = rd(p);
  const i = once(s, 'interface IYuzuNavLens {');
  s = s.slice(0, i) + `interface IYuzuNavLens {
    function requireFresh(address asset) external view returns (uint256 price18);
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
    function pyth() external view returns (address);
}

interface IYuzuRegistry {
    struct Route {
        address router;
        uint8 routerType;
        bytes path;
        bool isActive;
    }
    function routeFor(address tokenIn, address tokenOut) external view returns (Route memory);
}
`;
  wr(p, s);
}

// ---------------------------------------------------------------- YuzuAccount
{
  const p = 'src/YuzuAccount.sol';
  let s = rd(p);
  s = rep(s, 'import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";\n', '');
  s = rep(s, '\n} from "./interfaces/IYuzuPhase4Interfaces.sol";',
    ',\n    IYuzuAccountCompanion,\n    IYuzuCartridgePolicy\n} from "./interfaces/IYuzuPhase4Interfaces.sol";');
  s = rep(s, '    address public immutable defaultSlot4Adapter;\n',
    '    address public immutable defaultSlot4Adapter;\n    IYuzuAccountCompanion public immutable companion; // Contract 17: shared stateless helper, called, never delegatecalled\n');
  s = rep(s, '        address defaultSlot4Adapter_\n    ) {', '        address defaultSlot4Adapter_,\n        address companion_\n    ) {');
  s = rep(s, '        defaultSlot4Adapter = defaultSlot4Adapter_;\n',
    '        defaultSlot4Adapter = defaultSlot4Adapter_;\n        companion = IYuzuAccountCompanion(companion_);\n');
  s = rep(s, '    error CannotVaultYuzuMainframe();\n',
    '    error CannotVaultYuzuMainframe();\n    error OnlyCartridge();\n    error EthRescueFailed();\n');

  // desk fee routing moves to the companion
  s = span(s, '    function _routeDeskFee(', '    function _chargeLossBudget(',
`    function _routeDeskFee(address asset, uint256 feeAmount) internal {
        // WETH is split 80/20 at once; any other crypto asset goes to the Treasury fee escrow (in the companion).
        IERC20(asset).safeTransfer(address(companion), feeAmount);
        companion.routeDeskFee(asset, feeAmount);
    }

`);

  // run-fee split moves to the companion
  s = spanToHeader(s, "        // 80% to author unit's vault IF", '    // 5. TIER-2 DAILY FAST-LANE',
`        // 80% to the author unit's vault if its ROM bond is active, otherwise 100% to YuzuDistributor (in the companion).
        yuzuToken.safeTransfer(address(companion), runFee);
        companion.routeRunFee(authorTokenId, runFee);
    }

`);

  // Fence F7: no Tier-3 action while BOLTED or UNBOLTING
  s = rep(s, '    ) external onlyOwner nonReentrant {\n        _authorizeTier3(actionType, target, asset, amount, extraData, deadline, guardianSig);\n',
    '    ) external onlyOwner nonReentrant {\n        // Fence F7: a BOLTED or UNBOLTING vault accepts deposits and reward claims and nothing else.\n        if (mainframe.boltState(tokenId) != BoltState.UNBOLTED) revert VaultNotLive();\n        _authorizeTier3(actionType, target, asset, amount, extraData, deadline, guardianSig);\n');

  s = rep(s, '            require(ok, "ETH_RESCUE_FAILED");', '            if (!ok) revert EthRescueFailed();');

  // salvage routing moves to the companion
  s = rep(s, '                _routeSalvageShare(asset, salvageShare);',
    '                IERC20(asset).safeTransfer(address(companion), salvageShare);\n                companion.routeSalvage(asset, salvageShare);');
  s = spanToHeader(s, '    function _routeSalvageShare(', '    // 8. GUARDIAN PANIC FREEZE', '');

  // guardian signature recovery moves to the companion
  s = span(s, '        bytes32 digest = _hashGuardianAuth(\n            ACTION_RECOVERY_TRANSFER', '        if (signer != coldGuardian) return false;',
`        address signer = companion.recoverGuardianSigner(
            address(this),
            ACTION_RECOVERY_TRANSFER,
            recoveryAddress,
            address(0),
            tokenId_,
            bytes32(0),
            guardianNonce,
            guardianEpoch,
            deadline,
            sig
        );
`);
  s = span(s, '            bytes32 digest = _hashGuardianAuth(actionType,', '            if (signer != coldGuardian) revert InvalidGuardianSignature();',
`            address signer = companion.recoverGuardianSigner(
                address(this), actionType, target, asset, amount, extraData, guardianNonce, guardianEpoch, deadline, guardianSig
            );
`);
  s = span(s, '    function _hashGuardianAuth(', '    function _updatePyth(', '');

  // telemetry view moves to the companion
  s = span(s, '    function getAccountTelemetry()', '    /// @notice ERC-1271 signature verification is permanently disabled', '');

  // Slot 2 wiring
  s = insertAtHeader(s, '    // 7. SEED RAID', rd('wip/frag_vault_slot2.txt'));
  wr(p, s);
}

// ---------------------------------------------------------------- YuzuCartridge
{
  const p = 'src/YuzuCartridge.sol';
  let s = rd(p);
  s = rep(s, '            treasury.receiveFeeEscrow(asset, skimAmount);', '            treasury.receiveSkimEscrow(asset, skimAmount);');
  wr(p, s);
}

// ---------------------------------------------------------------- YuzuTreasury
{
  const p = 'src/YuzuTreasury.sol';
  let s = rd(p);
  s = rep(s, 'import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";\n',
    'import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";\nimport {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";\n');
  s = rep(s, 'import {YuzuPoolHook} from "./YuzuPoolHook.sol";\n',
    'import {IYuzuSwapRouter, IPythMinimal} from "./interfaces/IYuzuPhase4Interfaces.sol";\nimport {YuzuPoolHook} from "./YuzuPoolHook.sol";\n');
  s = rep(s, 'contract YuzuTreasury is IUnlockCallback, ReentrancyGuard {\n',
    'contract YuzuTreasury is IUnlockCallback, ReentrancyGuard {\n    using SafeERC20 for IERC20;\n\n');
  s = rep(s, '    mapping(address asset => uint256 amount) public feeEscrow;\n',
    '    mapping(address asset => uint256 amount) public feeEscrow;\n    // Part of feeEscrow[asset] owed to the buyback reserve (20% of desk fees, 50% of Slot-2 skims); the rest is the reward pool\'s\n    mapping(address asset => uint256 amount) public feeEscrowBuybackShare;\n');
  s = rep(s, '    event TreasuryFundsWithdrawn(address indexed to, uint256 amount);\n',
    '    event TreasuryFundsWithdrawn(address indexed to, uint256 amount);\n    event FeeEscrowReceived(address indexed asset, uint256 amount, uint256 buybackBps);\n    event SalvageEscrowReceived(address indexed asset, uint256 amount);\n    event FeesConverted(address indexed asset, uint256 amountIn, uint256 wethOut, uint256 toDistributor, uint256 toBuyback);\n    event SalvageConverted(address indexed asset, uint256 amountIn, uint256 wethOut);\n');
  s = rep(s, '    error SelloutNotReached();\n',
    '    error SelloutNotReached();\n    error EscrowAssetNotAllowed();\n    error EscrowNotFunded();\n    error NothingToConvert();\n    error ConvertOutputShort();\n    error PythFeeShort();\n    error RefundFailed();\n');
  const m = '    /// @notice Permissionless buyback after the Launch Gate lifts';
  const i = once(s, m);
  s = s.slice(0, i) + rd('wip/frag_treasury_escrow.txt') + s.slice(i);
  wr(p, s);
}

// ---------------------------------------------------------------- tests and mocks
{
  const p = 'test/mocks/Phase5Mocks.sol';
  let s = rd(p);
  s = rep(s, '    function receiveFeeEscrow(address a, uint256 amt) external override {\n        feeEscrow[a] += amt;\n    }\n',
    '    function receiveFeeEscrow(address a, uint256 amt) external override {\n        feeEscrow[a] += amt;\n    }\n\n    function receiveSkimEscrow(address a, uint256 amt) external override {\n        feeEscrow[a] += amt;\n    }\n');
  wr(p, s);
}
{
  const p = 'test/YuzuPhase4.t.sol';
  let s = rd(p);
  s = rep(s, 'import {YuzuAccount} from "../src/YuzuAccount.sol";\n',
    'import {YuzuAccount} from "../src/YuzuAccount.sol";\nimport {YuzuAccountCompanion} from "../src/YuzuAccountCompanion.sol";\n');
  s = rep(s, '    YuzuAccount vault;\n', '    YuzuAccount vault;\n    YuzuAccountCompanion companion;\n');
  s = rep(s, '        vault = new YuzuAccount(\n',
`        companion = new YuzuAccountCompanion(
            address(mainframe),
            address(lens),
            address(registry),
            address(socketBay),
            address(distributor),
            address(treasury),
            address(weth),
            address(yuzu)
        );

        vault = new YuzuAccount(
`);
  s = rep(s, '            address(0xDEF0)\n        );', '            address(0xDEF0),\n            address(companion)\n        );');
  wr(p, s);
}
console.log('patch applied');
