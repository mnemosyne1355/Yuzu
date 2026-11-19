// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Yuzu98v2} from "../src/Yuzu98v2.sol";
import {YuzuDistributor} from "../src/YuzuDistributor.sol";
import {YuzuSeeder} from "../src/YuzuSeeder.sol";
import {SeedMode, BoltState} from "../src/interfaces/IYuzuPhase3Interfaces.sol";
import {
    MockERC20,
    MockWETH3,
    MockPyth3,
    MockLens3,
    MockRouter3,
    MockRegistry3,
    MockSocketBay3,
    MockTreasury3,
    MockVault3,
    MockCartridge3
} from "./mocks/Phase3Mocks.sol";

contract YuzuPhase3Test is Test {
    Yuzu98v2 mainframe;
    YuzuDistributor distributor;
    YuzuSeeder seeder;

    MockWETH3 weth;
    MockERC20 yuzu;
    MockERC20 kbtc;
    MockERC20 usdg;
    MockERC20 wspyx;

    MockPyth3 pyth;
    MockLens3 lens;
    MockRouter3 router;
    MockRegistry3 registry;
    MockSocketBay3 socketBay;
    MockTreasury3 treasury;
    MockCartridge3 cartridge;

    MockVault3 vault0;
    MockVault3 vault1;
    MockVault3 vault2;

    address founder = address(0xF00D);
    address user1 = address(0x1111);
    address user2 = address(0x2222);
    address guardian1 = address(0xABCD);
    address recovery1 = address(0x9999);

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.roll(100);

        weth = new MockWETH3();
        yuzu = new MockERC20("Yuzu", "YUZU", 18);
        kbtc = new MockERC20("Kraken BTC", "kBTC", 8);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        wspyx = new MockERC20("Wrapped SPYx", "wSPYx", 18);

        pyth = new MockPyth3();
        lens = new MockLens3();
        lens.setAssetPrice(address(weth), 2000e18, 18);
        lens.setAssetPrice(address(kbtc), 100_000e18, 8);
        lens.setAssetPrice(address(usdg), 1e18, 6);
        lens.setAssetPrice(address(wspyx), 600e18, 18);

        router = new MockRouter3(lens);
        registry = new MockRegistry3(address(router));
        socketBay = new MockSocketBay3();
        treasury = new MockTreasury3(yuzu);
        cartridge = new MockCartridge3();

        mainframe = new Yuzu98v2();
        vault0 = new MockVault3();
        vault1 = new MockVault3();
        vault2 = new MockVault3();

        address[] memory vaults = new address[](3);
        vaults[0] = address(vault0);
        vaults[1] = address(vault1);
        vaults[2] = address(vault2);
        mainframe.registerVaultAddresses(0, vaults);

        distributor = new YuzuDistributor(
            address(mainframe),
            address(socketBay),
            address(treasury),
            address(lens),
            address(pyth),
            address(weth),
            address(yuzu)
        );

        seeder = new YuzuSeeder(
            address(mainframe),
            address(socketBay),
            address(treasury),
            address(distributor),
            address(lens),
            address(registry),
            address(pyth),
            address(weth),
            address(yuzu),
            address(kbtc),
            address(usdg),
            address(wspyx)
        );

        mainframe.configureCore(address(seeder), address(treasury), address(cartridge), address(0));
        yuzu.mint(address(seeder), 150_100_000e18);

        // Commission #0000 at deployment
        bytes[] memory emptyPyth;
        vm.deal(founder, 10 ether);
        // CHANGE (2026-11-18): #0000 may only be commissioned by the Seeder's deployer (this test contract).
        // The wiring is done and #0000 is not minted yet, which is the front-run window: an outsider is refused.
        vm.deal(address(0xBAD), 1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert(YuzuSeeder.OnlyDeployer.selector);
        seeder.commissionFounderUnitZero{value: 0.15 ether}(address(0xBAD), address(0x10), address(0x20), emptyPyth);
        seeder.commissionFounderUnitZero{value: 0.15 ether}(founder, address(0x10), address(0x20), emptyPyth);
    }

    function test_Commissioning_4WaySplit_AndOracleCheckedSeed() public {
        bytes[] memory emptyPyth;
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        seeder.commissionMainframe{value: 0.15 ether}(1, SeedMode.US_BASKET, guardian1, recovery1, emptyPyth);

        assertEq(mainframe.ownerOf(1), user1);
        assertEq(mainframe.commissionedCount(), 2);
        assertEq(socketBay.ramTier(1), 1);

        // Check 4-way ETH split across #0000 and #0001 (2 units):
        // - Distributor: 2 * 0.0150 = 0.0300 WETH
        // - Treasury LP: 2 * 0.0225 = 0.0450 WETH
        // - Treasury Funds: 2 * 0.0375 = 0.0750 WETH
        assertEq(weth.balanceOf(address(distributor)), 0.0300 ether);
        assertEq(treasury.lpWethReceived(), 0.0450 ether);
        assertEq(treasury.treasuryWethReceived(), 0.0750 ether);

        // Check Unit #1 US_BASKET seed: 0.0300 WETH + kBTC + USDG
        assertEq(vault1.seedUnits(address(weth)), 0.0300 ether);
        assertGt(vault1.seedUnits(address(kbtc)), 0);
        assertGt(vault1.seedUnits(address(usdg)), 0);
    }

    function test_CommitReveal_2BlockUnsealing_AndMissedWindowFallback() public {
        bytes[] memory emptyPyth;
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        seeder.commissionMainframe{value: 0.30 ether}(2, SeedMode.NON_US_XSTOCK, guardian1, recovery1, emptyPyth);

        // Unit #1 commits at block 100 -> target block is 102
        vm.prank(user1);
        mainframe.commitUnseal(1);
        assertEq(mainframe.unsealCommitBlock(1), 102);

        // Cannot bolt or transfer while unseal commit is pending
        vm.prank(address(vault1));
        vm.expectRevert(Yuzu98v2.PendingUnsealCommit.selector);
        mainframe.boltForSaleFromVault(1);

        // Reveal at block 103 (earliest valid block > 102)
        vm.roll(103);
        mainframe.revealUnseal(1);
        assertGt(mainframe.grade(1), 0);

        // Unit #2 commits and misses the 256-block window -> resolves to Grade 1 (PRODUCTION)
        vm.prank(user1);
        mainframe.commitUnseal(2);
        vm.roll(500); // > 256 blocks later, blockhash == 0
        mainframe.revealUnseal(2);
        assertEq(mainframe.grade(2), mainframe.GRADE_PRODUCTION());
    }

    function test_ListingBolt_24hCooldowns_NoUnitInVault_AndRecoveryTransfer() public {
        bytes[] memory emptyPyth;
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        seeder.commissionMainframe{value: 0.15 ether}(1, SeedMode.US_BASKET, guardian1, recovery1, emptyPyth);

        // Unbolted transfer reverts
        vm.prank(user1);
        vm.expectRevert(Yuzu98v2.TransferRequiresBoltedState.selector);
        mainframe.transferFrom(user1, user2, 1);

        // Open Slot-2 calls block bolting for sale
        cartridge.setOpenCalls(1, true);
        vm.prank(address(vault1));
        vm.expectRevert(Yuzu98v2.OpenSlot2CallsExist.selector);
        mainframe.boltForSaleFromVault(1);

        // However, guardianRecoveryTransfer works EVEN when unbolted AND with open Slot-2 calls!
        mainframe.guardianRecoveryTransfer(1, recovery1, block.timestamp + 1 hours, hex"1234");
        assertEq(mainframe.ownerOf(1), recovery1);
        assertEq(vault1.resetCount(), 1);
        assertEq(cartridge.policyClearedCount(1), 1);

        // Clear open calls, bolt from recovery1, and test that transferring into a YUZU-98 vault reverts
        cartridge.setOpenCalls(1, false);
        vm.prank(address(vault1));
        mainframe.boltForSaleFromVault(1);

        vm.prank(recovery1);
        vm.expectRevert(Yuzu98v2.NoUnitInVault.selector);
        mainframe.transferFrom(recovery1, address(vault0), 1);

        // Force-unbolt starts 24h re-bolt cooldown
        vm.prank(address(vault1));
        mainframe.guardianForceUnbolt(1);
        assertEq(uint8(mainframe.boltState(1)), uint8(BoltState.UNBOLTED));

        vm.prank(address(vault1));
        vm.expectRevert();
        mainframe.boltForSaleFromVault(1);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(address(vault1));
        mainframe.boltForSaleFromVault(1);
        assertEq(uint8(mainframe.boltState(1)), uint8(BoltState.BOLTED));
    }

    function test_Distributor_EpochCheckpoints_OutflowRatchet_And26WeekFarmCredit() public {
        bytes[] memory emptyPyth;
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        seeder.commissionMainframe{value: 0.15 ether}(1, SeedMode.US_BASKET, guardian1, recovery1, emptyPyth);

        // Unseal Unit #1
        vm.prank(user1);
        mainframe.commitUnseal(1);
        vm.roll(105);
        mainframe.revealUnseal(1);

        // Set Liquid NAV of Unit #1 to $8,000
        lens.setVaultNav(address(vault1), 8000e18);

        // Warp to Epoch 1 opening boundary
        distributor.syncEpoch1Start();
        uint256 ep1Start = distributor.epoch1Start();
        vm.warp(ep1Start + 10 minutes);
        assertEq(distributor.currentEpoch(), 1);

        // Opening checkpoint for Unit #1 in Epoch 1
        distributor.checkpoint(1);
        assertEq(distributor.qualifyingNav(1, 1), 8000e18);

        // Mid-epoch Priced ERC-20 withdrawal reduces NAV to $5,000 -> noteOutflow ratchets qualifyingNav down to $5,000
        vm.warp(ep1Start + 3 days);
        vm.prank(address(vault1));
        distributor.noteOutflow(1, 5000e18);
        assertEq(distributor.qualifyingNav(1, 1), 5000e18);

        // Deposit back to $9,000 before Epoch 1 closes -> qualifyingNav stays at the minimum ($5,000)!
        lens.setVaultNav(address(vault1), 9000e18);

        // Warp to Epoch 2 opening boundary (closes Epoch 1)
        uint256 ep2Start = ep1Start + 7 days;
        vm.warp(ep2Start + 10 minutes);
        assertEq(distributor.currentEpoch(), 2);

        // What if an outflow happens inside the 6h boundary window BEFORE checkpoint(1) is called?
        // Our v4.9 fix updates the unclosed Epoch 1 record!
        vm.prank(address(vault1));
        distributor.noteOutflow(1, 4000e18);
        assertEq(distributor.qualifyingNav(1, 1), 4000e18);

        lens.setVaultNav(address(vault1), 4000e18);
        distributor.checkpoint(1);
        assertTrue(distributor.isClosed(1, 1));
        assertGt(distributor.unitWeight(1, 1), 0);

        // Warp past the 6h checkpoint window and claim Epoch 1 rewards
        vm.warp(ep2Start + 6 hours + 1);
        distributor.claim(1, 1, emptyPyth);

        // Vault1 received WETH reward and auto-compound hook `onRewardPaid` was called
        assertGt(vault1.lastRewardPaid(), 0);
        // Unit #1 earned 1,000,000 $YUZU of 26-week locked farm credit
        assertEq(distributor.farmCredit(1, 1), 1_000_000e18);

        // Cannot unlock farm credit before 26 epochs
        vm.expectRevert(YuzuDistributor.NothingToClaim.selector);
        distributor.releaseCredit(1);

        // Warp 26 epochs forward (Epoch 27) and unlock farm credit to vault1
        vm.warp(ep1Start + 26 * 7 days + 1);
        uint256 unlocked = distributor.releaseCredit(1);
        assertEq(unlocked, 1_000_000e18);
        assertEq(yuzu.balanceOf(address(vault1)), 1_000_000e18);
    }
}
