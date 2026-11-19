// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey, IPoolManager, IWETH, V4StateLib} from "../src/interfaces/IYuzuV4Interfaces.sol";
import {SeedMode} from "../src/interfaces/IYuzuPhase3Interfaces.sol";
import {YuzuSwapRouterAdapter} from "../src/adapters/YuzuSwapRouterAdapter.sol";
import {DeployYuzu98V50} from "../script/DeployYuzu98V50.s.sol";
import {MockChainlinkFeed, MockPyth} from "./mocks/Phase2Mocks.sol";

interface IV3PoolView {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IV3FactoryView {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IV3PositionManagerMinimal {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params) external payable returns (uint256, uint128, uint256, uint256);
}

interface IWrapperView {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice ADDED (bankr 2026-11-19, founder request 00:01Z). Runs script/DeployYuzu98V50.s.sol (deployAndWireAll17,
///         all 17 contracts) and the adapter's V3 leg on a fork of Ink against the real Uniswap v4 PoolManager,
///         the real Universal Router, the real Uniswap V3 pools, the real Quotrons USDG / wSPYx pool and the real
///         WETH, USDG, kBTC and wSPYx tokens.
/// @dev Needs INK_RPC_URL; without it every test here is skipped. A fork is a local copy of Ink: nothing is sent.
///      NOT real here: the oracles. No Chainlink or Pyth address on Ink has been supplied, so the feeds are
///      MockChainlinkFeed / MockPyth, priced at each pool's own spot price at the fork block. That is the most
///      favourable case for the Seeder's 1.50% check: any shortfall is the pool's fee plus price impact only.
///      The script's default routes are overridden for Ink in _params (the only WETH / USDG V3 pool is the 1.00%
///      tier). The kBTC address was not supplied by the founder; it is the token on Ink whose symbol() is kBTC.
contract YuzuInkForkDeployTest is Test {
    using SafeERC20 for IERC20;

    uint24 constant V3_FEE_WETH_USDG = 10_000;
    uint24 constant V3_FEE_WETH_KBTC = 3_000;

    bytes32 constant PYTH_ETH = bytes32(uint256(1));
    bytes32 constant PYTH_BTC = bytes32(uint256(2));
    bytes32 constant PYTH_USDG = bytes32(uint256(3));
    bytes32 constant PYTH_SPY = bytes32(uint256(4));

    address pm;
    address weth;
    address usdg;
    address wspyx;
    address kbtc;
    address universalRouter;
    address v3Factory;
    address v3PositionManager;
    address quotronHook;
    address wethUsdgPool;
    address wethKbtcPool;
    bytes32 qPoolId;
    bool forked;

    DeployYuzu98V50 deployerScript;
    MockPyth pyth;
    MockChainlinkFeed ethFeed;
    MockChainlinkFeed btcFeed;
    MockChainlinkFeed usdgFeed;
    MockChainlinkFeed spyFeed;
    uint256 eth8;
    uint256 btc8;
    uint256 wspyx8;
    uint256 spy8;

    address multisig = address(0xA11CE);
    address team = address(0xB0B);
    address founder;
    address guardian;
    address recovery;
    address alice;

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
        kbtc = vm.parseAddress("0x73e0c0d45e048d25fc26fa3159b0aa04bfa4db98");
        universalRouter = vm.parseAddress("0x661e93cca42afacb172121ef892830ca3b70f08d");
        // The V3 factory and position manager named in that Universal Router's constructor arguments
        v3Factory = vm.parseAddress("0x640887a9ba3a9c53ed27d0f7e8246a4f933f3424");
        v3PositionManager = vm.parseAddress("0xc0836e5b058bbe22ae2266e1ac488a1a0fd8dce8");

        founder = makeAddr("founder");
        guardian = makeAddr("guardian");
        recovery = makeAddr("recovery");
        alice = makeAddr("alice");

        wethUsdgPool = IV3FactoryView(v3Factory).getPool(weth, usdg, V3_FEE_WETH_USDG);
        wethKbtcPool = IV3FactoryView(v3Factory).getPool(weth, kbtc, V3_FEE_WETH_KBTC);
        require(wethUsdgPool != address(0) && wethKbtcPool != address(0), "V3 pools");

        deployerScript = new DeployYuzu98V50();
        vm.deal(address(deployerScript), 1 ether);
        quotronHook = deployerScript.QUOTRON_STOCK_HOOK();
        bool usdgIs0 = usdg < wspyx;
        qPoolId = keccak256(
            abi.encode(
                PoolKey({
                    currency0: usdgIs0 ? usdg : wspyx,
                    currency1: usdgIs0 ? wspyx : usdg,
                    fee: deployerScript.QUOTRON_DYNAMIC_FEE_FLAG(),
                    tickSpacing: deployerScript.QUOTRON_TICK_SPACING(),
                    hooks: quotronHook
                })
            )
        );

        // Mock oracles priced at the pools' own spot prices (USD, 8 decimals; USDG taken as $1)
        require(weth < usdg && weth < kbtc, "token order");
        (uint160 s,,,,,,) = IV3PoolView(wethUsdgPool).slot0();
        eth8 = Math.mulDiv(uint256(s) * uint256(s), 1e20, 1 << 192);
        (s,,,,,,) = IV3PoolView(wethKbtcPool).slot0();
        btc8 = Math.mulDiv(eth8, 1 << 192, uint256(s) * uint256(s) * 1e10);
        (uint160 q,) = V4StateLib.getSlot0(IPoolManager(pm), qPoolId);
        uint256 q2 = uint256(q) * uint256(q);
        wspyx8 = usdgIs0 ? Math.mulDiv(1e20, 1 << 192, q2) : Math.mulDiv(q2, 1e20, 1 << 192);
        spy8 = (wspyx8 * 1e18) / IWrapperView(wspyx).convertToAssets(1e18);

        ethFeed = new MockChainlinkFeed(8, int256(eth8));
        btcFeed = new MockChainlinkFeed(8, int256(btc8));
        usdgFeed = new MockChainlinkFeed(8, 1e8);
        spyFeed = new MockChainlinkFeed(8, int256(spy8));
        pyth = new MockPyth();
        pyth.setPrice(PYTH_ETH, int64(int256(eth8)), -8, block.timestamp);
        pyth.setPrice(PYTH_BTC, int64(int256(btc8)), -8, block.timestamp);
        pyth.setPrice(PYTH_USDG, 1e8, -8, block.timestamp);
        pyth.setPrice(PYTH_SPY, int64(int256(spy8)), -8, block.timestamp);
    }

    function _logPrices() internal view {
        console.log("fork block", block.number);
        console.log("pool spot: ETH in USD (8 dp)", eth8);
        console.log("pool spot: BTC in USD (8 dp)", btc8);
        console.log("pool spot: wSPYx in USDG (8 dp)", wspyx8);
    }

    function _twoHop(bool buy) internal view returns (bytes memory) {
        YuzuSwapRouterAdapter.V4Hop memory v3 = YuzuSwapRouterAdapter.V4Hop({
            tokenIn: buy ? weth : usdg,
            tokenOut: buy ? usdg : weth,
            fee: V3_FEE_WETH_USDG,
            tickSpacing: 0,
            hooks: address(0)
        });
        YuzuSwapRouterAdapter.V4Hop memory qh = YuzuSwapRouterAdapter.V4Hop({
            tokenIn: buy ? usdg : wspyx,
            tokenOut: buy ? wspyx : usdg,
            fee: deployerScript.QUOTRON_DYNAMIC_FEE_FLAG(),
            tickSpacing: deployerScript.QUOTRON_TICK_SPACING(),
            hooks: quotronHook
        });
        YuzuSwapRouterAdapter.V4Hop[] memory hops = new YuzuSwapRouterAdapter.V4Hop[](2);
        hops[0] = buy ? v3 : qh;
        hops[1] = buy ? qh : v3;
        return abi.encode(hops);
    }

    /// @dev The script's own parameters and default registry inputs, with the real Ink addresses, the Universal
    ///      Router as the V3 router (so the script deploys YuzuSwapRouterAdapter itself), and the four routes
    ///      that cross WETH / USDG moved from the script's default 0.30% tier to the 1.00% tier, the only
    ///      WETH / USDG V3 pool on Ink.
    function _params(uint256 vaultCount) internal view returns (DeployYuzu98V50.DeployParams memory p) {
        p.multisig = multisig;
        p.teamRecipient = team;
        p.founderRecipient = founder;
        p.initialGuardian = guardian;
        p.recoveryAddress = recovery;
        p.poolManager = pm;
        p.pyth = address(pyth);
        p.weth = weth;
        p.kbtc = kbtc;
        p.usdg = usdg;
        p.wspyx = wspyx;
        p.hookPermissionMask = deployerScript.DEFAULT_HOOK_PERMISSION_MASK();
        p.initialVaultBatchCount = vaultCount;
        p.v3SwapRouter = universalRouter;
        (p.initialAssets, p.initialRoutes) = deployerScript.buildDefaultRegistryInputs(
            weth,
            kbtc,
            usdg,
            wspyx,
            address(ethFeed),
            address(btcFeed),
            address(usdgFeed),
            address(spyFeed),
            PYTH_ETH,
            PYTH_BTC,
            PYTH_USDG,
            PYTH_SPY,
            address(0)
        );
        p.pythUpdateData = new bytes[](0);

        require(p.initialRoutes[1].tokenIn == weth && p.initialRoutes[1].tokenOut == usdg, "route 1");
        require(p.initialRoutes[2].tokenIn == weth && p.initialRoutes[2].tokenOut == wspyx, "route 2");
        require(p.initialRoutes[5].tokenIn == wspyx && p.initialRoutes[5].tokenOut == weth, "route 5");
        require(p.initialRoutes[6].tokenIn == usdg && p.initialRoutes[6].tokenOut == weth, "route 6");
        p.initialRoutes[1].route.path = abi.encode(V3_FEE_WETH_USDG);
        p.initialRoutes[6].route.path = abi.encode(V3_FEE_WETH_USDG);
        p.initialRoutes[2].route.path = _twoHop(true);
        p.initialRoutes[5].route.path = _twoHop(false);
    }

    function dealExternal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }

    function _fund(address token, uint256 amount) internal {
        try this.dealExternal(token, address(this), amount) {} catch {}
        require(IERC20(token).balanceOf(address(this)) >= amount, "could not create test tokens on the fork");
    }

    /// @dev Adds a full-range position of 100 WETH plus the matching amount of `other` at the pool's current
    ///      price. The price does not move; only the depth changes.
    function _deepen(address other, uint24 fee, int24 tick, uint256 otherDesired)
        internal
        returns (uint256 wethUsed, uint256 otherUsed)
    {
        _fund(other, otherDesired);
        IERC20(weth).forceApprove(v3PositionManager, 100 ether);
        IERC20(other).forceApprove(v3PositionManager, otherDesired);
        (,, wethUsed, otherUsed) = IV3PositionManagerMinimal(v3PositionManager).mint(
            IV3PositionManagerMinimal.MintParams({
                token0: weth,
                token1: other,
                fee: fee,
                tickLower: -tick,
                tickUpper: tick,
                amount0Desired: 100 ether,
                amount1Desired: otherDesired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 60
            })
        );
    }

    function _leg(
        YuzuSwapRouterAdapter adapter,
        string memory label,
        address tokenOut,
        uint256 wethIn,
        bytes memory path,
        uint256 fairOut
    ) internal returns (bool ok, uint256 out) {
        console.log(label);
        console.log("  output at the pool's spot price, no fee", fairOut);
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        uint256 routerWeth = IERC20(weth).balanceOf(universalRouter);
        try adapter.swapExactIn(weth, tokenOut, wethIn, 1, address(this), path) returns (uint256 o) {
            ok = true;
            out = o;
            console.log("  received", out);
            console.log("  shortfall vs spot, bps", fairOut > out ? ((fairOut - out) * 10_000) / fairOut : 0);
            assertEq(IERC20(tokenOut).balanceOf(address(this)) - before, out, "output delivered");
        } catch (bytes memory err) {
            console.log("  REVERTED, error data:");
            console.logBytes(err);
        }
        assertEq(IERC20(weth).balanceOf(address(adapter)), 0, "adapter WETH");
        assertEq(IERC20(usdg).balanceOf(address(adapter)), 0, "adapter USDG");
        assertEq(IERC20(tokenOut).balanceOf(address(adapter)), 0, "adapter output token");
        assertEq(IERC20(weth).balanceOf(universalRouter), routerWeth, "nothing left in the Universal Router");
    }

    /// @notice The adapter's V3 leg against the real Universal Router and the real V3 pools, at the three sizes
    ///         the Seeder uses. Shows what the pools pay today; a leg that reverts is logged, not hidden.
    function test_Fork_AdapterV3Leg_ThroughInkUniversalRouter() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _logPrices();
        YuzuSwapRouterAdapter adapter = new YuzuSwapRouterAdapter(pm, universalRouter);
        vm.deal(address(this), 10 ether);
        IWETH(weth).deposit{value: 1 ether}();
        IERC20(weth).forceApprove(address(adapter), 1 ether);

        (bool okUsdg,) = _leg(
            adapter,
            "A. 0.015 WETH -> USDG, V3 1.00% pool (US_BASKET USDG leg)",
            usdg,
            0.015 ether,
            abi.encode(V3_FEE_WETH_USDG),
            (uint256(0.015 ether) * eth8) / 1e20
        );
        assertTrue(okUsdg, "V3 leg through the Universal Router");

        _leg(
            adapter,
            "B. 0.03 WETH -> kBTC, V3 0.30% pool (US_BASKET kBTC leg)",
            kbtc,
            0.03 ether,
            "",
            (uint256(0.03 ether) * eth8) / btc8 / 1e10
        );

        _leg(
            adapter,
            "C. 0.075 WETH -> USDG (V3 1.00%) -> wSPYx (Quotrons v4) (NON_US_XSTOCK seed)",
            wspyx,
            0.075 ether,
            _twoHop(true),
            (uint256(0.075 ether) * eth8) / wspyx8
        );
    }

    /// @notice The full 17-contract deploy script on Ink as it is today. Logs whether it completes or where it
    ///         reverts.
    function test_Fork_FullDeploy_OnInkAsItIsToday() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _logPrices();
        DeployYuzu98V50.DeployParams memory p = _params(3);
        try deployerScript.deployAndWireAll17(p) returns (DeployYuzu98V50.DeployedContracts memory d) {
            console.log("AS-IS DEPLOY: completed");
            console.log("  #0000 vault kBTC", IERC20(kbtc).balanceOf(d.deployedVaults[0]));
            console.log("  #0000 vault USDG", IERC20(usdg).balanceOf(d.deployedVaults[0]));
        } catch (bytes memory err) {
            console.log("AS-IS DEPLOY: REVERTED, error data:");
            console.logBytes(err);
        }
    }

    /// @notice The same script after 100 WETH of full-range liquidity is added, on the fork only, to each of the
    ///         two V3 pools the seed uses. Shows the 17 contracts deploy, wire and commission units against the
    ///         real PoolManager, Universal Router, V3 pools, Quotrons pool and tokens once the pools have depth.
    function test_Fork_FullDeploy_WithDeepenedV3Pools() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _logPrices();
        vm.deal(address(this), 300 ether);
        IWETH(weth).deposit{value: 200 ether}();
        (uint256 w1, uint256 u1) = _deepen(usdg, V3_FEE_WETH_USDG, 887_200, (200e6 * eth8) / 1e8);
        (uint256 w2, uint256 k2) = _deepen(kbtc, V3_FEE_WETH_KBTC, 887_220, (200e8 * eth8) / btc8);
        console.log("added to WETH/USDG pool: WETH", w1);
        console.log("added to WETH/USDG pool: USDG", u1);
        console.log("added to WETH/kBTC pool: WETH", w2);
        console.log("added to WETH/kBTC pool: kBTC", k2);

        DeployYuzu98V50.DeployedContracts memory d = deployerScript.deployAndWireAll17(_params(3));
        address adapter = address(d.swapRouterAdapter);

        // Wiring
        assertGt(adapter.code.length, 0, "adapter deployed by the script");
        assertEq(d.swapRouterAdapter.v3Router(), universalRouter, "adapter points at the Universal Router");
        assertEq(address(d.swapRouterAdapter.poolManager()), pm, "adapter points at the PoolManager");
        assertEq(d.registry.routeFor(weth, kbtc).router, adapter, "WETH -> kBTC router");
        assertEq(d.registry.routeFor(weth, wspyx).router, adapter, "WETH -> wSPYx router");
        assertEq(uint160(address(d.hook)) & 0x3FFF, 0x2880, "hook permission bits");
        assertLt(d.deployedVaults[0].code.length, 24_576, "vault size");
        assertGt(d.deployedVaults[0].code.length, 20_000, "full standalone vault");

        // #0000 and the $YUZU / WETH pool on the real PoolManager
        assertEq(d.mainframe.ownerOf(0), founder, "#0000 owner");
        assertEq(d.socketBay.ramTier(0), 5, "#0000 RAM tier");
        assertTrue(d.treasury.poolOpened(), "pool opened");
        bool yuzuIs0 = address(d.yuzuToken) < weth;
        PoolKey memory key = PoolKey({
            currency0: yuzuIs0 ? address(d.yuzuToken) : weth,
            currency1: yuzuIs0 ? weth : address(d.yuzuToken),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(d.hook)
        });
        (uint160 sqrtP,) = V4StateLib.getSlot0(IPoolManager(pm), keccak256(abi.encode(key)));
        assertEq(sqrtP, d.treasury.openingSqrtPriceX96(), "pool price on the real PoolManager");
        assertApproxEqAbs(d.treasury.totalYuzuAddedToLp(), 150_000e18, 1e17, "YUZU in the pool");

        // #0000's seed, bought through the adapter on the real V3 pools
        address v0 = d.deployedVaults[0];
        assertEq(IERC20(weth).balanceOf(v0), 0.03 ether, "#0000 WETH seed");
        uint256 fairKbtc = (uint256(0.03 ether) * eth8) / btc8 / 1e10;
        uint256 fairUsdg = (uint256(0.015 ether) * eth8) / 1e20;
        console.log("#0000 kBTC seed", IERC20(kbtc).balanceOf(v0));
        console.log("  at spot, no fee", fairKbtc);
        console.log("#0000 USDG seed", IERC20(usdg).balanceOf(v0));
        console.log("  at spot, no fee", fairUsdg);
        assertGe(IERC20(kbtc).balanceOf(v0), (fairKbtc * 9850) / 10_000, "#0000 kBTC seed within 1.50%");
        assertGe(IERC20(usdg).balanceOf(v0), (fairUsdg * 9850) / 10_000, "#0000 USDG seed within 1.50%");

        // #0001: a public US_BASKET mint
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        d.seeder.commissionMainframe{value: 0.15 ether}(1, SeedMode.US_BASKET, guardian, recovery, new bytes[](0));
        assertEq(d.mainframe.ownerOf(1), alice, "#0001 owner");
        assertEq(d.socketBay.ramTier(1), 1, "#0001 RAM tier");
        assertGt(IERC20(kbtc).balanceOf(d.deployedVaults[1]), 0, "#0001 kBTC seed");
        assertGt(IERC20(usdg).balanceOf(d.deployedVaults[1]), 0, "#0001 USDG seed");

        // #0002: a public NON_US_XSTOCK mint, WETH -> USDG on V3 then USDG -> wSPYx on the real Quotrons pool
        uint256 fairWspyx = (uint256(0.075 ether) * eth8) / wspyx8;
        console.log("#0002 wSPYx at spot, no fee", fairWspyx);
        vm.prank(alice);
        try d.seeder.commissionMainframe{value: 0.15 ether}(
            1, SeedMode.NON_US_XSTOCK, guardian, recovery, new bytes[](0)
        ) {
            uint256 got = IERC20(wspyx).balanceOf(d.deployedVaults[2]);
            console.log("#0002 wSPYx seed", got);
            console.log("  shortfall vs spot, bps", fairWspyx > got ? ((fairWspyx - got) * 10_000) / fairWspyx : 0);
            assertEq(d.mainframe.ownerOf(2), alice, "#0002 owner");
        } catch (bytes memory err) {
            console.log("#0002 NON_US_XSTOCK mint REVERTED, error data:");
            console.logBytes(err);
        }

        // The adapter keeps nothing
        assertEq(IERC20(weth).balanceOf(adapter), 0, "adapter WETH");
        assertEq(IERC20(usdg).balanceOf(adapter), 0, "adapter USDG");
        assertEq(IERC20(kbtc).balanceOf(adapter), 0, "adapter kBTC");
        assertEq(IERC20(wspyx).balanceOf(adapter), 0, "adapter wSPYx");
    }
}
