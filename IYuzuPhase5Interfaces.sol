// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared interfaces for YUZU-98 Phase 5 (`YuzuCartridge.sol` & `YuzuRelativeStrengthAdapter.sol`, v4.9).

enum BoltState {
    UNBOLTED,
    BOLTED,
    UNBOLTING
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IYuzu98v2Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isGutted(uint256 tokenId) external view returns (bool);
    function boltState(uint256 tokenId) external view returns (BoltState);
    function getVaultAddress(uint256 tokenId) external view returns (address);
}

interface IYuzuAccountMinimal {
    function guardianFrozen() external view returns (bool);
    function aiSessionKey() external view returns (address);
    function aiSessionExpiry() external view returns (uint256);
    function seedUnits(address asset) external view returns (uint256);
    function pullSlot2Asset(address asset, uint256 amount, address to) external;
}

interface IYuzuSocketBayMinimal {
    function ramTier(uint256 tokenId) external view returns (uint8);
}

interface IYuzuNavLensMinimal {
    function requireFresh(address asset) external view returns (uint256 price18);
    function valueOf(address asset, uint256 amount) external view returns (uint256 usdValue18);
    function getLiquidNavUsd(address vault) external view returns (uint256 liquidNavUsd18);
}

interface IYuzuRegistryMinimal {
    function isPricedAsset(address asset) external view returns (bool);
    function getPricedAssets() external view returns (address[] memory);
    function venues(address venue)
        external
        view
        returns (bool isListed, bool isPaused, bool isLendingMarket, address receiptToken);
}

interface IYuzuTreasuryMinimal {
    function recordProtocolFeeWeth(uint256 toDistributor, uint256 toBuyback) external;
    function receiveFeeEscrow(address asset, uint256 amount) external;
    function receiveSkimEscrow(address asset, uint256 amount) external;
}

interface IYuzuPriceArchiveMinimal {
    function get14DayReturnBps(address asset) external view returns (bool valid, int256 returnBps);
}

interface IOptionsVenueAdapter {
    function writeCall(
        address vault,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 strikePrice18,
        uint64 expiry,
        address premiumAsset,
        uint256 minGrossPremium
    ) external returns (uint256 venueCallId, uint256 grossPremiumPaidToCartridge);

    function settleOrExpireCall(uint256 venueCallId, address vault) external returns (bool settled);
}

interface ILendingMarketAdapter {
    function supplyForVault(address underlyingAsset, uint256 amount, address vault)
        external
        returns (uint256 receiptSharesMintedToVault);

    function withdrawForVault(address underlyingAsset, uint256 receiptShares, address vault)
        external
        returns (uint256 underlyingRedeemedToCartridge);
}

interface IYuzuCustomStrategy {
    function strategyName() external pure returns (string memory);

    function evaluate(address vault, bytes calldata params)
        external
        view
        returns (bool shouldExecute, address tokenIn, address tokenOut, uint256 amountIn);
}
