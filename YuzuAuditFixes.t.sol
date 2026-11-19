// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "../src/interfaces/IYuzuV4Interfaces.sol";
import {SeedMode} from "../src/interfaces/IYuzuPhase3Interfaces.sol";
import {Yuzu98v2} from "../src/Yuzu98v2.sol";
import {YuzuDistributor} from "../src/YuzuDistributor.sol";
import {YuzuSeeder} from "../src/YuzuSeeder.sol";
import {YuzuNavLens} from "../src/YuzuNavLens.sol";
import {YuzuRegistry} from "../src/YuzuRegistry.sol";
import {YuzuSocketBay} from "../src/YuzuSocketBay.sol";
import {YuzuTreasury} from "../src/YuzuTreasury.sol";
import {YuzuToken} from "../src/YuzuToken.sol";
import {YuzuCartridge} from "../src/YuzuCartridge.sol";
import {MockV4PoolManager, MockWETH, MockYuzuUnits} from "./mocks/Phase1Mocks.sol";
import {MockChainlinkFeed, MockPyth} from "./mocks/Phase2Mocks.sol";
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
import {
    MockERC20_5,
    MockWETH5,
    MockMainframe5,
    MockVault5,
    MockSocketBay5,
    MockLens5,
    MockRegistry5,
    MockTreasury5,
    MockHypercallAdapter,
    MockTydroLendingAdapter
} from "./mocks/Phase5Mocks.sol";

/// @dev Helper wrapper that reverts on convertToAssets() to test Finding #2.
contract RevertingWrapper {
    function convertToAssets(uint256) external pure returns (uint256) {
        revert("WRAPPER_BROKEN");
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1e18;
    }
}

/// @dev Helper ERC-20 / ERC-721 that reverts on balanceOf() to test Finding #8.
contract RevertingBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        revert("BALANCE_OF_REVERT");
    }
}

/// @dev Helper contract that rejects ETH transfers to test Finding #5.
contract RejectEthCaller {
    function callClaim(YuzuDistributor dist, uint256 epoch, uint256 tokenId) external payable {
        bytes[] memory emptyPyth;
        dist.claim{value: msg.value}(epoch, tokenId, emptyPyth);
    }
}

/// @notice Regression tests for all Critical, High, and Medium findings from the 6-contract security audit.
contract YuzuAuditFixesTest is Test {
    // -------------------------------------------------------------------------
    // Findings #1, #3, #5: YuzuDistributor
    // -------------------------------------------------------------------------

    function _setupDistributorEnv()
        internal
        returns (
            Yuzu98v2 mainframe,
            YuzuDistributor distributor,
            YuzuSeeder seeder,
            MockWETH3 weth,
            MockERC20 yuzu,
            MockLens3 lens,
            MockSocketBay3 socketBay,
            MockTreasury3 treasury,
            MockVault3 vault1
        )
    {
        vm.warp(1_760_000_000);
        vm.roll(100);

        weth = new MockWETH3();
        yuzu = new MockERC20("Yuzu", "YUZU", 18);
        MockERC20 kbtc = new MockERC20("kBTC", "kBTC", 8);
        MockERC20 usdg = new MockERC20("USDG", "USDG", 6);
        MockERC20 wspyx = new MockERC20("wSPYx", "wSPYx", 18);

        MockPyth3 pyth = new MockPyth3();
        lens = new MockLens3();
        lens.setAssetPrice(address(weth), 2000e18, 18);
        lens.setAssetPrice(address(kbtc), 100_000e18, 8);
        lens.setAssetPrice(address(usdg), 1e18, 6);
        lens.setAssetPrice(address(wspyx), 600e18, 18);

        MockRouter3 router = new MockRouter3(lens);
        MockRegistry3 registry = new MockRegistry3(address(router));
        socketBay = new MockSocketBay3();
        treasury = new MockTreasury3(yuzu);
        MockCartridge3 cartridge = new MockCartridge3();

        mainframe = new Yuzu98v2();
        MockVault3 vault0 = new MockVault3();
        vault1 = new MockVault3();
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault0);
        vaults[1] = address(vault1);
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

        bytes[] memory emptyPyth;
        vm.deal(address(this), 10 ether);
        seeder.commissionFounderUnitZero{value: 0.15 ether}(address(0xF00D), address(0x10), address(0x20), emptyPyth);

        address user1 = address(0x1111);
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        seeder.commissionMainframe{value: 0.15 ether}(1, SeedMode.US_BASKET, address(0x30), address(0x40), emptyPyth);

        // Unseal unit #1 so grade > 0
        vm.prank(user1);
        mainframe.commitUnseal(1);
        vm.roll(block.number + 3);
        mainframe.revealUnseal(1);

        lens.setVaultNav(address(vault1), 5_000e18);
    }

    function test_Finding1_UnclaimedFarmNotDoubleCounted_AndSweptAfterExpiry() public {
        (
            ,
            YuzuDistributor distributor,
            ,
            ,
            MockERC20 yuzu,
            ,
            ,
            ,
        ) = _setupDistributorEnv();

        // Start Epoch 1 and checkpoint unit #1
        distributor.syncEpoch1Start();
        uint256 e1 = distributor.epoch1Start();
        vm.warp(e1 + 1 hours);
        distributor.checkpoint(1);

        // Epoch 2 boundary: close Epoch 1 and open Epoch 2
        vm.warp(e1 + 7 days + 1 hours);
        distributor.checkpoint(1);

        // Finalize Epoch 1 after 6h window: emits 1,000,000 $YUZU farm into distributor (0 free $YUZU before)
        vm.warp(e1 + 7 days + 6 hours + 1);
        distributor.finalizeEpoch(1);
        assertEq(distributor.totalUnclaimedFarmYuzu(), 1_000_000e18, "farm reserved on finalize");

        // Epoch 3 boundary: close Epoch 2 WITHOUT claiming Epoch 1
        vm.warp(e1 + 14 days + 1 hours);
        distributor.checkpoint(1);
        vm.warp(e1 + 14 days + 6 hours + 1);
        distributor.finalizeEpoch(2);

        // Epoch 2 MUST release 0 $YUZU from the free pool (Epoch 1's unclaimed farm is NOT double-counted)
        (,,,, uint256 ep2YuzuReleased,,,,,) = distributor.epochPools(2);
        assertEq(ep2YuzuReleased, 0, "unclaimed farm must not be released as free YUZU");
        assertEq(distributor.totalUnclaimedFarmYuzu(), 2_000_000e18, "both epochs reserved");

        // Warp past Epoch 1 expiry (> epoch 1 + 8) and sweep Epoch 1
        vm.warp(e1 + 9 * 7 days + 1 hours);
        distributor.sweepExpiredEpoch(1);
        assertEq(distributor.totalUnclaimedFarmYuzu(), 1_000_000e18, "expired farm swept back to free pool");
        assertEq(yuzu.balanceOf(address(distributor)), 2_000_000e18);
    }

    function test_Finding3_GuttedUnitCannotClaimFarmCreditAfterRaid() public {
        (
            Yuzu98v2 mainframe,
            YuzuDistributor distributor,
            ,
            ,
            ,
            ,
            ,
            ,
            MockVault3 vault1
        ) = _setupDistributorEnv();

        distributor.syncEpoch1Start();
        uint256 e1 = distributor.epoch1Start();
        vm.warp(e1 + 1 hours);
        distributor.checkpoint(1);

        // Close Epoch 1 cleanly while unit #1 is live
        vm.warp(e1 + 7 days + 1 hours);
        distributor.checkpoint(1);
        vm.warp(e1 + 7 days + 6 hours + 1);
        distributor.finalizeEpoch(1);

        // Unit #1 executes Seed Raid BEFORE calling claim(1, 1)
        vm.prank(address(vault1));
        mainframe.markGuttedFromVault(1);
        vm.prank(address(vault1));
        distributor.cancelLockedCreditOnRaid(1);

        // Now claim Epoch 1: WETH/YUZU epoch share is paid, but farm credit MUST be forfeited (not locked for unlock)
        bytes[] memory emptyPyth;
        distributor.claim(1, 1, emptyPyth);

        assertEq(distributor.farmCredit(1, 1), 0, "gutted unit must not receive farm credit");
        assertEq(distributor.totalLockedFarmCredit(), 0, "no locked farm credit added");
        assertEq(distributor.totalUnclaimedFarmYuzu(), 0, "forfeited farm released to free pool");
    }

    function test_Finding5_ClaimRefundsExcessEthWithEmptyPyth_AndRevertsOnFailedRefund() public {
        (
            ,
            YuzuDistributor distributor,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = _setupDistributorEnv();

        distributor.syncEpoch1Start();
        uint256 e1 = distributor.epoch1Start();
        vm.warp(e1 + 1 hours);
        distributor.checkpoint(1);
        vm.warp(e1 + 7 days + 1 hours);
        distributor.checkpoint(1);
        vm.warp(e1 + 7 days + 6 hours + 1);
        distributor.finalizeEpoch(1);

        // 1. A caller that rejects ETH reverts with EthRefundFailed when sending excess ETH
        RejectEthCaller rejecter = new RejectEthCaller();
        vm.deal(address(rejecter), 1 ether);
        vm.expectRevert(YuzuDistributor.EthRefundFailed.selector);
        rejecter.callClaim{value: 0.1 ether}(distributor, 1, 1);

        // 2. An EOA sending accidental ETH with empty pythUpdateData gets 100% refunded
        address caller = address(0xCAFE);
        vm.deal(caller, 1 ether);
        bytes[] memory emptyPyth;
        vm.prank(caller);
        distributor.claim{value: 0.25 ether}(1, 1, emptyPyth);
        assertEq(caller.balance, 1 ether, "accidental ETH must be fully refunded");
        assertEq(address(distributor).balance, 0, "no ETH trapped in distributor");
    }

    // -------------------------------------------------------------------------
    // Findings #2 & #8: YuzuNavLens
    // -------------------------------------------------------------------------

    function test_Finding2_And_8_NavLensWrapperRevertAndTryGetNavResilience() public {
        vm.warp(1_760_000_000);
        MockPyth pyth = new MockPyth();
        MockChainlinkFeed spyFeed = new MockChainlinkFeed(8, 500e8);
        RevertingWrapper badWrapper = new RevertingWrapper();
        RevertingBalanceToken badBalToken = new RevertingBalanceToken();

        YuzuRegistry.InitialAssetInput[] memory assets = new YuzuRegistry.InitialAssetInput[](2);
        assets[0] = YuzuRegistry.InitialAssetInput({
            asset: address(badWrapper),
            config: YuzuRegistry.AssetConfig({
                isRegistered: true,
                isPaused: false,
                isWrapper: true,
                isCryptoLeg: false,
                tokenDecimals: 18,
                maxAge: 3600,
                chainlinkFeed: address(spyFeed),
                pythFeedId: bytes32(0)
            })
        });
        assets[1] = YuzuRegistry.InitialAssetInput({
            asset: address(badBalToken),
            config: YuzuRegistry.AssetConfig({
                isRegistered: true,
                isPaused: false,
                isWrapper: false,
                isCryptoLeg: true,
                tokenDecimals: 18,
                maxAge: 3600,
                chainlinkFeed: address(spyFeed),
                pythFeedId: bytes32(0)
            })
        });
        YuzuRegistry.InitialRouteInput[] memory routes = new YuzuRegistry.InitialRouteInput[](0);

        YuzuRegistry registry = new YuzuRegistry(address(this), assets, routes);
        YuzuNavLens lens = new YuzuNavLens(address(registry), address(pyth));

        // Finding #2: requireFresh MUST revert InvalidOraclePrice when wrapper.convertToAssets reverts
        vm.expectRevert(abi.encodeWithSelector(YuzuNavLens.InvalidOraclePrice.selector, address(badWrapper)));
        lens.requireFresh(address(badWrapper));

        // Finding #8: tryGetNav MUST NOT revert when a token's balanceOf reverts; sets anyStale = true
        (uint256 liqNav, uint256 dispNav, bool anyStale) = lens.tryGetNav(address(0x1234));
        assertEq(liqNav, 0);
        assertEq(dispNav, 0);
        assertTrue(anyStale, "broken balanceOf must flag anyStale without reverting");
    }

    // -------------------------------------------------------------------------
    // Findings #4 & #6: YuzuSocketBay & YuzuTreasury
    // -------------------------------------------------------------------------

    function test_Finding4_And_6_ConfigureCoreOnlyDeployer_AndBoltStateEnforced() public {
        MockV4PoolManager pm = new MockV4PoolManager();
        MockWETH weth = new MockWETH();
        YuzuToken yuzu = new YuzuToken(address(this));
        MockYuzuUnits units = new MockYuzuUnits();

        YuzuSocketBay sb = new YuzuSocketBay(address(pm), address(yuzu), address(weth));
        YuzuTreasury tr = new YuzuTreasury(
            address(pm), address(yuzu), address(weth), address(0xA11CE), address(0xB0B), uint160(1 << 96)
        );

        PoolKey memory key = PoolKey({
            currency0: address(yuzu) < address(weth) ? address(yuzu) : address(weth),
            currency1: address(yuzu) < address(weth) ? address(weth) : address(yuzu),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(0x2880)
        });

        // Finding #4: non-deployer cannot front-run configureCore on SocketBay or Treasury
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(YuzuSocketBay.OnlyDeployer.selector);
        sb.configureCore(address(units), address(0x1), address(0x2), key);

        vm.prank(attacker);
        vm.expectRevert(YuzuTreasury.OnlyDeployer.selector);
        tr.configureCore(address(0x2880), address(sb), address(units), address(0x1), address(0x2), address(0), address(0), key);

        // Deployer succeeds
        sb.configureCore(address(units), address(this), address(0x2), key);
        units.setUnit(1, address(0x1111), address(0x7111), false);
        sb.seedInitialRam(1, 1);

        // Finding #6: buyAndSeat and buyAndBond revert with UnitNotUnbolted when boltState != 0 (BOLTED = 1)
        units.setBoltState(1, 1);
        vm.deal(address(0x1111), 1 ether);

        vm.prank(address(0x1111));
        vm.expectRevert(YuzuSocketBay.UnitNotUnbolted.selector);
        sb.buyAndSeat{value: 0.1 ether}(1, 1, 0.1 ether);

        vm.prank(address(0x1111));
        vm.expectRevert(YuzuSocketBay.UnitNotUnbolted.selector);
        sb.buyAndBond{value: 0.1 ether}(1, 0.1 ether);
    }

    // -------------------------------------------------------------------------
    // Finding #7: YuzuRegistry 2-Step Admin Rotation
    // -------------------------------------------------------------------------

    function test_Finding7_RegistryAdminRotationRequiresPendingAdmin() public {
        vm.warp(1_760_000_000);
        YuzuRegistry.InitialAssetInput[] memory assets = new YuzuRegistry.InitialAssetInput[](0);
        YuzuRegistry.InitialRouteInput[] memory routes = new YuzuRegistry.InitialRouteInput[](0);

        address oldAdmin = address(0xA11CE);
        address newAdmin = address(0xB0B);
        YuzuRegistry registry = new YuzuRegistry(oldAdmin, assets, routes);

        vm.prank(oldAdmin);
        registry.queueAdminRotation(newAdmin);

        vm.warp(block.timestamp + 7 days + 1);

        // Old admin can no longer force-execute rotation without newAdmin accepting
        vm.prank(oldAdmin);
        vm.expectRevert(YuzuRegistry.OnlyPendingAdmin.selector);
        registry.executeAdminRotation();

        // Pending admin accepts and becomes admin
        vm.prank(newAdmin);
        registry.executeAdminRotation();
        assertEq(registry.admin(), newAdmin);
    }

    // -------------------------------------------------------------------------
    // Cartridge Audit Findings: Unpriced Receipt Guard & Swap-and-Pop Active Calls
    // -------------------------------------------------------------------------

    function test_Cartridge_SupplyRevertsIfReceiptUnpriced_AndSwapAndPopCalls() public {
        vm.warp(1_760_000_000);
        MockWETH5 weth = new MockWETH5();
        MockERC20_5 usdg = new MockERC20_5("Global Dollar", "USDG", 6);
        MockERC20_5 unpricedReceipt = new MockERC20_5("Unpriced Receipt", "uUSDG", 6);

        MockMainframe5 mf = new MockMainframe5();
        MockVault5 v1 = new MockVault5();
        MockSocketBay5 sb = new MockSocketBay5();
        MockLens5 lens = new MockLens5();
        MockRegistry5 reg = new MockRegistry5();
        MockTreasury5 tr = new MockTreasury5(weth);
        MockHypercallAdapter hc = new MockHypercallAdapter();
        MockTydroLendingAdapter lend = new MockTydroLendingAdapter(unpricedReceipt);

        lens.setPrice(address(weth), 2000e18, 18);
        lens.setPrice(address(usdg), 1e18, 6);
        reg.addPricedAsset(address(weth));
        reg.addPricedAsset(address(usdg));
        // Deliberately do NOT register unpricedReceipt as a priced asset
        reg.setVenue(address(hc), true, false, false, address(0));
        reg.setVenue(address(lend), true, false, true, address(unpricedReceipt));

        YuzuCartridge cart = new YuzuCartridge(
            address(mf), address(sb), address(lens), address(reg), address(tr), address(weth)
        );

        address owner = address(0x1111);
        mf.setUnit(1, owner, address(v1));
        sb.setTier(1, 5);
        weth.mint(address(v1), 2 ether);
        usdg.mint(address(v1), 1000e6);

        // 1. Supplying to a lending venue whose receiptToken is NOT a priced asset MUST revert VenueNotApproved
        vm.prank(owner);
        vm.expectRevert(YuzuCartridge.VenueNotApproved.selector);
        cart.supplyToCashLeg(1, address(lend), address(usdg), 500e6);

        // 2. Write two covered calls, settle index 0 (swap-and-pop), then settle remaining index 0
        address[] memory allowed = new address[](1);
        allowed[0] = address(weth);
        vm.prank(address(v1));
        cart.setPolicyFromVaultTier3(1, allowed, 10200, 100, 7 days, 10000);

        hc.setSimulatedPremium(0.01 ether);
        vm.startPrank(owner);
        cart.writeCoveredCall(1, address(hc), address(weth), 0.25 ether, 2100e18, uint64(block.timestamp + 3 days), address(weth), 0.005 ether);
        cart.writeCoveredCall(1, address(hc), address(weth), 0.25 ether, 2200e18, uint64(block.timestamp + 3 days), address(weth), 0.005 ether);
        vm.stopPrank();

        assertEq(cart.openCallCount(1), 2);
        assertTrue(cart.hasOpenCalls(1));

        // Settle first call -> second call swaps into index 0
        cart.settleExpiredCall(1, 0);
        assertEq(cart.openCallCount(1), 1);
        assertTrue(cart.hasOpenCalls(1));

        // Settle remaining call at index 0 -> array is empty
        cart.settleExpiredCall(1, 0);
        assertEq(cart.openCallCount(1), 0);
        assertFalse(cart.hasOpenCalls(1));

        // Out-of-bounds settle reverts cleanly with CallAlreadySettled
        vm.expectRevert(YuzuCartridge.CallAlreadySettled.selector);
        cart.settleExpiredCall(1, 0);
    }
}
