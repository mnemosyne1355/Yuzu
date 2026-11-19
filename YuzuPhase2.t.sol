// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {YuzuRegistry} from "../src/YuzuRegistry.sol";
import {YuzuNavLens} from "../src/YuzuNavLens.sol";
import {YuzuPriceArchive} from "../src/YuzuPriceArchive.sol";
import {
    MockChainlinkFeed,
    MockPyth,
    MockERC20Asset,
    MockXStockWrapper,
    MockCartridge
} from "./mocks/Phase2Mocks.sol";

contract YuzuPhase2Test is Test {
    YuzuRegistry registry;
    YuzuNavLens lens;
    YuzuPriceArchive archive;
    MockPyth pyth;

    MockERC20Asset weth;
    MockERC20Asset usdg;
    MockXStockWrapper wspyx;
    MockChainlinkFeed wethClFeed;
    MockChainlinkFeed usdgClFeed;
    MockChainlinkFeed spyxClFeed;

    bytes32 constant WETH_PYTH_ID = keccak256("WETH_USD");
    bytes32 constant SPYX_PYTH_ID = keccak256("SPY_USD");

    address multisig = address(0xA11CE);
    address router = address(0x9999);
    address vault = address(0x7001);

    function setUp() public {
        vm.warp(1_760_000_000); // Realistic timestamp so block.timestamp > 96 hours

        pyth = new MockPyth();
        weth = new MockERC20Asset("Wrapped Ether", "WETH", 18);
        usdg = new MockERC20Asset("Global Dollar", "USDG", 6);
        wspyx = new MockXStockWrapper("Wrapped SPYx", "wSPYx", 18, address(0x5555));

        // WETH = $2,050.00 (8 decimals Chainlink + Pyth expo -8)
        wethClFeed = new MockChainlinkFeed(8, 2050_00000000);
        pyth.setPrice(WETH_PYTH_ID, 2050_00000000, -8, block.timestamp);

        // USDG = $1.00 (Single-anchored Chainlink 8 decimals)
        usdgClFeed = new MockChainlinkFeed(8, 1_00000000);

        // SPYx = $600.00 (Dual-anchored Chainlink 8 decimals + Pyth expo -8)
        spyxClFeed = new MockChainlinkFeed(8, 600_00000000);
        pyth.setPrice(SPYX_PYTH_ID, 600_00000000, -8, block.timestamp);

        // Prepare constructor launch assets & routes
        YuzuRegistry.InitialAssetInput[] memory initAssets = new YuzuRegistry.InitialAssetInput[](3);
        initAssets[0] = YuzuRegistry.InitialAssetInput({
            asset: address(weth),
            config: YuzuRegistry.AssetConfig({
                isRegistered: true,
                isPaused: false,
                isWrapper: false,
                isCryptoLeg: true,
                tokenDecimals: 18,
                maxAge: 3600,
                chainlinkFeed: address(wethClFeed),
                pythFeedId: WETH_PYTH_ID
            })
        });
        initAssets[1] = YuzuRegistry.InitialAssetInput({
            asset: address(usdg),
            config: YuzuRegistry.AssetConfig({
                isRegistered: true,
                isPaused: false,
                isWrapper: false,
                isCryptoLeg: true,
                tokenDecimals: 6,
                maxAge: 86400,
                chainlinkFeed: address(usdgClFeed),
                pythFeedId: bytes32(0)
            })
        });
        initAssets[2] = YuzuRegistry.InitialAssetInput({
            asset: address(wspyx),
            config: YuzuRegistry.AssetConfig({
                isRegistered: true,
                isPaused: false,
                isWrapper: true,
                isCryptoLeg: false,
                tokenDecimals: 18,
                maxAge: 3600,
                chainlinkFeed: address(spyxClFeed),
                pythFeedId: SPYX_PYTH_ID
            })
        });

        YuzuRegistry.InitialRouteInput[] memory initRoutes = new YuzuRegistry.InitialRouteInput[](1);
        initRoutes[0] = YuzuRegistry.InitialRouteInput({
            tokenIn: address(weth),
            tokenOut: address(wspyx),
            route: YuzuRegistry.Route({router: router, routerType: 1, path: abi.encodePacked(address(weth), address(wspyx)), isActive: true})
        });

        registry = new YuzuRegistry(multisig, initAssets, initRoutes);
        lens = new YuzuNavLens(address(registry), address(pyth));
        archive = new YuzuPriceArchive(address(lens));
    }

    function test_DualAnchored_DivergenceCheckAndWrapperMultiplier() public {
        // Set wSPYx ERC-4626 multiplier to 1.05x (underlying SPY = $600 -> wSPYx = $630)
        wspyx.setMultiplier(1.05e18);
        uint256 price = lens.requireFresh(address(wspyx));
        assertEq(price, 630e18);

        // Skew Pyth price by 2.00% ($612 vs $600 Chainlink) -> exceeds 1.50% (150 bps) fence
        pyth.setPrice(SPYX_PYTH_ID, 612_00000000, -8, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                YuzuNavLens.OracleDivergenceExceeded.selector, address(wspyx), 600e18, 612e18
            )
        );
        lens.requireFresh(address(wspyx));
    }

    function test_WeekendStaleVs96HourHardStaleCeiling_AndPauseZeroing() public {
        // Mint 1 WETH ($2,050), 1,000 USDG ($1,000), and 2 wSPYx ($1,200) to vault -> $4,250 Liquid NAV
        weth.mint(vault, 1e18);
        usdg.mint(vault, 1000e6);
        wspyx.mint(vault, 2e18);

        assertEq(lens.getLiquidNavUsd(vault), 4250e18);

        // Advance 48 hours (standard weekend: wSPYx feed stops publishing, WETH and USDG stay fresh)
        vm.warp(block.timestamp + 48 hours);
        wethClFeed.setRoundData(2050_00000000, block.timestamp);
        pyth.setPrice(WETH_PYTH_ID, 2050_00000000, -8, block.timestamp);
        usdgClFeed.setRoundData(1_00000000, block.timestamp);

        // wSPYx is > maxAge (1h), so requireFresh(wspyx) reverts (blocking equity trades on weekends)
        vm.expectRevert();
        lens.requireFresh(address(wspyx));

        // However, getLiquidNavUsd still includes wSPYx at its Friday close ($1,200) because 48h <= 96h ceiling!
        assertEq(lens.getLiquidNavUsd(vault), 4250e18);
        (uint256 liqNav, , bool anyStale) = lens.tryGetNav(vault);
        assertEq(liqNav, 4250e18);
        assertTrue(anyStale);

        // If the registry admin pauses wSPYx (e.g. corporate-action window), its NAV contribution immediately zeroes!
        vm.prank(multisig);
        registry.setAssetPaused(address(wspyx), true);
        assertEq(lens.getLiquidNavUsd(vault), 3050e18); // Only WETH ($2,050) + USDG ($1,000)

        vm.prank(multisig);
        registry.setAssetPaused(address(wspyx), false);
        assertEq(lens.getLiquidNavUsd(vault), 4250e18);

        // Now advance past 96 hours (e.g. 100 hours since Friday close) -> wSPYx hits HARD_STALE_CEILING and zeroes!
        vm.warp(block.timestamp + 52 hours);
        wethClFeed.setRoundData(2050_00000000, block.timestamp);
        pyth.setPrice(WETH_PYTH_ID, 2050_00000000, -8, block.timestamp);
        usdgClFeed.setRoundData(1_00000000, block.timestamp);

        assertEq(lens.getLiquidNavUsd(vault), 3050e18);
    }

    function test_Registry48hTimelock_AndCartridgeCodeHashCheck() public {
        MockCartridge cart = new MockCartridge();
        bytes32 opHash = keccak256(abi.encode("LIST_CARTRIDGE", address(cart), uint256(42), uint256(100e18)));

        vm.prank(multisig);
        registry.queueOperation(opHash, "List MockCartridge");

        // Cannot execute before 48 hours
        vm.prank(multisig);
        vm.expectRevert(YuzuRegistry.OpNotReady.selector);
        registry.executeListCartridge(address(cart), 42, 100e18);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        registry.executeListCartridge(address(cart), 42, 100e18);

        (bool ok, uint256 authorId, uint256 fee) = registry.isCartridgeExecutable(address(cart));
        assertTrue(ok);
        assertEq(authorId, 42);
        assertEq(fee, 100e18);

        // Attempting to re-list with a HIGHER run price reverts
        bytes32 opHashHigher = keccak256(abi.encode("LIST_CARTRIDGE", address(cart), uint256(42), uint256(200e18)));
        vm.prank(multisig);
        registry.queueOperation(opHashHigher, "Raise price");
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(YuzuRegistry.RunPriceCannotIncrease.selector);
        registry.executeListCartridge(address(cart), 42, 200e18);
    }

    function test_PriceArchive_14DayReturnWithWeekendFallback() public {
        // Record Day 0 price for WETH ($2,050)
        archive.record(address(weth));

        // Warp 14 days forward and update WETH price to $2,255 (+10.00% = +1000 bps)
        vm.warp(block.timestamp + 14 days);
        wethClFeed.setRoundData(2255_00000000, block.timestamp);
        pyth.setPrice(WETH_PYTH_ID, 2255_00000000, -8, block.timestamp);

        (bool valid, int256 retBps) = archive.get14DayReturnBps(address(weth));
        assertTrue(valid);
        assertEq(retBps, 1000); // +10.00%

        // Warp 2 more days (so the Day 0 record is now 16 days ago, testing the 5-day weekend/holiday fallback window)
        vm.warp(block.timestamp + 2 days);
        wethClFeed.setRoundData(2255_00000000, block.timestamp);
        pyth.setPrice(WETH_PYTH_ID, 2255_00000000, -8, block.timestamp);

        (bool validFallback, int256 retBpsFallback) = archive.get14DayReturnBps(address(weth));
        assertTrue(validFallback);
        assertEq(retBpsFallback, 1000);
    }
}
