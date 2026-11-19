// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared Oracle, Wrapper, and Registry interfaces for YUZU-98 Phase 2 (v4.9).

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

struct PythPrice {
    int64 price;
    uint64 conf;
    int32 expo;
    uint256 publishTime;
}

interface IPyth {
    function getPriceUnsafe(bytes32 id) external view returns (PythPrice memory price);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

interface IERC4626Wrapper {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

interface IERC20MetadataMinimal {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Minimal {
    function balanceOf(address owner) external view returns (uint256);
}
