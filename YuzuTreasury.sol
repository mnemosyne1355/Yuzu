// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IUnlockCallback,
    PoolKey,
    ModifyLiquidityParams,
    SwapParams,
    IPoolManager,
    IWETH,
    IYuzuUnits,
    IYuzuNavLens,
    IYuzuRegistry,
    V4StateLib
} from "./interfaces/IYuzuV4Interfaces.sol";
import {IYuzuSwapRouter, IPythMinimal} from "./interfaces/IYuzuPhase4Interfaces.sol";
import {YuzuPoolHook} from "./YuzuPoolHook.sol";
import {YuzuSocketBay} from "./YuzuSocketBay.sol";

/// @title YuzuTreasury — Contract 09 of 16 (YUZU-98 Master Specification v4.9, Sections 2.2, 2.4, 9.1)
/// @notice Non-upgradeable protocol treasury, LP Reserve manager, Permanently Locked Uniswap v4 LP holder,
///         Ecosystem Farm emitter (349.9M, 1:1 Farm Gate), R&D Vesting vault (50M, 3/20 Seat Gate),
///         Core Team Vesting vault (200M, 12m cliff + 24m linear, 2% of pool $YUZU per 30d release limit),
///         Buyback engine, Royalty distributor, and Salvage/Fee conversion escrows.
contract YuzuTreasury is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // v4.9 Token Allocation Constants (out of 1,000,000,000 $YUZU total supply; 150.1M sits in YuzuSeeder)
    uint256 public constant LP_RESERVE_ALLOCATION = 250_000_000e18;        // 25.00%
    uint256 public constant ECOSYSTEM_VAULT_ALLOCATION = 349_900_000e18;   // 34.99%
    uint256 public constant RND_ALLOCATION = 50_000_000e18;                // 5.00%
    uint256 public constant TEAM_ALLOCATION = 200_000_000e18;              // 20.00%

    // Commissioning & LP constants
    uint256 public constant OPENING_WETH_LP = 0.0225 ether;
    uint256 public constant OPENING_YUZU_LP = 150_000e18;
    uint256 public constant MAX_YUZU_LP_PER_UNIT = 250_000e18;
    uint256 public constant FLEET_SIZE = 1_000;

    // Vesting, Gate & Farm constants
    uint256 public constant RND_VESTING_DURATION = 730 days;               // 24 months linear
    uint256 public constant TEAM_CLIFF_DURATION = 365 days;                // 12 months cliff
    uint256 public constant TEAM_VESTING_DURATION = 730 days;              // 24 months linear after cliff
    uint256 public constant TEAM_RELEASE_COOLDOWN = 30 days;
    uint256 public constant TEAM_POOL_SHARE_BPS = 200;                     // 2.00% of pool position $YUZU
    uint256 public constant WEEKLY_FARM_RATE = 1_922_115e18;               // ~182 weeks for 349.9M
    uint256 public constant BUYBACK_COOLDOWN = 1 hours;
    uint256 public constant BUYBACK_MAX_POOL_WETH_BPS = 100;               // 1.00% of pool WETH per call

    // Full-range tick bounds for 1.00% fee tier (tickSpacing = 200)
    int24 public constant FULL_RANGE_TICK_LOWER = -887200;
    int24 public constant FULL_RANGE_TICK_UPPER = 887200;

    enum CallbackAction {
        ADD_LIQUIDITY,
        COLLECT_FEES,
        BUYBACK
    }

    IPoolManager public immutable poolManager;
    IERC20 public immutable yuzuToken;
    IWETH public immutable weth;
    address public immutable multisig;
    address public immutable teamRecipient;
    uint160 public immutable openingSqrtPriceX96;
    bool public immutable yuzuIsCurrency0;
    address public immutable deployer;

    YuzuPoolHook public hook;
    YuzuSocketBay public socketBay;
    IYuzuUnits public units;
    address public seeder;
    address public distributor;
    IYuzuNavLens public lens;
    IYuzuRegistry public registry;
    PoolKey public poolKey;
    bytes32 public poolId;
    bool public coreConfigured;
    bool public poolOpened;
    bool public lpLeftoversSwept;
    // v4 alignment pass (2026-11-18): liquidity units of the Treasury's permanently locked full-range position
    uint128 public lockedLiquidity;

    // Ring-fenced $YUZU buckets
    uint256 public lpReserveYuzuRemaining = LP_RESERVE_ALLOCATION;
    uint256 public totalYuzuAddedToLp;
    uint256 public ecosystemVaultYuzuRemaining = ECOSYSTEM_VAULT_ALLOCATION;
    uint256 public totalFarmEmitted;
    uint256 public rndReleased;
    uint256 public teamReleased;
    uint256 public lastTeamReleaseAt;

    // Ring-fenced WETH buckets (multisig can ONLY spend `treasuryWethFunds`)
    uint256 public treasuryWethFunds;
    uint256 public lpReserveWethPending;
    uint256 public buybackWethReserve;
    uint256 public lastBuybackAt;

    // Non-WETH fee & salvage escrows
    mapping(address asset => uint256 amount) public salvageEscrow;
    mapping(address asset => uint256 amount) public feeEscrow;
    // Part of feeEscrow[asset] owed to the buyback reserve (20% of desk fees, 50% of Slot-2 skims); the rest is the reward pool's
    mapping(address asset => uint256 amount) public feeEscrowBuybackShare;

    event CoreConfigured(address hook, address socketBay, address units, address seeder, address distributor);
    event PoolOpened(bytes32 indexed poolId, uint256 wethAdded, uint256 yuzuAdded);
    event MintLiquidityAdded(uint256 wethAdded, uint256 yuzuAdded, uint256 totalYuzuAdded);
    event MintLiquiditySkippedByGuard(uint256 pendingWeth, int24 currentTick, int24 referenceTick);
    event LpLeftoversSwept(uint256 yuzuSweptToEcosystem, uint256 unpairedWethToDistributor);
    event LpFeesCollected(uint256 wethToDistributor, uint256 wethToTreasury, uint256 yuzuToDistributor);
    event RndReleased(address indexed to, uint256 amount, uint256 cumulativeReleased);
    event TeamReleased(address indexed to, uint256 amount, uint256 cumulativeReleased);
    event FarmEpochEmitted(uint256 indexed epoch, uint256 amount, uint256 cumulativeEmitted);
    event BuybackExecuted(uint256 wethSpent, uint256 yuzuBought);
    event RoyaltiesDistributed(uint256 toDistributor, uint256 toBuyback, uint256 toTreasury);
    event TreasuryFundsWithdrawn(address indexed to, uint256 amount);
    event FeeEscrowReceived(address indexed asset, uint256 amount, uint256 buybackBps);
    event SalvageEscrowReceived(address indexed asset, uint256 amount);
    event FeesConverted(address indexed asset, uint256 amountIn, uint256 wethOut, uint256 toDistributor, uint256 toBuyback);
    event SalvageConverted(address indexed asset, uint256 amountIn, uint256 wethOut);

    error ZeroAddress();
    error OnlyDeployer();
    error AlreadyConfigured();
    error NotConfigured();
    error OnlyMultisig();
    error OnlySeeder();
    error OnlyDistributor(); // ADDED (bankr 2026-11-19): emitWeeklyFarm used OnlySeeder for a distributor-only check
    error OnlyPoolManager();
    error PoolAlreadyOpened();
    error PoolNotOpened();
    error GateStillActive();
    error NothingToRelease();
    error TeamCooldownActive();
    error BuybackCooldownActive();
    error OutsideReferenceBand();
    error InsufficientTreasuryFunds();
    error SelloutNotReached();
    error EscrowAssetNotAllowed();
    error EscrowNotFunded();
    error NothingToConvert();
    error ConvertOutputShort();
    error PythFeeShort();
    error RefundFailed();

    modifier onlyMultisig() {
        if (msg.sender != multisig) revert OnlyMultisig();
        _;
    }

    constructor(
        address poolManager_,
        address yuzuToken_,
        address weth_,
        address multisig_,
        address teamRecipient_,
        uint160 openingSqrtPriceX96_
    ) {
        if (
            poolManager_ == address(0) || yuzuToken_ == address(0) || weth_ == address(0)
                || multisig_ == address(0) || teamRecipient_ == address(0)
        ) revert ZeroAddress();

        poolManager = IPoolManager(poolManager_);
        yuzuToken = IERC20(yuzuToken_);
        weth = IWETH(weth_);
        multisig = multisig_;
        teamRecipient = teamRecipient_;
        openingSqrtPriceX96 = openingSqrtPriceX96_;
        yuzuIsCurrency0 = yuzuToken_ < weth_;
        deployer = msg.sender;
    }

    /// @notice One-time wiring called at deployment.
    function configureCore(
        address hook_,
        address socketBay_,
        address units_,
        address seeder_,
        address distributor_,
        address lens_,
        address registry_,
        PoolKey calldata poolKey_
    ) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (coreConfigured) revert AlreadyConfigured();
        if (
            hook_ == address(0) || socketBay_ == address(0) || units_ == address(0)
                || seeder_ == address(0) || distributor_ == address(0)
        ) revert ZeroAddress();

        hook = YuzuPoolHook(hook_);
        socketBay = YuzuSocketBay(payable(socketBay_));
        units = IYuzuUnits(units_);
        seeder = seeder_;
        distributor = distributor_;
        lens = IYuzuNavLens(lens_);
        registry = IYuzuRegistry(registry_);
        poolKey = poolKey_;
        poolId = keccak256(abi.encode(poolKey_));
        coreConfigured = true;

        emit CoreConfigured(hook_, socketBay_, units_, seeder_, distributor_);
    }

    // =========================================================================
    // 1. MINT-SEEDED LIQUIDITY & PERMANENT LP LOCK (Section 2.2)
    // =========================================================================

    /// @notice Called by YuzuSeeder during Commissioning: credits commissioning WETH shares and triggers addMintLiquidity.
    function receiveCommissioningWeth(uint256 lpWeth, uint256 treasuryWeth) external {
        if (msg.sender != seeder) revert OnlySeeder();
        lpReserveWethPending += lpWeth;
        treasuryWethFunds += treasuryWeth;
        if (!poolOpened) {
            _openPoolWithUnitZero();
        } else {
            addMintLiquidity();
        }
    }

    /// @notice Opens the Uniswap v4 $YUZU / WETH pool during #0000's commissioning with 0.0225 WETH + 150,000 $YUZU.
    function _openPoolWithUnitZero() internal {
        if (!coreConfigured) revert NotConfigured();
        if (poolOpened) revert PoolAlreadyOpened();

        poolManager.initialize(poolKey, openingSqrtPriceX96);
        poolOpened = true;

        (uint256 wethPaid, uint256 yuzuPaid) = _addLiquidity(OPENING_WETH_LP, OPENING_YUZU_LP);
        emit PoolOpened(poolId, wethPaid, yuzuPaid);
    }

    /// @notice Pairs pending commissioning WETH in the LP reserve with $YUZU at the pool's current ratio,
    ///         up to the cumulative 250,000 $YUZU per commissioned unit ceiling, guarded by referenceTick post-gate.
    function addMintLiquidity() public nonReentrant {
        _addMintLiquidity();
    }

    /// @dev FIX (bankr 2026-11-19): the body of addMintLiquidity, moved here unchanged (same reference-band guard,
    ///      same 250,000 $YUZU per unit ceiling, same pool-ratio pairing, still a silent no-op when there is
    ///      nothing to pair) so sweepSelloutLpLeftovers, which already holds the reentrancy lock, can pair without
    ///      entering a second nonReentrant function. Returns false only when the band guard skipped the add.
    function _addMintLiquidity() internal returns (bool withinBand) {
        if (!poolOpened) revert PoolNotOpened();
        uint256 wethPending = lpReserveWethPending;
        if (wethPending == 0 || lpReserveYuzuRemaining == 0) return true;

        int24 currentTick;
        int24 refTick;
        (withinBand, currentTick, refTick) = hook.syncIfNeededAndCheckBand();
        if (!withinBand) {
            emit MintLiquiditySkippedByGuard(wethPending, currentTick, refTick);
            return false;
        }

        // Read the locked position's balances at the current price to match the pool ratio
        (uint256 poolYuzu, uint256 poolWeth) = _getPoolBalances();

        uint256 yuzuDesired = poolWeth > 0 ? (wethPending * poolYuzu) / poolWeth : OPENING_YUZU_LP;
        uint256 maxCumulativeYuzu = units.commissionedCount() * MAX_YUZU_LP_PER_UNIT;
        uint256 yuzuCapRemaining = maxCumulativeYuzu > totalYuzuAddedToLp ? maxCumulativeYuzu - totalYuzuAddedToLp : 0;
        if (yuzuCapRemaining > lpReserveYuzuRemaining) {
            yuzuCapRemaining = lpReserveYuzuRemaining;
        }
        if (yuzuCapRemaining == 0) return true;

        uint256 wethToUse = wethPending;
        uint256 yuzuToUse = yuzuDesired;

        // If the price fell enough that yuzuDesired exceeds the 250k/unit cap, scale wethToUse proportionally
        if (yuzuToUse > yuzuCapRemaining) {
            yuzuToUse = yuzuCapRemaining;
            wethToUse = poolYuzu > 0 ? (yuzuToUse * poolWeth) / poolYuzu : wethPending;
        }
        if (wethToUse == 0 || yuzuToUse == 0) return true;

        (uint256 wethPaid, uint256 yuzuPaid) = _addLiquidity(wethToUse, yuzuToUse);
        emit MintLiquidityAdded(wethPaid, yuzuPaid, totalYuzuAddedToLp);
    }

    /// @dev v4 alignment pass (argon, 2026-11-18). The $YUZU and WETH held by the locked full-range position at
    ///      the pool's current price. Only the Treasury can add liquidity (the hook enforces it), so this is the
    ///      whole pool. Replaces getPositionBalances, which the real PoolManager does not have.
    function _getPoolBalances() internal view returns (uint256 poolYuzu, uint256 poolWeth) {
        (uint160 sqrtPriceX96,) = V4StateLib.getSlot0(poolManager, poolId);
        (uint256 bal0, uint256 bal1) = V4StateLib.fullRangeAmountsForLiquidity(sqrtPriceX96, lockedLiquidity);
        poolYuzu = yuzuIsCurrency0 ? bal0 : bal1;
        poolWeth = yuzuIsCurrency0 ? bal1 : bal0;
    }

    /// @dev Adds full-range liquidity and debits the LP reserve by what the position actually took, so rounding
    ///      leftovers stay in the reserve (argon, 2026-11-18).
    ///      FIX (bankr 2026-11-18): on real v4 an add also pays out the fees the position has accrued, netted
    ///      against what is owed. As pasted, those fees stayed inside the LP reserve. They are split here exactly
    ///      like collectLpFees.
    function _addLiquidity(uint256 wethToUse, uint256 yuzuToUse) internal returns (uint256 wethPaid, uint256 yuzuPaid) {
        bytes memory res = poolManager.unlock(abi.encode(CallbackAction.ADD_LIQUIDITY, wethToUse, yuzuToUse));
        uint256 feeWeth;
        uint256 feeYuzu;
        (wethPaid, yuzuPaid, feeWeth, feeYuzu) = abi.decode(res, (uint256, uint256, uint256, uint256));
        lpReserveWethPending -= wethPaid;
        lpReserveYuzuRemaining -= yuzuPaid;
        totalYuzuAddedToLp += yuzuPaid;
        _distributeLpFees(feeWeth, feeYuzu);
    }

    /// @dev LP fee split: WETH 50% to YuzuDistributor and 50% to Treasury funds; $YUZU 100% to YuzuDistributor.
    function _distributeLpFees(uint256 wethFees, uint256 yuzuFees) internal {
        if (wethFees == 0 && yuzuFees == 0) return;
        uint256 wethToDist = wethFees / 2;
        uint256 wethToTreas = wethFees - wethToDist;

        if (wethToDist > 0) weth.transfer(distributor, wethToDist);
        if (wethToTreas > 0) treasuryWethFunds += wethToTreas;
        if (yuzuFees > 0) yuzuToken.transfer(distributor, yuzuFees);

        emit LpFeesCollected(wethToDist, wethToTreas, yuzuFees);
    }

    /// @notice Once all 1,000 units are commissioned: pairs whatever LP-reserve WETH and $YUZU can still be paired,
    ///         then sweeps what is left of BOTH buckets: leftover $YUZU into the Ecosystem Vault, leftover WETH
    ///         (rounding dust, or all of it if the $YUZU ran out) to YuzuDistributor. One shot.
    /// @dev FIX (bankr 2026-11-19), two bugs reported by the founder's reviewer 2026-11-19 and confirmed by reading:
    ///      (1) this function is nonReentrant and called the nonReentrant addMintLiquidity, so it reverted whenever
    ///      both buckets were non-zero; (2) after a pairing both buckets normally still hold something (real v4
    ///      leaves a few wei of rounding in the reserve), and the old if / else-if only handled exactly one bucket
    ///      being non-zero, so it reverted NothingToRelease. Together the sweep could not run after a sellout.
    ///      Kept from the old behaviour: while the price is outside the reference band nothing is swept (the old
    ///      code reverted NothingToRelease there; it now reverts OutsideReferenceBand), so pending LP WETH cannot
    ///      be diverted to the reward pool by pushing the price out of the band.
    function sweepSelloutLpLeftovers() external nonReentrant {
        if (units.commissionedCount() < FLEET_SIZE) revert SelloutNotReached();
        if (lpLeftoversSwept) revert NothingToRelease();
        if (!_addMintLiquidity()) revert OutsideReferenceBand();

        uint256 sweptYuzu = lpReserveYuzuRemaining;
        uint256 sweptWeth = lpReserveWethPending;
        lpLeftoversSwept = true;

        if (sweptYuzu > 0) {
            lpReserveYuzuRemaining = 0;
            ecosystemVaultYuzuRemaining += sweptYuzu;
        }
        if (sweptWeth > 0) {
            lpReserveWethPending = 0;
            weth.transfer(distributor, sweptWeth);
        }

        emit LpLeftoversSwept(sweptYuzu, sweptWeth);
    }

    /// @notice Collects accrued LP fees from the permanently locked v4 position (liquidityDelta = 0).
    ///         Splits WETH 50% to YuzuDistributor and 50% to Treasury; sends 100% of $YUZU to YuzuDistributor.
    function collectLpFees() external nonReentrant returns (uint256 wethFees, uint256 yuzuFees) {
        if (!poolOpened) revert PoolNotOpened();
        bytes memory res = poolManager.unlock(abi.encode(CallbackAction.COLLECT_FEES, uint256(0), uint256(0)));
        (,, wethFees, yuzuFees) = abi.decode(res, (uint256, uint256, uint256, uint256));

        _distributeLpFees(wethFees, yuzuFees);
    }

    // =========================================================================
    // 2. R&D SEAT GATE (3/20 on 50M) & TEAM RELEASE LIMIT (2% of Pool / 30d)
    // =========================================================================

    /// @notice Computes currently releasable R&D $YUZU: min(24m linear schedule, 3/20 of netSeatedYuzu) - rndReleased.
    function releasableRnd() public view returns (uint256) {
        if (!coreConfigured || !hook.gateLifted()) return 0;
        uint256 start = units.firstPublicCommissionAt();
        if (start == 0 || block.timestamp <= start) return 0;

        uint256 elapsed = block.timestamp - start;
        uint256 timeVested = elapsed >= RND_VESTING_DURATION
            ? RND_ALLOCATION
            : (RND_ALLOCATION * elapsed) / RND_VESTING_DURATION;

        // Seat Gate: 3 $YUZU for every 20 $YUZU net seated (15%)
        uint256 seatCap = (socketBay.netSeatedYuzu() * 3) / 20;
        uint256 ceiling = timeVested < seatCap ? timeVested : seatCap;

        return ceiling > rndReleased ? ceiling - rndReleased : 0;
    }

    /// @notice Releases unlocked R&D $YUZU to the multisig (or specified R&D recipient).
    function releaseRnd(address to) external onlyMultisig nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = releasableRnd();
        if (amount == 0) revert NothingToRelease();

        rndReleased += amount;
        yuzuToken.transfer(to, amount);
        emit RndReleased(to, amount, rndReleased);
    }

    /// @notice Computes vested Team $YUZU (12m cliff, then 24m linear) before applying the 2% pool cap.
    function vestedTeamTotal() public view returns (uint256) {
        if (!coreConfigured || !hook.gateLifted()) return 0;
        uint256 start = units.firstPublicCommissionAt();
        if (start == 0 || block.timestamp < start + TEAM_CLIFF_DURATION) return 0;

        uint256 postCliff = block.timestamp - (start + TEAM_CLIFF_DURATION);
        if (postCliff >= TEAM_VESTING_DURATION) return TEAM_ALLOCATION;
        return (TEAM_ALLOCATION * postCliff) / TEAM_VESTING_DURATION;
    }

    /// @notice Releases Team $YUZU to the fixed teamRecipient, at most once every 30 days,
    ///         capped at 2% of the $YUZU currently held in the locked pool position. Callable by anyone.
    function releaseTeam() external nonReentrant returns (uint256 amount) {
        if (!coreConfigured || !hook.gateLifted()) revert GateStillActive();
        if (lastTeamReleaseAt != 0 && block.timestamp < lastTeamReleaseAt + TEAM_RELEASE_COOLDOWN) {
            revert TeamCooldownActive();
        }

        uint256 vestedUnclaimed = vestedTeamTotal();
        if (vestedUnclaimed <= teamReleased) revert NothingToRelease();
        vestedUnclaimed -= teamReleased;

        (uint256 poolYuzu,) = _getPoolBalances();
        uint256 poolCap = (poolYuzu * TEAM_POOL_SHARE_BPS) / 10000;

        amount = vestedUnclaimed < poolCap ? vestedUnclaimed : poolCap;
        if (amount == 0) revert NothingToRelease();

        teamReleased += amount;
        lastTeamReleaseAt = block.timestamp;
        yuzuToken.transfer(teamRecipient, amount);

        emit TeamReleased(teamRecipient, amount, teamReleased);
    }

    // =========================================================================
    // 3. ECOSYSTEM FARM EMISSION (349.9M Vault, 1:1 Farm Gate, Section 2.4)
    // =========================================================================

    /// @notice Called by YuzuDistributor at the close of each epoch to emit up to 1,922,115 $YUZU,
    ///         strictly capped by the 1:1 Farm Gate (totalFarmEmitted <= socketBay.netSeatedYuzu()).
    function emitWeeklyFarm(uint256 epoch) external nonReentrant returns (uint256 emitted) {
        if (msg.sender != distributor) revert OnlyDistributor(); // FIX (bankr 2026-11-19): was OnlySeeder
        if (ecosystemVaultYuzuRemaining == 0) return 0;

        uint256 netSeated = socketBay.netSeatedYuzu();
        if (netSeated <= totalFarmEmitted) return 0;

        uint256 gateRoom = netSeated - totalFarmEmitted;
        emitted = WEEKLY_FARM_RATE;
        if (emitted > gateRoom) emitted = gateRoom;
        if (emitted > ecosystemVaultYuzuRemaining) emitted = ecosystemVaultYuzuRemaining;

        if (emitted > 0) {
            ecosystemVaultYuzuRemaining -= emitted;
            totalFarmEmitted += emitted;
            yuzuToken.transfer(distributor, emitted);
            emit FarmEpochEmitted(epoch, emitted, totalFarmEmitted);
        }
    }

    // =========================================================================
    // 4. BUYBACK ENGINE, ROYALTIES & FEE ESCROWS (Section 2.4)
    // =========================================================================

    /// @notice Records WETH arriving from the 0.25% in-vault desk fee (80% Distributor, 20% Buyback)
    ///         or 10% Slot-2 skim (50% Distributor, 50% Buyback).
    function recordProtocolFeeWeth(uint256 toDistributor, uint256 toBuyback) external {
        if (toDistributor > 0) weth.transferFrom(msg.sender, distributor, toDistributor);
        if (toBuyback > 0) {
            weth.transferFrom(msg.sender, address(this), toBuyback);
            buybackWethReserve += toBuyback;
        }
    }

    // ---- Non-WETH fee and salvage escrows (Sections 2.4 and 9.1) ----

    uint256 public constant ESCROW_MIN_OUT_BPS = 9850;     // 98.50% of the oracle quote
    uint256 public constant DESK_FEE_BUYBACK_BPS = 2000;   // desk fee: 80% reward pool, 20% buyback
    uint256 public constant SKIM_BUYBACK_BPS = 5000;       // Slot-2 skim: 50% reward pool, 50% buyback

    /// @notice Credits a desk fee taken in a non-WETH asset. The caller must have transferred `amount` here first.
    function receiveFeeEscrow(address asset, uint256 amount) external nonReentrant {
        _creditFeeEscrow(asset, amount, DESK_FEE_BUYBACK_BPS);
    }

    /// @notice Credits a Slot-2 skim taken in a non-WETH asset. The caller must have transferred `amount` here first.
    function receiveSkimEscrow(address asset, uint256 amount) external nonReentrant {
        _creditFeeEscrow(asset, amount, SKIM_BUYBACK_BPS);
    }

    /// @notice Credits a Seed Raid salvage share that could not be swapped. The caller must have transferred it first.
    function receiveSalvageEscrow(address asset, uint256 amount) external nonReentrant {
        _requireEscrowFunded(asset, amount);
        salvageEscrow[asset] += amount;
        emit SalvageEscrowReceived(asset, amount);
    }

    /// @notice Anyone can call. Swaps the whole fee escrow of `asset` to WETH at no less than 98.5% of the oracle
    ///         quote and splits it between the reward pool and the buyback reserve in the proportions it was
    ///         collected in. Send the Pyth update fee as msg.value; any excess is returned.
    function convertFees(address asset, bytes[] calldata pythUpdateData)
        external
        payable
        nonReentrant
        returns (uint256 wethOut)
    {
        uint256 amount = feeEscrow[asset];
        if (amount == 0) revert NothingToConvert();
        uint256 buybackShare = feeEscrowBuybackShare[asset];
        feeEscrow[asset] = 0;
        feeEscrowBuybackShare[asset] = 0;

        wethOut = _convertEscrow(asset, amount, pythUpdateData);

        uint256 toBuyback = (wethOut * buybackShare) / amount;
        uint256 toDist = wethOut - toBuyback;
        if (toDist > 0) weth.transfer(distributor, toDist);
        buybackWethReserve += toBuyback;
        emit FeesConverted(asset, amount, wethOut, toDist, toBuyback);
    }

    /// @notice Anyone can call. Swaps the whole salvage escrow of `asset` to WETH on the same terms and sends all
    ///         of it to YuzuDistributor.
    function convertSalvage(address asset, bytes[] calldata pythUpdateData)
        external
        payable
        nonReentrant
        returns (uint256 wethOut)
    {
        uint256 amount = salvageEscrow[asset];
        if (amount == 0) revert NothingToConvert();
        salvageEscrow[asset] = 0;

        wethOut = _convertEscrow(asset, amount, pythUpdateData);
        weth.transfer(distributor, wethOut);
        emit SalvageConverted(asset, amount, wethOut);
    }

    function _creditFeeEscrow(address asset, uint256 amount, uint256 buybackBps) internal {
        _requireEscrowFunded(asset, amount);
        feeEscrow[asset] += amount;
        feeEscrowBuybackShare[asset] += (amount * buybackBps) / 10000;
        emit FeeEscrowReceived(asset, amount, buybackBps);
    }

    /// @dev Credit is only given for tokens that are actually here and not already counted, so these functions can
    ///      stay open to any caller. WETH and $YUZU are refused because the Treasury holds ring-fenced balances of both.
    function _requireEscrowFunded(address asset, uint256 amount) internal view {
        if (asset == address(weth) || asset == address(yuzuToken)) revert EscrowAssetNotAllowed();
        if (IERC20(asset).balanceOf(address(this)) < salvageEscrow[asset] + feeEscrow[asset] + amount) {
            revert EscrowNotFunded();
        }
    }

    function _convertEscrow(address asset, uint256 amount, bytes[] calldata pythUpdateData)
        internal
        returns (uint256 wethOut)
    {
        uint256 pythFee = 0;
        if (pythUpdateData.length > 0) {
            IPythMinimal p = IPythMinimal(lens.pyth());
            pythFee = p.getUpdateFee(pythUpdateData);
            if (msg.value < pythFee) revert PythFeeShort();
            p.updatePriceFeeds{value: pythFee}(pythUpdateData);
        }
        if (msg.value > pythFee) {
            (bool ok,) = msg.sender.call{value: msg.value - pythFee}("");
            if (!ok) revert RefundFailed();
        }

        lens.requireFresh(asset);
        lens.requireFresh(address(weth));
        uint256 minWeth = (lens.quote(asset, address(weth), amount) * ESCROW_MIN_OUT_BPS) / 10000;
        if (minWeth == 0) revert ConvertOutputShort();

        IYuzuRegistry.Route memory r = registry.routeFor(asset, address(weth));
        uint256 before = weth.balanceOf(address(this));
        IERC20(asset).forceApprove(r.router, amount);
        IYuzuSwapRouter(r.router).swapExactIn(asset, address(weth), amount, minWeth, address(this), r.path);
        IERC20(asset).forceApprove(r.router, 0);
        wethOut = weth.balanceOf(address(this)) - before;
        if (wethOut < minWeth) revert ConvertOutputShort();
    }

    /// @notice Permissionless buyback after the Launch Gate lifts: requires spot within ±488 ticks (~5%)
    ///         of referenceTick, spends at most 1% of the pool's WETH per call, once per hour.
    function executeBuyback() external nonReentrant returns (uint256 wethSpent, uint256 yuzuBought) {
        if (!hook.gateLifted()) revert GateStillActive();
        if (block.timestamp < lastBuybackAt + BUYBACK_COOLDOWN) revert BuybackCooldownActive();
        if (buybackWethReserve == 0) revert NothingToRelease();

        (bool withinBand,,) = hook.syncIfNeededAndCheckBand();
        if (!withinBand) revert OutsideReferenceBand();

        (, uint256 poolWeth) = _getPoolBalances();
        uint256 maxWethCall = (poolWeth * BUYBACK_MAX_POOL_WETH_BPS) / 10000;
        if (maxWethCall == 0) revert NothingToRelease();

        wethSpent = buybackWethReserve < maxWethCall ? buybackWethReserve : maxWethCall;
        buybackWethReserve -= wethSpent;
        lastBuybackAt = block.timestamp;

        bytes memory res = poolManager.unlock(abi.encode(CallbackAction.BUYBACK, wethSpent, uint256(0)));
        yuzuBought = abi.decode(res, (uint256));

        emit BuybackExecuted(wethSpent, yuzuBought);
    }

    /// @notice Splits any un-accounted ETH/WETH (ERC-2981 marketplace royalties) 50% Distributor, 25% Buyback, 25% Treasury.
    function distributeRoyalties() external nonReentrant returns (uint256 totalRoyalty) {
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            weth.deposit{value: ethBal}();
        }
        uint256 wethBal = weth.balanceOf(address(this));
        uint256 accounted = treasuryWethFunds + lpReserveWethPending + buybackWethReserve;
        if (wethBal <= accounted) revert NothingToRelease();

        totalRoyalty = wethBal - accounted;
        uint256 toDist = totalRoyalty / 2;
        uint256 toBuyback = totalRoyalty / 4;
        uint256 toTreas = totalRoyalty - toDist - toBuyback;

        if (toDist > 0) weth.transfer(distributor, toDist);
        buybackWethReserve += toBuyback;
        treasuryWethFunds += toTreas;

        emit RoyaltiesDistributed(toDist, toBuyback, toTreas);
    }

    /// @notice Withdraws unconstrained treasuryWethFunds (the 25% commissioning share, 50% WETH LP fees, 25% royalties).
    ///         The multisig cannot touch LP reserves, locked LP, Ecosystem Vault, Buyback reserve, R&D, or Team locks.
    function withdrawTreasuryFunds(address to, uint256 amount) external onlyMultisig nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > treasuryWethFunds) revert InsufficientTreasuryFunds();
        treasuryWethFunds -= amount;
        weth.transfer(to, amount);
        emit TreasuryFundsWithdrawn(to, amount);
    }

    // =========================================================================
    // 5. UNISWAP V4 IUNLOCKCALLBACK IMPLEMENTATION
    // =========================================================================

    /// @dev v4 alignment pass (argon, 2026-11-18): real liquidity units, packed BalanceDelta returns, valid price
    ///      limits, and sync -> transfer -> settle() to pay the PoolManager.
    ///      FIX (bankr 2026-11-18): ADD_LIQUIDITY and COLLECT_FEES share one branch (a collect is an add of zero)
    ///      and both return (wethIntoPosition, yuzuIntoPosition, feeWeth, feeYuzu), so fees paid out during an
    ///      add are reported separately from what the position took.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (CallbackAction action, uint256 amountWeth, uint256 amountYuzu) =
            abi.decode(data, (CallbackAction, uint256, uint256));

        if (action != CallbackAction.BUYBACK) {
            uint128 liq = 0;
            if (action == CallbackAction.ADD_LIQUIDITY) {
                (uint160 sqrtPriceX96,) = V4StateLib.getSlot0(poolManager, poolId);
                liq = V4StateLib.fullRangeLiquidityForAmounts(
                    sqrtPriceX96,
                    yuzuIsCurrency0 ? amountYuzu : amountWeth,
                    yuzuIsCurrency0 ? amountWeth : amountYuzu
                );
                lockedLiquidity += liq;
            }

            (int256 callerDelta, int256 feesAccrued) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: FULL_RANGE_TICK_LOWER,
                    tickUpper: FULL_RANGE_TICK_UPPER,
                    liquidityDelta: int256(uint256(liq)),
                    salt: bytes32(0)
                }),
                ""
            );
            // callerDelta = fees paid out minus what the position took. Negative: the Treasury owes the
            // PoolManager. Positive: the PoolManager owes the Treasury.
            (int128 d0, int128 d1) = V4StateLib.unpackDelta(callerDelta);
            (int128 f0, int128 f1) = V4StateLib.unpackDelta(feesAccrued);
            _settleOrTake(poolKey.currency0, d0);
            _settleOrTake(poolKey.currency1, d1);

            uint256 into0 = uint256(int256(f0) - int256(d0));
            uint256 into1 = uint256(int256(f1) - int256(d1));
            uint256 fee0 = uint256(uint128(f0));
            uint256 fee1 = uint256(uint128(f1));
            return yuzuIsCurrency0 ? abi.encode(into1, into0, fee1, fee0) : abi.encode(into0, into1, fee0, fee1);
        }

        // CallbackAction.BUYBACK: exact-input swap of amountWeth for $YUZU delivered to YuzuDistributor
        bool zeroForOne = !yuzuIsCurrency0;
        int256 swapDelta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountWeth),
                sqrtPriceLimitX96: zeroForOne
                    ? V4StateLib.MIN_SQRT_PRICE_PLUS_ONE
                    : V4StateLib.MAX_SQRT_PRICE_MINUS_ONE
            }),
            ""
        );
        (int128 s0, int128 s1) = V4StateLib.unpackDelta(swapDelta);
        int128 yuzuDelta = yuzuIsCurrency0 ? s0 : s1;
        uint256 yuzuOut = yuzuDelta > 0 ? uint256(uint128(yuzuDelta)) : 0;

        poolManager.sync(address(weth));
        weth.transfer(address(poolManager), amountWeth);
        poolManager.settle();
        poolManager.take(address(yuzuToken), distributor, yuzuOut);

        return abi.encode(yuzuOut);
    }

    /// @dev Pays the PoolManager a negative delta (sync, transfer, settle) or collects a positive one.
    function _settleOrTake(address currency, int128 delta) internal {
        if (delta < 0) {
            poolManager.sync(currency);
            IERC20(currency).safeTransfer(address(poolManager), uint256(uint128(-delta)));
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(uint128(delta)));
        }
    }

    receive() external payable {}
}
