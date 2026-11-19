// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {YuzuNavLens} from "./YuzuNavLens.sol";

/// @title YuzuPriceArchive — Contract 15 of 16 (YUZU-98 Master Specification v4.9, Section 6.4)
/// @notice Stores one fresh oracle price per listed asset per UTC day (`block.timestamp / 1 days`),
///         providing 14-day historical return lookups for `YuzuRelativeStrengthAdapter` and third-party
///         Slot-4 strategy cartridges.
contract YuzuPriceArchive {
    uint256 public constant LOOKBACK_DAYS = 14;
    uint256 public constant MAX_FALLBACK_WINDOW = 5; // Up to 5 earlier days to bridge weekends/holidays

    YuzuNavLens public immutable lens;

    // dayIndex (block.timestamp / 1 days) => asset => 18-decimal USD price
    mapping(uint256 dayIndex => mapping(address asset => uint256 price18)) public dailyPrice;

    event DailyPriceRecorded(address indexed asset, uint256 indexed dayIndex, uint256 price18);

    error ZeroAddress();
    error AlreadyRecordedToday(address asset, uint256 dayIndex);

    constructor(address lens_) {
        if (lens_ == address(0)) revert ZeroAddress();
        lens = YuzuNavLens(lens_);
    }

    /// @notice Permissionless once-daily recorder for `asset`. Requires a live, fresh price via `lens.requireFresh`.
    function record(address asset) public returns (uint256 dayIndex, uint256 price18) {
        dayIndex = block.timestamp / 1 days;
        if (dailyPrice[dayIndex][asset] != 0) revert AlreadyRecordedToday(asset, dayIndex);

        price18 = lens.requireFresh(asset);
        dailyPrice[dayIndex][asset] = price18;

        emit DailyPriceRecorded(asset, dayIndex, price18);
    }

    /// @notice Batch helper for keepers to record multiple fresh assets in one transaction.
    function recordBatch(address[] calldata assets) external {
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 dayIndex = block.timestamp / 1 days;
            if (dailyPrice[dayIndex][assets[i]] == 0) {
                record(assets[i]);
            }
        }
    }

    /// @notice Returns the 14-day return of `asset` in signed basis points (e.g., +500 = +5.00%, -250 = -2.50%).
    ///         Compares the live fresh price against the record from `currentDay - 14` (or the nearest earlier
    ///         trading day within `MAX_FALLBACK_WINDOW` days for equities over weekends/holidays).
    function get14DayReturnBps(address asset) external view returns (bool valid, int256 returnBps) {
        // Check freshness without reverting so Slot-4 `evaluate()` views never revert
        (uint256 currentPrice, uint256 updatedAt) = lens.priceOf(asset);
        uint32 maxAge = lens.registry().maxAgeOf(asset);
        if (currentPrice == 0 || maxAge == 0 || (block.timestamp > updatedAt && block.timestamp - updatedAt > maxAge)) {
            return (false, 0);
        }

        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay < LOOKBACK_DAYS) return (false, 0);

        uint256 targetDay = currentDay - LOOKBACK_DAYS;
        uint256 pastPrice = 0;

        for (uint256 i = 0; i <= MAX_FALLBACK_WINDOW; i++) {
            if (targetDay < i) break;
            uint256 p = dailyPrice[targetDay - i][asset];
            if (p != 0) {
                pastPrice = p;
                break;
            }
        }

        if (pastPrice == 0) return (false, 0);

        int256 diff = int256(currentPrice) - int256(pastPrice);
        returnBps = (diff * 10000) / int256(pastPrice);
        return (true, returnBps);
    }
}
