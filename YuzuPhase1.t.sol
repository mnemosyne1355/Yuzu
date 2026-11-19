// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {YuzuToken} from "../src/YuzuToken.sol";
import {YuzuPoolHook} from "../src/YuzuPoolHook.sol";
import {YuzuSocketBay} from "../src/YuzuSocketBay.sol";
import {YuzuTreasury} from "../src/YuzuTreasury.sol";
import {PoolKey, SwapParams, ModifyLiquidityParams, IUnlockCallback, V4StateLib} from "../src/interfaces/IYuzuV4Interfaces.sol";
import {MockWETH, MockYuzuUnits, MockV4PoolManager} from "./mocks/Phase1Mocks.sol";

contract ExternalSwapper is IUnlockCallback {
    MockV4PoolManager public pm;
    YuzuToken public yuzu;
    MockWETH public weth;
    PoolKey public key;
    bool public yuzuIs0;

    constructor(MockV4PoolManager pm_, YuzuToken yuzu_, MockWETH weth_, PoolKey memory key_) {
        pm = pm_;
        yuzu = yuzu_;
        weth = weth_;
        key = key_;
        yuzuIs0 = address(yuzu_) < address(weth_);
    }

    function attemptBuyYuzu(uint256 yuzuOut, uint256 maxWeth) external {
        pm.unlock(abi.encode(true, yuzuOut, maxWeth, msg.sender));
    }

    function sellYuzu(uint256 yuzuIn) external returns (uint256 wethOut) {
        yuzu.transferFrom(msg.sender, address(this), yuzuIn);
        bytes memory res = pm.unlock(abi.encode(false, yuzuIn, uint256(0), msg.sender));
        wethOut = abi.decode(res, (uint256));
    }

    // CHANGE (bankr 2026-11-18, v4 alignment): real v4 calling convention. A valid price limit on every swap
    // (0 is rejected), one packed BalanceDelta back from swap, and sync -> transfer -> settle() to pay.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (bool isBuy, uint256 amount, , address user) = abi.decode(data, (bool, uint256, uint256, address));
        if (isBuy) {
            bool zeroForOne = !yuzuIs0;
            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? V4StateLib.MIN_SQRT_PRICE_PLUS_ONE
                    : V4StateLib.MAX_SQRT_PRICE_MINUS_ONE
            });
            pm.swap(key, params, "");
            return "";
        } else {
            bool zeroForOne = yuzuIs0;
            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? V4StateLib.MIN_SQRT_PRICE_PLUS_ONE
                    : V4StateLib.MAX_SQRT_PRICE_MINUS_ONE
            });
            (int128 d0, int128 d1) = V4StateLib.unpackDelta(pm.swap(key, params, ""));
            uint256 wethOut = uint256(uint128(yuzuIs0 ? d1 : d0));
            pm.sync(address(yuzu));
            yuzu.transfer(address(pm), amount);
            pm.settle();
            pm.take(address(weth), user, wethOut);
            return abi.encode(wethOut);
        }
    }
}

contract YuzuPhase1Test is Test {
    // CHANGE (bankr 2026-11-18, v4 alignment): the pool now takes real liquidity units, so the test opens it at
    // the deploy script's price (0.0225 WETH : 150,000 $YUZU) instead of a 1:1 placeholder. Set in setUp.
    uint160 OPENING_SQRT_PRICE_X96;

    MockV4PoolManager pm;
    MockWETH weth;
    YuzuToken yuzu;
    MockYuzuUnits units;
    YuzuPoolHook hook;
    YuzuSocketBay socketBay;
    YuzuTreasury treasury;
    PoolKey poolKey;
    ExternalSwapper externalSwapper;

    address multisig = address(0xA11CE);
    address teamWallet = address(0xB0B);
    address seeder = address(0x5EED);
    address distributor = address(0xD157);
    address user1 = address(0x1111);
    address vault1 = address(0x7111);

    function setUp() public {
        pm = new MockV4PoolManager();
        weth = new MockWETH();
        yuzu = new YuzuToken(address(this));
        units = new MockYuzuUnits();
        OPENING_SQRT_PRICE_X96 = address(yuzu) < address(weth)
            ? uint160((uint256(15_000) << 96) / 38_729_833)
            : uint160((uint256(38_729_833) << 96) / 15_000);

        socketBay = new YuzuSocketBay(address(pm), address(yuzu), address(weth));
        treasury = new YuzuTreasury(
            address(pm), address(yuzu), address(weth), multisig, teamWallet, OPENING_SQRT_PRICE_X96
        );
        hook = new YuzuPoolHook(
            address(pm),
            address(yuzu),
            address(weth),
            address(treasury),
            address(socketBay),
            address(units),
            OPENING_SQRT_PRICE_X96
        );

        address c0 = address(yuzu) < address(weth) ? address(yuzu) : address(weth);
        address c1 = address(yuzu) < address(weth) ? address(weth) : address(yuzu);
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 10000, tickSpacing: 200, hooks: address(hook)});

        socketBay.configureCore(address(units), seeder, distributor, poolKey);
        treasury.configureCore(
            address(hook), address(socketBay), address(units), seeder, distributor, address(0), address(0), poolKey
        );

        // Transfer v4.9 allocations: 150.1M to Seeder, 849.9M to Treasury
        yuzu.transfer(seeder, 150_100_000e18);
        yuzu.transfer(address(treasury), 849_900_000e18);

        externalSwapper = new ExternalSwapper(pm, yuzu, weth, poolKey);

        // Commission #0000 at deployment: opens pool with 0.0225 WETH + 150,000 $YUZU
        units.setUnit(0, multisig, address(0x7000), false);
        units.setCommissioned(1, 0);
        vm.deal(seeder, 100 ether);
        vm.startPrank(seeder);
        weth.deposit{value: 0.0600 ether}();
        weth.transfer(address(treasury), 0.0600 ether);
        treasury.receiveCommissioningWeth(0.0225 ether, 0.0375 ether);
        yuzu.transfer(address(socketBay), 250_000e18);
        socketBay.seedInitialRam(0, 5);
        vm.stopPrank();

        // Setup Unit #1 for user1
        units.setUnit(1, user1, vault1, false);
        units.setCommissioned(2, block.timestamp);
        vm.startPrank(seeder);
        weth.deposit{value: 0.0600 ether}();
        weth.transfer(address(treasury), 0.0600 ether);
        treasury.receiveCommissioningWeth(0.0225 ether, 0.0375 ether);
        yuzu.transfer(address(socketBay), 150_000e18);
        socketBay.seedInitialRam(1, 1);
        vm.stopPrank();
    }

    function test_V49_SupplyAndAllocations() public view {
        assertEq(yuzu.totalSupply(), 1_000_000_000e18);
        // 2 units commissioned -> 300,000 $YUZU added to LP out of 250M LP Reserve
        // CHANGE (v4 alignment): the LP reserve is debited by what the position actually took (rounding stays in it)
        assertApproxEqAbs(treasury.totalYuzuAddedToLp(), 300_000e18, 1e17);
        assertEq(treasury.lpReserveYuzuRemaining(), 250_000_000e18 - treasury.totalYuzuAddedToLp());
        assertEq(treasury.ecosystemVaultYuzuRemaining(), 349_900_000e18);
    }

    function test_LaunchGate_BlocksExternalWalletBuy() public {
        vm.deal(user1, 1 ether);
        vm.startPrank(user1);
        weth.deposit{value: 0.1 ether}();
        weth.transfer(address(externalSwapper), 0.1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(YuzuPoolHook.LaunchGateBuyRestricted.selector, address(externalSwapper))
        );
        externalSwapper.attemptBuyYuzu(10_000e18, 0.1 ether);
        vm.stopPrank();
    }

    function test_LaunchGate_AllowsSocketBayBuyAndSeat_AndUpdatesGates() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        uint256 spent = socketBay.buyAndSeat{value: 0.05 ether}(1, 2, 0.05 ether);
        assertGt(spent, 0);
        assertEq(socketBay.ramTier(1), 3);
        assertEq(socketBay.ramLocked(1), 200_000e18);
        assertEq(socketBay.netSeatedYuzu(), 50_000e18); // 2 blades = 50,000 $YUZU net seated
    }

    function test_LaunchGate_AllowsSellingByAnyone() public {
        // Give user1 some reward $YUZU and sell into the pool while gate is active
        vm.prank(seeder);
        yuzu.transfer(user1, 10_000e18);

        vm.startPrank(user1);
        yuzu.approve(address(externalSwapper), 10_000e18);
        uint256 wethOut = externalSwapper.sellYuzu(10_000e18);
        vm.stopPrank();

        assertGt(wethOut, 0);
        assertEq(weth.balanceOf(user1), wethOut);
    }

    function test_LaunchGate_BufferCapEnforcedAt50kPerVault() public {
        vm.deal(vault1, 1 ether);
        vm.startPrank(vault1);
        weth.deposit{value: 0.5 ether}();
        weth.approve(address(socketBay), 0.5 ether);

        socketBay.buyBufferFor(1, 30_000e18, 0.1 ether);
        assertEq(socketBay.gateBought(vault1), 30_000e18);

        // Exceeding 50,000 lifetime cap reverts
        vm.expectRevert(abi.encodeWithSelector(YuzuSocketBay.VaultBufferCapExceeded.selector, 55_000e18));
        socketBay.buyBufferFor(1, 25_000e18, 0.1 ether);

        // Buying remaining 20,000 succeeds
        socketBay.buyBufferFor(1, 20_000e18, 0.1 ether);
        assertEq(socketBay.gateBought(vault1), 50_000e18);
        vm.stopPrank();
    }

    function test_FarmGate_1To1_AndSubtractionOnForfeit() public {
        // Initially netSeatedYuzu == 0 -> Farm emits 0
        vm.prank(distributor);
        uint256 emitted0 = treasury.emitWeeklyFarm(1);
        assertEq(emitted0, 0);

        // Pool depth: with 2 units commissioned the pool holds 300,000 $YUZU, less than the 350,000 bought below.

        // Add three more units of commissioning liquidity first (5 units = 750,000 $YUZU in the pool).

        vm.startPrank(seeder);

        for (uint256 i = 0; i < 3; i++) {

            weth.deposit{value: 0.0600 ether}();

            weth.transfer(address(treasury), 0.0600 ether);

            treasury.receiveCommissioningWeth(0.0225 ether, 0.0375 ether);

        }

        vm.stopPrank();


        // User1 seats 4 blades (100,000 $YUZU) + 1 ROM bond (250,000 $YUZU) = 350,000 $YUZU net seated
        vm.deal(user1, 5 ether);
        vm.startPrank(user1);
        socketBay.buyAndSeat{value: 1 ether}(1, 4, 1 ether);
        socketBay.buyAndBond{value: 2 ether}(1, 2 ether);
        vm.stopPrank();

        assertEq(socketBay.netSeatedYuzu(), 350_000e18);

        // Farm Gate (1:1) now allows emitting 350,000 $YUZU (less than weekly 1,922,115 cap)
        vm.prank(distributor);
        uint256 emitted1 = treasury.emitWeeklyFarm(1);
        assertEq(emitted1, 350_000e18);
        assertEq(treasury.totalFarmEmitted(), 350_000e18);

        // Next epoch emits 0 until more blades/bonds are seated
        vm.prank(distributor);
        assertEq(treasury.emitWeeklyFarm(2), 0);

        // If Unit #1 raids its seed and forfeits RAM + bond, netSeatedYuzu drops back to 0
        vm.prank(vault1);
        uint256 forfeited = socketBay.forfeit(1);
        assertEq(forfeited, 500_000e18); // 150k starter + 100k blades + 250k bond
        assertEq(socketBay.netSeatedYuzu(), 0);
    }

    function test_RndSeatGate_3Per20_AndTeamReleaseLimit_2PercentPool() public {
        // Seat 100,000 $YUZU on Unit #1
        vm.deal(user1, 2 ether);
        vm.prank(user1);
        socketBay.buyAndSeat{value: 1 ether}(1, 4, 1 ether);
        assertEq(socketBay.netSeatedYuzu(), 100_000e18);

        // Cannot release R&D or Team before Launch Gate lifts
        assertEq(treasury.releasableRnd(), 0);

        // Warp 90 days + 1 second after #0001 commission and lift gate
        vm.warp(block.timestamp + 90 days + 1);
        hook.liftGate();
        assertTrue(hook.gateLifted());

        // 3/20 (15%) of 100,000 $YUZU = 15,000 $YUZU R&D ceiling (time-vested after 90d is ~6.16M, so Seat Gate binds!)
        assertEq(treasury.releasableRnd(), 15_000e18);
        vm.prank(multisig);
        uint256 rndOut = treasury.releaseRnd(multisig);
        assertEq(rndOut, 15_000e18);
        assertEq(treasury.releasableRnd(), 0);

        // Warp past 12-month Team cliff (to day 400)
        vm.warp(block.timestamp + 310 days);
        uint256 teamOut = treasury.releaseTeam();
        assertGt(teamOut, 0);
        assertEq(yuzu.balanceOf(teamWallet), teamOut);

        // Second call within 30 days reverts
        vm.expectRevert(YuzuTreasury.TeamCooldownActive.selector);
        treasury.releaseTeam();
    }

    // =========================================================================
    // ADDED (bankr 2026-11-19): sellout sweep + emitWeeklyFarm caller error.
    // Written against this repo's Treasury and mocks; the tests pasted by the founder 2026-11-19 03:58Z used
    // helpers that do not exist here (mockUnits.setCommissionedCount, a distributor contract) and sent WETH to
    // the Treasury without crediting the LP reserve, so they could not run.
    // =========================================================================

    /// @dev Leaves unpaired WETH in the LP reserve while $YUZU is still in it. With 2 units commissioned the
    ///      cumulative ceiling is 500,000 $YUZU and about 300,000 is already in the pool, so 0.06 WETH (worth
    ///      400,000 $YUZU at the pool ratio) can only be paired with about 200,000 $YUZU; about 0.03 WETH stays.
    function _leaveUnpairedLpWeth() internal returns (uint256 pendingWeth) {
        vm.startPrank(seeder);
        weth.deposit{value: 0.06 ether}();
        weth.transfer(address(treasury), 0.06 ether);
        treasury.receiveCommissioningWeth(0.06 ether, 0);
        vm.stopPrank();
        pendingWeth = treasury.lpReserveWethPending();
        assertGt(pendingWeth, 0.02 ether);
        assertGt(treasury.lpReserveYuzuRemaining(), 0);
    }

    function test_SweepSelloutLpLeftovers_PairsThenSweepsBothBuckets() public {
        uint256 pending = _leaveUnpairedLpWeth();

        // Not before sellout
        vm.expectRevert(YuzuTreasury.SelloutNotReached.selector);
        treasury.sweepSelloutLpLeftovers();

        units.setCommissioned(1000, block.timestamp);

        uint256 yuzuReserveBefore = treasury.lpReserveYuzuRemaining();
        uint256 addedBefore = treasury.totalYuzuAddedToLp();
        uint256 ecoBefore = treasury.ecosystemVaultYuzuRemaining();
        uint256 distWethBefore = weth.balanceOf(distributor);
        uint256 pmWethBefore = weth.balanceOf(address(pm));
        uint256 treasuryWethBefore = weth.balanceOf(address(treasury));
        uint256 treasuryYuzuBefore = yuzu.balanceOf(address(treasury));
        uint256 treasuryFundsBefore = treasury.treasuryWethFunds();

        // Both buckets are non-zero here: the sweep has to pair first, then sweep what is left of BOTH.
        treasury.sweepSelloutLpLeftovers();

        uint256 yuzuPaired = treasury.totalYuzuAddedToLp() - addedBefore;
        uint256 wethPaired = weth.balanceOf(address(pm)) - pmWethBefore;
        uint256 wethSwept = weth.balanceOf(distributor) - distWethBefore;
        emit log_named_uint("LP WETH pending before sweep (wei)", pending);
        emit log_named_uint("WETH paired into the pool (wei)", wethPaired);
        emit log_named_uint("WETH swept to distributor (wei)", wethSwept);
        emit log_named_uint("YUZU paired into the pool (wei)", yuzuPaired);
        emit log_named_uint("YUZU swept to ecosystem vault (wei)", yuzuReserveBefore - yuzuPaired);

        // The pending WETH was paired at the pool ratio (about 0.03 WETH with about 200,000 $YUZU), not given away
        assertGt(wethPaired, 0.029 ether);
        assertApproxEqRel(yuzuPaired, 200_000e18, 1e16);

        // Both buckets end at zero and every wei is accounted for
        assertEq(treasury.lpReserveWethPending(), 0);
        assertEq(treasury.lpReserveYuzuRemaining(), 0);
        assertTrue(treasury.lpLeftoversSwept());
        assertEq(wethPaired + wethSwept, pending);
        assertEq(weth.balanceOf(address(treasury)), treasuryWethBefore - pending);
        assertEq(treasury.ecosystemVaultYuzuRemaining(), ecoBefore + yuzuReserveBefore - yuzuPaired);
        assertEq(yuzu.balanceOf(address(treasury)), treasuryYuzuBefore - yuzuPaired);
        assertEq(treasury.treasuryWethFunds(), treasuryFundsBefore);

        // One shot
        vm.expectRevert(YuzuTreasury.NothingToRelease.selector);
        treasury.sweepSelloutLpLeftovers();
    }

    function test_SweepSelloutLpLeftovers_WaitsWhilePriceIsOutsideTheBand() public {
        uint256 pending = _leaveUnpairedLpWeth();
        units.setCommissioned(1000, block.timestamp);
        hook.liftGate();

        bytes32 pid = treasury.poolId();
        int24 refTick = hook.referenceTick();
        uint256 yuzuReserveBefore = treasury.lpReserveYuzuRemaining();
        uint256 distWethBefore = weth.balanceOf(distributor);

        // Spot price pushed outside the reference band: the pending LP WETH must NOT be swept to the reward pool
        pm.setTickForTest(pid, refTick + 1000);
        vm.expectRevert(YuzuTreasury.OutsideReferenceBand.selector);
        treasury.sweepSelloutLpLeftovers();
        assertEq(treasury.lpReserveWethPending(), pending);
        assertEq(treasury.lpReserveYuzuRemaining(), yuzuReserveBefore);
        assertEq(weth.balanceOf(distributor), distWethBefore);
        assertFalse(treasury.lpLeftoversSwept());

        // Back inside the band: the sweep pairs and completes
        pm.setTickForTest(pid, refTick);
        treasury.sweepSelloutLpLeftovers();
        assertEq(treasury.lpReserveWethPending(), 0);
        assertEq(treasury.lpReserveYuzuRemaining(), 0);
        assertTrue(treasury.lpLeftoversSwept());
        // Only rounding dust went to the reward pool; the rest of the 0.03 WETH went into the pool
        assertLt(weth.balanceOf(distributor) - distWethBefore, 1e12);
    }

    function test_EmitWeeklyFarm_RevertsOnlyDistributor() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OnlyDistributor()"));
        treasury.emitWeeklyFarm(1);
    }
}
