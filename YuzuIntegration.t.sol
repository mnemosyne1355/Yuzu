// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {YuzuAccount} from "../src/YuzuAccount.sol";
import {YuzuAccountCompanion} from "../src/YuzuAccountCompanion.sol";
import {YuzuCartridge} from "../src/YuzuCartridge.sol";
import {YuzuTreasury} from "../src/YuzuTreasury.sol";
import {PoolKey} from "../src/interfaces/IYuzuV4Interfaces.sol";
import {SeedMode, BoltState} from "../src/interfaces/IYuzuPhase4Interfaces.sol";
import {
    MockERC20_4,
    MockWETH4,
    MockPyth4,
    MockMainframe4,
    MockRouter4,
    MockDistributor4,
    MockHook4
} from "./mocks/Phase4Mocks.sol";
import {MockERC20_5, MockHypercallAdapter, MockTydroLendingAdapter} from "./mocks/Phase5Mocks.sol";
import {MockLensI, MockRegistryI, MockSocketBayI, MockStrategyI} from "./mocks/IntegrationMocks.sol";

/// @notice Runs the REAL YuzuAccount, YuzuAccountCompanion, YuzuCartridge and YuzuTreasury against each other.
///         The per-phase suites test each of these against a stand-in for the others, which is how the missing
///         Slot-2 wiring and the missing Treasury escrows went unnoticed. Mainframe, lens, registry, router,
///         socket bay, distributor, hook, Pyth and the two venue adapters are still mocks.
contract YuzuIntegrationTest is Test {
    YuzuAccount vault;
    YuzuAccountCompanion companion;
    YuzuCartridge cartridge;
    YuzuTreasury treasury;

    MockWETH4 weth;
    MockERC20_4 yuzu;
    MockERC20_4 usdg;
    MockERC20_4 wspyx;
    MockERC20_5 tUsdg;

    MockPyth4 pyth;
    MockMainframe4 mainframe;
    MockLensI lens;
    MockRouter4 router;
    MockRegistryI registry;
    MockSocketBayI socketBay;
    MockDistributor4 distributor;
    MockHook4 hook;
    MockHypercallAdapter hypercall;
    MockTydroLendingAdapter tydro;

    uint256 guardianPk = 0xBEEF;
    address guardian;
    address owner = address(0x1111);
    address aiAgent = address(0xA1A1);
    address recovery = address(0x9999);
    address seeder = address(0x5EED);
    address multisig = address(0xA11CE);
    address keeper = address(0xCEE9);
    address stranger = address(0xBAD);

    function setUp() public {
        vm.warp(1_760_000_000);
        guardian = vm.addr(guardianPk);

        weth = new MockWETH4();
        yuzu = new MockERC20_4("Yuzu", "YUZU", 18);
        usdg = new MockERC20_4("Global Dollar", "USDG", 6);
        wspyx = new MockERC20_4("Wrapped SPYx", "wSPYx", 18);
        tUsdg = new MockERC20_5("Tydro USDG", "tUSDG", 6);

        pyth = new MockPyth4();
        mainframe = new MockMainframe4();
        lens = new MockLensI(address(pyth));
        lens.addAsset(address(weth), 2000e18, 18);
        lens.addAsset(address(usdg), 1e18, 6);
        lens.addAsset(address(wspyx), 500e18, 18);
        lens.addAsset(address(tUsdg), 1e18, 6);

        router = new MockRouter4(lens);
        registry = new MockRegistryI(address(router));
        registry.setAsset(address(weth), true, true);
        registry.setAsset(address(usdg), true, true);
        registry.setAsset(address(wspyx), true, false); // xStock: not a crypto leg
        registry.setAsset(address(tUsdg), true, false); // lending receipt token: priced, not a crypto leg

        socketBay = new MockSocketBayI(yuzu, weth);
        distributor = new MockDistributor4();
        hook = new MockHook4();
        hypercall = new MockHypercallAdapter();
        tydro = new MockTydroLendingAdapter(tUsdg);
        registry.setVenue(address(hypercall), true, false, false, address(0));
        registry.setVenue(address(tydro), true, false, true, address(tUsdg));

        treasury = new YuzuTreasury(address(0x9001), address(yuzu), address(weth), multisig, address(0xB0B), 2 ** 96);
        PoolKey memory key = PoolKey({
            currency0: address(yuzu) < address(weth) ? address(yuzu) : address(weth),
            currency1: address(yuzu) < address(weth) ? address(weth) : address(yuzu),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(hook)
        });
        treasury.configureCore(
            address(hook),
            address(socketBay),
            address(mainframe),
            seeder,
            address(distributor),
            address(lens),
            address(registry),
            key
        );

        cartridge = new YuzuCartridge(
            address(mainframe), address(socketBay), address(lens), address(registry), address(treasury), address(weth)
        );
        companion = new YuzuAccountCompanion(
            address(mainframe),
            address(lens),
            address(registry),
            address(socketBay),
            address(distributor),
            address(treasury),
            address(weth),
            address(yuzu)
        );

        // Unit #1: 0.1 WETH seed + 0.9 WETH + 1,000 USDG of trading capital -> Liquid NAV $3,000, RAM Tier 2
        vault = _newVault(1, address(weth), 0.1 ether, SeedMode.US_BASKET);
        weth.mint(address(vault), 0.9 ether);
        usdg.mint(address(vault), 1000e6);
        socketBay.setTier(1, 2);
    }

    function _newVault(uint256 id, address seedAsset, uint256 seedAmount, SeedMode mode)
        internal
        returns (YuzuAccount v)
    {
        v = new YuzuAccount(
            address(mainframe),
            address(lens),
            address(registry),
            address(socketBay),
            address(distributor),
            address(treasury),
            address(hook),
            address(pyth),
            address(weth),
            address(yuzu),
            seeder,
            address(cartridge),
            address(0xDEF0),
            address(companion)
        );
        mainframe.setUnit(id, owner, address(v));
        vm.startPrank(seeder);
        v.initializeFromSeeder(id, guardian, recovery);
        MockERC20_4(seedAsset).mint(address(v), seedAmount);
        v.recordSeed(seedAsset, seedAmount, mode);
        vm.stopPrank();
    }

    function _sign(
        YuzuAccount v,
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = companion.hashGuardianAuth(
            address(v), actionType, target, asset, amount, extraData, v.guardianNonce(), v.guardianEpoch(), deadline
        );
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(guardianPk, digest);
        return abi.encodePacked(r, s, sv);
    }

    function _wethPolicy() internal view returns (address[] memory allowed) {
        allowed = new address[](1);
        allowed[0] = address(weth);
    }

    function _loosenWithGuardian() internal {
        address[] memory allowed = _wethPolicy();
        uint8 act = companion.ACTION_LOOSEN_DESK_POLICY();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 polHash = companion.deskPolicyHash(allowed, 10300, 100, uint32(5 days), 5000);
        bytes memory sig = _sign(vault, act, address(cartridge), address(0), 0, polHash, deadline);
        vm.prank(owner);
        vault.loosenDeskPolicy(allowed, 10300, 100, uint32(5 days), 5000, deadline, sig);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Slot 2: desk policy set through the vault's Tier 3, covered call pulls collateral from the real vault
    // ---------------------------------------------------------------------------------------------------------

    function test_Slot2_CoveredCall_ThroughRealVault_GuardianLoosenedPolicy() public {
        vm.prank(owner);
        vault.setAiSessionKey(aiAgent, block.timestamp + 1 days);
        uint64 expiry = uint64(block.timestamp + 3 days);

        // Fresh unit: empty policy, so no call can be written
        vm.prank(aiAgent);
        vm.expectRevert(abi.encodeWithSelector(YuzuCartridge.AssetNotAllowedByPolicy.selector, address(weth)));
        cartridge.writeCoveredCall(1, address(hypercall), address(weth), 0.25 ether, 2100e18, expiry, address(weth), 0.005 ether);

        // The Owner cannot loosen it without Tier-3 authorization
        address[] memory allowed = _wethPolicy();
        vm.prank(owner);
        vm.expectRevert(YuzuAccount.OpNotQueued.selector);
        vault.loosenDeskPolicy(allowed, 10300, 100, uint32(5 days), 5000, 0, "");

        _loosenWithGuardian();
        (uint16 minStrike, uint16 minPremium, uint32 maxExpiry, uint16 share) = cartridge.deskPolicy(1);
        assertEq(minStrike, 10300);
        assertEq(minPremium, 100);
        assertEq(maxExpiry, 5 days);
        assertEq(share, 5000);
        assertEq(cartridge.getAllowedAssets(1)[0], address(weth));

        // AI key writes a call: 0.25 WETH collateral ($500 <= $600 cap), strike $2,100, premium 0.005 WETH
        hypercall.setSimulatedPremium(0.005 ether);
        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        vm.prank(aiAgent);
        uint256 callId =
            cartridge.writeCoveredCall(1, address(hypercall), address(weth), 0.25 ether, 2100e18, expiry, address(weth), 0.005 ether);
        assertEq(callId, 1);
        assertTrue(cartridge.hasOpenCalls(1));

        // Collateral left the real vault, 90% of the premium came back, 10% skim split 50/50 in the real Treasury
        assertEq(weth.balanceOf(address(vault)), vaultWethBefore - 0.25 ether + 0.0045 ether);
        assertEq(weth.balanceOf(address(hypercall)), 0.25 ether);
        assertEq(weth.balanceOf(address(distributor)), 0.00025 ether);
        assertEq(treasury.buybackWethReserve(), 0.00025 ether);
        assertEq(weth.balanceOf(address(cartridge)), 0);

        cartridge.settleExpiredCall(1, 0);
        assertFalse(cartridge.hasOpenCalls(1));
        assertEq(weth.balanceOf(address(vault)), vaultWethBefore + 0.0045 ether);
    }

    function test_Slot2_PolicyLoosen_48hQueue_AndPullGuards() public {
        address[] memory allowed = _wethPolicy();
        uint8 act = companion.ACTION_LOOSEN_DESK_POLICY();
        bytes32 polHash = companion.deskPolicyHash(allowed, 10300, 100, uint32(5 days), 5000);

        vm.prank(owner);
        vault.queueTier3Action(act, address(cartridge), address(0), 0, polHash);

        vm.prank(owner);
        vm.expectRevert(YuzuAccount.OpNotReady.selector);
        vault.loosenDeskPolicy(allowed, 10300, 100, uint32(5 days), 5000, 0, "");

        vm.warp(block.timestamp + 48 hours + 1);

        // A looser policy than the one queued is not authorized
        vm.prank(owner);
        vm.expectRevert(YuzuAccount.OpNotQueued.selector);
        vault.loosenDeskPolicy(allowed, 10200, 100, uint32(5 days), 5000, 0, "");

        vm.prank(owner);
        vault.loosenDeskPolicy(allowed, 10300, 100, uint32(5 days), 5000, 0, "");
        (uint16 minStrike,,, uint16 share) = cartridge.deskPolicy(1);
        assertEq(minStrike, 10300);
        assertEq(share, 5000);

        // executeTier3Action has no branch for action 11: the dedicated function is the only door
        vm.prank(owner);
        vault.queueTier3Action(act, address(cartridge), address(0), 0, polHash);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        vm.expectRevert(YuzuAccount.InvalidLimits.selector);
        vault.executeTier3Action(act, address(cartridge), address(0), 0, polHash, 0, "");

        // pullSlot2Asset: only the cartridge, only to itself, never below the seed
        vm.prank(stranger);
        vm.expectRevert(YuzuAccount.OnlyCartridge.selector);
        vault.pullSlot2Asset(address(weth), 0.1 ether, stranger);

        vm.prank(owner);
        vm.expectRevert(YuzuAccount.OnlyCartridge.selector);
        vault.pullSlot2Asset(address(weth), 0.1 ether, owner);

        vm.prank(address(cartridge));
        vm.expectRevert(YuzuAccount.OnlyCartridge.selector);
        vault.pullSlot2Asset(address(weth), 0.1 ether, stranger);

        vm.prank(address(cartridge));
        vm.expectRevert(
            abi.encodeWithSelector(YuzuAccount.SeedReserveBreached.selector, address(weth), 0.05 ether, 0.1 ether)
        );
        vault.pullSlot2Asset(address(weth), 0.95 ether, address(cartridge));

        // Unpriced $YUZU can never leave through Slot 2
        yuzu.mint(address(vault), 100e18);
        vm.prank(address(cartridge));
        vm.expectRevert(YuzuAccount.UnpricedOrSeedAssetInFastLane.selector);
        vault.pullSlot2Asset(address(yuzu), 1e18, address(cartridge));
    }

    // ---------------------------------------------------------------------------------------------------------
    // Cash leg + desk fee in USDG -> real Treasury fee escrow -> convertFees
    // ---------------------------------------------------------------------------------------------------------

    function test_CashLeg_AndDeskFee_NonWeth_FeeEscrow_AndConvertFees() public {
        bytes[] memory emptyPyth;

        // Owner lends 500 USDG; the receipt token lands in the real vault
        vm.prank(owner);
        uint256 shares = cartridge.supplyToCashLeg(1, address(tydro), address(usdg), 500e6);
        assertEq(shares, 500e6);
        assertEq(tUsdg.balanceOf(address(vault)), 500e6);
        assertEq(usdg.balanceOf(address(vault)), 500e6);

        // Withdraw: 525 USDG back, 25 interest, 2.5 USDG skim to the Treasury fee escrow at the 50/50 skim split
        vm.prank(owner);
        (uint256 netToVault, uint256 skim) = cartridge.withdrawFromCashLeg(1, address(tydro), address(usdg), 500e6);
        assertEq(skim, 2.5e6);
        assertEq(netToVault, 522.5e6);
        assertEq(usdg.balanceOf(address(vault)), 1022.5e6);
        assertEq(tUsdg.balanceOf(address(vault)), 0);
        assertEq(treasury.feeEscrow(address(usdg)), 2.5e6);
        assertEq(treasury.feeEscrowBuybackShare(address(usdg)), 1.25e6);

        // Tier-1 swap of 400 USDG -> wSPYx: 0.25% desk fee = 1 USDG, taken in USDG, escrowed at the 80/20 fee split
        vm.prank(owner);
        vault.executeTier1Swap(address(usdg), address(wspyx), 400e6, emptyPyth);
        assertEq(treasury.feeEscrow(address(usdg)), 3.5e6);
        assertEq(treasury.feeEscrowBuybackShare(address(usdg)), 1.45e6);
        assertEq(usdg.balanceOf(address(treasury)), 3.5e6);
        assertEq(usdg.balanceOf(address(companion)), 0);

        // Anyone converts: 3.5 USDG -> 0.00175 WETH fair, 0.30% router cost -> 0.00174475 WETH
        bytes[] memory upd = new bytes[](1);
        upd[0] = hex"01";
        vm.deal(keeper, 1 ether);
        uint256 distBefore = weth.balanceOf(address(distributor));
        vm.prank(keeper);
        uint256 wethOut = treasury.convertFees{value: 5}(address(usdg), upd);

        assertEq(wethOut, 1744750000000000);
        assertEq(treasury.buybackWethReserve(), 722825000000000);                         // 1.45 / 3.5 of it
        assertEq(weth.balanceOf(address(distributor)) - distBefore, 1021925000000000);     // the rest
        assertEq(weth.balanceOf(address(treasury)), 722825000000000);
        assertEq(treasury.feeEscrow(address(usdg)), 0);
        assertEq(treasury.feeEscrowBuybackShare(address(usdg)), 0);
        assertEq(usdg.balanceOf(address(treasury)), 0);
        assertEq(keeper.balance, 1 ether - 1); // 1 wei Pyth fee kept, 4 wei returned

        vm.expectRevert(YuzuTreasury.NothingToConvert.selector);
        treasury.convertFees(address(usdg), emptyPyth);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Seed Raid on a non-WETH seed: stale feed -> salvage escrow -> convertSalvage; fresh feed -> swapped at once
    // ---------------------------------------------------------------------------------------------------------

    function test_SeedRaid_StaleFeed_SalvageEscrow_ThenConvertSalvage() public {
        bytes[] memory emptyPyth;
        YuzuAccount v2 = _newVault(2, address(wspyx), 1 ether, SeedMode.NON_US_XSTOCK);

        lens.setPriceRaw(address(wspyx), 0); // weekend: the equity feed is stale

        uint8 act = companion.ACTION_SEED_RAID();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(v2, act, owner, address(0), 2, bytes32(0), deadline);
        vm.prank(owner);
        v2.decommissionAndRaidSeed(deadline, sig, emptyPyth);

        assertEq(wspyx.balanceOf(owner), 0.8 ether);
        assertEq(wspyx.balanceOf(address(v2)), 0);
        assertEq(wspyx.balanceOf(address(companion)), 0);
        assertEq(wspyx.balanceOf(address(treasury)), 0.2 ether);
        assertEq(treasury.salvageEscrow(address(wspyx)), 0.2 ether);
        assertEq(weth.balanceOf(address(distributor)), 0);
        assertTrue(mainframe.isGutted(2));

        // Still stale: the conversion refuses and the escrow is untouched
        vm.expectRevert();
        treasury.convertSalvage(address(wspyx), emptyPyth);
        assertEq(treasury.salvageEscrow(address(wspyx)), 0.2 ether);

        // Feed is back: 0.2 wSPYx ($100) -> 0.05 WETH fair, 0.04985 after the router's 0.30%, all to the reward pool
        lens.setPriceRaw(address(wspyx), 500e18);
        vm.prank(keeper);
        uint256 wethOut = treasury.convertSalvage(address(wspyx), emptyPyth);
        assertEq(wethOut, 0.04985 ether);
        assertEq(weth.balanceOf(address(distributor)), 0.04985 ether);
        assertEq(treasury.salvageEscrow(address(wspyx)), 0);
        assertEq(wspyx.balanceOf(address(treasury)), 0);
        assertEq(weth.balanceOf(address(treasury)), 0);
    }

    function test_SeedRaid_FreshFeed_SalvageSwappedToRewardPool() public {
        bytes[] memory emptyPyth;
        YuzuAccount v3 = _newVault(3, address(wspyx), 1 ether, SeedMode.NON_US_XSTOCK);

        uint8 act = companion.ACTION_SEED_RAID();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(v3, act, owner, address(0), 3, bytes32(0), deadline);
        vm.prank(owner);
        v3.decommissionAndRaidSeed(deadline, sig, emptyPyth);

        assertEq(wspyx.balanceOf(owner), 0.8 ether);
        assertEq(weth.balanceOf(address(distributor)), 0.04985 ether);
        assertEq(treasury.salvageEscrow(address(wspyx)), 0);
        assertEq(wspyx.balanceOf(address(treasury)), 0);
        assertEq(wspyx.balanceOf(address(companion)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Fence F7: nothing leaves a BOLTED unit
    // ---------------------------------------------------------------------------------------------------------

    function test_FenceF7_BoltedUnit_BlocksTier3_Slot2_AndQueuedWithdrawal() public {
        _loosenWithGuardian();
        uint8 actWithdraw = companion.ACTION_WITHDRAW_ERC20();
        uint8 actBolt = companion.ACTION_BOLT_FOR_SALE();

        // The seller queues a withdrawal BEFORE bolting
        vm.prank(owner);
        vault.queueTier3Action(actWithdraw, owner, address(weth), 0.1 ether, bytes32(0));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigBolt = _sign(vault, actBolt, address(0), address(0), 0, bytes32(0), deadline);
        vm.prank(owner);
        vault.executeTier3Action(actBolt, address(0), address(0), 0, bytes32(0), deadline, sigBolt);
        assertEq(uint8(mainframe.boltState(1)), uint8(BoltState.BOLTED));

        vm.warp(block.timestamp + 48 hours + 1);
        deadline = block.timestamp + 1 hours;

        // 1. The queued withdrawal is ready but cannot run while the unit is listed
        vm.prank(owner);
        vm.expectRevert(YuzuAccount.VaultNotLive.selector);
        vault.executeTier3Action(actWithdraw, owner, address(weth), 0.1 ether, bytes32(0), 0, "");

        // 2. Neither can a withdrawal with a fresh Guardian signature
        bytes memory sigW = _sign(vault, actWithdraw, owner, address(weth), 0.2 ether, bytes32(0), deadline);
        vm.prank(owner);
        vm.expectRevert(YuzuAccount.VaultNotLive.selector);
        vault.executeTier3Action(actWithdraw, owner, address(weth), 0.2 ether, bytes32(0), deadline, sigW);

        // 3. Slot 2 cannot pull, through the cartridge or straight at the vault
        vm.prank(owner);
        vm.expectRevert(YuzuCartridge.VaultNotLive.selector);
        cartridge.supplyToCashLeg(1, address(tydro), address(usdg), 100e6);
        vm.prank(address(cartridge));
        vm.expectRevert(YuzuAccount.VaultNotLive.selector);
        vault.pullSlot2Asset(address(usdg), 100e6, address(cartridge));

        // 4. No slot change either
        address[] memory allowed = _wethPolicy();
        vm.prank(owner);
        vm.expectRevert(YuzuAccount.VaultNotLive.selector);
        vault.loosenDeskPolicy(allowed, 10200, 100, uint32(5 days), 5000, 0, "");

        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(usdg.balanceOf(address(vault)), 1000e6);

        // Once unbolted, the queued withdrawal works again
        mainframe.guardianForceUnbolt(1);
        vm.prank(owner);
        vault.executeTier3Action(actWithdraw, owner, address(weth), 0.1 ether, bytes32(0), 0, "");
        assertEq(weth.balanceOf(owner), 0.1 ether);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Treasury escrow guards
    // ---------------------------------------------------------------------------------------------------------

    function test_Treasury_EscrowCredit_NeedsRealTokens_AndRefusesWethAndYuzu() public {
        vm.expectRevert(YuzuTreasury.EscrowNotFunded.selector);
        treasury.receiveFeeEscrow(address(usdg), 1e6);
        vm.expectRevert(YuzuTreasury.EscrowNotFunded.selector);
        treasury.receiveSkimEscrow(address(usdg), 1e6);
        vm.expectRevert(YuzuTreasury.EscrowNotFunded.selector);
        treasury.receiveSalvageEscrow(address(usdg), 1e6);

        weth.mint(address(treasury), 1 ether);
        yuzu.mint(address(treasury), 1 ether);
        vm.expectRevert(YuzuTreasury.EscrowAssetNotAllowed.selector);
        treasury.receiveFeeEscrow(address(weth), 1 ether);
        vm.expectRevert(YuzuTreasury.EscrowAssetNotAllowed.selector);
        treasury.receiveSalvageEscrow(address(yuzu), 1 ether);

        // 1 USDG arrives: it can be credited once, to one escrow, and not a second time
        usdg.mint(address(treasury), 1e6);
        treasury.receiveSalvageEscrow(address(usdg), 1e6);
        vm.expectRevert(YuzuTreasury.EscrowNotFunded.selector);
        treasury.receiveFeeEscrow(address(usdg), 1e6);
        assertEq(treasury.salvageEscrow(address(usdg)), 1e6);
        assertEq(treasury.feeEscrow(address(usdg)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Slot-4 run fee split, now done by the companion
    // ---------------------------------------------------------------------------------------------------------

    function test_Slot4_RunFee_SplitByCompanion_BondedAndUnbondedAuthor() public {
        bytes[] memory emptyPyth;
        address authorVault = address(0xA000);
        mainframe.setUnit(0, address(0xF00D), authorVault);
        socketBay.setRomBond(0, 250_000e18);

        MockStrategyI strategy = new MockStrategyI(address(weth), address(wspyx), 0.1 ether);
        vm.prank(owner);
        vault.seatSlot4Adapter(address(strategy), "");

        // Raise the daily run-fee cap to 1,000 $YUZU (Tier 3)
        uint8 actRaise = companion.ACTION_RAISE_LIMITS();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig =
            _sign(vault, actRaise, address(uint160(0)), address(uint160(300)), 1000e18, bytes32(0), deadline);
        vm.prank(owner);
        vault.executeTier3Action(actRaise, address(uint160(0)), address(uint160(300)), 1000e18, bytes32(0), deadline, sig);

        yuzu.mint(address(vault), 1000e18);

        // Run 1: author's ROM bond is active -> 80 $YUZU to the author's vault, 20 to the reward pool
        vm.prank(owner);
        vault.executeSlot4Strategy(emptyPyth);
        assertEq(yuzu.balanceOf(authorVault), 80e18);
        assertEq(yuzu.balanceOf(address(distributor)), 20e18);
        assertEq(yuzu.balanceOf(address(vault)), 900e18);
        assertEq(yuzu.balanceOf(address(companion)), 0);

        // Run 2 a day later: bond gone -> all 100 $YUZU to the reward pool
        socketBay.setRomBond(0, 0);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.executeSlot4Strategy(emptyPyth);
        assertEq(yuzu.balanceOf(authorVault), 80e18);
        assertEq(yuzu.balanceOf(address(distributor)), 120e18);
        assertEq(yuzu.balanceOf(address(vault)), 800e18);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Companion views
    // ---------------------------------------------------------------------------------------------------------

    function test_Companion_TypehashesMatchVault_AndTelemetry() public {
        assertEq(address(vault.companion()), address(companion));

        (
            uint256 lossUsed,
            uint16 lossBudget,
            SeedMode mode,
            bool frozen,
            bool gutted,
            BoltState bolt,
            uint256 aiExpiry,
            uint256 feeRemaining,
            bool anyStale
        ) = companion.accountTelemetry(address(vault));
        assertEq(lossUsed, 0);
        assertEq(lossBudget, 300);
        assertEq(uint8(mode), uint8(SeedMode.US_BASKET));
        assertFalse(frozen);
        assertFalse(gutted);
        assertEq(uint8(bolt), uint8(BoltState.UNBOLTED));
        assertEq(aiExpiry, 0);
        assertEq(feeRemaining, 0);
        assertFalse(anyStale);

        vm.prank(guardian);
        vault.guardianPanicFreeze();
        (,,, frozen,,,,,) = companion.accountTelemetry(address(vault));
        assertTrue(frozen);

        // Frozen: Slot 2 cannot pull
        vm.prank(address(cartridge));
        vm.expectRevert(YuzuAccount.VaultNotLive.selector);
        vault.pullSlot2Asset(address(usdg), 100e6, address(cartridge));
    }

    // ---------------------------------------------------------------------------------------------------------
    // The swap leg now runs in the companion: same numbers, nothing left behind, fences still hold
    // ---------------------------------------------------------------------------------------------------------

    function test_SwapLeg_RunsInCompanion_NoResidue_FencesHold() public {
        bytes[] memory emptyPyth;

        // WETH -> wSPYx, fee on the input leg: 0.1 WETH in, 0.00025 WETH fee split 80/20 in the real Treasury
        vm.prank(owner);
        vault.executeTier1Swap(address(weth), address(wspyx), 0.1 ether, emptyPyth);
        assertEq(weth.balanceOf(address(vault)), 0.9 ether);
        assertEq(weth.balanceOf(address(distributor)), 0.0002 ether);
        assertEq(treasury.buybackWethReserve(), 0.00005 ether);
        // 0.09975 WETH = $199.50 -> 0.399 wSPYx fair, less the router's 0.30%
        assertEq(wspyx.balanceOf(address(vault)), 0.397803 ether);

        // wSPYx -> USDG, fee on the output leg (never in the xStock): 99.7 USDG gross, 0.24925 USDG fee
        vm.prank(owner);
        vault.executeTier1Swap(address(wspyx), address(usdg), 0.2 ether, emptyPyth);
        assertEq(wspyx.balanceOf(address(vault)), 0.197803 ether);
        assertEq(usdg.balanceOf(address(vault)), 1_099_450_750);
        assertEq(treasury.feeEscrow(address(usdg)), 249_250);
        assertEq(treasury.feeEscrowBuybackShare(address(usdg)), 49_850);

        // Nothing is left in the companion and the vault gave it no approval
        assertEq(weth.balanceOf(address(companion)), 0);
        assertEq(wspyx.balanceOf(address(companion)), 0);
        assertEq(usdg.balanceOf(address(companion)), 0);
        assertEq(weth.allowance(address(vault), address(companion)), 0);
        assertEq(wspyx.allowance(address(vault), address(companion)), 0);

        // Fence F3 still holds: 0.5 WETH is over 20% of Liquid NAV, and the whole call rolls back
        vm.prank(owner);
        vm.expectRevert(YuzuAccount.FenceF3ExposureCapExceeded.selector);
        vault.executeTier1Swap(address(weth), address(wspyx), 0.5 ether, emptyPyth);
        assertEq(weth.balanceOf(address(vault)), 0.9 ether);

        // A stranger cannot use the swap leg on tokens that are not there
        vm.prank(stranger);
        vm.expectRevert(YuzuAccountCompanion.SwapNotFunded.selector);
        companion.swapFor(address(weth), address(wspyx), 0.1 ether, 9900, true, 3000e18);
    }
}
