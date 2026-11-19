// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PoolKey, ModifyLiquidityParams, SwapParams, IPoolManager, IHooks, IYuzuUnits, V4StateLib} from "./interfaces/IYuzuV4Interfaces.sol";
import {TickMath} from "./libraries/v4/TickMath.sol";

/// @title YuzuPoolHook — Contract 16 of 16 (YUZU-98 Master Specification v4.9, Section 2.2)
/// @notice Non-upgradeable Uniswap v4 hook on the $YUZU / WETH 1.00% pool.
///         1. Initialization: Only YuzuTreasury can initialize the pool, and only at the opening sqrtPriceX96.
///            Initializes referenceTick and lastSyncTickCumulative.
///         2. Liquidity: Only YuzuTreasury can add liquidity (sender == treasury in beforeAddLiquidity).
///         3. Buying (Launch Gate): While !gateLifted, only YuzuSocketBay (sender == socketBay in beforeSwap)
///            can buy $YUZU out of the pool. Selling $YUZU into the pool is open to all addresses from deployment.
///         4. Logarithmic Tick Accumulator & Reference Price: Updates tickCumulative in beforeSwap using the
///            pre-swap tick (immune to same-block flash manipulation). Maintains referenceTick with a >= 1 hour
///            sync interval and a <= 488 ticks/day (~5%/day) movement clamp.
contract YuzuPoolHook is IHooks {
    uint256 public constant FLEET_SIZE = 1_000;
    uint256 public constant GATE_DURATION = 90 days;
    uint256 public constant MIN_SYNC_INTERVAL = 1 hours;
    int24 public constant MAX_DRIFT_TICKS_PER_DAY = 488; // 1.0001^488 ~= 1.050008 (~5.00%)
    int24 public constant GUARD_BAND_TICKS = 488;        // ±488 ticks (~5.00% spot band)

    // Hook permission bit flags (Uniswap v4 standard convention)
    uint160 public constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 public constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 public constant BEFORE_SWAP_FLAG = 1 << 7;

    IPoolManager public immutable poolManager;
    address public immutable yuzuToken;
    address public immutable weth;
    address public immutable treasury;
    address public immutable socketBay;
    IYuzuUnits public immutable units;
    uint160 public immutable openingSqrtPriceX96;
    bool public immutable yuzuIsCurrency0;

    bytes32 public poolId;
    bool public poolInitialized;
    bool public gateLifted;

    // Logarithmic tick accumulator state
    int56 public tickCumulative;
    uint32 public lastTimestamp;
    int24 public lastRecordedTick;

    // Reference tick state for post-gate liquidity adds & buybacks
    int24 public referenceTick;
    int56 public lastSyncTickCumulative;
    uint32 public lastSyncTimestamp;

    // 24h ring buffer (hourly checkpoints) used to initialize referenceTick to the 24h TWAP when the gate lifts
    struct Checkpoint {
        uint32 timestamp;
        int56 tickCumulative;
    }
    Checkpoint[25] public hourlyHistory;
    uint8 public historyIndex;
    uint8 public historyCount;

    event PoolInitialized(bytes32 indexed poolId, uint160 sqrtPriceX96, int24 openingTick);
    event GateLifted(uint256 timestamp, uint256 commissioned, int24 initialReferenceTick);
    event ReferenceSynced(int24 oldReferenceTick, int24 newReferenceTick, uint256 timestamp);

    error ZeroAddress();
    error OnlyPoolManager();
    error OnlyTreasuryCanInitialize();
    error InvalidPoolCurrencies();
    error InvalidOpeningPrice();
    error PoolAlreadyInitialized();
    error OnlyTreasuryCanAddLiquidity();
    error LaunchGateBuyRestricted(address sender);
    error GateAlreadyLifted();
    error GateConditionsNotMet();
    error SyncTooSoon();
    error GateStillActive();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    constructor(
        address poolManager_,
        address yuzuToken_,
        address weth_,
        address treasury_,
        address socketBay_,
        address units_,
        uint160 openingSqrtPriceX96_
    ) {
        if (
            poolManager_ == address(0) || yuzuToken_ == address(0) || weth_ == address(0)
                || treasury_ == address(0) || socketBay_ == address(0) || units_ == address(0)
        ) revert ZeroAddress();
        if (openingSqrtPriceX96_ == 0) revert InvalidOpeningPrice();

        poolManager = IPoolManager(poolManager_);
        yuzuToken = yuzuToken_;
        weth = weth_;
        treasury = treasury_;
        socketBay = socketBay_;
        units = IYuzuUnits(units_);
        openingSqrtPriceX96 = openingSqrtPriceX96_;
        yuzuIsCurrency0 = yuzuToken_ < weth_;
    }

    /// @notice Computes the deterministic PoolId for a PoolKey.
    function computePoolId(PoolKey calldata key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @notice Uniswap v4 beforeInitialize hook: allows only YuzuTreasury at the exact opening price.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sender != treasury) revert OnlyTreasuryCanInitialize();

        address expected0 = yuzuIsCurrency0 ? yuzuToken : weth;
        address expected1 = yuzuIsCurrency0 ? weth : yuzuToken;
        if (key.currency0 != expected0 || key.currency1 != expected1 || key.hooks != address(this)) {
            revert InvalidPoolCurrencies();
        }
        if (sqrtPriceX96 != openingSqrtPriceX96) revert InvalidOpeningPrice();

        bytes32 id = computePoolId(key);
        poolId = id;
        poolInitialized = true;

        int24 openTick = _tickFromSqrtPrice(sqrtPriceX96);
        uint32 nowTs = uint32(block.timestamp);
        lastTimestamp = nowTs;
        lastRecordedTick = openTick;
        referenceTick = openTick;
        lastSyncTimestamp = nowTs;
        lastSyncTickCumulative = 0;

        hourlyHistory[0] = Checkpoint({timestamp: nowTs, tickCumulative: 0});
        historyCount = 1;

        emit PoolInitialized(id, sqrtPriceX96, openTick);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Uniswap v4 beforeAddLiquidity hook: only YuzuTreasury can add liquidity (or collect fees via delta=0).
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        if (sender != treasury) revert OnlyTreasuryCanAddLiquidity();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Uniswap v4 beforeSwap hook:
    ///         1. Updates tickCumulative using the pre-swap tick (immune to same-block flash manipulation).
    ///         2. Enforces the Launch Gate: while !gateLifted, buying $YUZU out of the pool requires sender == socketBay.
    function beforeSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int256, uint24) {
        _accrueTick();

        if (!gateLifted) {
            // Buying $YUZU means $YUZU is the output token leaving the pool:
            // - If $YUZU is currency0, buying $YUZU is !zeroForOne (swapping currency1 WETH -> currency0 $YUZU).
            // - If $YUZU is currency1, buying $YUZU is zeroForOne (swapping currency0 WETH -> currency1 $YUZU).
            bool buyingYuzu = yuzuIsCurrency0 ? !params.zeroForOne : params.zeroForOne;
            if (buyingYuzu && sender != socketBay) {
                revert LaunchGateBuyRestricted(sender);
            }
        }

        return (IHooks.beforeSwap.selector, 0, 0);
    }

    /// @notice True once the 1,000th unit is commissioned or 90 days have elapsed since unit #0001.
    function gateCanLift() public view returns (bool) {
        if (!poolInitialized || gateLifted) return false;
        if (units.commissionedCount() >= FLEET_SIZE) return true;
        uint256 first = units.firstPublicCommissionAt();
        return first != 0 && block.timestamp >= first + GATE_DURATION;
    }

    /// @notice Lifts the Launch Gate permanently and initializes referenceTick to the preceding 24h TWAP tick.
    function liftGate() external {
        if (gateLifted) revert GateAlreadyLifted();
        if (!gateCanLift()) revert GateConditionsNotMet();

        _accrueTick();
        gateLifted = true;

        int24 twap24h = _compute24hTwapTick();
        referenceTick = twap24h;
        lastSyncTickCumulative = tickCumulative;
        lastSyncTimestamp = uint32(block.timestamp);

        emit GateLifted(block.timestamp, units.commissionedCount(), twap24h);
    }

    /// @notice Moves referenceTick toward the TWAP tick since the last sync, clamped to ±488 ticks per 24 hours.
    ///         Requires at least 1 hour since lastSyncTimestamp.
    function syncReference() public {
        if (!gateLifted) revert GateStillActive();
        uint32 nowTs = uint32(block.timestamp);
        uint32 dt = nowTs - lastSyncTimestamp;
        if (dt < MIN_SYNC_INTERVAL) revert SyncTooSoon();

        _accrueTick();

        int56 deltaCumulative = tickCumulative - lastSyncTickCumulative;
        int24 avgTick = int24(deltaCumulative / int56(uint56(dt)));
        int24 diff = avgTick - referenceTick;

        // Pro-rata max drift: 488 ticks per 86,400 seconds (minimum 1 tick after 1 hour)
        int24 maxMove = int24(int256((uint256(uint24(MAX_DRIFT_TICKS_PER_DAY)) * uint256(dt)) / 1 days));
        if (maxMove < 1) maxMove = 1;

        int24 oldRef = referenceTick;
        int24 newRef;
        if (diff > maxMove) {
            newRef = oldRef + maxMove;
        } else if (diff < -maxMove) {
            newRef = oldRef - maxMove;
        } else {
            newRef = avgTick;
        }

        referenceTick = newRef;
        lastSyncTickCumulative = tickCumulative;
        lastSyncTimestamp = nowTs;

        emit ReferenceSynced(oldRef, newRef, nowTs);
    }

    /// @notice Syncs referenceTick if >= 1 hour has passed (no-op otherwise) and returns whether spot tick is within ±488 ticks.
    function syncIfNeededAndCheckBand() external returns (bool withinBand, int24 currentTick, int24 refTick) {
        (, currentTick) = V4StateLib.getSlot0(poolManager, poolId);
        if (!gateLifted) {
            return (true, currentTick, referenceTick);
        }
        if (block.timestamp - lastSyncTimestamp >= MIN_SYNC_INTERVAL) {
            syncReference();
        }
        refTick = referenceTick;
        int24 diff = currentTick >= refTick ? currentTick - refTick : refTick - currentTick;
        withinBand = diff <= GUARD_BAND_TICKS;
    }

    /// @notice View check for whether the current pool spot tick is within ±488 ticks of referenceTick.
    function isWithinReferenceBand() external view returns (bool) {
        if (!poolInitialized) return false;
        if (!gateLifted) return true;
        (, int24 currentTick) = V4StateLib.getSlot0(poolManager, poolId);
        int24 diff = currentTick >= referenceTick ? currentTick - referenceTick : referenceTick - currentTick;
        return diff <= GUARD_BAND_TICKS;
    }

    function _accrueTick() internal {
        (, int24 currentTick) = V4StateLib.getSlot0(poolManager, poolId);
        uint32 nowTs = uint32(block.timestamp);
        uint32 dt = nowTs - lastTimestamp;
        if (dt > 0) {
            tickCumulative += int56(currentTick) * int56(uint56(dt));
            lastTimestamp = nowTs;

            // Record hourly snapshot for 24h TWAP initialization at gate lift
            Checkpoint memory latest = hourlyHistory[historyIndex];
            if (nowTs - latest.timestamp >= 1 hours) {
                historyIndex = (historyIndex + 1) % 25;
                hourlyHistory[historyIndex] = Checkpoint({timestamp: nowTs, tickCumulative: tickCumulative});
                if (historyCount < 25) historyCount++;
            }
        }
        lastRecordedTick = currentTick;
    }

    function _compute24hTwapTick() internal view returns (int24) {
        uint32 nowTs = uint32(block.timestamp);
        // Find oldest checkpoint within ~24h
        uint8 oldestIdx = historyCount < 25 ? 0 : (historyIndex + 1) % 25;
        Checkpoint memory oldest = hourlyHistory[oldestIdx];
        uint32 dt = nowTs - oldest.timestamp;
        if (dt == 0) {
            (, int24 currentTick) = V4StateLib.getSlot0(poolManager, poolId);
            return currentTick;
        }
        return int24((tickCumulative - oldest.tickCumulative) / int56(uint56(dt)));
    }

    /// @dev FIX (bankr 2026-11-18): computed from the price with Uniswap v4-core's TickMath, the same function the
    ///      PoolManager uses in initialize. The previous version read the pool's slot0, but beforeInitialize runs
    ///      before the PoolManager writes slot0, so the opening tick was recorded as 0 on real v4.
    function _tickFromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }
}
