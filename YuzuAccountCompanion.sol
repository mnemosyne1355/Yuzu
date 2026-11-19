// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    SeedMode,
    BoltState,
    IYuzu98v2Minimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuSwapRouter,
    IYuzuSocketBayMinimal,
    IYuzuTreasuryMinimal
} from "./interfaces/IYuzuPhase4Interfaces.sol";

interface IYuzuVaultDirectory {
    function getVaultAddress(uint256 tokenId) external view returns (address);
}

interface IYuzuAccountState {
    function tokenId() external view returns (uint256);
    function seedMode() external view returns (SeedMode);
    function guardianFrozen() external view returns (bool);
    function lossBudgetBps() external view returns (uint16);
    function lossUsedBps() external view returns (uint256);
    function lossStamp() external view returns (uint256);
    function aiSessionExpiry() external view returns (uint256);
    function slot4DailyFeeCap() external view returns (uint256);
    function slot4FeeUsedToday() external view returns (uint256);
    function slot4FeeDayStamp() external view returns (uint256);
}

/// @title YuzuAccountCompanion - Contract 17 (split out of YuzuAccount.sol to fit the 24,576-byte EIP-170 limit)
/// @notice One shared, non-upgradeable helper for every YUZU-98 vault. It has no owner, no admin and no storage.
///         The vault reaches it with ordinary calls only (never delegatecall), so it cannot touch vault storage.
///         It holds five jobs that do not need to live in the vault's own bytecode:
///         1. Guardian EIP-712 hashing and signature recovery (view only; the vault still compares the signer).
///         2. Routing a desk fee the vault has already sent here (WETH split 80/20, other assets to the fee escrow).
///         3. Routing a Seed Raid salvage share the vault has already sent here (swap to WETH for the reward pool,
///            or the Treasury salvage escrow when the feed is stale or the swap fails).
///         4. Splitting a Slot-4 run fee the vault has already sent here (80% author vault, 20% reward pool).
///         5. Running the swap leg of a vault swap on tokens the vault has already sent here (Fences F2, F3, F4, F6
///            and F8 and the 0.25% desk fee) and paying the output back to the caller.
///         plus the read-only vault telemetry view. The route functions only ever move the amount named in the
///         call out of this contract's own balance, so they are safe to leave permissionless.
contract YuzuAccountCompanion {
    using SafeERC20 for IERC20;

    uint256 public constant SALVAGE_MIN_OUT_BPS = 9850;        // 98.50% oracle minOut on the salvage swap
    uint256 public constant DESK_FEE_DISTRIBUTOR_BPS = 8000;   // desk fee: 80% reward pool, 20% buyback
    uint256 public constant RUN_FEE_AUTHOR_BPS = 8000;         // run fee: 80% author vault, 20% reward pool

    // The vault's limits and Tier-3 action codes, copied verbatim from YuzuAccount.sol, which keeps them internal
    // to save bytecode. Read them here.
    uint256 public constant FENCE_F3_MAX_EXPOSURE_BPS = 2000;      // 20.00% of Liquid NAV per swap
    uint256 public constant FENCE_F5_MIN_NAV_BPS = 9900;           // 99.00% per-trade NAV invariant (1.00% max loss)
    uint256 public constant AUTO_COMPOUND_MIN_NAV_BPS = 9950;      // 99.50% auto-compound NAV invariant (0.50% max loss)
    uint256 public constant AUTO_COMPOUND_MIN_WETH = 0.001 ether;  // 0.001 WETH threshold for onRewardPaid
    uint256 public constant DESK_FEE_BPS = 25;                     // 0.25% in-vault desk fee
    uint16 public constant DEFAULT_LOSS_BUDGET_BPS = 300;          // 3.00% default 24h Loss Budget
    uint16 public constant MIN_LOSS_BUDGET_BPS = 50;               // 0.50% min
    uint16 public constant MAX_LOSS_BUDGET_BPS = 500;              // 5.00% max
    uint16 public constant MAX_FAST_LANE_BPS = 1000;               // 10.00% max 24h Fast-Lane allowance
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant TIMELOCK_EXPIRY = 7 days;
    uint256 public constant GUARDIAN_ROTATION_DELAY = 7 days;
    uint256 public constant SLOT4_COOLDOWN = 24 hours;
    uint8 public constant ACTION_WITHDRAW_ERC20 = 1;
    uint8 public constant ACTION_RESCUE_ASSET = 2;
    uint8 public constant ACTION_EJECT_NFT = 3;
    uint8 public constant ACTION_SEED_RAID = 4;
    uint8 public constant ACTION_BOLT_FOR_SALE = 5;
    uint8 public constant ACTION_RAISE_LIMITS = 6;
    uint8 public constant ACTION_SET_RECOVERY = 7;
    uint8 public constant ACTION_ROTATE_GUARDIAN = 8;
    uint8 public constant ACTION_POST_ROM_BOND = 9;
    uint8 public constant ACTION_RECOVERY_TRANSFER = 10;
    uint8 public constant ACTION_LOOSEN_DESK_POLICY = 11;

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 public constant GUARDIAN_AUTH_TYPEHASH = keccak256(
        "GuardianAuth(uint8 actionType,address target,address asset,uint256 amount,bytes32 extraData,uint256 guardianNonce,uint256 guardianEpoch,uint256 deadline)"
    );

    IYuzu98v2Minimal public immutable mainframe;
    IYuzuNavLensMinimal public immutable lens;
    IYuzuRegistryMinimal public immutable registry;
    IYuzuSocketBayMinimal public immutable socketBay;
    address public immutable distributor;
    IYuzuTreasuryMinimal public immutable treasury;
    IERC20 public immutable weth;
    IERC20 public immutable yuzuToken;

    error ZeroAddress();
    error OnlySelf();
    error SalvageQuoteZero();
    error SalvageSwapShort();
    error SwapNotFunded();
    error FenceF3ExposureCapExceeded();
    error FenceF8OutputInsufficient();

    constructor(
        address mainframe_,
        address lens_,
        address registry_,
        address socketBay_,
        address distributor_,
        address treasury_,
        address weth_,
        address yuzuToken_
    ) {
        if (
            mainframe_ == address(0) || lens_ == address(0) || registry_ == address(0) || socketBay_ == address(0)
                || distributor_ == address(0) || treasury_ == address(0) || weth_ == address(0)
                || yuzuToken_ == address(0)
        ) revert ZeroAddress();
        mainframe = IYuzu98v2Minimal(mainframe_);
        lens = IYuzuNavLensMinimal(lens_);
        registry = IYuzuRegistryMinimal(registry_);
        socketBay = IYuzuSocketBayMinimal(socketBay_);
        distributor = distributor_;
        treasury = IYuzuTreasuryMinimal(treasury_);
        weth = IERC20(weth_);
        yuzuToken = IERC20(yuzuToken_);
    }

    // =========================================================================
    // 0. TIER-1 SWAP LEG (Fences F2, F3, F4, F6, F8 and the 0.25% desk fee): the vault transfers `amountIn` here first
    // =========================================================================

    /// @notice Swaps exactly `amountIn` of `tokenIn` that the caller has already sent here and pays the output back to
    ///         the caller. The caller gives no approval, so no more than `amountIn` can ever be spent (Fence F8 input).
    ///         The vault keeps its own checks after this returns: seed reserve, the NAV invariant and the Loss Budget.
    ///         `navBeforeUsd` is the caller's Liquid NAV before it sent the tokens; a caller that misreports it only
    ///         loosens its own exposure cap.
    function swapFor(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOutBps,
        bool chargeDeskFee,
        uint256 navBeforeUsd
    ) external returns (uint256 amountOut) {
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        if (inBefore < amountIn) revert SwapNotFunded();

        lens.requireFresh(tokenIn);
        lens.requireFresh(tokenOut);                                                  // Fence F4
        IYuzuRegistryMinimal.Route memory r = registry.routeFor(tokenIn, tokenOut);   // Fence F2
        if (lens.valueOf(tokenIn, amountIn) * 10000 > navBeforeUsd * FENCE_F3_MAX_EXPOSURE_BPS) {
            revert FenceF3ExposureCapExceeded();                                      // Fence F3 (20.00% cap)
        }

        uint256 swapAmountIn = amountIn;
        bool feeTakenPre = false;

        // 0.25% desk fee: taken from the crypto leg only (never in an xStock)
        if (chargeDeskFee && registry.isCryptoAsset(tokenIn)) {
            uint256 feeIn = (amountIn * DESK_FEE_BPS) / 10000;
            if (feeIn > 0) {
                swapAmountIn = amountIn - feeIn;
                routeDeskFee(tokenIn, feeIn);
                feeTakenPre = true;
            }
        }

        uint256 minOut = (lens.quote(tokenIn, tokenOut, swapAmountIn) * minOutBps) / 10000;
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(r.router, swapAmountIn);
        IYuzuSwapRouter(r.router).swapExactIn(tokenIn, tokenOut, swapAmountIn, minOut, address(this), r.path);
        IERC20(tokenIn).forceApprove(r.router, 0);                                    // Fence F6

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < minOut) revert FenceF8OutputInsufficient();                   // Fence F8

        if (chargeDeskFee && !feeTakenPre && registry.isCryptoAsset(tokenOut)) {
            uint256 feeOut = (amountOut * DESK_FEE_BPS) / 10000;
            if (feeOut > 0) {
                routeDeskFee(tokenOut, feeOut);
                amountOut -= feeOut;
            }
        }

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        // Anything the router did not take goes straight back to the caller
        uint256 inLeft = IERC20(tokenIn).balanceOf(address(this)) - (inBefore - amountIn);
        if (inLeft > 0) IERC20(tokenIn).safeTransfer(msg.sender, inLeft);
    }

    // =========================================================================
    // 1. GUARDIAN EIP-712 (view only)
    // =========================================================================

    /// @notice The EIP-712 digest a vault's Cold Guardian signs. The domain is bound to `vault`, not to this contract.
    function hashGuardianAuth(
        address vault,
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData,
        uint256 guardianNonce,
        uint256 guardianEpoch,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes("YuzuAccount")), keccak256(bytes("1")), block.chainid, vault
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                GUARDIAN_AUTH_TYPEHASH,
                actionType,
                target,
                asset,
                amount,
                extraData,
                guardianNonce,
                guardianEpoch,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @notice Recovers the signer of a Guardian authorization. Reverts on a malformed signature.
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
    ) external view returns (address) {
        return ECDSA.recover(
            hashGuardianAuth(
                vault, actionType, target, asset, amount, extraData, guardianNonce, guardianEpoch, deadline
            ),
            sig
        );
    }

    /// @notice The `extraData` value a Guardian signs (or the Owner queues) for a Slot-2 desk-policy loosening.
    function deskPolicyHash(
        address[] calldata allowedAssets,
        uint16 minStrikeBps,
        uint16 minPremiumBps,
        uint32 maxExpirySeconds,
        uint16 maxExposureShareBps
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(allowedAssets, minStrikeBps, minPremiumBps, maxExpirySeconds, maxExposureShareBps));
    }

    // =========================================================================
    // 2. DESK FEE (Section 2.4): the vault transfers `amount` here first
    // =========================================================================

    function routeDeskFee(address asset, uint256 amount) public {
        if (asset == address(weth)) {
            uint256 toDist = (amount * DESK_FEE_DISTRIBUTOR_BPS) / 10000;
            weth.forceApprove(address(treasury), amount);
            treasury.recordProtocolFeeWeth(toDist, amount - toDist);
        } else {
            IERC20(asset).safeTransfer(address(treasury), amount);
            treasury.receiveFeeEscrow(asset, amount);
        }
    }

    // =========================================================================
    // 3. SEED RAID SALVAGE (Section 9.1): the vault transfers `amount` here first
    // =========================================================================

    function routeSalvage(address asset, uint256 amount) external {
        if (asset == address(weth)) {
            weth.safeTransfer(distributor, amount);
            return;
        }
        // Any failure inside the swap leg (stale feed, no route, router revert, short output) is rolled back
        // as one unit and the raw salvage token goes to the Treasury salvage escrow instead.
        try this.swapSalvageToWeth(asset, amount) {}
        catch {
            IERC20(asset).safeTransfer(address(treasury), amount);
            treasury.receiveSalvageEscrow(asset, amount);
        }
    }

    function swapSalvageToWeth(address asset, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        lens.requireFresh(asset);
        lens.requireFresh(address(weth));
        uint256 minWeth = (lens.quote(asset, address(weth), amount) * SALVAGE_MIN_OUT_BPS) / 10000;
        if (minWeth == 0) revert SalvageQuoteZero();

        IYuzuRegistryMinimal.Route memory r = registry.routeFor(asset, address(weth));
        uint256 before = weth.balanceOf(distributor);
        IERC20(asset).forceApprove(r.router, amount);
        IYuzuSwapRouter(r.router).swapExactIn(asset, address(weth), amount, minWeth, distributor, r.path);
        IERC20(asset).forceApprove(r.router, 0);
        if (weth.balanceOf(distributor) - before < minWeth) revert SalvageSwapShort();
    }

    // =========================================================================
    // 4. SLOT-4 RUN FEE (Section 6.4): the vault transfers `runFee` $YUZU here first
    // =========================================================================

    function routeRunFee(uint256 authorTokenId, uint256 runFee) external {
        address authorVault = address(0);
        if (socketBay.romBond(authorTokenId) > 0) {
            try mainframe.ownerOf(authorTokenId) returns (address) {
                try IYuzuVaultDirectory(address(mainframe)).getVaultAddress(authorTokenId) returns (address v) {
                    authorVault = v;
                } catch {}
            } catch {}
        }

        if (authorVault != address(0)) {
            uint256 authorShare = (runFee * RUN_FEE_AUTHOR_BPS) / 10000;
            yuzuToken.safeTransfer(authorVault, authorShare);
            yuzuToken.safeTransfer(distributor, runFee - authorShare);
        } else {
            yuzuToken.safeTransfer(distributor, runFee);
        }
    }

    // =========================================================================
    // 5. VAULT TELEMETRY (read-only, moved out of YuzuAccount)
    // =========================================================================

    function accountTelemetry(address vault)
        external
        view
        returns (
            uint256 currentLossUsedBps,
            uint16 currentLossBudgetBps,
            SeedMode mode,
            bool isFrozen,
            bool gutted,
            BoltState bolt,
            uint256 aiExpiry,
            uint256 slot4FeeRemainingToday,
            bool anyStale
        )
    {
        IYuzuAccountState acc = IYuzuAccountState(vault);
        uint256 id = acc.tokenId();

        currentLossBudgetBps = acc.lossBudgetBps();
        uint256 used = acc.lossUsedBps();
        uint256 drained = (uint256(currentLossBudgetBps) * (block.timestamp - acc.lossStamp())) / 1 days;
        currentLossUsedBps = used > drained ? used - drained : 0;

        mode = acc.seedMode();
        isFrozen = acc.guardianFrozen();
        gutted = mainframe.isGutted(id);
        bolt = mainframe.boltState(id);
        aiExpiry = acc.aiSessionExpiry();

        uint256 usedToday = acc.slot4FeeDayStamp() == block.timestamp / 1 days ? acc.slot4FeeUsedToday() : 0;
        uint256 cap = acc.slot4DailyFeeCap();
        slot4FeeRemainingToday = cap > usedToday ? cap - usedToday : 0;

        (,, anyStale) = lens.tryGetNav(vault);
    }
}
