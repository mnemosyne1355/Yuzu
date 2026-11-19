// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {YuzuCartridge} from "../src/YuzuCartridge.sol";
import {YuzuRelativeStrengthAdapter} from "../src/adapters/YuzuRelativeStrengthAdapter.sol";
import {
    MockERC20_5,
    MockWETH5,
    MockMainframe5,
    MockVault5,
    MockSocketBay5,
    MockLens5,
    MockRegistry5,
    MockTreasury5,
    MockArchive5,
    MockHypercallAdapter,
    MockTydroLendingAdapter
} from "./mocks/Phase5Mocks.sol";

contract YuzuPhase5Test is Test {
    YuzuCartridge cartridge;
    YuzuRelativeStrengthAdapter rsAdapter;

    MockWETH5 weth;
    MockERC20_5 usdg;
    MockERC20_5 wspyx;
    MockERC20_5 tydroUsdgReceipt;

    MockMainframe5 mainframe;
    MockVault5 vault1;
    MockSocketBay5 socketBay;
    MockLens5 lens;
    MockRegistry5 registry;
    MockTreasury5 treasury;
    MockArchive5 archive;
    MockHypercallAdapter hypercall;
    MockTydroLendingAdapter tydro;

    address owner = address(0x1111);
    address aiAgent = address(0xA1A1);

    function setUp() public {
        vm.warp(1_760_000_000);

        weth = new MockWETH5();
        usdg = new MockERC20_5("Global Dollar", "USDG", 6);
        wspyx = new MockERC20_5("Wrapped SPYx", "wSPYx", 18);
        tydroUsdgReceipt = new MockERC20_5("Tydro USDG", "tUSDG", 6);

        mainframe = new MockMainframe5();
        vault1 = new MockVault5();
        socketBay = new MockSocketBay5();
        lens = new MockLens5();
        registry = new MockRegistry5();
        treasury = new MockTreasury5(weth);
        archive = new MockArchive5();
        hypercall = new MockHypercallAdapter();
        tydro = new MockTydroLendingAdapter(tydroUsdgReceipt);

        // Set prices: WETH = $2,000, USDG = $1, wSPYx = $500, tUSDG = $1
        lens.setPrice(address(weth), 2000e18, 18);
        lens.setPrice(address(usdg), 1e18, 6);
        lens.setPrice(address(wspyx), 500e18, 18);
        lens.setPrice(address(tydroUsdgReceipt), 1e18, 6);

        registry.addPricedAsset(address(weth));
        registry.addPricedAsset(address(usdg));
        registry.addPricedAsset(address(wspyx));
        registry.addPricedAsset(address(tydroUsdgReceipt));

        registry.setVenue(address(hypercall), true, false, false, address(0));
        registry.setVenue(address(tydro), true, false, true, address(tydroUsdgReceipt));

        cartridge = new YuzuCartridge(
            address(mainframe),
            address(socketBay),
            address(lens),
            address(registry),
            address(treasury),
            address(weth)
        );

        rsAdapter = new YuzuRelativeStrengthAdapter(address(registry), address(lens), address(archive));

        // Configure Unit #1: Owner, Vault1, Tier 2 RAM (40% max exposure cap)
        mainframe.setUnit(1, owner, address(vault1));
        socketBay.setTier(1, 2);
        vault1.setAiKey(aiAgent, block.timestamp + 1 days);

        // Vault1 holds: 0.1 WETH seed ($200) + 0.9 WETH non-seed ($1,800) + 1,000 USDG non-seed ($1,000) -> $3,000 NAV
        weth.mint(address(vault1), 1.0 ether);
        vault1.setSeed(address(weth), 0.1 ether);
        usdg.mint(address(vault1), 1000e6);
    }

    function test_Slot2_DeskPolicy_CoveredCallWriting_Min50UsdFloor_And10PercentSkim() public {
        // 1. Fresh unit has empty policy -> AI key cannot write a call
        vm.prank(aiAgent);
        vm.expectRevert(abi.encodeWithSelector(YuzuCartridge.AssetNotAllowedByPolicy.selector, address(weth)));
        cartridge.writeCoveredCall(
            1, address(hypercall), address(weth), 0.1 ether, 2100e18, uint64(block.timestamp + 3 days), address(weth), 0.002 ether
        );

        // 2. Vault sets Desk Policy via Tier 3: allow WETH, minStrike 103% (10300 bps), minPremium 100 bps (1%),
        //    maxExpiry 5 days, maxExposureShare 50% (5000 bps of Tier-2's 40% = 20% of $3,000 = $600 max)
        address[] memory allowed = new address[](1);
        allowed[0] = address(weth);
        vm.prank(address(vault1));
        cartridge.setPolicyFromVaultTier3(1, allowed, 10300, 100, 5 days, 5000);

        // 3. Dust call (< $50 minCollateralUsd: 0.01 WETH = $20) reverts!
        vm.prank(aiAgent);
        vm.expectRevert(abi.encodeWithSelector(YuzuCartridge.CollateralBelowMinUsd.selector, 20e18, 50e18));
        cartridge.writeCoveredCall(
            1, address(hypercall), address(weth), 0.01 ether, 2100e18, uint64(block.timestamp + 3 days), address(weth), 0.0002 ether
        );

        // 4. Strike below policy minimum (102.5% = $2,050 < 103% = $2,060) reverts!
        vm.prank(aiAgent);
        vm.expectRevert(abi.encodeWithSelector(YuzuCartridge.StrikeBelowPolicyMinimum.selector, 2050e18, 2060e18));
        cartridge.writeCoveredCall(
            1, address(hypercall), address(weth), 0.2 ether, 2050e18, uint64(block.timestamp + 3 days), address(weth), 0.002 ether
        );

        // 5. Valid call by AI key: 0.25 WETH ($500 <= $600 cap), strike $2,100 (105%), gross premium 0.005 WETH ($10 = 2%)
        hypercall.setSimulatedPremium(0.005 ether);
        uint256 vaultWethBefore = weth.balanceOf(address(vault1));

        vm.prank(aiAgent);
        uint256 callId = cartridge.writeCoveredCall(
            1, address(hypercall), address(weth), 0.25 ether, 2100e18, uint64(block.timestamp + 3 days), address(weth), 0.005 ether
        );
        assertEq(callId, 1);
        assertTrue(cartridge.hasOpenCalls(1));

        // Check 10% skim on 0.005 WETH premium = 0.0005 WETH (50% = 0.00025 to Dist, 50% = 0.00025 to Buyback)
        // Net premium to vault = 0.0045 WETH; collateral pulled = 0.25 WETH
        assertEq(treasury.distWeth(), 0.00025 ether);
        assertEq(treasury.buybackWeth(), 0.00025 ether);
        assertEq(weth.balanceOf(address(vault1)), vaultWethBefore - 0.25 ether + 0.0045 ether);

        // Settle expired call -> collateral returns to vault and hasOpenCalls becomes false
        cartridge.settleExpiredCall(1, 0);
        assertFalse(cartridge.hasOpenCalls(1));
    }

    function test_Slot2_CashLegLending_And10PercentInterestSkim() public {
        // Owner supplies 500 USDG to Tydro cash leg
        vm.prank(owner);
        uint256 shares = cartridge.supplyToCashLeg(1, address(tydro), address(usdg), 500e6);
        assertEq(shares, 500e6);
        assertEq(tydroUsdgReceipt.balanceOf(address(vault1)), 500e6);

        // Withdraw all 500 shares -> MockTydro pays +5.00% interest (525 USDG gross -> 25 USDG interest)
        // 10% skim on 25 USDG interest = 2.5 USDG to fee escrow; 522.5 USDG net to vault1
        uint256 usdgBefore = usdg.balanceOf(address(vault1));
        vm.prank(owner);
        (uint256 netToVault, uint256 skim) = cartridge.withdrawFromCashLeg(1, address(tydro), address(usdg), 500e6);

        assertEq(skim, 2.5e6);
        assertEq(netToVault, 522.5e6);
        assertEq(usdg.balanceOf(address(vault1)) - usdgBefore, 522.5e6);
        assertEq(treasury.feeEscrow(address(usdg)), 2.5e6);
    }

    function test_Slot4_RelativeStrengthAdapter_250BpsSpread_SeedProtection_AndFenceF3Clamp() public {
        // Set 14-day returns: wSPYx = +8.00% (+800 bps, leader), WETH = +1.00% (+100 bps, laggard), USDG = +2.00% (+200 bps)
        archive.setReturn(address(wspyx), true, 800);
        archive.setReturn(address(weth), true, 100);
        archive.setReturn(address(usdg), true, 200);

        // Request a 50% rotation of laggard (WETH non-seed = 0.9 WETH = $1,800; 50% = $900).
        // Because $900 exceeds Fence F3 (20% of $3,000 NAV = $600 = 0.30 WETH), the adapter clamps `amountIn` to 0.30 WETH!
        (bool shouldExec, address tokenIn, address tokenOut, uint256 amountIn) =
            rsAdapter.evaluate(address(vault1), abi.encode(uint256(5000)));

        assertTrue(shouldExec);
        assertEq(tokenIn, address(weth));
        assertEq(tokenOut, address(wspyx));
        assertEq(amountIn, 0.30 ether); // Clamped to 20% of $3,000 NAV ($600 = 0.30 WETH)!
    }
}
