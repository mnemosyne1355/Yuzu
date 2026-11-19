// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared enums and cross-contract interfaces for YUZU-98 Phase 3 (v4.9).

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

interface IYuzuNavLensMinimal {
    function requireFresh(address asset) external view returns (uint256 price18);
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 fairAmountOut);
    function getLiquidNavUsd(address vault) external view returns (uint256 liquidNavUsd18);
}

interface IYuzuRegistryMinimal {
    struct Route {
        address router;
        uint8 routerType;
        bytes path;
        bool isActive;
    }
    function routeFor(address tokenIn, address tokenOut) external view returns (Route memory);
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
    function ramTier(uint256 tokenId) external view returns (uint8);
    function ramMultiplierBps(uint256 tokenId) external view returns (uint256);
    function seedInitialRam(uint256 tokenId, uint8 initialTier) external;
    function recommissionStarterBlade(uint256 tokenId) external;
    function buyStarterBlade(uint256 tokenId, uint256 maxWethIn) external payable returns (uint256 wethSpent);
}

interface IYuzuTreasuryMinimal {
    function receiveCommissioningWeth(uint256 lpWeth, uint256 treasuryWeth) external;
    function emitWeeklyFarm(uint256 epoch) external returns (uint256 emitted);
}

interface IYuzuAccountMinimal {
    function initializeFromSeeder(uint256 tokenId, address initialGuardian, address recoveryAddress) external;
    function recordSeed(address asset, uint256 amount, SeedMode mode) external;
    function clearSeedStorageForRecommission() external;
    function verifyGuardianRecoverySig(address expectedTarget, uint256 tokenId, uint256 deadline, bytes calldata sig)
        external
        returns (bool);
    function onNftTransferReset() external;
    function onRewardPaid(uint256 wethAmount) external;
}

interface IYuzuCartridgeMinimal {
    function hasOpenCalls(uint256 tokenId) external view returns (bool);
    function clearPolicyOnTransfer(uint256 tokenId) external;
}

interface IYuzuRendererMinimal {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
