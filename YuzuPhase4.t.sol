// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {YuzuAccount} from "../src/YuzuAccount.sol";
import {YuzuAccountCompanion} from "../src/YuzuAccountCompanion.sol";
import {SeedMode, BoltState} from "../src/interfaces/IYuzuPhase4Interfaces.sol";
import {
    MockERC20_4,
    MockWETH4,
    MockPyth4,
    MockMainframe4,
    MockRegistry4,
    MockLens4,
    MockRouter4,
    MockSocketBay4,
    MockDistributor4,
    MockTreasury4,
    MockHook4
} from "./mocks/Phase4Mocks.sol";

contract YuzuPhase4Test is Test {
    YuzuAccount vault;
    YuzuAccountCompanion companion;

    MockWETH4 weth;
    MockERC20_4 yuzu;
    MockERC20_4 usdg;
    MockERC20_4 wspyx;

    MockPyth4 pyth;
    MockMainframe4 mainframe;
    MockLens4 lens;
    MockRouter4 router;
    MockRegistry4 registry;
    MockSocketBay4 socketBay;
    MockDistributor4 distributor;
    MockTreasury4 treasury;
    MockHook4 hook;

    uint256 guardianPk = 0xBEEF;
    address guardian;
    address owner = address(0x1111);
    address aiAgent = address(0xA1A1);
    address recovery = address(0x9999);
    address seeder = address(0x5EED);

    function setUp() public {
        vm.warp(1_760_000_000);
        guardian = vm.addr(guardianPk);

        weth = new MockWETH4();
        yuzu = new MockERC20_4("Yuzu", "YUZU", 18);
        usdg = new MockERC20_4("Global Dollar", "USDG", 6);
        wspyx = new MockERC20_4("Wrapped SPYx", "wSPYx", 18);

        pyth = new MockPyth4();
        mainframe = new MockMainframe4();
        lens = new MockLens4();
        lens.addAsset(address(weth), 2000e18, 18);
        lens.addAsset(address(usdg), 1e18, 6);
        lens.addAsset(address(wspyx), 500e18, 18);

        router = new MockRouter4(lens);
        registry = new MockRegistry4(address(router));
        registry.setAsset(address(weth), true, true);
        registry.setAsset(address(usdg), true, true);
        registry.setAsset(address(wspyx), true, false); // xStock: NOT a crypto leg!

        socketBay = new MockSocketBay4(yuzu, weth);
        distributor = new MockDistributor4();
        treasury = new MockTreasury4(weth, address(distributor));
        hook = new MockHook4();

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

        vault = new YuzuAccount(
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
            address(0xCA77),
            address(0xDEF0),
            address(companion)
        );

        mainframe.setUnit(1, owner, address(vault));

        vm.startPrank(seeder);
        vault.initializeFromSeeder(1, guardian, recovery);
        // Seed vault with 0.1 WETH ($200) as Factory Seed
        weth.mint(address(vault), 0.1 ether);
        vault.recordSeed(address(weth), 0.1 ether, SeedMode.US_BASKET);
        vm.stopPrank();

        // Deposit an extra 0.9 WETH ($1,800) of non-seed trading capital -> Total Liquid NAV = $2,000
        weth.mint(address(vault), 0.9 ether);
    }

    function _signGuardian(
        uint8 actionType,
        address target,
        address asset,
        uint256 amount,
        bytes32 extraData,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                companion.EIP712_DOMAIN_TYPEHASH(),
                keccak256(bytes("YuzuAccount")),
                keccak256(bytes("1")),
                block.chainid,
                address(vault)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                companion.GUARDIAN_AUTH_TYPEHASH(),
                actionType,
                target,
                asset,
                amount,
                extraData,
                vault.guardianNonce(),
                vault.guardianEpoch(),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_Tier1Swap_FencesF3_F5_SeedReserve_AndCryptoLegDeskFee() public {
        bytes[] memory emptyPyth;

        // Bind AI session key
        vm.prank(owner);
        vault.setAiSessionKey(aiAgent, block.timestamp + 1 days);

        // 1. Fence F3: Swapping > 20% of Liquid NAV (0.25 WETH = $500 > 20% of $2,000) reverts!
        vm.prank(aiAgent);
        vm.expectRevert(YuzuAccount.FenceF3ExposureCapExceeded.selector);
        vault.executeTier1Swap(address(weth), address(wspyx), 0.25 ether, emptyPyth);

        // 2. Valid 20% swap (0.20 WETH = $400 -> wSPYx):
        //    0.25% desk fee is taken on the WETH crypto leg (0.0005 WETH: 80% to Distributor, 20% to Buyback)
        vm.prank(aiAgent);
        vault.executeTier1Swap(address(weth), address(wspyx), 0.20 ether, emptyPyth);

        assertEq(weth.balanceOf(address(distributor)), 0.0004 ether);
        assertEq(treasury.buybackWeth(), 0.0001 ether);
        assertGt(wspyx.balanceOf(address(vault)), 0);
        assertGt(vault.lossUsedBps(), 0);
    }

    function test_OnRewardPaid_AutoCompound_50BpsCap_ZeroDeskFee_AndMinThreshold() public {
        vm.prank(owner);
        vault.setRewardPayoutAsset(address(wspyx));

        // 1. Dust reward (< 0.001 WETH) is skipped without swapping
        weth.mint(address(vault), 0.0005 ether);
        vm.prank(address(distributor));
        vault.onRewardPaid(0.0005 ether);
        assertEq(wspyx.balanceOf(address(vault)), 0);

        // 2. Qualifying reward (0.01 WETH) auto-compounds into wSPYx with ZERO desk fee
        weth.mint(address(vault), 0.01 ether);
        vm.prank(address(distributor));
        vault.onRewardPaid(0.01 ether);
        assertGt(wspyx.balanceOf(address(vault)), 0);
        assertEq(treasury.buybackWeth(), 0); // Zero desk fee charged on auto-compound!
    }

    function test_Tier2FastLane_AndTier3PricedOnlyNoteOutflow_AndBufferLock() public {
        bytes[] memory emptyPyth;

        // 1. Raise Fast-Lane allowance to 10.00% (1000 bps) via Cold Guardian EIP-712 Co-Signature
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigRaise = _signGuardian(
            companion.ACTION_RAISE_LIMITS(),
            address(uint160(1000)),
            address(uint160(300)),
            50_000e18,
            bytes32(0),
            deadline
        );
        vm.startPrank(owner);
        vault.executeTier3Action(
            companion.ACTION_RAISE_LIMITS(),
            address(uint160(1000)),
            address(uint160(300)),
            50_000e18,
            bytes32(0),
            deadline,
            sigRaise
        );
        vm.stopPrank();
        assertEq(vault.dailyFastLaneBps(), 1000);

        // 2. Fast-Lane withdrawal of 0.05 WETH ($100 = 5% of $2,000 NAV) succeeds and calls noteOutflow
        vm.prank(owner);
        vault.withdrawFastLane(address(weth), 0.05 ether, owner, emptyPyth);
        assertEq(distributor.outflowCallCount(), 1);

        // 3. Buy 10,000 $YUZU run-fee buffer during Launch Gate
        vm.prank(owner);
        vault.buyRunFeeBuffer(0.01 ether, 10_000e18, emptyPyth);
        assertEq(yuzu.balanceOf(address(vault)), 10_000e18);

        // 4. Attempting to withdraw pool-bought buffer $YUZU via Tier 3 while Launch Gate is active reverts!
        bytes memory sigWithdrawBuffer = _signGuardian(
            companion.ACTION_WITHDRAW_ERC20(), owner, address(yuzu), 5_000e18, bytes32(0), deadline
        );
        uint8 actWithdrawErc20 = companion.ACTION_WITHDRAW_ERC20();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YuzuAccount.LaunchGateBufferLocked.selector, 10_000e18, 5_000e18));
        vault.executeTier3Action(
            actWithdrawErc20, owner, address(yuzu), 5_000e18, bytes32(0), deadline, sigWithdrawBuffer
        );

        // 5. Deposit 20,000 reward/wallet $YUZU into vault -> withdrawing that 20,000 via Tier 3 succeeds
        //    AND does NOT call distributor.noteOutflow() because $YUZU is Unpriced!
        yuzu.mint(address(vault), 20_000e18);
        bytes memory sigWithdrawFreeYuzu = _signGuardian(
            companion.ACTION_WITHDRAW_ERC20(), owner, address(yuzu), 20_000e18, bytes32(0), deadline
        );
        vm.startPrank(owner);
        vault.executeTier3Action(
            companion.ACTION_WITHDRAW_ERC20(), owner, address(yuzu), 20_000e18, bytes32(0), deadline, sigWithdrawFreeYuzu
        );
        vm.stopPrank();
        assertEq(yuzu.balanceOf(owner), 20_000e18);
        assertEq(distributor.outflowCallCount(), 1); // Unchanged!
    }

    function test_SeedRaid_80_20_Split_AndForfeit() public {
        bytes[] memory emptyPyth;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigRaid = _signGuardian(
            companion.ACTION_SEED_RAID(), owner, address(0), 1, bytes32(0), deadline
        );

        uint256 ownerWethBefore = weth.balanceOf(owner);
        vm.prank(owner);
        vault.decommissionAndRaidSeed(deadline, sigRaid, emptyPyth);

        // 80% of 0.10 WETH seed = 0.08 WETH to Owner; 20% = 0.02 WETH to Distributor
        assertEq(weth.balanceOf(owner) - ownerWethBefore, 0.08 ether);
        assertEq(weth.balanceOf(address(distributor)), 0.02 ether);
        assertEq(socketBay.forfeitedTokenId(), 1);
        assertEq(distributor.raidCancelledTokenId(), 1);
        assertTrue(mainframe.isGutted(1));
    }
}
