// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IUnlockCallback,
    IPoolManager,
    PoolKey,
    SwapParams,
    V4StateLib
} from "../interfaces/IYuzuV4Interfaces.sol";
import {IYuzuSwapRouter} from "../interfaces/IYuzuPhase4Interfaces.sol";

/// @dev CHANGE (bankr 2026-11-19, founder request 00:01Z): the V3 leg goes through Uniswap's Universal Router, the
///      router Uniswap deploys on Ink (0x661E93cca42AfacB172121EF892830cA3b70F08d), instead of SwapRouter02's
///      exactInputSingle. Read from the verified source of that deployment: `execute(bytes,bytes[])`, command
///      0x00 = V3_SWAP_EXACT_IN with inputs
///      abi.encode(address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool payerIsUser,
///      uint256[] minHopPriceX36), path = abi.encodePacked(tokenIn, uint24 fee, tokenOut).
interface IUniversalRouterMinimal {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

/// @title YuzuSwapRouterAdapter — Stateless Periphery Router implementing IYuzuSwapRouter
/// @notice Supports:
///         1. Default / 32-byte path: Single-hop Uniswap V3 swap through the Universal Router (default fee 3000,
///            or the uint24 fee abi-encoded in the 32-byte path).
///         2. 160-byte `V4Hop` or variable-length `V4Hop[]`: Single-hop or multi-hop routes where each hop can be:
///            - A Uniswap v4 pool (`hop.hooks != address(0)` or `hop.tickSpacing != 0`), using valid v4 sqrtPriceLimitX96 bounds, OR
///            - A Uniswap V3 pool (`hop.hooks == address(0)` and `hop.tickSpacing == 0`), allowing mixed 2-hop routes
///              such as `WETH -> USDG (V3) -> wSPYx (Quotrons V4)`.
contract YuzuSwapRouterAdapter is IYuzuSwapRouter, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 public constant QUOTRON_TICK_SPACING = 60;
    address public constant QUOTRON_STOCK_HOOK = 0x8bb4516059F9149Bc3b89018Fc7537f1F14a30cc;

    // Uniswap v4 TickMath valid price limits
    uint160 public constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;
    uint160 public constant MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    /// @dev Universal Router command byte for a V3 exact-input swap.
    bytes internal constant V3_SWAP_EXACT_IN = hex"00";

    IPoolManager public immutable poolManager;
    /// @notice The chain's Uniswap Universal Router. The name is kept from the SwapRouter02 version so the deploy
    ///         script and its `V3_SWAP_ROUTER` variable are unchanged.
    address public immutable v3Router;

    error ZeroAddress();
    error OnlyPoolManager();
    error EmptyHopPath();
    error InvalidHopEndpoints(address firstIn, address lastOut, address expectedIn, address expectedOut);
    error InvalidHopContinuity(uint256 hopIndex, address prevOut, address nextIn);
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    /// @dev ADDED (bankr 2026-11-19): the V3 pool did not take the whole input (it ran out of liquidity).
    error V3InputNotFullyUsed(address tokenIn, uint256 leftover);

    struct V4Hop {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing; // If tickSpacing == 0 && hooks == address(0), executes via v3Router; otherwise via v4 PoolManager
        address hooks;
    }

    constructor(address poolManager_, address v3Router_) {
        if (poolManager_ == address(0) || v3Router_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        v3Router = v3Router_;
    }

    /// @inheritdoc IYuzuSwapRouter
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata path
    ) external override returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (path.length == 0 || path.length == 32) {
            uint24 fee = path.length == 32 ? abi.decode(path, (uint24)) : uint24(3000);
            amountOut = _swapV3Single(tokenIn, tokenOut, fee, amountIn, minAmountOut, recipient);
        } else {
            V4Hop[] memory hops;
            if (path.length == 160) {
                hops = new V4Hop[](1);
                hops[0] = abi.decode(path, (V4Hop));
            } else {
                hops = abi.decode(path, (V4Hop[]));
            }
            if (hops.length == 0) revert EmptyHopPath();
            if (hops[0].tokenIn != tokenIn || hops[hops.length - 1].tokenOut != tokenOut) {
                revert InvalidHopEndpoints(hops[0].tokenIn, hops[hops.length - 1].tokenOut, tokenIn, tokenOut);
            }

            uint256 currentAmount = amountIn;
            for (uint256 i = 0; i < hops.length; i++) {
                V4Hop memory h = hops[i];
                if (i > 0 && hops[i - 1].tokenOut != h.tokenIn) {
                    revert InvalidHopContinuity(i, hops[i - 1].tokenOut, h.tokenIn);
                }
                address hopRecipient = (i + 1 == hops.length) ? recipient : address(this);
                if (h.hooks == address(0) && h.tickSpacing == 0) {
                    currentAmount = _swapV3Single(h.tokenIn, h.tokenOut, h.fee, currentAmount, 0, hopRecipient);
                } else {
                    bytes memory res = poolManager.unlock(abi.encode(h, currentAmount, hopRecipient));
                    currentAmount = abi.decode(res, (uint256));
                }
            }
            amountOut = currentAmount;
        }

        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);
    }

    /// @dev CHANGE (bankr 2026-11-19): one V3 hop through the Universal Router. The input is sent to the router
    ///      first and the swap is paid from the router's own balance (payerIsUser = false), so no Permit2 or
    ///      ERC-20 approval is ever given. The router returns nothing, so the output is measured as the
    ///      recipient's balance change. If the pool does not take the whole input the remainder would sit in the
    ///      router, where anyone can sweep it, so that case reverts.
    function _swapV3Single(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) internal returns (uint256 amountOut) {
        uint256 routerInBefore = IERC20(tokenIn).balanceOf(v3Router);
        uint256 outBefore = IERC20(tokenOut).balanceOf(recipient);

        IERC20(tokenIn).safeTransfer(v3Router, amountIn);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            recipient,
            amountIn,
            minOut,
            abi.encodePacked(tokenIn, fee, tokenOut),
            false,
            new uint256[](0)
        );
        IUniversalRouterMinimal(v3Router).execute(V3_SWAP_EXACT_IN, inputs);

        uint256 routerInAfter = IERC20(tokenIn).balanceOf(v3Router);
        if (routerInAfter > routerInBefore) revert V3InputNotFullyUsed(tokenIn, routerInAfter - routerInBefore);
        amountOut = IERC20(tokenOut).balanceOf(recipient) - outBefore;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (V4Hop memory h, uint256 amountIn, address takeRecipient) =
            abi.decode(data, (V4Hop, uint256, address));

        (address c0, address c1) = h.tokenIn < h.tokenOut ? (h.tokenIn, h.tokenOut) : (h.tokenOut, h.tokenIn);
        bool zeroForOne = (h.tokenIn == c0);

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: h.fee,
            tickSpacing: h.tickSpacing,
            hooks: h.hooks
        });

        int256 swapDelta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_PLUS_ONE : MAX_SQRT_PRICE_MINUS_ONE
            }),
            ""
        );

        (int128 delta0, int128 delta1) = V4StateLib.unpackDelta(swapDelta);
        int256 outDelta = zeroForOne ? delta1 : delta0;
        uint256 hopOut = outDelta > 0 ? uint256(outDelta) : uint256(-outDelta);

        poolManager.sync(h.tokenIn);
        IERC20(h.tokenIn).safeTransfer(address(poolManager), amountIn);
        poolManager.settle();
        poolManager.take(h.tokenOut, takeRecipient, hopOut);

        return abi.encode(hopOut);
    }

    /// @notice Encodes a single-hop Uniswap v4 route (hooked or hookless).
    function encodeV4Hop(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hooks)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(
            V4Hop({tokenIn: tokenIn, tokenOut: tokenOut, fee: fee, tickSpacing: tickSpacing, hooks: hooks})
        );
    }

    /// @notice Encodes a multi-hop Uniswap v4 (or mixed) route.
    function encodeV4Path(V4Hop[] calldata hops) external pure returns (bytes memory) {
        return abi.encode(hops);
    }

    /// @notice Encodes a single-hop Quotrons Ink xStock/USDG v4 route (`fee = 0x800000`, `tickSpacing = 60`).
    function encodeQuotronV4Hop(address tokenIn, address tokenOut) external pure returns (bytes memory) {
        return abi.encode(
            V4Hop({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: DYNAMIC_FEE_FLAG,
                tickSpacing: QUOTRON_TICK_SPACING,
                hooks: QUOTRON_STOCK_HOOK
            })
        );
    }

    /// @notice Encodes a 2-hop mixed route (e.g., WETH -> USDG on V3, then USDG -> wSPYx on Quotrons V4).
    function encodeTwoHopV3ToQuotronV4(address tokenIn, address midUsdg, uint24 v3Fee, address xStockOut)
        external
        pure
        returns (bytes memory)
    {
        V4Hop[] memory hops = new V4Hop[](2);
        hops[0] = V4Hop({tokenIn: tokenIn, tokenOut: midUsdg, fee: v3Fee, tickSpacing: 0, hooks: address(0)});
        hops[1] = V4Hop({
            tokenIn: midUsdg,
            tokenOut: xStockOut,
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: QUOTRON_TICK_SPACING,
            hooks: QUOTRON_STOCK_HOOK
        });
        return abi.encode(hops);
    }
}
