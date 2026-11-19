// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    PoolKey,
    SwapParams,
    IUnlockCallback,
    IPoolManager,
    IWETH,
    V4StateLib
} from "../src/interfaces/IYuzuV4Interfaces.sol";
import {YuzuToken} from "../src/YuzuToken.sol";
import {YuzuPoolHook} from "../src/YuzuPoolHook.sol";
import {YuzuSocketBay} from "../src/YuzuSocketBay.sol";
import {YuzuTreasury} from "../src/YuzuTreasury.sol";
import {YuzuSwapRouterAdapter} from "../src/adapters/YuzuSwapRouterAdapter.sol";
import {MockYuzuUnits} from "./mocks/Phase1Mocks.sol";

/// @dev An ordinary wallet's route into a v4 pool: exact-input swap, paid with sync -> transfer -> settle().
contract ForkSwapper is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable pm;

    constructor(address pm_) {
        pm = IPoolManager(pm_);
    }

    function swapExactIn(PoolKey memory key, address tokenIn, uint256 amountIn, address to)
        external
        returns (uint256 out)
    {
        out = abi.decode(pm.unlock(abi.encode(key, tokenIn, amountIn, to)), (uint256));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "ONLY_POOL_MANAGER");
        (PoolKey memory key, address tokenIn, uint256 amountIn, address to) =
            abi.decode(data, (PoolKey, address, uint256, address));
        bool zeroForOne = tokenIn == key.currency0;
        (int128 d0, int128 d1) = V4StateLib.unpackDelta(
            pm.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zeroForOne
                        ? V4StateLib.MIN_SQRT_PRICE_PLUS_ONE
                        : V4StateLib.MAX_SQRT_PRICE_MINUS_ONE
                }),
                ""
            )
        );
        uint256 out = uint256(uint128(zeroForOne ? d1 : d0));
        pm.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(address(pm), amountIn);
        pm.settle();
        pm.take(zeroForOne ? key.currency1 : key.currency0, to, out);
        return abi.encode(out);
    }
}

/// @notice ADDED (bankr 2026-11-18, v4 alignment pass, founder request). Runs the real YuzuTreasury, YuzuPoolHook,
///         YuzuSocketBay and YuzuSwapRouterAdapter against Ink's deployed Uniswap v4 PoolManager on a fork.
/// @dev Needs the environment variable INK_RPC_URL (e.g. https://rpc-gel.inkonchain.com); without it every test
///      here is skipped, so the normal suite never touches the network:
///        INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-path test/YuzuInkFork.t.sol -vv
///      A fork is a local copy of Ink's state: nothing is sent to the chain. The unit registry is MockYuzuUnits and
///      the seeder / distributor are plain addresses; the Seeder, vaults, registry, lens and oracles are not here.
contract YuzuInkForkTest is Test {
    using SafeERC20 for IERC20;

    address pm;
    address weth;
    address usdg;
    address wspyx;
    bool forked;

    YuzuToken yuzu;
    MockYuzuUnits units;
    YuzuTreasury treasury;
    YuzuSocketBay socketBay;
    YuzuPoolHook hook;
    PoolKey key;
    bytes32 poolId;
    uint160 opening;

    address multisig = address(0xA11CE);
    address team = address(0xB0B);
    address seeder = address(0x5EED);
    address distributor = address(0xD157);
    address user1 = address(0x1111);
    address vault1 = address(0x7111);

    function setUp() public {
        string memory url = vm.envOr("INK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        require(block.chainid == 57073, "not Ink");
        forked = true;

        pm = vm.parseAddress("0x360e68faccca8ca495c1b759fd9eee466db9fb32");
        weth = vm.parseAddress("0x4200000000000000000000000000000000000006");
        usdg = vm.parseAddress("0xe343167631d89b6ffc58b88d6b7fb0228795491d");
        wspyx = vm.parseAddress("0xe7e553cd128f0011777323a0b44a7b96ea1cb540");
        require(pm.code.length > 0, "no PoolManager");

        yuzu = new YuzuToken(address(this));
        units = new MockYuzuUnits();
        // Same formula as script/DeployYuzu98V50.s.sol computeOpeningSqrtPriceX96
        opening = address(yuzu) < weth
            ? uint160((uint256(15_000) << 96) / 38_729_833)
            : uint160((uint256(38_729_833) << 96) / 15_000);

        socketBay = new YuzuSocketBay(pm, address(yuzu), weth);
        treasury = new YuzuTreasury(pm, address(yuzu), weth, multisig, team, opening);

        // Hook address mined so its low 14 bits are 0x2880 (beforeInitialize | beforeAddLiquidity | beforeSwap)
        bytes memory initCode = abi.encodePacked(
            type(YuzuPoolHook).creationCode,
            abi.encode(pm, address(yuzu), weth, address(treasury), address(socketBay), address(units), opening)
        );
        (bytes32 salt, address predicted) = _mineHookSalt(initCode);
        hook = new YuzuPoolHook{salt: salt}(
            pm, address(yuzu), weth, address(treasury), address(socketBay), address(units), opening
        );
        require(address(hook) == predicted, "hook address");

        bool yuzuIs0 = address(yuzu) < weth;
        key = PoolKey({
            currency0: yuzuIs0 ? address(yuzu) : weth,
            currency1: yuzuIs0 ? weth : address(yuzu),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(hook)
        });
        poolId = keccak256(abi.encode(key));

        socketBay.configureCore(address(units), seeder, distributor, key);
        treasury.configureCore(
            address(hook), address(socketBay), address(units), seeder, distributor, address(0), address(0), key
        );
        yuzu.transfer(seeder, 150_100_000e18);
        yuzu.transfer(address(treasury), 849_900_000e18);
    }

    function _mineHookSalt(bytes memory initCode) internal view returns (bytes32 salt, address predicted) {
        bytes32 h = keccak256(initCode);
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))));
            if (uint160(predicted) & 0x3FFF == 0x2880) return (salt, predicted);
        }
        revert("HOOK_SALT_NOT_FOUND");
    }

    /// @dev What the Seeder does on every commissioning: 0.0225 WETH for the pool, 0.0375 WETH for the Treasury.
    function _commission() internal {
        vm.deal(seeder, 1 ether);
        vm.startPrank(seeder);
        IWETH(weth).deposit{value: 0.06 ether}();
        IWETH(weth).transfer(address(treasury), 0.06 ether);
        treasury.receiveCommissioningWeth(0.0225 ether, 0.0375 ether);
        vm.stopPrank();
    }

    /// @dev The pool's total liquidity as the real PoolManager stores it (Pool.State.liquidity, 3 slots after slot0).
    function _poolLiquidity() internal view returns (uint128) {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        return uint128(uint256(IPoolManager(pm).extsload(bytes32(uint256(stateSlot) + 3))));
    }

    /// @dev Every WETH and $YUZU the Treasury holds is in one of its ledgers, to the wei.
    function _assertTreasuryLedgers(string memory when) internal view {
        assertEq(
            IERC20(weth).balanceOf(address(treasury)),
            treasury.treasuryWethFunds() + treasury.lpReserveWethPending() + treasury.buybackWethReserve(),
            string.concat("WETH ledger: ", when)
        );
        assertEq(
            yuzu.balanceOf(address(treasury)),
            849_900_000e18 - treasury.totalYuzuAddedToLp(),
            string.concat("YUZU ledger: ", when)
        );
        assertEq(_poolLiquidity(), treasury.lockedLiquidity(), string.concat("pool liquidity: ", when));
    }

    function dealExternal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }

    /// @dev Gives the test tokens on the fork. Falls back to moving them out of the PoolManager's own balance when
    ///      the token's storage layout defeats forge's deal.
    function _fund(address token, address to, uint256 amount) internal {
        try this.dealExternal(token, to, amount) {}
        catch {
            vm.prank(pm);
            IERC20(token).safeTransfer(to, amount);
        }
        require(IERC20(token).balanceOf(to) >= amount, "fund failed");
    }

    function test_Fork_Treasury_Hook_SocketBay_OnInkPoolManager() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        IPoolManager p = IPoolManager(pm);

        console.log("YuzuTreasury runtime bytes", address(treasury).code.length);
        console.log("YuzuPoolHook runtime bytes", address(hook).code.length);
        console.log("YuzuSocketBay runtime bytes", address(socketBay).code.length);
        assertLt(address(treasury).code.length, 24_576, "treasury size");
        assertEq(uint160(address(hook)) & 0x3FFF, 0x2880, "hook flags");

        // 1. The real PoolManager calls the hook on initialize: nobody but the Treasury can open the pool
        vm.expectRevert();
        p.initialize(key, opening);

        // 2. #0000: the Treasury opens the pool and adds the first liquidity
        units.setUnit(0, multisig, address(0x7000), false);
        units.setCommissioned(1, 0);
        _commission();
        assertTrue(treasury.poolOpened(), "pool opened");
        (uint160 sqrtP, int24 tick) = V4StateLib.getSlot0(p, poolId);
        assertEq(sqrtP, opening, "pool price read through extsload");
        // The hook must record the pool's real opening tick (it recorded 0 before the fix: DEPLOY_SCRIPT_NOTES.md 0d).
        emit log_named_int("pool tick at open", tick);
        emit log_named_int("hook referenceTick at open", hook.referenceTick());
        emit log_named_int("hook lastRecordedTick at open", hook.lastRecordedTick());
        assertEq(hook.referenceTick(), tick, "hook referenceTick = pool opening tick");
        assertEq(hook.lastRecordedTick(), tick, "hook lastRecordedTick = pool opening tick");
        console.log("opening tick (abs)", uint256(int256(tick < 0 ? -tick : tick)));
        int24 absTick = tick < 0 ? -tick : tick;
        assertGt(absTick, 157_000, "tick");
        assertLt(absTick, 157_300, "tick");
        uint256 added = treasury.totalYuzuAddedToLp();
        console.log("YUZU into the pool at open", added);
        console.log("WETH left unpaired at open", treasury.lpReserveWethPending());
        assertApproxEqAbs(added, 150_000e18, 1e17, "YUZU added");
        assertEq(yuzu.balanceOf(pm), added, "PoolManager holds exactly what the Treasury was debited");
        assertApproxEqAbs(treasury.lpReserveWethPending(), 0, 1e6, "WETH used");
        assertGt(treasury.lockedLiquidity(), 0, "liquidity");
        _assertTreasuryLedgers("after open");

        // 3. #0001: a second add at the pool ratio
        units.setUnit(1, user1, vault1, false);
        units.setCommissioned(2, block.timestamp);
        _commission();
        assertApproxEqAbs(treasury.totalYuzuAddedToLp(), 300_000e18, 2e17, "YUZU added after #0001");
        _assertTreasuryLedgers("after #0001");

        // 4. Launch Gate on the real PoolManager: an outside wallet cannot buy $YUZU
        ForkSwapper swapper = new ForkSwapper(pm);
        vm.deal(address(this), 1 ether);
        IWETH(weth).deposit{value: 0.01 ether}();
        IWETH(weth).transfer(address(swapper), 0.01 ether);
        vm.expectRevert();
        swapper.swapExactIn(key, weth, 0.001 ether, address(this));

        // 5. ...but a unit owner can, through the SocketBay (exact-output buy of 2 blades = 50,000 $YUZU)
        vm.prank(seeder);
        socketBay.seedInitialRam(1, 1);
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        uint256 spent = socketBay.buyAndSeat{value: 0.05 ether}(1, 2, 0.05 ether);
        console.log("WETH paid for 50,000 YUZU", spent);
        assertEq(socketBay.ramTier(1), 3, "tier");
        assertEq(yuzu.balanceOf(address(socketBay)), 50_000e18, "SocketBay received the blades");
        assertGt(spent, 0.009 ether, "spent");
        assertLt(spent, 0.0095 ether, "spent");
        assertEq(user1.balance, 1 ether - spent, "refund");

        // 6. Selling is open to anyone during the gate
        vm.prank(seeder);
        yuzu.transfer(address(swapper), 20_000e18);
        uint256 wethOut = swapper.swapExactIn(key, address(yuzu), 10_000e18, user1);
        assertGt(wethOut, 0, "sell output");

        // 7. Fee collection from the locked position: 1% of each swap's input
        uint256 distYuzu = yuzu.balanceOf(distributor);
        uint256 distWeth = IERC20(weth).balanceOf(distributor);
        uint256 funds = treasury.treasuryWethFunds();
        (uint256 wethFees, uint256 yuzuFees) = treasury.collectLpFees();
        console.log("LP fees collected, WETH", wethFees);
        console.log("LP fees collected, YUZU", yuzuFees);
        assertApproxEqRel(yuzuFees, 100e18, 1e15, "1% of 10,000 YUZU sold");
        assertApproxEqRel(wethFees, spent / 100, 1e16, "1% of the WETH paid");
        assertEq(yuzu.balanceOf(distributor) - distYuzu, yuzuFees, "YUZU fees to distributor");
        assertEq(IERC20(weth).balanceOf(distributor) - distWeth, wethFees / 2, "half the WETH fees to distributor");
        assertEq(treasury.treasuryWethFunds() - funds, wethFees - wethFees / 2, "half the WETH fees to treasury");
        _assertTreasuryLedgers("after collect");

        // 8. Fees that accrue before the next liquidity add are paid out by that add; they still go to the reward
        //    pool and the ledgers still match
        swapper.swapExactIn(key, address(yuzu), 10_000e18, user1);
        units.setCommissioned(3, units.firstPublicCommissionAt());
        distYuzu = yuzu.balanceOf(distributor);
        added = treasury.totalYuzuAddedToLp();
        _commission();
        assertGt(treasury.totalYuzuAddedToLp(), added, "liquidity added");
        assertApproxEqRel(yuzu.balanceOf(distributor) - distYuzu, 100e18, 1e15, "fees paid out by the add");
        _assertTreasuryLedgers("after add with fees");

        // 9. Gate lift after 90 days, then a buyback swap through the Treasury
        vm.warp(block.timestamp + 90 days + 1);
        hook.liftGate();
        IWETH(weth).deposit{value: 0.01 ether}();
        IWETH(weth).approve(address(treasury), 0.01 ether);
        treasury.recordProtocolFeeWeth(0, 0.01 ether);
        distYuzu = yuzu.balanceOf(distributor);
        (uint256 wethSpent, uint256 bought) = treasury.executeBuyback();
        console.log("buyback WETH spent", wethSpent);
        console.log("buyback YUZU bought", bought);
        assertGt(wethSpent, 0, "buyback spent");
        assertGt(bought, 0, "buyback bought");
        assertEq(yuzu.balanceOf(distributor) - distYuzu, bought, "bought YUZU to distributor");
        _assertTreasuryLedgers("after buyback");

        // 10. ADDED (bankr 2026-11-19): sellout sweep on the real PoolManager. Real v4 rounding leaves a few wei of
        //     WETH in the LP reserve next to the unused $YUZU, so both buckets can be non-zero here: the case the
        //     old sweep could not handle (DEPLOY_SCRIPT_NOTES.md 0e).
        units.setCommissioned(1000, units.firstPublicCommissionAt());
        uint256 swWethPending = treasury.lpReserveWethPending();
        uint256 swYuzuLeft = treasury.lpReserveYuzuRemaining();
        console.log("LP WETH pending before sweep (wei)", swWethPending);
        assertGt(swYuzuLeft, 0, "YUZU left before sweep");
        uint256 swEco = treasury.ecosystemVaultYuzuRemaining();
        uint256 swDistWeth = IERC20(weth).balanceOf(distributor);
        uint256 swAdded = treasury.totalYuzuAddedToLp();
        treasury.sweepSelloutLpLeftovers();
        uint256 swPairedYuzu = treasury.totalYuzuAddedToLp() - swAdded;
        uint256 swWethToDist = IERC20(weth).balanceOf(distributor) - swDistWeth;
        console.log("WETH swept to distributor (wei)", swWethToDist);
        console.log("YUZU paired by the sweep (wei)", swPairedYuzu);
        assertEq(treasury.lpReserveWethPending(), 0, "WETH bucket empty");
        assertEq(treasury.lpReserveYuzuRemaining(), 0, "YUZU bucket empty");
        assertEq(treasury.ecosystemVaultYuzuRemaining(), swEco + swYuzuLeft - swPairedYuzu, "leftover YUZU to ecosystem vault");
        assertTrue(treasury.lpLeftoversSwept(), "swept");
        _assertTreasuryLedgers("after sellout sweep");
    }

    function test_Fork_AdapterSwapsOnRealQuotronPool() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        // The V3 router is not used by a single v4 hop; its Ink address is still not supplied
        YuzuSwapRouterAdapter adapter = new YuzuSwapRouterAdapter(pm, address(0xDEAD));
        console.log("YuzuSwapRouterAdapter runtime bytes", address(adapter).code.length);

        _fund(usdg, address(this), 500e6);
        uint256 spyBefore = IERC20(wspyx).balanceOf(address(this));

        // USDG -> wSPYx on the real Quotrons pool, through the real QuotronStockHook
        IERC20(usdg).forceApprove(address(adapter), 500e6);
        uint256 spyOut = adapter.swapExactIn(
            usdg, wspyx, 500e6, 1, address(this), adapter.encodeQuotronV4Hop(usdg, wspyx)
        );
        console.log("500 USDG -> wSPYx (18 dp)", spyOut);
        assertGt(spyOut, 0, "wSPYx out");
        assertEq(IERC20(wspyx).balanceOf(address(this)) - spyBefore, spyOut, "wSPYx delivered");
        uint256 usdgPerWspyx = (uint256(500e6) * 1e18) / spyOut;
        console.log("implied USDG per wSPYx (6 dp)", usdgPerWspyx);
        assertGt(usdgPerWspyx, 100e6, "price sanity");
        assertLt(usdgPerWspyx, 5_000e6, "price sanity");

        // wSPYx -> USDG, the other direction
        uint256 usdgBefore = IERC20(usdg).balanceOf(address(this));
        IERC20(wspyx).forceApprove(address(adapter), spyOut);
        uint256 usdgBack = adapter.swapExactIn(
            wspyx, usdg, spyOut, 1, address(this), adapter.encodeQuotronV4Hop(wspyx, usdg)
        );
        console.log("round trip back to USDG (6 dp)", usdgBack);
        assertEq(IERC20(usdg).balanceOf(address(this)) - usdgBefore, usdgBack, "USDG delivered");
        assertGt(usdgBack, 450e6, "round trip lost more than 10%");
        assertLt(usdgBack, 500e6, "round trip cannot profit");

        assertEq(IERC20(usdg).balanceOf(address(adapter)), 0, "adapter USDG");
        assertEq(IERC20(wspyx).balanceOf(address(adapter)), 0, "adapter wSPYx");
    }
}
