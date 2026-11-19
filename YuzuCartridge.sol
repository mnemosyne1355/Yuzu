// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    BoltState,
    IWETH,
    IYuzu98v2Minimal,
    IYuzuAccountMinimal,
    IYuzuSocketBayMinimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuTreasuryMinimal,
    IOptionsVenueAdapter,
    ILendingMarketAdapter
} from "./interfaces/IYuzuPhase5Interfaces.sol";

/// @title YuzuCartridge — Contract 05 of 16 (YUZU-98 Master Specification v4.9, Sections 2.4, 6.2, 11)
/// @notice Non-upgradeable Slot-2 Covered-Call & Cash-Leg Lending Cartridge.
///         Stores `deskPolicy[tokenId]` per unit to keep `YuzuAccount.sol` well under the 24,576-byte EIP-170 limit.
///         Enforces all 8 Slot-2 hardware rules:
///         1. Escrow that can only pay the vault (listed in `YuzuRegistry.sol` via 48h timelock).
///         2. Covered only & $50 (`minCollateralUsd`) floor per call; factory seed (`seedUnits`) can never be collateral.
///         3. Strike floor >= 102% (10200 bps) of fresh oracle price; max expiry <= 7 days.
///         4. Exposure cap: <= 20% of Liquid NAV per RAM tier (20% T1 .. 100% T5) * deskPolicy.maxExposureShareBps.
///         5. Premium paid on the spot in a priced asset; 10% skimmed immediately (50% Distributor, 50% Buyback), 90% to vault.
///         6. Valuation helper (`openCallCollateralValuationUsd`) valuing open collateral at `min(oraclePrice, strikePrice)`.
///         7. `hasOpenCalls(tokenId)` blocks `boltForSale` while any call is open (`guardianRecoveryTransfer` exempt).
///         8. Cash-leg lending (Owner-only) for idle stablecoins above `seedUnits`, with 10% skim on realized interest.
contract YuzuCartridge is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_COLLATERAL_USD = 50e18;        // $50 minimum collateral per call (v4.9 rule)
    uint16 public constant HARD_MIN_STRIKE_BPS = 10200;        // 102.00% strike floor
    uint32 public constant HARD_MAX_DURATION = 7 days;         // 7-day maximum call expiry
    uint256 public constant TIER_EXPOSURE_STEP_BPS = 2000;     // 20.00% of Liquid NAV per RAM tier
    uint256 public constant PROTOCOL_SKIM_BPS = 1000;          // 10.00% skim on option premiums & lending interest

    struct DeskPolicy {
        uint16 minStrikeBps;          // >= 10200 (102.00%)
        uint16 minPremiumBps;         // Minimum gross premium as bps of collateral oracle value
        uint32 maxExpirySeconds;      // <= 7 days (604,800 seconds)
        uint16 maxExposureShareBps;   // 0..10000 share of the unit's RAM-tier exposure cap
    }

    struct OpenCall {
        uint256 callId;
        address venue;
        uint256 venueCallId;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 strikePrice18;
        uint64 expiry;
        bool settled;
    }

    struct LendingPosition {
        uint256 principalSupplied;
        uint256 receiptShares;
    }

    IYuzu98v2Minimal public immutable mainframe;
    IYuzuSocketBayMinimal public immutable socketBay;
    IYuzuNavLensMinimal public immutable lens;
    IYuzuRegistryMinimal public immutable registry;
    IYuzuTreasuryMinimal public immutable treasury;
    IWETH public immutable weth;

    // Per-unit Slot-2 Desk Policy (cleared on every NFT transfer)
    mapping(uint256 tokenId => DeskPolicy) public deskPolicy;
    mapping(uint256 tokenId => mapping(address asset => bool)) public policyAssetAllowed;
    mapping(uint256 tokenId => address[]) private _policyAssetList;

    // Open covered calls per unit
    uint256 public nextCallId = 1;
    mapping(uint256 tokenId => OpenCall[]) private _unitCalls;

    // Cash-leg lending principal & receipt tracking: tokenId => venue => underlyingAsset => LendingPosition
    mapping(uint256 tokenId => mapping(address venue => mapping(address asset => LendingPosition))) public lendingPositions;

    event DeskPolicyUpdated(
        uint256 indexed tokenId,
        uint16 minStrikeBps,
        uint16 minPremiumBps,
        uint32 maxExpirySeconds,
        uint16 maxExposureShareBps,
        bool isLoosening
    );
    event DeskPolicyCleared(uint256 indexed tokenId);
    event CoveredCallWritten(
        uint256 indexed tokenId,
        uint256 indexed callId,
        address indexed venue,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 strikePrice18,
        uint64 expiry,
        address premiumAsset,
        uint256 netPremiumToVault,
        uint256 protocolSkim
    );
    event CoveredCallSettled(uint256 indexed tokenId, uint256 indexed callId, address venue);
    event CashLegSupplied(uint256 indexed tokenId, address indexed venue, address indexed asset, uint256 amount, uint256 shares);
    event CashLegWithdrawn(
        uint256 indexed tokenId,
        address indexed venue,
        address indexed asset,
        uint256 netToVault,
        uint256 interestSkim
    );

    error ZeroAddress();
    error OnlyMainframe();
    error OnlyUnitVault();
    error OnlyOwner();
    error OnlyOwnerOrAi();
    error VaultNotLive();
    error InvalidDeskPolicy();
    error PolicyChangeIsLoosening();
    error VenueNotApproved();
    error AssetNotAllowedByPolicy(address asset);
    error CollateralBelowMinUsd(uint256 collateralUsd, uint256 minRequired);
    error SeedReserveBreached();
    error StrikeBelowPolicyMinimum(uint256 strikePrice18, uint256 requiredStrike18);
    error ExpiryExceedsPolicyMaximum(uint64 expiry, uint256 maxAllowedExpiry);
    error ExposureCapExceeded(uint256 totalCollateralUsd, uint256 maxAllowedUsd);
    error PremiumAssetNotPriced(address premiumAsset);
    error VenueCollateralNotTaken();
    error PremiumBelowPolicyMinimum(uint256 premiumUsd, uint256 requiredPremiumUsd);
    error CallAlreadySettled();
    error InsufficientLendingPosition();

    constructor(
        address mainframe_,
        address socketBay_,
        address lens_,
        address registry_,
        address treasury_,
        address weth_
    ) {
        if (
            mainframe_ == address(0) || socketBay_ == address(0) || lens_ == address(0)
                || registry_ == address(0) || treasury_ == address(0) || weth_ == address(0)
        ) revert ZeroAddress();

        mainframe = IYuzu98v2Minimal(mainframe_);
        socketBay = IYuzuSocketBayMinimal(socketBay_);
        lens = IYuzuNavLensMinimal(lens_);
        registry = IYuzuRegistryMinimal(registry_);
        treasury = IYuzuTreasuryMinimal(treasury_);
        weth = IWETH(weth_);
    }

    // =========================================================================
    // 1. DESK POLICY MANAGEMENT (Tier-3 Loosening / Instant Owner Tightening)
    // =========================================================================

    /// @notice Called by the unit's vault after Tier-3 authorization (Guardian EIP-712 co-sign or 48h queue)
    ///         to set or loosen the unit's Slot-2 Desk Policy.
    function setPolicyFromVaultTier3(
        uint256 tokenId,
        address[] calldata allowedAssets,
        uint16 minStrikeBps,
        uint16 minPremiumBps,
        uint32 maxExpirySeconds,
        uint16 maxExposureShareBps
    ) external {
        if (msg.sender != mainframe.getVaultAddress(tokenId)) revert OnlyUnitVault();
        _validatePolicyBounds(minStrikeBps, maxExpirySeconds, maxExposureShareBps);

        _clearAllowedAssets(tokenId);
        for (uint256 i = 0; i < allowedAssets.length; i++) {
            address a = allowedAssets[i];
            if (!registry.isPricedAsset(a)) revert InvalidDeskPolicy();
            if (!policyAssetAllowed[tokenId][a]) {
                policyAssetAllowed[tokenId][a] = true;
                _policyAssetList[tokenId].push(a);
            }
        }

        deskPolicy[tokenId] = DeskPolicy({
            minStrikeBps: minStrikeBps,
            minPremiumBps: minPremiumBps,
            maxExpirySeconds: maxExpirySeconds,
            maxExposureShareBps: maxExposureShareBps
        });

        emit DeskPolicyUpdated(tokenId, minStrikeBps, minPremiumBps, maxExpirySeconds, maxExposureShareBps, true);
    }

    /// @notice Instant Owner-only tightening of the unit's Slot-2 Desk Policy (can remove assets, raise minStrike
    ///         or minPremium, shorten maxExpiry, or lower maxExposureShareBps). Reverts if any field is loosened.
    function tightenDeskPolicy(
        uint256 tokenId,
        address[] calldata newAllowedAssets,
        uint16 newMinStrikeBps,
        uint16 newMinPremiumBps,
        uint32 newMaxExpirySeconds,
        uint16 newMaxExposureShareBps
    ) external {
        if (msg.sender != mainframe.ownerOf(tokenId)) revert OnlyOwner();
        DeskPolicy memory cur = deskPolicy[tokenId];

        if (newMaxExposureShareBps == 0) {
            _clearAllowedAssets(tokenId);
            delete deskPolicy[tokenId];
            emit DeskPolicyCleared(tokenId);
            return;
        }

        _validatePolicyBounds(newMinStrikeBps, newMaxExpirySeconds, newMaxExposureShareBps);

        if (
            cur.maxExposureShareBps == 0 || newMinStrikeBps < cur.minStrikeBps || newMinPremiumBps < cur.minPremiumBps
                || newMaxExpirySeconds > cur.maxExpirySeconds || newMaxExposureShareBps > cur.maxExposureShareBps
        ) {
            revert PolicyChangeIsLoosening();
        }

        // Every asset in newAllowedAssets must already be allowed in the current policy
        for (uint256 i = 0; i < newAllowedAssets.length; i++) {
            if (!policyAssetAllowed[tokenId][newAllowedAssets[i]]) {
                revert PolicyChangeIsLoosening();
            }
        }

        _clearAllowedAssets(tokenId);
        for (uint256 i = 0; i < newAllowedAssets.length; i++) {
            address a = newAllowedAssets[i];
            if (!policyAssetAllowed[tokenId][a]) {
                policyAssetAllowed[tokenId][a] = true;
                _policyAssetList[tokenId].push(a);
            }
        }

        deskPolicy[tokenId] = DeskPolicy({
            minStrikeBps: newMinStrikeBps,
            minPremiumBps: newMinPremiumBps,
            maxExpirySeconds: newMaxExpirySeconds,
            maxExposureShareBps: newMaxExposureShareBps
        });

        emit DeskPolicyUpdated(
            tokenId, newMinStrikeBps, newMinPremiumBps, newMaxExpirySeconds, newMaxExposureShareBps, false
        );
    }

    /// @notice Called by `Yuzu98v2._update` on every sale or recovery transfer to reset the unit's Desk Policy.
    function clearPolicyOnTransfer(uint256 tokenId) external {
        if (msg.sender != address(mainframe)) revert OnlyMainframe();
        _clearAllowedAssets(tokenId);
        delete deskPolicy[tokenId];
        emit DeskPolicyCleared(tokenId);
    }

    function getAllowedAssets(uint256 tokenId) external view returns (address[] memory) {
        return _policyAssetList[tokenId];
    }

    // =========================================================================
    // 2. COVERED-CALL WRITING & SETTLEMENT (Owner or AI Key Inside Policy)
    // =========================================================================

    function writeCoveredCall(
        uint256 tokenId,
        address venue,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 strikePrice18,
        uint64 expiry,
        address premiumAsset,
        uint256 minGrossPremium
    ) external nonReentrant returns (uint256 callId) {
        address vault = _requireLiveAndAuthorized(tokenId, true);

        // Rule 1: Venue must be listed, unpaused, and an options venue (not a lending market)
        (bool isListed, bool isPaused, bool isLendingMarket,) = registry.venues(venue);
        if (!isListed || isPaused || isLendingMarket) revert VenueNotApproved();
        if (!registry.isPricedAsset(premiumAsset)) revert PremiumAssetNotPriced(premiumAsset);

        // Check Desk Policy
        DeskPolicy memory pol = deskPolicy[tokenId];
        if (pol.maxExposureShareBps == 0 || !policyAssetAllowed[tokenId][collateralAsset]) {
            revert AssetNotAllowedByPolicy(collateralAsset);
        }

        // Rule 2: Fresh prices, $50 minCollateralUsd floor, and non-seed collateral check
        uint256 spotPrice18 = lens.requireFresh(collateralAsset);
        lens.requireFresh(premiumAsset);

        uint256 collateralUsd = lens.valueOf(collateralAsset, collateralAmount);
        if (collateralUsd < MIN_COLLATERAL_USD) {
            revert CollateralBelowMinUsd(collateralUsd, MIN_COLLATERAL_USD);
        }

        uint256 vaultBal = IERC20(collateralAsset).balanceOf(vault);
        uint256 requiredSeed = IYuzuAccountMinimal(vault).seedUnits(collateralAsset);
        if (vaultBal < collateralAmount + requiredSeed) revert SeedReserveBreached();

        // Rule 3: Strike floor (>= policy.minStrikeBps >= 102%) and expiry (<= policy.maxExpirySeconds <= 7 days)
        uint256 minRequiredStrike18 = (spotPrice18 * pol.minStrikeBps) / 10000;
        if (strikePrice18 < minRequiredStrike18) {
            revert StrikeBelowPolicyMinimum(strikePrice18, minRequiredStrike18);
        }
        if (expiry <= block.timestamp || expiry > block.timestamp + pol.maxExpirySeconds) {
            revert ExpiryExceedsPolicyMaximum(expiry, block.timestamp + pol.maxExpirySeconds);
        }

        // Rule 4: RAM-scaled exposure cap (20% per RAM tier) * deskPolicy.maxExposureShareBps
        uint8 tier = socketBay.ramTier(tokenId);
        uint256 liquidNavUsd = lens.getLiquidNavUsd(vault) + openCallCollateralValuationUsd(tokenId);
        uint256 tierCapBps = uint256(tier) * TIER_EXPOSURE_STEP_BPS; // 2000..10000 bps
        uint256 effectiveCapUsd = (((liquidNavUsd * tierCapBps) / 10000) * pol.maxExposureShareBps) / 10000;

        uint256 existingOpenUsd = _activeCollateralOracleUsd(tokenId);
        if (existingOpenUsd + collateralUsd > effectiveCapUsd) {
            revert ExposureCapExceeded(existingOpenUsd + collateralUsd, effectiveCapUsd);
        }

        // Pull collateral from vault into Cartridge and execute call on Venue Adapter
        IYuzuAccountMinimal(vault).pullSlot2Asset(collateralAsset, collateralAmount, address(this));
        IERC20(collateralAsset).forceApprove(venue, collateralAmount);

        uint256 premBefore = IERC20(premiumAsset).balanceOf(address(this));
        // If the premium is paid in the collateral asset, the venue pulls the collateral out of this contract
        // during writeCall, so the baseline must exclude it or the subtraction below underflows.
        if (premiumAsset == collateralAsset) premBefore -= collateralAmount;
        (uint256 venueCallId,) = IOptionsVenueAdapter(venue).writeCall(
            vault, collateralAsset, collateralAmount, strikePrice18, expiry, premiumAsset, minGrossPremium
        );
        // The venue must take the full collateral: a partial pull would be misread as premium or left stranded here.
        if (IERC20(collateralAsset).allowance(address(this), venue) != 0) revert VenueCollateralNotTaken();
        IERC20(collateralAsset).forceApprove(venue, 0);

        uint256 grossPremium = IERC20(premiumAsset).balanceOf(address(this)) - premBefore;
        uint256 grossPremiumUsd = lens.valueOf(premiumAsset, grossPremium);
        uint256 minPremiumUsd = (collateralUsd * pol.minPremiumBps) / 10000;
        if (grossPremium < minGrossPremium || grossPremiumUsd < minPremiumUsd) {
            revert PremiumBelowPolicyMinimum(grossPremiumUsd, minPremiumUsd);
        }

        // Rule 5: 10% protocol skim (50% Distributor / 50% Buyback), 90% paid into the vault on the spot
        uint256 skim = (grossPremium * PROTOCOL_SKIM_BPS) / 10000;
        uint256 netToVault = grossPremium - skim;

        if (skim > 0) _routeSlot2Skim(premiumAsset, skim);
        if (netToVault > 0) IERC20(premiumAsset).safeTransfer(vault, netToVault);

        callId = nextCallId++;
        _unitCalls[tokenId].push(
            OpenCall({
                callId: callId,
                venue: venue,
                venueCallId: venueCallId,
                collateralAsset: collateralAsset,
                collateralAmount: collateralAmount,
                strikePrice18: strikePrice18,
                expiry: expiry,
                settled: false
            })
        );

        emit CoveredCallWritten(
            tokenId,
            callId,
            venue,
            collateralAsset,
            collateralAmount,
            strikePrice18,
            expiry,
            premiumAsset,
            netToVault,
            skim
        );
    }

    /// @notice Settles an expired call on the venue so unexercised collateral returns to `vault` and `hasOpenCalls` clears.
    /// @dev Uses swap-and-pop on `_unitCalls[tokenId]` so settled calls never accumulate unbounded loop gas.
    function settleExpiredCall(uint256 tokenId, uint256 callIndex) external nonReentrant {
        OpenCall[] storage calls = _unitCalls[tokenId];
        if (callIndex >= calls.length) revert CallAlreadySettled();
        OpenCall memory c = calls[callIndex];
        if (c.settled) revert CallAlreadySettled();

        address vault = mainframe.getVaultAddress(tokenId);
        bool done = IOptionsVenueAdapter(c.venue).settleOrExpireCall(c.venueCallId, vault);
        if (done) {
            uint256 lastIdx = calls.length - 1;
            if (callIndex != lastIdx) {
                calls[callIndex] = calls[lastIdx];
            }
            calls.pop();
            emit CoveredCallSettled(tokenId, c.callId, c.venue);
        }
    }

    /// @notice Rule 7: O(1) check returning true if `tokenId` has any unsettled covered call (blocks `boltForSale`).
    function hasOpenCalls(uint256 tokenId) external view returns (bool) {
        return _unitCalls[tokenId].length > 0;
    }

    /// @notice Returns the number of currently active (unsettled) covered calls for `tokenId`.
    function openCallCount(uint256 tokenId) external view returns (uint256) {
        return _unitCalls[tokenId].length;
    }

    /// @notice Rule 6: Values collateral under open calls at `min(oraclePrice, strikePrice)` per token.
    function openCallCollateralValuationUsd(uint256 tokenId) public view returns (uint256 totalUsd18) {
        OpenCall[] storage calls = _unitCalls[tokenId];
        for (uint256 i = 0; i < calls.length; i++) {
            OpenCall storage c = calls[i];
            if (c.settled) continue;
            uint256 oracleUsd = lens.valueOf(c.collateralAsset, c.collateralAmount);
            uint256 strikeUsd = (c.collateralAmount * c.strikePrice18) / (10 ** _decimalsOf(c.collateralAsset));
            totalUsd18 += oracleUsd < strikeUsd ? oracleUsd : strikeUsd;
        }
    }

    // =========================================================================
    // 3. CASH-LEG LENDING (Rule 8, Owner-Only, 10% Interest Skim)
    // =========================================================================

    function supplyToCashLeg(uint256 tokenId, address venue, address asset, uint256 amount)
        external
        nonReentrant
        returns (uint256 sharesMinted)
    {
        address vault = _requireLiveAndAuthorized(tokenId, false); // Owner only

        if (amount == 0) revert InsufficientLendingPosition();

        (bool isListed, bool isPaused, bool isLendingMarket, address receiptToken) = registry.venues(venue);
        if (!isListed || isPaused || !isLendingMarket || receiptToken == address(0)) revert VenueNotApproved();
        if (!registry.isPricedAsset(receiptToken)) revert VenueNotApproved();

        uint256 vaultBal = IERC20(asset).balanceOf(vault);
        uint256 requiredSeed = IYuzuAccountMinimal(vault).seedUnits(asset);
        if (vaultBal < amount + requiredSeed) revert SeedReserveBreached();

        IYuzuAccountMinimal(vault).pullSlot2Asset(asset, amount, address(this));
        IERC20(asset).forceApprove(venue, amount);
        uint256 receiptBefore = IERC20(receiptToken).balanceOf(vault);
        ILendingMarketAdapter(venue).supplyForVault(asset, amount, vault);
        IERC20(asset).forceApprove(venue, 0);

        sharesMinted = IERC20(receiptToken).balanceOf(vault) - receiptBefore;
        if (sharesMinted == 0) revert InsufficientLendingPosition();

        LendingPosition storage pos = lendingPositions[tokenId][venue][asset];
        pos.principalSupplied += amount;
        pos.receiptShares += sharesMinted;

        emit CashLegSupplied(tokenId, venue, asset, amount, sharesMinted);
    }

    function withdrawFromCashLeg(uint256 tokenId, address venue, address asset, uint256 sharesToRedeem)
        external
        nonReentrant
        returns (uint256 netToVault, uint256 interestSkim)
    {
        if (msg.sender != mainframe.ownerOf(tokenId)) revert OnlyOwner();
        address vault = mainframe.getVaultAddress(tokenId);

        (bool isListed, , bool isLendingMarket, address receiptToken) = registry.venues(venue);
        if (!isListed || !isLendingMarket) revert VenueNotApproved();

        LendingPosition storage pos = lendingPositions[tokenId][venue][asset];
        if (sharesToRedeem == 0 || sharesToRedeem > pos.receiptShares) revert InsufficientLendingPosition();

        // Pro-rata principal reduction
        uint256 principalPortion = (pos.principalSupplied * sharesToRedeem) / pos.receiptShares;
        pos.principalSupplied -= principalPortion;
        pos.receiptShares -= sharesToRedeem;

        IYuzuAccountMinimal(vault).pullSlot2Asset(receiptToken, sharesToRedeem, address(this));
        IERC20(receiptToken).forceApprove(venue, sharesToRedeem);

        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        ILendingMarketAdapter(venue).withdrawForVault(asset, sharesToRedeem, address(this));
        IERC20(receiptToken).forceApprove(venue, 0);

        uint256 grossRedeemed = IERC20(asset).balanceOf(address(this)) - balBefore;
        if (grossRedeemed > principalPortion) {
            uint256 interestEarned = grossRedeemed - principalPortion;
            interestSkim = (interestEarned * PROTOCOL_SKIM_BPS) / 10000;
            if (interestSkim > 0) {
                _routeSlot2Skim(asset, interestSkim);
            }
        }

        netToVault = grossRedeemed - interestSkim;
        if (netToVault > 0) {
            IERC20(asset).safeTransfer(vault, netToVault);
        }

        emit CashLegWithdrawn(tokenId, venue, asset, netToVault, interestSkim);
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    function _requireLiveAndAuthorized(uint256 tokenId, bool allowAiKey) internal view returns (address vault) {
        if (mainframe.isGutted(tokenId) || mainframe.boltState(tokenId) != BoltState.UNBOLTED) {
            revert VaultNotLive();
        }
        vault = mainframe.getVaultAddress(tokenId);
        IYuzuAccountMinimal acc = IYuzuAccountMinimal(vault);
        if (acc.guardianFrozen()) revert VaultNotLive();

        address owner = mainframe.ownerOf(tokenId);
        if (msg.sender == owner) return vault;

        if (allowAiKey) {
            address ai = acc.aiSessionKey();
            if (ai != address(0) && msg.sender == ai && block.timestamp <= acc.aiSessionExpiry()) {
                return vault;
            }
            revert OnlyOwnerOrAi();
        }
        revert OnlyOwner();
    }

    function _validatePolicyBounds(uint16 minStrikeBps, uint32 maxExpirySeconds, uint16 maxExposureShareBps)
        internal
        pure
    {
        if (
            minStrikeBps < HARD_MIN_STRIKE_BPS || maxExpirySeconds == 0 || maxExpirySeconds > HARD_MAX_DURATION
                || maxExposureShareBps == 0 || maxExposureShareBps > 10000
        ) {
            revert InvalidDeskPolicy();
        }
    }

    function _clearAllowedAssets(uint256 tokenId) internal {
        address[] storage list = _policyAssetList[tokenId];
        for (uint256 i = 0; i < list.length; i++) {
            delete policyAssetAllowed[tokenId][list[i]];
        }
        delete _policyAssetList[tokenId];
    }

    function _activeCollateralOracleUsd(uint256 tokenId) internal view returns (uint256 totalUsd18) {
        OpenCall[] storage calls = _unitCalls[tokenId];
        for (uint256 i = 0; i < calls.length; i++) {
            if (!calls[i].settled) {
                totalUsd18 += lens.valueOf(calls[i].collateralAsset, calls[i].collateralAmount);
            }
        }
    }

    function _routeSlot2Skim(address asset, uint256 skimAmount) internal {
        if (asset == address(weth)) {
            uint256 toDist = skimAmount / 2;
            uint256 toBuyback = skimAmount - toDist;
            IERC20(address(weth)).forceApprove(address(treasury), skimAmount);
            treasury.recordProtocolFeeWeth(toDist, toBuyback);
        } else {
            IERC20(asset).safeTransfer(address(treasury), skimAmount);
            treasury.receiveSkimEscrow(asset, skimAmount);
        }
    }

    function _decimalsOf(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint8));
        return 18;
    }
}
