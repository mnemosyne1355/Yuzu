// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IYuzuAccountMinimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuPriceArchiveMinimal,
    IYuzuCustomStrategy
} from "../interfaces/IYuzuPhase5Interfaces.sol";

/// @title YuzuRelativeStrengthAdapter — Contract 06 of 16 (YUZU-98 Master Specification v4.9, Sections 6.4, 12)
/// @notice Factory Default Slot-4 Strategy ROM Cartridge (`IYuzuCustomStrategy`).
///         - Stateless, read-only view contract; free to run (zero $YUZU run fee).
///         - Compares the 14-day return of every priced asset held in `vault` (above `seedUnits`) using
///           `YuzuPriceArchive.get14DayReturnBps(asset)`.
///         - When the leader's 14-day return exceeds the laggard's by more than `250 bps` (`2.50%`), returns
///           an intent to swap `rotationBps` of the laggard's non-seed balance into the leader, automatically
///           clamped so the trade never exceeds Fence F3 (`20.00%` of vault Liquid NAV).
contract YuzuRelativeStrengthAdapter is IYuzuCustomStrategy {
    int256 public constant MIN_SPREAD_BPS = 250;          // 2.50% minimum 14-day return spread
    uint256 public constant DEFAULT_ROTATION_BPS = 2000;  // 20.00% of non-seed laggard position
    uint256 public constant FENCE_F3_MAX_NAV_BPS = 2000;  // 20.00% of total Liquid NAV ceiling

    IYuzuRegistryMinimal public immutable registry;
    IYuzuNavLensMinimal public immutable lens;
    IYuzuPriceArchiveMinimal public immutable archive;

    error ZeroAddress();

    constructor(address registry_, address lens_, address archive_) {
        if (registry_ == address(0) || lens_ == address(0) || archive_ == address(0)) revert ZeroAddress();
        registry = IYuzuRegistryMinimal(registry_);
        lens = IYuzuNavLensMinimal(lens_);
        archive = IYuzuPriceArchiveMinimal(archive_);
    }

    function strategyName() external pure override returns (string memory) {
        return "YUZU-98 Factory Relative Strength (14D Momentum)";
    }

    /// @notice Evaluates 14-day momentum across all priced assets in `vault` and returns a Fence-F3-safe swap intent.
    function evaluate(address vault, bytes calldata params)
        external
        view
        override
        returns (bool shouldExecute, address tokenIn, address tokenOut, uint256 amountIn)
    {
        uint256 rotationBps = DEFAULT_ROTATION_BPS;
        if (params.length >= 32) {
            rotationBps = abi.decode(params, (uint256));
            if (rotationBps == 0 || rotationBps > 10000) rotationBps = DEFAULT_ROTATION_BPS;
        }

        address[] memory assets = registry.getPricedAssets();
        if (assets.length < 2) return (false, address(0), address(0), 0);

        address leader = address(0);
        int256 leaderRet = type(int256).min;

        address laggard = address(0);
        int256 laggardRet = type(int256).max;
        uint256 laggardTradableBal = 0;

        for (uint256 i = 0; i < assets.length; i++) {
            address a = assets[i];
            (bool valid, int256 retBps) = archive.get14DayReturnBps(a);
            if (!valid) continue;

            // Any valid priced asset in the registry with a 14-day record can be the rotation target (leader)
            if (retBps > leaderRet) {
                leaderRet = retBps;
                leader = a;
            }

            // Only assets held in the vault above `seedUnits` can be the rotation source (laggard)
            uint256 bal = IERC20(a).balanceOf(vault);
            uint256 seedReq = IYuzuAccountMinimal(vault).seedUnits(a);
            if (bal > seedReq) {
                uint256 tradable = bal - seedReq;
                if (lens.valueOf(a, tradable) > 0 && retBps < laggardRet) {
                    laggardRet = retBps;
                    laggard = a;
                    laggardTradableBal = tradable;
                }
            }
        }

        if (leader == address(0) || laggard == address(0) || leader == laggard) {
            return (false, address(0), address(0), 0);
        }

        if (leaderRet - laggardRet <= MIN_SPREAD_BPS) {
            return (false, address(0), address(0), 0);
        }

        uint256 desiredIn = (laggardTradableBal * rotationBps) / 10000;
        if (desiredIn == 0) return (false, address(0), address(0), 0);

        // Clamp `amountIn` to Fence F3 (20.00% of Liquid NAV) so the intent never reverts on F3
        uint256 navUsd = lens.getLiquidNavUsd(vault);
        uint256 maxTradeUsd = (navUsd * FENCE_F3_MAX_NAV_BPS) / 10000;
        uint256 desiredUsd = lens.valueOf(laggard, desiredIn);

        if (desiredUsd > maxTradeUsd && desiredUsd > 0) {
            desiredIn = (desiredIn * maxTradeUsd) / desiredUsd;
        }
        if (desiredIn == 0) return (false, address(0), address(0), 0);

        return (true, laggard, leader, desiredIn);
    }
}
