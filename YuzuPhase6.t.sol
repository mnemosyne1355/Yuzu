// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {YuzuRenderer} from "../src/YuzuRenderer.sol";
import {YuzuSvgCrateLib} from "../src/libraries/YuzuSvgCrateLib.sol";
import {YuzuSvgChassisLib} from "../src/libraries/YuzuSvgChassisLib.sol";
import {
    SeedMode,
    BoltState,
    IYuzu98v2View,
    IYuzuSocketBayView,
    IYuzuNavLensView,
    IYuzuAccountView
} from "../src/interfaces/IYuzuPhase6Interfaces.sol";

contract MockMainframe6 is IYuzu98v2View {
    mapping(uint256 => uint8) public override grade;
    mapping(uint256 => bool) public override isGutted;
    mapping(uint256 => BoltState) public override boltState;
    mapping(uint256 => uint256) public override boltEpoch;
    mapping(uint256 => address) public override getVaultAddress;

    function setUnit(uint256 id, uint8 g, bool gut, BoltState b, uint256 ep, address v) external {
        grade[id] = g;
        isGutted[id] = gut;
        boltState[id] = b;
        boltEpoch[id] = ep;
        getVaultAddress[id] = v;
    }
}

contract MockSocketBay6 is IYuzuSocketBayView {
    mapping(uint256 => uint8) public override ramTier;
    mapping(uint256 => uint256) public override ramLocked;
    mapping(uint256 => uint256) public override romBond;

    function setHardware(uint256 id, uint8 t, uint256 ram, uint256 bond) external {
        ramTier[id] = t;
        ramLocked[id] = ram;
        romBond[id] = bond;
    }
}

contract MockLens6 is IYuzuNavLensView {
    uint256 public liq;
    uint256 public disp;
    bool public stale;

    function setNav(uint256 l, uint256 d, bool s) external {
        liq = l;
        disp = d;
        stale = s;
    }

    function tryGetNav(address) external view override returns (uint256, uint256, bool) {
        return (liq, disp, stale);
    }
}

contract MockVault6 is IYuzuAccountView {
    address public override coldGuardian = address(0xBEEF);
    bool public override guardianFrozen;
    SeedMode public override seedMode = SeedMode.US_BASKET;
    address public override aiSessionKey = address(0xA1A1);
    uint256 public override aiSessionExpiry;

    function setExpiry(uint256 e) external { aiSessionExpiry = e; }
}

contract YuzuPhase6Test is Test {
    YuzuRenderer renderer;
    MockMainframe6 mainframe;
    MockSocketBay6 socketBay;
    MockLens6 lens;
    MockVault6 vault;

    function setUp() public {
        vm.warp(1_760_000_000);
        mainframe = new MockMainframe6();
        socketBay = new MockSocketBay6();
        lens = new MockLens6();
        vault = new MockVault6();
        vault.setExpiry(block.timestamp + 1 days);

        renderer = new YuzuRenderer(address(mainframe), address(socketBay), address(lens));
    }

    function test_RenderState0_SealedCargoCrate() public {
        mainframe.setUnit(7, 0, false, BoltState.UNBOLTED, 0, address(vault));
        string memory uri = renderer.tokenURI(7);
        assertGt(bytes(uri).length, 100);
    }

    function test_RenderUnsealedGrades_AndStaleMarkerNeverReverts() public {
        // Test Grade 3 LABORATORY (#0412) with $6,842 Liquid NAV, Tier 3 RAM (200,000 $YUZU), stale=true
        mainframe.setUnit(412, 3, false, BoltState.UNBOLTED, 0, address(vault));
        socketBay.setHardware(412, 3, 200_000e18, 0);
        lens.setNav(6842e18, 8000e18, true);

        string memory uri = renderer.tokenURI(412);
        assertGt(bytes(uri).length, 200);

        // Test Grade 5 HQ_MAINFRAME (#0000)
        mainframe.setUnit(0, 5, false, BoltState.UNBOLTED, 0, address(vault));
        socketBay.setHardware(0, 5, 250_000e18, 250_000e18);
        string memory uri0 = renderer.tokenURI(0);
        assertGt(bytes(uri0).length, 200);
    }
}
