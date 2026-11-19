// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SeedMode,
    BoltState,
    IWETH,
    IPythMinimal,
    IYuzu98v2Minimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuSocketBayMinimal,
    IYuzuDistributorMinimal,
    IYuzuTreasuryMinimal,
    IYuzuPoolHookMinimal,
    IYuzuCustomStrategy,
    IERC721Minimal,
    IERC1155Minimal,
    IYuzuAccountCompanion,
    IYuzuCartridgePolicy
} from "./interfaces/IYuzuPhase4Interfaces.sol";

/// @title YuzuAccount — Contract 02 of 16 (YUZU-98 Master Specification v4.9, Sections 1.2, 5, 6, 7, 8, 9)
/// @notice Non-upgradeable ERC-6551 Sovereign Omni-Vault enforcing:
///         - Three-Tier Asymmetric Security (Hot Operator / Slot-3 AI Key / Cold Guardian EIP-712 Deadbolt + 48h Queue).
///         - All 8 Hardware Safety Fences (F1-F8), vault-built swaps, 20.00% exposure cap, 1.00% per-trade NAV invariant,
///           and the 3.00% (300 bps) 24-hour rolling Loss Budget.
///         - In-vault 0.25% desk fee (80% Distributor, 20% Buyback) taken only on the swap's crypto leg.
///         - `onRewardPaid` auto-compounding (>= 0.001 WETH threshold, 0% desk fee, 50 bps max slippage).
///         - Launch Gate `buyRunFeeBuffer` and buffer lock accounting (`gateBought - bufferSpentOrSeated`).
///         - Tier-2 rolling 24h Fast-Lane allowance (0-1000 bps) and Priced-only `distributor.noteOutflow()` triggers.
///         - `decommissionAndRaidSeed` (80% to Owner, 20% salvage swap to WETH or Treasury salvage escrow, RAM/credit forfeit).
///         - Zero generic `execute()`, zero `delegatecall`, and permanent ERC-1271 `0xffffffff` rejection.
///         - Split for the 24,576-byte EIP-170 limit: the swap leg (Fences F2, F3, F4, F6, F8 and the desk fee), salvage
///           routing, the run-fee split and Guardian signature recovery run in YuzuAccountCompanion (Contract 17), reached
///           by plain calls only. Fence F5, the seed reserve, the Loss Budget and every authority check stay here.
///           Limits and action codes are internal here and published by the companion.
contract YuzuAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Hardware Fence & Security Constants
    uint256 internal constant FENCE_F5_MIN_NAV_BPS = 9900;           // 99.00% per-trade NAV invariant (1.00% max loss)
    uint256 internal constant AUTO_COMPOUND_MIN_NAV_BPS = 9950;      // 99.50% auto-compound NAV invariant (0.50% max loss)
    uint256 internal constant AUTO_COMPOUND_MIN_WETH = 0.001 ether;  // 0.001 WETH threshold for onRewardPaid
    uint16 internal constant DEFAULT_LOSS_BUDGET_BPS = 300;          // 3.00% default 24h Loss Budget
    uint16 internal constant MIN_LOSS_BUDGET_BPS = 50;               // 0.50% min
    uint16 internal constant MAX_LOSS_BUDGET_BPS = 500;              // 5.00% max
    uint16 internal constant MAX_FAST_LANE_BPS = 1000;               // 10.00% max 24h Fast-Lane allowance
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    uint256 internal constant TIMELOCK_EXPIRY = 7 days;
    uint256 internal constant GUARDIAN_ROTATION_DELAY = 7 days;
    uint256 internal constant SLOT4_COOLDOWN = 24 hours;

    // EIP-712 Action Types
    uint8 internal constant ACTION_WITHDRAW_ERC20 = 1;
    uint8 internal constant ACTION_RESCUE_ASSET = 2;
    uint8 internal constant ACTION_EJECT_NFT = 3;
    uint8 internal constant ACTION_SEED_RAID = 4;
    uint8 internal constant ACTION_BOLT_FOR_SALE = 5;
    uint8 internal constant ACTION_RAISE_LIMITS = 6;
    uint8 internal constant ACTION_SET_RECOVERY = 7;
    uint8 internal constant ACTION_ROTATE_GUARDIAN = 8;
    uint8 internal constant ACTION_POST_ROM_BOND = 9;
    uint8 internal constant ACTION_RECOVERY_TRANSFER = 10;
    uint8 internal constant ACTION_LOOSEN_DESK_POLICY = 11;

    // Immutable Protocol Wiring
    IYuzu98v2Minimal internal immutable mainframe;
    IYuzuNavLensMinimal internal immutable lens;
    IYuzuRegistryMinimal internal immutable registry;
    IYuzuSocketBayMinimal internal immutable socketBay;
    IYuzuDistributorMinimal internal immutable distributor;
    IYuzuTreasuryMinimal internal immutable treasury;
    IYuzuPoolHookMinimal internal immutable hook;
    IPythMinimal internal immutable pyth;
    IWETH internal immutable weth;
    IERC20 internal immutable yuzuToken;
    address internal immutable seeder;
    address public immutable cartridge;
    address internal immutable defaultSlot4Adapter;
    IYuzuAccountCompanion public immutable companion; // Contract 17: shared stateless helper, called, never delegatecalled

    // Unit Identity & Seed Reserve
    uint256 public tokenId;
    bool internal initialized;
    SeedMode public seedMode;
    address[] internal seedAssetList;
    mapping(address asset => uint256 amount) public seedUnits;

    // Authority & Guardian State
    address public coldGuardian;
    address public recoveryAddress;
    uint256 public guardianNonce;
    uint256 public guardianEpoch;
    uint256 public queueEpoch;
    bool public guardianFrozen;

    // 7-Day Lost-Guardian Rotation Queue
    address public pendingGuardian;
    uint256 public guardianRotationReadyAt;
    uint256 internal guardianRotationEpoch;

    // 48-Hour Tier-3 Timelock Queue: queueEpoch => opHash => readyAt
    mapping(uint256 qEpoch => mapping(bytes32 opHash => uint256 readyAt)) public timelockQueue;

    // Rolling 24-Hour Loss Budget (Fence F5) & Fast-Lane Meter (Tier 2)
    uint16 public lossBudgetBps = DEFAULT_LOSS_BUDGET_BPS;
    uint256 public lossUsedBps;
    uint256 public lossStamp;

    uint16 public dailyFastLaneBps; // Starts at 0, resets to 0 on transfer
    uint256 public fastLaneUsedBps;
    uint256 public fastLaneStamp;

    // Slot 3 (AI Session Key), Slot 4 (Strategy ROM), Auto-Compound & Buffer Lock
    address public aiSessionKey;
    uint256 public aiSessionExpiry;

    address public slot4Adapter;
    bytes internal slot4Params;
    uint256 internal lastSlot4RunAt;
    uint256 public slot4DailyFeeCap;
    uint256 public slot4FeeUsedToday;
    uint256 public slot4FeeDayStamp;

    address public rewardPayoutAsset;
    uint256 public bufferSpentOrSeated; // Tracks run fees & seated RAM drawn from Launch Gate buffer

    event VaultInitialized(uint256 indexed tokenId, address guardian, address recovery);
    event SeedRecorded(address indexed asset, uint256 amount, SeedMode mode);
    event Tier1SwapExecuted(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Tier2FastLaneWithdrawn(address indexed asset, address indexed to, uint256 amount, uint256 fastLaneUsedBps);
    event Tier3ActionQueued(bytes32 indexed opHash, uint8 actionType, uint256 readyAt, uint256 queueEpoch);
    event Tier3ActionCancelled(bytes32 indexed opHash, address indexed by);
    event Tier3ActionExecuted(uint8 indexed actionType, address indexed target, address asset, uint256 amount);
    event GuardianPanicFrozen(uint256 indexed tokenId, uint256 newQueueEpoch);
    event GuardianUnfrozen(uint256 indexed tokenId);
    event SeedRaided(uint256 indexed tokenId, address indexed owner);
    event RewardAutoCompounded(address indexed assetOut, uint256 wethIn, uint256 amountOut);

    error ZeroAddress();
    error AlreadyInitialized();
    error OnlySeeder();
    error OnlyMainframe();
    error OnlyDistributor();
    error OnlyOwner();
    error OnlyOwnerOrAi();
    error OnlyGuardian();
    error VaultNotLive();
    error VaultIsFrozen();
    error FenceF3ExposureCapExceeded();
    error FenceF5NavSlippageExceeded();
    error FenceF5LossBudgetExhausted();
    error FenceF8InputExceeded();
    error FenceF8OutputInsufficient();
    error SeedReserveBreached(address asset, uint256 balanceAfter, uint256 requiredSeed);
    error UnpricedOrSeedAssetInFastLane();
    error FastLaneAllowanceExceeded();
    error LaunchGateAlreadyLifted();
    error LaunchGateBufferLocked(uint256 lockedAmount, uint256 balanceAfter);
    error InvalidGuardianSignature();
    error SignatureExpired();
    error OpAlreadyQueued();
    error OpNotQueued();
    error OpNotReady();
    error OpExpired();
    error InvalidLimits();
    error InvalidRecoveryAddress();
    error NoGuardianBound();
    error GuardianAlreadyBound();
    error Slot4CooldownActive();
    error Slot4CartridgeNotExecutable();
    error Slot4DailyFeeCapExceeded();
    error CannotVaultYuzuMainframe();
    error OnlyCartridge();
    error EthRescueFailed();

    function _onlyOwner() internal view {
        if (msg.sender != mainframe.ownerOf(tokenId)) revert OnlyOwner();
    }

    function _onlyOwnerOrAi() internal view {
        address owner = mainframe.ownerOf(tokenId);
        bool isValidAi = (msg.sender == aiSessionKey && aiSessionKey != address(0) && block.timestamp <= aiSessionExpiry);
        if (msg.sender != owner && !isValidAi) revert OnlyOwnerOrAi();
    }

    function _onlyGuardian() internal view {
        if (coldGuardian == address(0) || msg.sender != coldGuardian) revert OnlyGuardian();
    }

    function _whenLive() internal view {
        if (guardianFrozen) revert VaultIsFrozen();
        if (mainframe.isGutted(tokenId)) revert VaultNotLive();
        if (mainframe.boltState(tokenId) != BoltState.UNBOLTED) revert VaultNotLive();
    }

    constructor(
        address mainframe_,
        address lens_,
        address registry_,
        address socketBay_,
        address distributor_,
        address treasury_,
        address hook_,
        address pyth_,
        address weth_,
        address yuzuToken_,
        address seeder_,
        address cartridge_,
        address defaultSlot4Adapter_,
        address companion_
    ) {
        mainframe = IYuzu98v2Minimal(mainframe_);
        lens = IYuzuNavLensMinimal(lens_);
        registry = IYuzuRegistryMinimal(registry_);
        socketBay = IYuzuSocketBayMinimal(socketBay_);
        distributor = IYuzuDistributorMinimal(distributor_);
        treasury = IYuzuTreasuryMinimal(treasury_);
        hook = IYuzuPoolHookMinimal(hook_);
        pyth = IPythMinimal(pyth_);
        weth = IWETH(weth_);
        yuzuToken = IERC20(yuzuToken_);
        seeder = seeder_;
        cartridge = cartridge_;
        defaultSlot4Adapter = defaultSlot4Adapter_;
        companion = IYuzuAccountCompanion(companion_);
        rewardPayoutAsset = weth_;
        slot4Adapter = defaultSlot4Adapter_;
    }

    // =========================================================================
    // 1. INITIALIZATION & SEED RESERVE RECORDING (Seeder Only)
    // =========================================================================

    function initializeFromSeeder(uint256 tokenId_, address initialGuardian, address recoveryAddr) external {
        if (msg.sender != seeder) revert OnlySeeder();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        tokenId = tokenId_;

        if (initialGuardian != address(0)) {
            coldGuardian = initialGuardian;
        }
        if (recoveryAddr != address(0) && recoveryAddr != initialGuardian) {
            recoveryAddress = recoveryAddr;
        }
        lossBudgetBps = DEFAULT_LOSS_BUDGET_BPS;
        rewardPayoutAsset = address(weth);
        slot4Adapter = defaultSlot4Adapter;

        emit VaultInitialized(tokenId_, initialGuardian, recoveryAddr);
    }

    function recordSeed(address asset, uint256 amount, SeedMode mode) external {
        if (msg.sender != seeder) revert OnlySeeder();
        if (seedUnits[asset] == 0) {
            seedAssetList.push(asset);
        }
        seedUnits[asset] += amount;
        seedMode = mode;
        emit SeedRecorded(asset, amount, mode);
    }

    function clearSeedStorageForRecommission() external {
        if (msg.sender != seeder) revert OnlySeeder();
        for (uint256 i = 0; i < seedAssetList.length; i++) {
            delete seedUnits[seedAssetList[i]];
        }
        delete seedAssetList;
    }

    function _requireSeedReserve() internal view {
        if (mainframe.isGutted(tokenId)) return;
        for (uint256 i = 0; i < seedAssetList.length; i++) {
            address a = seedAssetList[i];
            uint256 req = seedUnits[a];
            if (req > 0) {
                uint256 bal = IERC20(a).balanceOf(address(this));
                if (bal < req) revert SeedReserveBreached(a, bal, req);
            }
        }
    }

    // =========================================================================
    // 2. TIER-1 SWAPS, FENCES F2-F8, 0.25% DESK FEE & LOSS BUDGET
    // =========================================================================

    function executeTier1Swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _onlyOwnerOrAi();
        _whenLive();
        _updatePyth(pythUpdateData);
        uint256 out = _swap(tokenIn, tokenOut, amountIn, FENCE_F5_MIN_NAV_BPS, true);
        emit Tier1SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, out);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOutBps, bool chargeDeskFee)
        internal
        returns (uint256 receivedOut)
    {
        uint256 navBefore = lens.getLiquidNavUsd(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        // The companion runs Fences F2, F3, F4, F6 and F8 and the desk fee on exactly `amountIn` and pays the output
        // back here. It gets a transfer, never an approval, so it cannot spend more than `amountIn`.
        IERC20(tokenIn).safeTransfer(address(companion), amountIn);
        companion.swapFor(tokenIn, tokenOut, amountIn, minOutBps, chargeDeskFee, navBefore);
        receivedOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;

        _requireSeedReserve();

        uint256 navAfter = lens.getLiquidNavUsd(address(this));
        if (navAfter * 10000 < navBefore * minOutBps) revert FenceF5NavSlippageExceeded();
        _chargeLossBudget(navBefore, navAfter);                                       // Fence F5
    }

    function _chargeLossBudget(uint256 navBefore, uint256 navAfter) internal {
        uint256 elapsed = block.timestamp - lossStamp;
        uint256 drained = (uint256(lossBudgetBps) * elapsed) / 1 days;
        uint256 used = lossUsedBps > drained ? lossUsedBps - drained : 0;

        if (navAfter < navBefore && navBefore > 0) {
            used += ((navBefore - navAfter) * 10000 + navBefore - 1) / navBefore; // round up
        }
        if (used > lossBudgetBps) revert FenceF5LossBudgetExhausted();

        lossUsedBps = used;
        lossStamp = block.timestamp;
    }

    // =========================================================================
    // 3. REWARD AUTO-COMPOUND (`onRewardPaid`, Section 2.4)
    // =========================================================================

    function setRewardPayoutAsset(address asset) external {
        _onlyOwner();
        if (asset != address(weth)) {
            if (!registry.isPricedAsset(asset) || !registry.hasActiveRoute(address(weth), asset)) {
                revert UnpricedOrSeedAssetInFastLane();
            }
        }
        rewardPayoutAsset = asset;
    }

    /// @notice Called by `YuzuDistributor` inside a non-reverting try/catch after paying epoch WETH.
    ///         Enforces v4.9 griefing protections: >= 0.001 WETH threshold, 0% desk fee, and 50 bps max slippage.
    function onRewardPaid(uint256 wethAmount) external {
        if (msg.sender != address(distributor)) revert OnlyDistributor();
        if (wethAmount < AUTO_COMPOUND_MIN_WETH) return;
        address targetAsset = rewardPayoutAsset;
        if (targetAsset == address(0) || targetAsset == address(weth)) return;
        if (guardianFrozen || mainframe.isGutted(tokenId) || mainframe.boltState(tokenId) != BoltState.UNBOLTED) {
            return;
        }

        uint256 out = _swap(address(weth), targetAsset, wethAmount, AUTO_COMPOUND_MIN_NAV_BPS, false);
        emit RewardAutoCompounded(targetAsset, wethAmount, out);
    }

    // =========================================================================
    // 4. SLOT 1 (RAM SEATING), SLOT 3 (AI KEY) & SLOT 4 (STRATEGY ROM & BUFFER)
    // =========================================================================

    function seatRamBlades(uint8 blades) external nonReentrant {
        _onlyOwner();
        _whenLive();
        uint256 yuzuNeeded = uint256(blades) * 25_000e18;
        bufferSpentOrSeated += yuzuNeeded;
        yuzuToken.forceApprove(address(socketBay), yuzuNeeded);
        socketBay.seatBladesFromVault(tokenId, blades);
        yuzuToken.forceApprove(address(socketBay), 0);
    }

    /// @notice Buys up to 50,000 $YUZU lifetime run-fee buffer from the pool during the Launch Gate.
    ///         Because $YUZU is Unpriced (valued at 0), Fence F5 treats the entire WETH spent as a loss.
    function buyRunFeeBuffer(
        uint256 maxWethIn,
        uint256 yuzuAmount,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (uint256 wethSpent) {
        _onlyOwner();
        _whenLive();
        if (hook.gateLifted()) revert LaunchGateAlreadyLifted();
        _updatePyth(pythUpdateData);

        lens.requireFresh(address(weth));
        uint256 navBefore = lens.getLiquidNavUsd(address(this));

        weth.approve(address(socketBay), maxWethIn);
        wethSpent = socketBay.buyBufferFor(tokenId, yuzuAmount, maxWethIn);
        weth.approve(address(socketBay), 0);

        _requireSeedReserve();
        uint256 navAfter = lens.getLiquidNavUsd(address(this));
        if (navAfter * 10000 < navBefore * FENCE_F5_MIN_NAV_BPS) revert FenceF5NavSlippageExceeded();
        _chargeLossBudget(navBefore, navAfter);
    }

    function setAiSessionKey(address key, uint256 expiry) external {
        _onlyOwner();
        aiSessionKey = key;
        aiSessionExpiry = expiry;
    }

    function revokeAiSessionKey() external {
        if (msg.sender != mainframe.ownerOf(tokenId) && msg.sender != coldGuardian) revert OnlyOwner();
        aiSessionKey = address(0);
        aiSessionExpiry = 0;
    }

    function seatSlot4Adapter(address adapter, bytes calldata params) external {
        _onlyOwner();
        _whenLive();
        if (adapter != defaultSlot4Adapter) {
            (bool ok,,) = registry.isCartridgeExecutable(adapter);
            if (!ok) revert Slot4CartridgeNotExecutable();
        }
        slot4Adapter = adapter;
        slot4Params = params;
    }

    function executeSlot4Strategy(bytes[] calldata pythUpdateData)
        external
        payable
        nonReentrant
    {
        _onlyOwnerOrAi();
        _whenLive();
        if (lastSlot4RunAt != 0 && block.timestamp < lastSlot4RunAt + SLOT4_COOLDOWN) {
            revert Slot4CooldownActive();
        }
        _updatePyth(pythUpdateData);

        address adapter = slot4Adapter;
        uint256 authorTokenId = 0;
        uint256 runFee = 0;

        if (adapter != defaultSlot4Adapter) {
            bool ok;
            (ok, authorTokenId, runFee) = registry.isCartridgeExecutable(adapter);
            if (!ok) revert Slot4CartridgeNotExecutable();
        }

        (bool shouldExecute, address tokenIn, address tokenOut, uint256 amountIn) =
            IYuzuCustomStrategy(adapter).evaluate(address(this), slot4Params);
        if (!shouldExecute) return;

        lastSlot4RunAt = block.timestamp;
        _swap(tokenIn, tokenOut, amountIn, FENCE_F5_MIN_NAV_BPS, true);

        if (runFee > 0) {
            _settleSlot4RunFee(authorTokenId, runFee);
        }
    }

    function _settleSlot4RunFee(uint256 authorTokenId, uint256 runFee) internal {
        uint256 today = block.timestamp / 1 days;
        if (slot4FeeDayStamp != today) {
            slot4FeeDayStamp = today;
            slot4FeeUsedToday = 0;
        }
        if (slot4FeeUsedToday + runFee > slot4DailyFeeCap) revert Slot4DailyFeeCapExceeded();
        slot4FeeUsedToday += runFee;
        bufferSpentOrSeated += runFee;

        // 80% to the author unit's vault if its ROM bond is active, otherwise 100% to YuzuDistributor (in the companion).
        yuzuToken.safeTransfer(address(companion), runFee);
        companion.routeRunFee(authorTokenId, runFee);
    }

    // =========================================================================
    // 5. TIER-2 DAILY FAST-LANE WITHDRAWALS (Section 7)
    // =========================================================================

    function withdrawFastLane(
        address asset,
        uint256 amount,
        address to,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _onlyOwner();
        _whenLive();
        if (to == address(0)) revert ZeroAddress();
        if (!registry.isPricedAsset(asset)) revert UnpricedOrSeedAssetInFastLane();

        _updatePyth(pythUpdateData);
        lens.requireFresh(asset); // Needs a live price for the asset withdrawn

        uint256 navBefore = lens.getLiquidNavUsd(address(this));
        uint256 withdrawUsd = lens.valueOf(asset, amount);

        uint256 elapsed = block.timestamp - fastLaneStamp;
        uint256 drained = (uint256(dailyFastLaneBps) * elapsed) / 1 days;
        uint256 used = fastLaneUsedBps > drained ? fastLaneUsedBps - drained : 0;

        uint256 addedBps = navBefore > 0 ? ((withdrawUsd * 10000 + navBefore - 1) / navBefore) : 10001;
        if (used + addedBps > dailyFastLaneBps) revert FastLaneAllowanceExceeded();

        fastLaneUsedBps = used + addedBps;
        fastLaneStamp = block.timestamp;

        IERC20(asset).safeTransfer(to, amount);
        _requireSeedReserve();

        uint256 navAfter = lens.getLiquidNavUsd(address(this));
        distributor.noteOutflow(tokenId, navAfter);

        emit Tier2FastLaneWithdrawn(asset, to, amount, fastLaneUsedBps);
    }

    // =========================================================================
    // 6. TIER-3 DEADBOLT (EIP-712 CO-SIGN OR 48H TIMELOCK QUEUE, Section 7)
    // =========================================================================

    function lowerLimits(
        uint16 newFastLaneBps,
        uint16 newLossBudgetBps,
        uint256 newSlot4DailyFeeCap
    ) external {
        _onlyOwner();
        if (
            newFastLaneBps > dailyFastLaneBps || newLossBudgetBps > lossBudgetBps
                || newLossBudgetBps < MIN_LOSS_BUDGET_BPS || newSlot4DailyFeeCap > slot4DailyFeeCap
        ) revert InvalidLimits();

        dailyFastLaneBps = newFastLaneBps;
        lossBudgetBps = newLossBudgetBps;
        slot4DailyFeeCap = newSlot4DailyFeeCap;
    }

    function computeTier3OpHash(
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData
    ) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), queueEpoch, actionType, target, asset, amount, extraData));
    }

    function queueTier3Action(
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData
    ) external returns (bytes32 opHash, uint256 readyAt) {
        _onlyOwner();
        if (guardianFrozen) revert VaultIsFrozen();
        opHash = computeTier3OpHash(actionType, target, asset, amount, extraData);
        if (timelockQueue[queueEpoch][opHash] != 0) revert OpAlreadyQueued();

        readyAt = block.timestamp + TIMELOCK_DELAY;
        timelockQueue[queueEpoch][opHash] = readyAt;
        emit Tier3ActionQueued(opHash, actionType, readyAt, queueEpoch);
    }

    function cancelQueuedAction(bytes32 opHash) external {
        if (msg.sender != mainframe.ownerOf(tokenId) && msg.sender != coldGuardian) revert OnlyOwner();
        if (timelockQueue[queueEpoch][opHash] == 0) revert OpNotQueued();
        delete timelockQueue[queueEpoch][opHash];
        emit Tier3ActionCancelled(opHash, msg.sender);
    }

    function executeTier3Action(
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData,
        uint256 deadline,
        bytes calldata guardianSig
    ) external nonReentrant {
        _onlyOwner();
        // Fence F7: a BOLTED or UNBOLTING vault accepts deposits and reward claims and nothing else.
        if (mainframe.boltState(tokenId) != BoltState.UNBOLTED) revert VaultNotLive();
        _authorizeTier3(actionType, target, asset, amount, extraData, deadline, guardianSig);

        if (actionType == ACTION_WITHDRAW_ERC20) {
            _executeTier3WithdrawErc20(asset, amount, target);
        } else if (actionType == ACTION_RESCUE_ASSET) {
            uint8 standard = uint8(uint256(extraData));
            _executeRescueAsset(standard, asset, amount, target);
        } else if (actionType == ACTION_EJECT_NFT) {
            IERC721Minimal(asset).safeTransferFrom(address(this), target, amount);
        } else if (actionType == ACTION_BOLT_FOR_SALE) {
            aiSessionKey = address(0);
            mainframe.boltForSaleFromVault(tokenId);
        } else if (actionType == ACTION_RAISE_LIMITS) {
            (uint16 newFastLane, uint16 newLossBudget, uint256 newSlot4Cap) =
                abi.decode(abi.encode(target, asset, amount), (uint16, uint16, uint256));
            if (newFastLane > MAX_FAST_LANE_BPS || newLossBudget < MIN_LOSS_BUDGET_BPS || newLossBudget > MAX_LOSS_BUDGET_BPS) {
                revert InvalidLimits();
            }
            dailyFastLaneBps = newFastLane;
            lossBudgetBps = newLossBudget;
            slot4DailyFeeCap = newSlot4Cap;
        } else if (actionType == ACTION_SET_RECOVERY) {
            if (target == address(0) || target == coldGuardian) revert InvalidRecoveryAddress();
            recoveryAddress = target;
        } else if (actionType == ACTION_ROTATE_GUARDIAN) {
            coldGuardian = target;
            guardianEpoch += 1;
        } else if (actionType == ACTION_POST_ROM_BOND) {
            if (guardianFrozen || mainframe.isGutted(tokenId)) revert VaultNotLive();
            bufferSpentOrSeated += 250_000e18;
            yuzuToken.forceApprove(address(socketBay), 250_000e18);
            socketBay.postBondFromVault(tokenId);
            yuzuToken.forceApprove(address(socketBay), 0);
        } else {
            revert InvalidLimits();
        }

        emit Tier3ActionExecuted(actionType, target, asset, amount);
    }

    function _executeTier3WithdrawErc20(address asset, uint256 amount, address to) internal {
        if (to == address(0)) revert ZeroAddress();
        if (asset == address(yuzuToken) && !hook.gateLifted()) {
            uint256 bought = socketBay.gateBought(address(this));
            uint256 lockedBuffer = bought > bufferSpentOrSeated ? bought - bufferSpentOrSeated : 0;
            uint256 balAfter = yuzuToken.balanceOf(address(this)) - amount;
            if (balAfter < lockedBuffer) revert LaunchGateBufferLocked(lockedBuffer, balAfter);
        }

        IERC20(asset).safeTransfer(to, amount);
        _requireSeedReserve();

        // Priced-only noteOutflow ratchet (v4.9 rule)
        if (registry.isPricedAsset(asset)) {
            distributor.noteOutflow(tokenId, lens.getLiquidNavUsd(address(this)));
        }
    }

    function _executeRescueAsset(uint8 standard, address token, uint256 idOrAmount, address to) internal {
        if (to == address(0)) revert ZeroAddress();
        if (standard == 0) {
            // Native ETH
            (bool ok,) = to.call{value: idOrAmount}("");
            if (!ok) revert EthRescueFailed();
        } else if (standard == 1) {
            // ERC-20
            _executeTier3WithdrawErc20(token, idOrAmount, to);
        } else if (standard == 2) {
            // ERC-721
            IERC721Minimal(token).safeTransferFrom(address(this), to, idOrAmount);
        } else if (standard == 3) {
            // ERC-1155
            IERC1155Minimal(token).safeTransferFrom(address(this), to, idOrAmount, 1, "");
        }
    }

    // =========================================================================
    // 6b. SLOT 2 WIRING (collateral pull for YuzuCartridge and Tier-3 desk-policy loosening, Section 6.2)
    // =========================================================================

    /// @notice Hands a priced asset to YuzuCartridge for a covered call or a cash-leg move. Only the cartridge can
    ///         call it, and only to itself. The cartridge checks the caller, the desk policy and the venue; the vault
    ///         re-checks the freeze, the Listing Bolt (Fence F7) and the seed reserve against its own balance.
    function pullSlot2Asset(address asset, uint256 amount, address to) external nonReentrant {
        if (msg.sender != cartridge || to != cartridge) revert OnlyCartridge();
        if (guardianFrozen || mainframe.boltState(tokenId) != BoltState.UNBOLTED) revert VaultNotLive();
        if (!registry.isPricedAsset(asset)) revert UnpricedOrSeedAssetInFastLane();
        IERC20(asset).safeTransfer(to, amount);
        _requireSeedReserve();
    }

    /// @notice Tier-3 action 11: sets or loosens the unit's Slot-2 desk policy in YuzuCartridge. Authorized by a
    ///         Guardian co-signature or the 48h queue over (ACTION_LOOSEN_DESK_POLICY, cartridge, address(0), 0,
    ///         keccak256(abi.encode(allowedAssets, minStrikeBps, minPremiumBps, maxExpirySeconds, maxExposureShareBps))).
    function loosenDeskPolicy(
        address[] calldata allowedAssets,
        uint16 minStrikeBps,
        uint16 minPremiumBps,
        uint32 maxExpirySeconds,
        uint16 maxExposureShareBps,
        uint256 deadline,
        bytes calldata guardianSig
    ) external nonReentrant {
        _onlyOwner();
        if (mainframe.isGutted(tokenId) || mainframe.boltState(tokenId) != BoltState.UNBOLTED) revert VaultNotLive();
        _authorizeTier3(
            ACTION_LOOSEN_DESK_POLICY,
            cartridge,
            address(0),
            0,
            keccak256(abi.encode(allowedAssets, minStrikeBps, minPremiumBps, maxExpirySeconds, maxExposureShareBps)),
            deadline,
            guardianSig
        );
        IYuzuCartridgePolicy(cartridge).setPolicyFromVaultTier3(
            tokenId, allowedAssets, minStrikeBps, minPremiumBps, maxExpirySeconds, maxExposureShareBps
        );
        emit Tier3ActionExecuted(ACTION_LOOSEN_DESK_POLICY, cartridge, address(0), 0);
    }

    // =========================================================================
    // 7. SEED RAID (`decommissionAndRaidSeed`, Section 9.1)
    // =========================================================================

    function decommissionAndRaidSeed(
        uint256 deadline,
        bytes calldata guardianSig,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _onlyOwner();
        if (mainframe.boltState(tokenId) != BoltState.UNBOLTED || mainframe.isGutted(tokenId)) {
            revert VaultNotLive();
        }
        _authorizeTier3(ACTION_SEED_RAID, msg.sender, address(0), tokenId, bytes32(0), deadline, guardianSig);
        _updatePyth(pythUpdateData);

        address owner = msg.sender;

        // 1. Split each seed asset 80% to Owner, 20% salvage to YuzuDistributor (or salvage escrow if feed stale)
        for (uint256 i = 0; i < seedAssetList.length; i++) {
            address asset = seedAssetList[i];
            uint256 totalSeed = seedUnits[asset];
            if (totalSeed == 0) continue;
            seedUnits[asset] = 0;

            uint256 ownerShare = (totalSeed * 8000) / 10000;
            uint256 salvageShare = totalSeed - ownerShare;

            if (ownerShare > 0) {
                IERC20(asset).safeTransfer(owner, ownerShare);
            }
            if (salvageShare > 0) {
                IERC20(asset).safeTransfer(address(companion), salvageShare);
                companion.routeSalvage(asset, salvageShare);
            }
        }

        // 2. Forfeit all starter RAM, seated blades, and ROM bonds to YuzuDistributor
        socketBay.forfeit(tokenId);

        // 3. Cancel all locked farm credit in YuzuDistributor
        distributor.cancelLockedCreditOnRaid(tokenId);

        // 4. Mark unit gutted (`空`) and record 0 Qualifying NAV outflow
        mainframe.setGuttedFromVault(tokenId);
        distributor.noteOutflow(tokenId, 0);

        emit SeedRaided(tokenId, owner);
    }

    // =========================================================================
    // 8. GUARDIAN PANIC FREEZE, ROTATION & RECOVERY VERIFICATION (Section 7.4)
    // =========================================================================

    function guardianPanicFreeze() external {
        _onlyGuardian();
        guardianFrozen = true;
        aiSessionKey = address(0);
        aiSessionExpiry = 0;
        queueEpoch += 1;
        mainframe.guardianForceUnbolt(tokenId);
        emit GuardianPanicFrozen(tokenId, queueEpoch);
    }

    function guardianForceUnbolt() external {
        _onlyGuardian();
        mainframe.guardianForceUnbolt(tokenId);
    }

    function guardianUnfreeze() external {
        _onlyGuardian();
        guardianFrozen = false;
        emit GuardianUnfrozen(tokenId);
    }

    function guardianResetLossBudget() external {
        _onlyGuardian();
        lossUsedBps = 0;
        lossStamp = block.timestamp;
    }

    /// @notice Binds an initial Guardian when none is bound (48h delay), or queues a 7-day lost-key Guardian rotation.
    function queueGuardianChange(address newGuardian) external {
        _onlyOwner();
        pendingGuardian = newGuardian;
        guardianRotationEpoch = guardianEpoch;
        uint256 delay = coldGuardian == address(0) ? TIMELOCK_DELAY : GUARDIAN_ROTATION_DELAY;
        guardianRotationReadyAt = block.timestamp + delay;
    }

    function vetoGuardianRotation() external {
        _onlyGuardian();
        pendingGuardian = address(0);
        guardianRotationReadyAt = 0;
    }

    function executeQueuedGuardianChange() external {
        _onlyOwner();
        if (guardianRotationReadyAt == 0 || guardianRotationEpoch != guardianEpoch) revert OpNotQueued();
        if (block.timestamp < guardianRotationReadyAt) revert OpNotReady();

        coldGuardian = pendingGuardian;
        pendingGuardian = address(0);
        guardianRotationReadyAt = 0;
        guardianEpoch += 1;
    }

    /// @notice Called by `Yuzu98v2.guardianRecoveryTransfer` to verify the Cold Guardian's EIP-712 recovery signature.
    function verifyGuardianRecoverySig(
        address expectedTarget,
        uint256 tokenId_,
        uint256 deadline,
        bytes calldata sig
    ) external returns (bool) {
        if (msg.sender != address(mainframe)) revert OnlyMainframe();
        if (coldGuardian == address(0) || recoveryAddress == address(0)) return false;
        if (expectedTarget != recoveryAddress || tokenId_ != tokenId) return false;
        if (block.timestamp > deadline) return false;

        address signer = companion.recoverGuardianSigner(
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
        if (signer != coldGuardian) return false;

        guardianNonce += 1;
        return true;
    }

    /// @notice Called by `Yuzu98v2._update` on every sale or recovery transfer to reset all authority state.
    function onNftTransferReset() external {
        if (msg.sender != address(mainframe)) revert OnlyMainframe();

        coldGuardian = address(0);
        recoveryAddress = address(0);
        pendingGuardian = address(0);
        guardianRotationReadyAt = 0;
        aiSessionKey = address(0);
        aiSessionExpiry = 0;

        queueEpoch += 1;
        guardianEpoch += 1;
        guardianFrozen = false;

        dailyFastLaneBps = 0;
        fastLaneUsedBps = 0;
        slot4DailyFeeCap = 0;
        lossBudgetBps = DEFAULT_LOSS_BUDGET_BPS;
        lossUsedBps = 0;
        slot4Adapter = defaultSlot4Adapter;
        delete slot4Params;
        rewardPayoutAsset = address(weth);
    }

    // =========================================================================
    // 9. TELEMETRY, ERC-1271 BLOCK & EIP-712 VERIFICATION HELPERS
    // =========================================================================

    /// @notice ERC-1271 signature verification is permanently disabled (`0xffffffff`) so the vault can never sign permits/orders.
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0xffffffff;
    }

    /// @notice Rejects any YUZU-98 mainframe NFT transfer at the receiver hook as a second check (Section 5.1).
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender == address(mainframe)) revert CannotVaultYuzuMainframe();
        return this.onERC721Received.selector;
    }

    function _authorizeTier3(
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData,
        uint256 deadline,
        bytes calldata guardianSig
    ) internal {
        if (guardianSig.length > 0) {
            if (coldGuardian == address(0)) revert NoGuardianBound();
            if (block.timestamp > deadline) revert SignatureExpired();
            address signer = companion.recoverGuardianSigner(
                address(this), actionType, target, asset, amount, extraData, guardianNonce, guardianEpoch, deadline, guardianSig
            );
            if (signer != coldGuardian) revert InvalidGuardianSignature();
            guardianNonce += 1;
        } else {
            if (guardianFrozen) revert VaultIsFrozen();
            bytes32 opHash = computeTier3OpHash(actionType, target, asset, amount, extraData);
            uint256 readyAt = timelockQueue[queueEpoch][opHash];
            if (readyAt == 0) revert OpNotQueued();
            if (block.timestamp < readyAt) revert OpNotReady();
            if (block.timestamp > readyAt + TIMELOCK_EXPIRY) revert OpExpired();
            delete timelockQueue[queueEpoch][opHash];
        }
    }

    function _updatePyth(bytes[] calldata pythUpdateData) internal {
        if (pythUpdateData.length > 0) {
            uint256 fee = pyth.getUpdateFee(pythUpdateData);
            pyth.updatePriceFeeds{value: fee}(pythUpdateData);
        }
    }

    receive() external payable {}
}
