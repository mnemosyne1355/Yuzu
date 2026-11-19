// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Uniswap v4 PoolManager & Hook interfaces matching the PoolManager deployed at
///         0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32 on Ink (57073).
/// @dev Written by argon, pasted by the founder 2026-11-18 (v4 alignment pass; the paste's angle brackets restored).
///      Replaces the simplified interface (settle(address), two-int swap returns, getSlot0 / getPositionBalances),
///      none of which the real PoolManager has.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (int256 callerDelta, int256 feesAccrued);
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

/// @notice Shared helper library for Uniswap v4 BalanceDelta unpacking, TickMath price limits, and extsload slot0 reads.
library V4StateLib {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint160 internal constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    function unpackDelta(int256 delta) internal pure returns (int128 amount0, int128 amount1) {
        amount0 = int128(delta >> 128);
        amount1 = int128(delta);
    }

    function packDelta(int128 amount0, int128 amount1) internal pure returns (int256 delta) {
        delta = (int256(amount0) << 128) | (int256(uint256(uint128(amount1))));
    }

    /// @notice Reads `sqrtPriceX96` (low 160 bits) and `tick` (bits 160..183, signed int24) from PoolManager slot 6.
    function getSlot0(IPoolManager pm, bytes32 poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick)
    {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        uint256 data = uint256(pm.extsload(stateSlot));
        sqrtPriceX96 = uint160(data);
        tick = int24(int256(data << 72) >> 232);
    }

    /// @notice Computes full-range (-887200..887200) liquidity for (amt0, amt1) and active balances from liquidity.
    /// @dev Closed form that ignores the two range bounds. It rounds liquidity down (and takes one more unit off),
    ///      so the position never needs more than amt0 / amt1.
    function fullRangeLiquidityForAmounts(uint160 sqrtPriceX96, uint256 amt0, uint256 amt1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceX96 == 0) return 0;
        uint256 l0 = (amt0 * uint256(sqrtPriceX96)) >> 96;
        uint256 l1 = (amt1 << 96) / uint256(sqrtPriceX96);
        uint256 l = l0 < l1 ? l0 : l1;
        return l > 1 ? uint128(l - 1) : uint128(l);
    }

    function fullRangeAmountsForLiquidity(uint160 sqrtPriceX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amt0, uint256 amt1)
    {
        if (sqrtPriceX96 == 0 || liquidity == 0) return (0, 0);
        amt0 = (uint256(liquidity) << 96) / uint256(sqrtPriceX96);
        amt1 = (uint256(liquidity) * uint256(sqrtPriceX96)) >> 96;
    }
}

interface IHooks {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, int256, uint24);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IYuzuUnits {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isGutted(uint256 tokenId) external view returns (bool);
    function boltState(uint256 tokenId) external view returns (uint8);
    function getVaultAddress(uint256 tokenId) external view returns (address);
    function isVault(address account) external view returns (bool);
    function commissionedCount() external view returns (uint256);
    function firstPublicCommissionAt() external view returns (uint256);
}

interface IYuzuNavLens {
    function requireFresh(address asset) external view returns (uint256 price18);
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
    function pyth() external view returns (address);
}

interface IYuzuRegistry {
    struct Route {
        address router;
        uint8 routerType;
        bytes path;
        bool isActive;
    }
    function routeFor(address tokenIn, address tokenOut) external view returns (Route memory);
}
