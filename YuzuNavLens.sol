// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    IAggregatorV3,
    PythPrice,
    IPyth,
    IERC4626Wrapper,
    IERC20MetadataMinimal,
    IERC721Minimal
} from "./interfaces/IYuzuPhase2Interfaces.sol";
import {YuzuRegistry} from "./YuzuRegistry.sol";

/// @title YuzuNavLens — Contract 07 of 16 (YUZU-98 Master Specification v4.9, Sections 5.2, 8)
/// @notice Non-upgradeable Chainlink + Pyth valuation engine.
///         - Never reads a DEX pool.
///         - Enforces Dual-anchored (<= 1.50% divergence, Chainlink primary + Pyth check) and Single-anchored rules.
///         - Applies ERC-4626 `convertToAssets()` multiplier once for wrapped xStocks (`isWrapper == true`).
///         - Enforces the v4.9 96-hour `HARD_STALE_CEILING` and registry pause zeroing inside `getLiquidNavUsd()`
///           so deprecated, paused, or >96h frozen feeds are valued at 0 and cannot bloat Fast-Lane or Fence F3 caps.
///         - `tryGetNav()` never reverts, returning `liquidNav`, `displayNav`, and `anyStale` for on-chain SVG rendering.
contract YuzuNavLens {
    uint256 public constant HARD_STALE_CEILING = 96 hours;
    uint256 public constant MAX_ORACLE_DIVERGENCE_BPS = 150; // 1.50%

    YuzuRegistry public immutable registry;
    IPyth public immutable pyth;

    error ZeroAddress();
    error AssetNotPriced(address asset);
    error AssetIsPaused(address asset);
    error OraclePriceStale(address asset, uint256 updatedAt, uint256 maxAge);
    error InvalidOraclePrice(address asset);
    error OracleDivergenceExceeded(address asset, uint256 chainlinkPrice, uint256 pythPrice);

    constructor(address registry_, address pyth_) {
        if (registry_ == address(0) || pyth_ == address(0)) revert ZeroAddress();
        registry = YuzuRegistry(registry_);
        pyth = IPyth(pyth_);
    }

    /// @notice Fence F4 check: reverts if `asset` is not registered, is paused, has a stale feed (> maxAge),
    ///         or (for Dual-anchored assets) if Chainlink and Pyth diverge by more than 1.50% (150 bps).
    function requireFresh(address asset) public view returns (uint256 price18) {
        YuzuRegistry.AssetConfig memory cfg = registry.getAssetConfig(asset);
        if (!cfg.isRegistered) revert AssetNotPriced(asset);
        if (cfg.isPaused) revert AssetIsPaused(asset);

        bool hasCl = cfg.chainlinkFeed != address(0);
        bool hasPyth = cfg.pythFeedId != bytes32(0);

        uint256 clPrice;
        uint256 clUpdated;
        if (hasCl) {
            bool ok;
            (ok, clPrice, clUpdated) = _tryReadChainlink(cfg.chainlinkFeed);
            if (!ok || clPrice == 0) revert InvalidOraclePrice(asset);
            if (block.timestamp > clUpdated && block.timestamp - clUpdated > cfg.maxAge) {
                revert OraclePriceStale(asset, clUpdated, cfg.maxAge);
            }
        }

        uint256 pythPrice;
        uint256 pythUpdated;
        if (hasPyth) {
            bool ok;
            (ok, pythPrice, pythUpdated) = _tryReadPyth(cfg.pythFeedId);
            if (!ok || pythPrice == 0) revert InvalidOraclePrice(asset);
            if (block.timestamp > pythUpdated && block.timestamp - pythUpdated > cfg.maxAge) {
                revert OraclePriceStale(asset, pythUpdated, cfg.maxAge);
            }
        }

        if (hasCl && hasPyth) {
            // Dual-anchored: both must be within 1.50% (150 bps); Chainlink is the price used
            uint256 diff = clPrice >= pythPrice ? clPrice - pythPrice : pythPrice - clPrice;
            if (diff * 10000 > clPrice * MAX_ORACLE_DIVERGENCE_BPS) {
                revert OracleDivergenceExceeded(asset, clPrice, pythPrice);
            }
            price18 = clPrice;
        } else {
            price18 = hasCl ? clPrice : pythPrice;
        }

        if (cfg.isWrapper) {
            price18 = _applyWrapperMultiplier(asset, cfg.tokenDecimals, price18);
            if (price18 == 0) revert InvalidOraclePrice(asset);
        }
    }

    /// @notice Non-reverting price lookup used by `getLiquidNavUsd()` and `YuzuPriceArchive`.
    ///         Returns `(0, 0)` if `asset` is Unpriced, Paused in `YuzuRegistry`, or older than `HARD_STALE_CEILING` (96h).
    function priceOf(address asset) public view returns (uint256 price18, uint256 updatedAt) {
        YuzuRegistry.AssetConfig memory cfg = registry.getAssetConfig(asset);
        if (!cfg.isRegistered || cfg.isPaused) return (0, 0);

        (bool ok, uint256 rawPrice, uint256 ts) = _readLastKnownPrice(cfg);
        if (!ok || rawPrice == 0) return (0, 0);

        // Enforce v4.9 96-hour hard stale ceiling
        if (block.timestamp > ts && block.timestamp - ts > HARD_STALE_CEILING) {
            return (0, ts);
        }

        price18 = cfg.isWrapper ? _applyWrapperMultiplier(asset, cfg.tokenDecimals, rawPrice) : rawPrice;
        updatedAt = ts;
    }

    /// @notice Computes the 18-decimal USD value of `amount` of `asset` using `priceOf(asset)`.
    function valueOf(address asset, uint256 amount) public view returns (uint256 usdValue18) {
        if (amount == 0) return 0;
        YuzuRegistry.AssetConfig memory cfg = registry.getAssetConfig(asset);
        if (!cfg.isRegistered || cfg.isPaused) return 0;
        (uint256 p18,) = priceOf(asset);
        if (p18 == 0) return 0;
        return (amount * p18) / (10 ** cfg.tokenDecimals);
    }

    /// @notice Computes the oracle-implied output amount of `tokenOut` for `amountIn` of `tokenIn`.
    ///         Requires both feeds to be fresh (`requireFresh`).
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 fairAmountOut) {
        uint256 priceIn18 = requireFresh(tokenIn);
        uint256 priceOut18 = requireFresh(tokenOut);

        YuzuRegistry.AssetConfig memory cfgIn = registry.getAssetConfig(tokenIn);
        YuzuRegistry.AssetConfig memory cfgOut = registry.getAssetConfig(tokenOut);

        uint256 usdValue18 = (amountIn * priceIn18) / (10 ** cfgIn.tokenDecimals);
        fairAmountOut = (usdValue18 * (10 ** cfgOut.tokenDecimals)) / priceOut18;
    }

    /// @notice Returns the vault's Liquid NAV in 18-decimal USD.
    ///         Sums only active, unpaused priced assets whose oracle timestamp is within `HARD_STALE_CEILING` (96h).
    function getLiquidNavUsd(address vault) public view returns (uint256 liquidNavUsd18) {
        address[] memory assets = registry.getPricedAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 bal = IERC20MetadataMinimal(asset).balanceOf(vault);
            if (bal == 0) continue;
            liquidNavUsd18 += valueOf(asset, bal);
        }
    }

    /// @notice Non-reverting view for YuzuRenderer and telemetry.
    ///         Reports `liquidNav` (using `priceOf` with 96h ceiling), `displayNav` (adding NFT floor appraisals),
    ///         and `anyStale` (true if any held asset is paused or older than its per-asset `maxAge`).
    function tryGetNav(address vault)
        external
        view
        returns (uint256 liquidNav, uint256 displayNav, bool anyStale)
    {
        address[] memory assets = registry.getPricedAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 bal;
            try IERC20MetadataMinimal(asset).balanceOf(vault) returns (uint256 b) {
                bal = b;
            } catch {
                anyStale = true;
                continue;
            }
            if (bal == 0) continue;

            YuzuRegistry.AssetConfig memory cfg = registry.getAssetConfig(asset);
            if (cfg.isPaused) {
                anyStale = true;
                continue;
            }

            (bool ok, uint256 rawPrice, uint256 ts) = _readLastKnownPrice(cfg);
            if (!ok || rawPrice == 0) {
                anyStale = true;
                continue;
            }

            if (block.timestamp > ts && block.timestamp - ts > cfg.maxAge) {
                anyStale = true;
            }
            if (block.timestamp > ts && block.timestamp - ts > HARD_STALE_CEILING) {
                continue; // Zeroed in Liquid NAV past 96h
            }

            uint256 p18 = cfg.isWrapper ? _applyWrapperMultiplier(asset, cfg.tokenDecimals, rawPrice) : rawPrice;
            liquidNav += (bal * p18) / (10 ** cfg.tokenDecimals);
        }

        displayNav = liquidNav;
        address[] memory nfts = registry.getNftCollections();
        for (uint256 j = 0; j < nfts.length; j++) {
            address col = nfts[j];
            (, bool isPaused, address floorFeed, uint32 maxAge) = registry.nftConfigs(col);
            if (isPaused || floorFeed == address(0)) continue;

            uint256 count;
            try IERC721Minimal(col).balanceOf(vault) returns (uint256 c) {
                count = c;
            } catch {
                continue;
            }
            if (count == 0) continue;

            (bool ok, uint256 floor18, uint256 ts) = _tryReadChainlink(floorFeed);
            if (ok && floor18 > 0 && (block.timestamp <= ts || block.timestamp - ts <= maxAge)) {
                displayNav += count * floor18;
            }
        }
    }

    // =========================================================================
    // INTERNAL ORACLE READERS & NORMALIZATION TO 18 DECIMALS
    // =========================================================================

    function _readLastKnownPrice(YuzuRegistry.AssetConfig memory cfg)
        internal
        view
        returns (bool ok, uint256 price18, uint256 updatedAt)
    {
        if (cfg.chainlinkFeed != address(0)) {
            return _tryReadChainlink(cfg.chainlinkFeed);
        }
        if (cfg.pythFeedId != bytes32(0)) {
            return _tryReadPyth(cfg.pythFeedId);
        }
        return (false, 0, 0);
    }

    function _tryReadChainlink(address feed)
        internal
        view
        returns (bool ok, uint256 price18, uint256 updatedAt)
    {
        try IAggregatorV3(feed).decimals() returns (uint8 dec) {
            try IAggregatorV3(feed).latestRoundData() returns (
                uint80, int256 answer, uint256, uint256 updated, uint80
            ) {
                if (answer <= 0 || updated == 0) return (false, 0, 0);
                uint256 raw = uint256(answer);
                if (dec < 18) {
                    price18 = raw * (10 ** (18 - dec));
                } else if (dec > 18) {
                    price18 = raw / (10 ** (dec - 18));
                } else {
                    price18 = raw;
                }
                return (true, price18, updated);
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
        }
    }

    function _tryReadPyth(bytes32 feedId)
        internal
        view
        returns (bool ok, uint256 price18, uint256 updatedAt)
    {
        try pyth.getPriceUnsafe(feedId) returns (PythPrice memory p) {
            if (p.price <= 0 || p.publishTime == 0) return (false, 0, 0);
            uint256 base = uint256(uint64(p.price));
            int32 targetExpo = 18 + p.expo;
            if (targetExpo >= 0) {
                price18 = base * (10 ** uint32(targetExpo));
            } else {
                price18 = base / (10 ** uint32(-targetExpo));
            }
            return (true, price18, p.publishTime);
        } catch {
            return (false, 0, 0);
        }
    }

    function _applyWrapperMultiplier(address wrapper, uint8 wrapperDecimals, uint256 underlyingPrice18)
        internal
        view
        returns (uint256 wrappedPrice18)
    {
        uint256 oneShare = 10 ** wrapperDecimals;
        try IERC4626Wrapper(wrapper).convertToAssets(oneShare) returns (uint256 underlyingAssets) {
            return (underlyingPrice18 * underlyingAssets) / oneShare;
        } catch {
            return 0;
        }
    }
}
