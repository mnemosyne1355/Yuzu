// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// FIX (bankr 2026-11-18): SwapParams, IHooks and IUnlockCallback added for the stand-in hook and the liquidity
// callback below.
import {
    PoolKey,
    ModifyLiquidityParams,
    SwapParams,
    IHooks,
    IUnlockCallback
} from "../src/interfaces/IYuzuV4Interfaces.sol";
// CHANGE (bankr 2026-11-19): the adapter's V3 leg now calls the Universal Router, so the stand-in router below
// takes execute(bytes,bytes[]) with the V3_SWAP_EXACT_IN command instead of SwapRouter02's exactInputSingle.
import {YuzuSwapRouterAdapter, IUniversalRouterMinimal} from "../src/adapters/YuzuSwapRouterAdapter.sol";
import {MockV4PoolManager, MockWETH, FullRangeLpHelper} from "./mocks/Phase1Mocks.sol";
import {MockERC20Asset} from "./mocks/Phase2Mocks.sol";

/// @dev Argon's test, pasted by the founder 2026-11-18 20:01Z (the paste's angle brackets restored). It did not
///      compile or run as pasted; changes are marked `FIX (bankr 2026-11-18)` and additions `ADDED (bankr ...)`.
///      Local only: MockV4PoolManager and a mock V3 router, not real Uniswap v4 or V3, not Ink.
contract MockV3SwapRouter is IUniversalRouterMinimal {
    address public constant POOL_SINK = address(0x9001); // where the stand-in "pays the pool"
    uint256 public rateNum = 2000e6; // 1 WETH (1e18) -> 2,000 USDG (2000e6)
    uint256 public rateDen = 1e18;

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable override {
        require(commands.length == 1 && commands[0] == bytes1(0x00) && inputs.length == 1, "UR_COMMAND");
        (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser,) =
            abi.decode(inputs[0], (address, uint256, uint256, bytes, bool, uint256[]));
        require(!payerIsUser && path.length == 43, "UR_INPUT");
        address tokenIn;
        address tokenOut;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            tokenOut := shr(96, mload(add(path, 55)))
        }
        // The input must already be in the router (the adapter sends it first); it is paid on to the pool.
        IERC20(tokenIn).transfer(POOL_SINK, amountIn);
        uint256 amountOut = (amountIn * rateNum) / rateDen;
        require(amountOut >= amountOutMin, "V3_MIN_OUT");
        MockERC20Asset(tokenOut).mint(recipient, amountOut);
    }
}

/// @dev FIX (bankr 2026-11-18): added. MockV4PoolManager calls the pool's hook on initialize, add-liquidity and
///      swap, and the Quotrons hook address has no code in a local test, so every one of those calls reverted.
///      This pass-through is placed at that address with vm.etch. It is NOT the real QuotronStockHook: the real
///      hook's fee and any conditions it puts on a swap are not exercised here.
contract MockPassThroughHook is IHooks {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, int256, uint24)
    {
        return (IHooks.beforeSwap.selector, 0, 0);
    }
}

contract YuzuAdaptersTest is Test {
    MockV4PoolManager poolManager;
    MockV3SwapRouter v3Router;
    YuzuSwapRouterAdapter swapAdapter;

    MockWETH weth;
    MockERC20Asset usdg;
    MockERC20Asset wspyx;

    // ADDED (bankr 2026-11-18): kept so the tests can read the mock pool's reserves and predict exact outputs.
    bytes32 poolId;
    bool usdgIs0;

    function setUp() public {
        poolManager = new MockV4PoolManager();
        v3Router = new MockV3SwapRouter();
        swapAdapter = new YuzuSwapRouterAdapter(address(poolManager), address(v3Router));

        weth = new MockWETH();
        usdg = new MockERC20Asset("Global Dollar", "USDG", 6);
        wspyx = new MockERC20Asset("Wrapped SPYx", "wSPYx", 18);

        // FIX (bankr 2026-11-18): give the Quotrons hook address code (see MockPassThroughHook).
        vm.etch(swapAdapter.QUOTRON_STOCK_HOOK(), address(new MockPassThroughHook()).code);
        // FIX (bankr 2026-11-18): MockWETH has no mint(); the test wraps ETH with deposit() instead.
        vm.deal(address(this), 10 ether);

        (address c0, address c1) = address(usdg) < address(wspyx)
            ? (address(usdg), address(wspyx))
            : (address(wspyx), address(usdg));
        PoolKey memory qKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: swapAdapter.DYNAMIC_FEE_FLAG(),
            tickSpacing: swapAdapter.QUOTRON_TICK_SPACING(),
            hooks: swapAdapter.QUOTRON_STOCK_HOOK()
        });
        // CHANGE (bankr 2026-11-18, v4 alignment): the mock now takes real liquidity units and makes the provider
        // pay what it owes, so the pool opens at the price the two amounts imply ($500 per wSPYx) and a helper
        // contract supplies and settles the liquidity.
        uint256 amt0 = c0 == address(usdg) ? 500_000e6 : 1_000e18;
        uint256 amt1 = c0 == address(usdg) ? 1_000e18  : 500_000e6;
        FullRangeLpHelper lp = new FullRangeLpHelper(poolManager);
        poolManager.initialize(qKey, lp.sqrtPriceFor(amt0, amt1));
        poolId = keccak256(abi.encode(qKey));
        usdgIs0 = c0 == address(usdg);
        usdg.mint(address(lp), 500_000e6);
        wspyx.mint(address(lp), 1_000e18);
        lp.addFullRange(qKey, amt0, amt1);
    }

    /// @dev ADDED (bankr 2026-11-18): the mock pool's current reserves.
    function _reserves() internal view returns (uint256 reserveUsdg, uint256 reserveWspyx) {
        (,, uint256 r0, uint256 r1,,,) = poolManager.pools(poolId);
        (reserveUsdg, reserveWspyx) = usdgIs0 ? (r0, r1) : (r1, r0);
    }

    /// @dev ADDED (bankr 2026-11-18): MockV4PoolManager's exact-input math (1.00% fee, constant product).
    function _v4Out(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) internal pure returns (uint256) {
        uint256 netIn = (amountIn * 9900) / 10000;
        return (reserveOut * netIn) / (reserveIn + netIn);
    }

    function test_YuzuSwapRouterAdapter_V3Single_QuotronV4Single_AndTwoHopMixed() public {
        // 1. Single-hop V3 swap: 1 WETH -> 2,000 USDG
        weth.deposit{value: 1 ether}(); // FIX (bankr 2026-11-18): was weth.mint, which MockWETH does not have
        weth.approve(address(swapAdapter), 1 ether);
        uint256 usdgOut = swapAdapter.swapExactIn(address(weth), address(usdg), 1 ether, 1990e6, address(this), "");
        assertEq(usdgOut, 2000e6);
        assertEq(usdg.balanceOf(address(this)), 2000e6, "V3 output delivered"); // ADDED

        // 2. Single-hop Quotrons V4 swap: 500 USDG -> wSPYx
        (uint256 rU, uint256 rW) = _reserves();
        uint256 expectedSpy = _v4Out(rU, rW, 500e6); // ADDED: about 0.989 wSPYx at $500 with the mock's 1% fee
        bytes memory v4HopPath = swapAdapter.encodeQuotronV4Hop(address(usdg), address(wspyx));
        assertEq(v4HopPath.length, 160, "single hop is 160 bytes"); // ADDED
        usdg.approve(address(swapAdapter), 500e6);
        uint256 spyOut = swapAdapter.swapExactIn(address(usdg), address(wspyx), 500e6, 1, address(this), v4HopPath);
        assertGt(spyOut, 0);
        assertEq(spyOut, expectedSpy, "v4 hop output"); // ADDED
        assertEq(wspyx.balanceOf(address(this)), spyOut, "v4 output delivered"); // ADDED

        // 3. Two-hop Mixed (WETH -> USDG on V3, then USDG -> wSPYx on Quotrons V4)
        bytes memory twoHopPath =
            swapAdapter.encodeTwoHopV3ToQuotronV4(address(weth), address(usdg), 3000, address(wspyx));
        assertEq(twoHopPath.length, 384, "two hops are 384 bytes"); // ADDED
        (rU, rW) = _reserves();
        uint256 expectedTwoHop = _v4Out(rU, rW, 1000e6); // ADDED: 0.5 WETH -> 1,000 USDG -> wSPYx
        weth.deposit{value: 0.5 ether}(); // FIX (bankr 2026-11-18): was weth.mint
        weth.approve(address(swapAdapter), 0.5 ether);
        uint256 spyFromWeth =
            swapAdapter.swapExactIn(address(weth), address(wspyx), 0.5 ether, 1, address(this), twoHopPath);
        assertGt(spyFromWeth, 0);
        assertEq(spyFromWeth, expectedTwoHop, "two-hop output"); // ADDED
        assertEq(wspyx.balanceOf(address(this)), spyOut + spyFromWeth, "two-hop output delivered"); // ADDED

        // ADDED (bankr 2026-11-18): the adapter keeps nothing and leaves no approval on the V3 router.
        assertEq(weth.balanceOf(address(swapAdapter)), 0, "adapter WETH");
        assertEq(usdg.balanceOf(address(swapAdapter)), 0, "adapter USDG");
        assertEq(wspyx.balanceOf(address(swapAdapter)), 0, "adapter wSPYx");
        assertEq(weth.allowance(address(swapAdapter), address(v3Router)), 0, "adapter WETH approval");

        // 4. Endpoint mismatch reverts with InvalidHopEndpoints
        weth.deposit{value: 0.1 ether}(); // FIX (bankr 2026-11-18): was weth.mint
        weth.approve(address(swapAdapter), 0.1 ether);
        // FIX (bankr 2026-11-18): the paste used a bare vm.expectRevert(), which passes on any revert at all.
        vm.expectRevert(
            abi.encodeWithSelector(
                YuzuSwapRouterAdapter.InvalidHopEndpoints.selector,
                address(usdg),
                address(wspyx),
                address(weth),
                address(usdg)
            )
        );
        swapAdapter.swapExactIn(address(weth), address(usdg), 0.1 ether, 1, address(this), v4HopPath);
    }

    /// @notice ADDED (bankr 2026-11-18): the sell direction (wSPYx -> USDG, the shape of the registry's
    ///         routes[4]), which runs the other zeroForOne branch; a minimum that cannot be met; and the
    ///         callback's caller check.
    function test_QuotronV4_SellDirection_SlippageRevert_AndCallbackGuard() public {
        wspyx.mint(address(this), 2e18);
        wspyx.approve(address(swapAdapter), 2e18);
        bytes memory sellPath = swapAdapter.encodeQuotronV4Hop(address(wspyx), address(usdg));

        (uint256 rU, uint256 rW) = _reserves();
        uint256 expectedUsdg = _v4Out(rW, rU, 1e18); // about 494.5 USDG for 1 wSPYx
        uint256 out = swapAdapter.swapExactIn(address(wspyx), address(usdg), 1e18, expectedUsdg, address(this), sellPath);
        assertEq(out, expectedUsdg, "sell output");
        assertEq(usdg.balanceOf(address(this)), expectedUsdg, "sell output delivered");
        assertEq(wspyx.balanceOf(address(swapAdapter)), 0, "adapter wSPYx");

        // One unit more than the pool pays: SlippageExceeded, and the whole swap is undone
        (rU, rW) = _reserves();
        uint256 next = _v4Out(rW, rU, 1e18);
        vm.expectRevert(abi.encodeWithSelector(YuzuSwapRouterAdapter.SlippageExceeded.selector, next, next + 1));
        swapAdapter.swapExactIn(address(wspyx), address(usdg), 1e18, next + 1, address(this), sellPath);
        assertEq(wspyx.balanceOf(address(this)), 1e18, "failed swap took nothing");

        // Only the PoolManager may call the callback
        vm.expectRevert(YuzuSwapRouterAdapter.OnlyPoolManager.selector);
        swapAdapter.unlockCallback("");
    }
}
