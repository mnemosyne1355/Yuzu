// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared enums and interfaces for YUZU-98 Phase 4 (`YuzuAccount.sol`, v4.9).

enum SeedMode {
    US_BASKET,
    NON_US_XSTOCK
}

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

interface IPythMinimal {
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

interface IYuzu98v2Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isGutted(uint256 tokenId) external view returns (bool);
    function boltState(uint256 tokenId) external view returns (BoltState);
    function boltForSaleFromVault(uint256 tokenId) external;
    function guardianForceUnbolt(uint256 tokenId) external;
    function setGuttedFromVault(uint256 tokenId) external;
}

interface IYuzuNavLensMinimal {
    function requireFresh(address asset) external view returns (uint256 price18);
    function priceOf(address asset) external view returns (uint256 price18, uint256 updatedAt);
    function valueOf(address asset, uint256 amount) external view returns (uint256 usdValue18);
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 fairAmountOut);
    function getLiquidNavUsd(address vault) external view returns (uint256 liquidNavUsd18);
    function tryGetNav(address vault) external view returns (uint256 liquidNav, uint256 displayNav, bool anyStale);
}

interface IYuzuRegistryMinimal {
    struct Route {
        address router;
        uint8 routerType;
        bytes path;
        bool isActive;
    }
    function isPricedAsset(address asset) external view returns (bool);
    function isCryptoAsset(address asset) external view returns (bool);
    function routeFor(address tokenIn, address tokenOut) external view returns (Route memory);
    function hasActiveRoute(address tokenIn, address tokenOut) external view returns (bool);
    function isCartridgeExecutable(address cartridge)
        external
        view
        returns (bool ok, uint256 authorTokenId, uint256 runPriceYuzu);
}

interface IYuzuSwapRouter {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata path
    ) external returns (uint256 amountOut);
}

interface IYuzuSocketBayMinimal {
    function romBond(uint256 tokenId) external view returns (uint256);
    function gateBought(address vault) external view returns (uint256);
    function seatBladesFromVault(uint256 tokenId, uint8 blades) external;
    function postBondFromVault(uint256 tokenId) external;
    function buyBufferFor(uint256 tokenId, uint256 yuzuAmount, uint256 maxWethIn) external returns (uint256 wethSpent);
    function forfeit(uint256 tokenId) external returns (uint256 totalForfeited);
}

interface IYuzuDistributorMinimal {
    function noteOutflow(uint256 tokenId, uint256 navAfter) external;
    function cancelLockedCreditOnRaid(uint256 tokenId) external returns (uint256 cancelled);
}

interface IYuzuTreasuryMinimal {
    function recordProtocolFeeWeth(uint256 toDistributor, uint256 toBuyback) external;
    function receiveFeeEscrow(address asset, uint256 amount) external;
    function receiveSalvageEscrow(address asset, uint256 amount) external;
}

interface IYuzuPoolHookMinimal {
    function gateLifted() external view returns (bool);
}

interface IYuzuCustomStrategy {
    function strategyName() external pure returns (string memory);
    function evaluate(address vault, bytes calldata params)
        external
        view
        returns (bool shouldExecute, address tokenIn, address tokenOut, uint256 amountIn);
}

interface IERC721Minimal {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155Minimal {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

interface IYuzuAccountCompanion {
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
    ) external view returns (address);
    function swapFor(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOutBps,
        bool chargeDeskFee,
        uint256 navBeforeUsd
    ) external returns (uint256 amountOut);
    function routeDeskFee(address asset, uint256 amount) external;
    function routeSalvage(address asset, uint256 amount) external;
    function routeRunFee(uint256 authorTokenId, uint256 runFee) external;
}

interface IYuzuCartridgePolicy {
    function setPolicyFromVaultTier3(
        uint256 tokenId,
        address[] calldata allowedAssets,
        uint16 minStrikeBps,
        uint16 minPremiumBps,
        uint32 maxExpirySeconds,
        uint16 maxExposureShareBps
    ) external;
}
