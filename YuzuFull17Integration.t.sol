// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, ModifyLiquidityParams, IUnlockCallback} from "../src/interfaces/IYuzuV4Interfaces.sol";
// FIX (bankr 2026-11-18): SeedMode must come from the file the Seeder imports it from; BoltState was unused.
import {SeedMode} from "../src/interfaces/IYuzuPhase3Interfaces.sol";

// All 17 Real Protocol Contracts (10 & 11 are linked into 12 YuzuRenderer)
import {Yuzu98v2} from "../src/Yuzu98v2.sol";
import {YuzuAccount} from "../src/YuzuAccount.sol";
import {YuzuSeeder} from "../src/YuzuSeeder.sol";
import {YuzuSocketBay} from "../src/YuzuSocketBay.sol";
import {YuzuCartridge} from "../src/YuzuCartridge.sol";
import {YuzuRelativeStrengthAdapter} from "../src/adapters/YuzuRelativeStrengthAdapter.sol";
import {YuzuNavLens} from "../src/YuzuNavLens.sol";
import {YuzuDistributor} from "../src/YuzuDistributor.sol";
import {YuzuTreasury} from "../src/YuzuTreasury.sol";
import {YuzuRenderer} from "../src/YuzuRenderer.sol";
import {YuzuRegistry} from "../src/YuzuRegistry.sol";
import {YuzuToken} from "../src/YuzuToken.sol";
import {YuzuPriceArchive} from "../src/YuzuPriceArchive.sol";
import {YuzuPoolHook} from "../src/YuzuPoolHook.sol";
import {YuzuAccountCompanion} from "../src/YuzuAccountCompanion.sol";

import {DeployYuzu98V50} from "../script/DeployYuzu98V50.s.sol";
// ADDED (bankr 2026-11-18 20:05Z): for _assertWspyxPathsMatchAdapter.
import {YuzuSwapRouterAdapter, IUniversalRouterMinimal} from "../src/adapters/YuzuSwapRouterAdapter.sol";
// ADDED (bankr 2026-11-18 20:30Z): pass-through hook stand-in, shared with the adapter test.
import {MockPassThroughHook} from "./YuzuAdapters.t.sol";

// External Chain Infrastructure Mocks Only
import {MockV4PoolManager, MockWETH, FullRangeLpHelper} from "./mocks/Phase1Mocks.sol";
// FIX (bankr 2026-11-18): Phase2Mocks has no MockERC20Dec or MockSwapRouter. MockERC20Asset has the same
// constructor, and a MockSwapRouter is defined below.
import {MockChainlinkFeed, MockPyth, MockERC20Asset as MockERC20Dec, MockXStockWrapper} from "./mocks/Phase2Mocks.sol";

/// @dev FIX (bankr 2026-11-18): added. Stand-in for the external swap router the Seeder buys the seed through.
///      Pays out at the prices set by the test (the same prices the feeds report) and mints the output token.
contract MockSwapRouter {
    mapping(address => uint256) public price18;
    mapping(address => uint8) public dec;

    function setAsset(address token, uint256 p18, uint8 decimals_) external {
        price18[token] = p18;
        dec[token] = decimals_;
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * price18[tokenIn] * (10 ** dec[tokenOut])) / (price18[tokenOut] * (10 ** dec[tokenIn]));
        require(amountOut >= minAmountOut, "ROUTER_MIN_OUT");
        MockERC20Dec(tokenOut).mint(recipient, amountOut);
    }
}

/// @dev ADDED (bankr 2026-11-18 20:30Z): stand-in for the chain's Uniswap router, placed behind the real
///      YuzuSwapRouterAdapter. Same price table as MockSwapRouter. CHANGE (bankr 2026-11-19): it now takes the
///      Universal Router's execute(bytes,bytes[]) with the V3_SWAP_EXACT_IN command, which is what the adapter
///      calls. It ignores the fee tier, so it does not show that a pool exists for a pair at any tier.
contract MockV3PricedRouter is IUniversalRouterMinimal {
    address public constant POOL_SINK = address(0x9001); // where the stand-in "pays the pool"
    mapping(address => uint256) public price18;
    mapping(address => uint8) public dec;

    function setAsset(address token, uint256 p18, uint8 decimals_) external {
        price18[token] = p18;
        dec[token] = decimals_;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable override {
        require(commands.length == 1 && commands[0] == bytes1(0x00) && inputs.length == 1, "UR_COMMAND");
        (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser,) =
            abi.decode(inputs[0], (address, uint256, uint256, bytes, bool, uint256[]));
        require(!payerIsUser && path.length == 43, "UR_INPUT");
        address tokenIn;
        address tokenOut;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            tokenOut := shr(96, mload(add(path, 55)))
        }
        // The input must already be in the router (the adapter sends it first); it is paid on to the pool.
        IERC20(tokenIn).transfer(POOL_SINK, amountIn);
        uint256 amountOut = (amountIn * price18[tokenIn] * (10 ** dec[tokenOut]))
            / (price18[tokenOut] * (10 ** dec[tokenIn]));
        require(amountOut >= amountOutMin, "V3_MIN_OUT");
        MockERC20Dec(tokenOut).mint(recipient, amountOut);
    }
}

/// @notice Deploys all 17 real protocol contracts together through script/DeployYuzu98V50.s.sol, registers the
///         YuzuAccount vaults, opens the pool on #0000 commissioning, and commissions a public unit.
/// @dev Rewritten by bankr 2026-11-18 for the third version of the deploy script (new DeployParams fields,
///      hook mask 0x2880, run() reading the environment). Updated 2026-11-18 12:46Z for the founder's decisions:
///      full standalone vaults (clone path removed), 8 routes, wSPYx as a wrapper, 24h / 1h freshness windows,
///      PYTH_UPDATE_HEX and the Seeder's deployer check on #0000. Argon's original single test
///      is test_All17Contracts_DeployUnderEip170Limit_AndOpenPoolWithUnitZero; the other three are new.
///      Local only: MockV4PoolManager, not real Uniswap v4, not Ink.
contract YuzuFull17IntegrationTest is Test {
    uint256 internal constant EIP170_LIMIT = 24_576;

    DeployYuzu98V50 deployerScript;

    MockV4PoolManager poolManager;
    MockPyth pyth;
    MockWETH weth;
    MockERC20Dec kbtc;
    MockERC20Dec usdg;
    MockERC20Dec spyx;
    MockXStockWrapper wspyx;
    MockSwapRouter router;
    MockV3PricedRouter v3Router; // ADDED (bankr 2026-11-18 20:30Z)

    MockChainlinkFeed ethFeed;
    MockChainlinkFeed btcFeed;
    MockChainlinkFeed usdgFeed;
    MockChainlinkFeed spyFeed;

    bytes32 constant PYTH_ETH  = bytes32(uint256(1));
    bytes32 constant PYTH_BTC  = bytes32(uint256(2));
    bytes32 constant PYTH_USDG = bytes32(uint256(3));
    bytes32 constant PYTH_SPY  = bytes32(uint256(4));

    uint256 guardianPk = 0xBEEF;
    address guardian;
    address multisig = address(0xA11CE);
    address teamRecipient = address(0xB0B);
    address founder = address(0xF00D);
    address alice = address(0x1111);
    address recovery = address(0x9999);

    function setUp() public {
        vm.warp(1_760_000_000);
        guardian = vm.addr(guardianPk);

        // 1. Deploy External Chain Infrastructure Mocks
        poolManager = new MockV4PoolManager();
        pyth = new MockPyth();
        weth = new MockWETH();
        kbtc = new MockERC20Dec("Kraken BTC", "kBTC", 8);
        usdg = new MockERC20Dec("Global Dollar", "USDG", 6);
        // CHANGE (2026-11-18): wSPYx is registered as an ERC-4626 wrapper, so the mock has to be one. This uses
        // the existing MockXStockWrapper (adjustable multiplier) and leaves the plain token mock unchanged.
        spyx = new MockERC20Dec("SPYx", "SPYx", 18);
        wspyx = new MockXStockWrapper("Wrapped SPYx", "wSPYx", 18, address(spyx));

        ethFeed  = new MockChainlinkFeed(8, 2000e8);
        btcFeed  = new MockChainlinkFeed(8, 100000e8);
        usdgFeed = new MockChainlinkFeed(8, 1e8);
        spyFeed  = new MockChainlinkFeed(8, 500e8);

        pyth.setPrice(PYTH_ETH,  2000e8,   -8, block.timestamp);
        pyth.setPrice(PYTH_BTC,  100000e8, -8, block.timestamp);
        pyth.setPrice(PYTH_USDG, 1e8,      -8, block.timestamp);
        pyth.setPrice(PYTH_SPY,  500e8,    -8, block.timestamp);

        // FIX (bankr 2026-11-18): router for the seed swaps, priced like the feeds.
        router = new MockSwapRouter();
        router.setAsset(address(weth),  2000e18,   18);
        router.setAsset(address(kbtc),  100000e18, 8);
        router.setAsset(address(usdg),  1e18,      6);
        router.setAsset(address(wspyx), 500e18,    18);

        // ADDED (bankr 2026-11-18 20:30Z): V3 router stand-in for the tests that let the script deploy the real
        // YuzuSwapRouterAdapter. It prices the crypto legs only; wSPYx goes through the v4 pool.
        v3Router = new MockV3PricedRouter();
        v3Router.setAsset(address(weth),  2000e18,   18);
        v3Router.setAsset(address(kbtc),  100000e18, 8);
        v3Router.setAsset(address(usdg),  1e18,      6);

        deployerScript = new DeployYuzu98V50();
        vm.deal(address(deployerScript), 1 ether);
    }

    /// @dev Parameters for a direct call. Assets and routes come from the script's own
    ///      buildDefaultRegistryInputs, so that function is exercised too.
    function _params(uint256 vaultCount)
        internal
        view
        returns (DeployYuzu98V50.DeployParams memory p)
    {
        p.create2Deployer = address(0); // direct call: the script itself runs CREATE2
        p.txSender = address(0);        // direct call: the script itself holds the supply and pays for #0000
        p.multisig = multisig;
        p.teamRecipient = teamRecipient;
        p.founderRecipient = founder;
        p.initialGuardian = guardian;
        p.recoveryAddress = recovery;
        p.poolManager = address(poolManager);
        p.pyth = address(pyth);
        p.weth = address(weth);
        p.kbtc = address(kbtc);
        p.usdg = address(usdg);
        p.wspyx = address(wspyx);
        p.hookPermissionMask = deployerScript.DEFAULT_HOOK_PERMISSION_MASK(); // 0x2880, mined for real
        p.initialVaultBatchCount = vaultCount;
        (p.initialAssets, p.initialRoutes) = deployerScript.buildDefaultRegistryInputs(
            address(weth),
            address(kbtc),
            address(usdg),
            address(wspyx),
            address(ethFeed),
            address(btcFeed),
            address(usdgFeed),
            address(spyFeed),
            PYTH_ETH,
            PYTH_BTC,
            PYTH_USDG,
            PYTH_SPY,
            address(router)
        );
        p.pythUpdateData = new bytes[](0);
        // CHANGE (2026-11-18 20:30Z): the script now takes the router in DeployParams. These parameters supply an
        // existing one (the mock router), so the script deploys no adapter.
        p.swapRouter = address(router);
    }

    /// @dev ADDED (bankr 2026-11-18 20:30Z): parameters for the path where the script deploys
    ///      YuzuSwapRouterAdapter itself: no router supplied, routes built with router address(0), and the V3
    ///      router stand-in behind the adapter.
    function _paramsAutoAdapter(uint256 vaultCount)
        internal
        view
        returns (DeployYuzu98V50.DeployParams memory p)
    {
        p = _params(vaultCount);
        p.swapRouter = address(0);
        p.v3SwapRouter = address(v3Router);
        (p.initialAssets, p.initialRoutes) = deployerScript.buildDefaultRegistryInputs(
            address(weth),
            address(kbtc),
            address(usdg),
            address(wspyx),
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
    }

    /// @dev ADDED (bankr 2026-11-18 20:30Z): opens a USDG / wSPYx pool in the mock pool manager at the Quotrons
    ///      pool key (fee 0x800000, tickSpacing 60, the Quotrons hook address) holding 50,000,000 USDG and
    ///      100,000 wSPYx, which is $500 per wSPYx, the feed price. A pass-through hook is placed at the Quotrons
    ///      hook address; it is NOT the real hook.
    function _openMockQuotronPool() internal returns (bytes32 id, bool usdgIs0) {
        vm.etch(deployerScript.QUOTRON_STOCK_HOOK(), address(new MockPassThroughHook()).code);
        usdgIs0 = address(usdg) < address(wspyx);
        PoolKey memory qKey = PoolKey({
            currency0: usdgIs0 ? address(usdg) : address(wspyx),
            currency1: usdgIs0 ? address(wspyx) : address(usdg),
            fee: deployerScript.QUOTRON_DYNAMIC_FEE_FLAG(),
            tickSpacing: deployerScript.QUOTRON_TICK_SPACING(),
            hooks: deployerScript.QUOTRON_STOCK_HOOK()
        });
        // CHANGE (bankr 2026-11-18, v4 alignment): the mock now takes real liquidity units and makes the provider
        // pay what it owes, so the pool opens at the price the two amounts imply and a helper contract supplies
        // and settles the liquidity.
        uint256 usdgAmt = 50_000_000e6;
        uint256 wspyxAmt = 100_000e18;
        (uint256 amt0, uint256 amt1) = usdgIs0 ? (usdgAmt, wspyxAmt) : (wspyxAmt, usdgAmt);
        FullRangeLpHelper lp = new FullRangeLpHelper(poolManager);
        poolManager.initialize(qKey, lp.sqrtPriceFor(amt0, amt1));
        id = keccak256(abi.encode(qKey));
        usdg.mint(address(lp), usdgAmt);
        wspyx.mint(address(lp), wspyxAmt);
        lp.addFullRange(qKey, amt0, amt1);
    }

    function _assertSizes(DeployYuzu98V50.DeployedContracts memory d) internal view {
        assertLt(address(d.mainframe).code.length,     EIP170_LIMIT, "Yuzu98v2 > 24,576 B");
        assertLt(d.deployedVaults[0].code.length, EIP170_LIMIT, "YuzuAccount > 24,576 B");
        assertGt(d.deployedVaults[0].code.length, 20_000, "full standalone vault expected");
        assertLt(address(d.seeder).code.length,        EIP170_LIMIT, "YuzuSeeder > 24,576 B");
        assertLt(address(d.socketBay).code.length,     EIP170_LIMIT, "YuzuSocketBay > 24,576 B");
        assertLt(address(d.cartridge).code.length,     EIP170_LIMIT, "YuzuCartridge > 24,576 B");
        assertLt(address(d.rsAdapter).code.length,     EIP170_LIMIT, "YuzuRSAdapter > 24,576 B");
        assertLt(address(d.lens).code.length,          EIP170_LIMIT, "YuzuNavLens > 24,576 B");
        assertLt(address(d.distributor).code.length,   EIP170_LIMIT, "YuzuDistributor > 24,576 B");
        assertLt(address(d.treasury).code.length,      EIP170_LIMIT, "YuzuTreasury > 24,576 B");
        assertLt(address(d.renderer).code.length,      EIP170_LIMIT, "YuzuRenderer > 24,576 B");
        assertLt(address(d.registry).code.length,      EIP170_LIMIT, "YuzuRegistry > 24,576 B");
        assertLt(address(d.yuzuToken).code.length,     EIP170_LIMIT, "YuzuToken > 24,576 B");
        assertLt(address(d.archive).code.length,       EIP170_LIMIT, "YuzuPriceArchive > 24,576 B");
        assertLt(address(d.hook).code.length,          EIP170_LIMIT, "YuzuPoolHook > 24,576 B");
        assertLt(address(d.companion).code.length,     EIP170_LIMIT, "YuzuAccountCompanion > 24,576 B");
    }

    /// @dev #0000 exists, the pool opened at the script's price with 150,000 $YUZU + 0.0225 WETH, the hook
    ///      address carries the 0x2880 permission bits, and vault #0000 holds its seed.
    function _assertUnitZeroAndPool(DeployYuzu98V50.DeployedContracts memory d) internal view {
        assertEq(d.mainframe.getVaultAddress(0), d.deployedVaults[0], "vault #0000 registered");
        YuzuAccount vault0 = YuzuAccount(payable(d.deployedVaults[0]));
        assertEq(address(vault0.companion()), address(d.companion), "vault #0000 companion");

        assertEq(uint160(address(d.hook)) & 0x3FFF, 0x2880, "hook address permission bits");

        uint160 expectedSqrtPrice = deployerScript.computeOpeningSqrtPriceX96(address(d.yuzuToken), address(weth));
        assertEq(d.treasury.openingSqrtPriceX96(), expectedSqrtPrice);
        assertTrue(expectedSqrtPrice != uint160(2 ** 96));

        assertEq(d.mainframe.ownerOf(0), founder, "#0000 owner");
        assertTrue(d.seeder.unitZeroCommissioned(), "#0000 not commissioned");
        assertEq(d.socketBay.ramTier(0), 5, "#0000 RAM tier");
        assertEq(d.socketBay.ramLocked(0), 250_000e18, "#0000 RAM locked");
        assertTrue(d.treasury.poolOpened(), "treasury poolOpened");

        bool yuzuIs0 = address(d.yuzuToken) < address(weth);
        PoolKey memory key = PoolKey({
            currency0: yuzuIs0 ? address(d.yuzuToken) : address(weth),
            currency1: yuzuIs0 ? address(weth) : address(d.yuzuToken),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(d.hook)
        });
        (uint160 poolSqrtPrice,, uint256 reserve0, uint256 reserve1,,, bool initialized) =
            poolManager.pools(keccak256(abi.encode(key)));
        assertTrue(initialized, "pool not opened");
        assertEq(poolSqrtPrice, expectedSqrtPrice, "pool opening price");
        // CHANGE (v4 alignment): real liquidity units round a few wei under the two amounts
        assertApproxEqAbs(yuzuIs0 ? reserve0 : reserve1, 150_000e18, 1e17, "pool $YUZU");
        assertApproxEqAbs(yuzuIs0 ? reserve1 : reserve0, 0.0225 ether, 1e6, "pool WETH");

        assertGt(weth.balanceOf(address(vault0)), 0, "vault WETH seed");
        assertGt(kbtc.balanceOf(address(vault0)), 0, "vault kBTC seed");
        assertGt(usdg.balanceOf(address(vault0)), 0, "vault USDG seed");
    }

    /// @dev A member of the public commissions #0001 for 0.15 ETH into its pre-registered vault.
    function _publicMintUnitOne(DeployYuzu98V50.DeployedContracts memory d) internal {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        d.seeder.commissionMainframe{value: 0.15 ether}(1, SeedMode.US_BASKET, guardian, recovery, new bytes[](0));

        assertEq(d.mainframe.ownerOf(1), alice, "#0001 owner");
        address v1 = d.mainframe.getVaultAddress(1);
        assertEq(v1, d.deployedVaults[1], "#0001 vault");
        assertEq(d.socketBay.ramTier(1), 1, "#0001 RAM tier");
        assertEq(d.socketBay.ramLocked(1), 150_000e18, "#0001 RAM locked");
        assertGt(weth.balanceOf(v1), 0, "#0001 WETH seed");
        assertGt(kbtc.balanceOf(v1), 0, "#0001 kBTC seed");
        assertGt(usdg.balanceOf(v1), 0, "#0001 USDG seed");

        // The vault's own storage was set up by the Seeder
        YuzuAccount va = YuzuAccount(payable(v1));
        assertEq(va.rewardPayoutAsset(), address(weth), "#0001 reward asset");
        assertEq(va.slot4Adapter(), address(d.rsAdapter), "#0001 slot 4 adapter");
        assertGt(va.lossBudgetBps(), 0, "#0001 loss budget");
        assertEq(address(va.companion()), address(d.companion), "#0001 companion");
    }

    function _cfg(YuzuRegistry r, address a) internal view returns (bool isWrapper, uint32 maxAge) {
        (,, isWrapper,,, maxAge,,) = r.assetConfigs(a);
    }

    /// @dev ADDED (bankr 2026-11-18 20:05Z): the script builds the wSPYx paths with its own copy of the Quotrons
    ///      constants. This checks three of them are byte-for-byte what YuzuSwapRouterAdapter's own encoders
    ///      produce (the encodings test/YuzuAdapters.t.sol runs swaps through), and decodes the sell-side two-hop,
    ///      for which the adapter has no encoder. The paths are compared here, not executed: this suite's router
    ///      is MockSwapRouter, which ignores the path.
    function _assertWspyxPathsMatchAdapter(YuzuRegistry r) internal {
        YuzuSwapRouterAdapter a = new YuzuSwapRouterAdapter(address(poolManager), address(router));
        assertEq(
            r.routeFor(address(usdg), address(wspyx)).path,
            a.encodeQuotronV4Hop(address(usdg), address(wspyx)),
            "USDG -> wSPYx path bytes"
        );
        assertEq(
            r.routeFor(address(wspyx), address(usdg)).path,
            a.encodeQuotronV4Hop(address(wspyx), address(usdg)),
            "wSPYx -> USDG path bytes"
        );
        assertEq(
            r.routeFor(address(weth), address(wspyx)).path,
            a.encodeTwoHopV3ToQuotronV4(address(weth), address(usdg), 3000, address(wspyx)),
            "WETH -> wSPYx path bytes"
        );
        assertEq(uint256(r.routeFor(address(weth), address(wspyx)).routerType), 2, "wSPYx routerType");
        assertEq(uint256(r.routeFor(address(weth), address(usdg)).routerType), 1, "crypto routerType");

        YuzuSwapRouterAdapter.V4Hop[] memory hops =
            abi.decode(r.routeFor(address(wspyx), address(weth)).path, (YuzuSwapRouterAdapter.V4Hop[]));
        assertEq(hops.length, 2, "sell two-hop length");
        assertEq(hops[0].tokenIn, address(wspyx), "sell hop 0 in");
        assertEq(hops[0].tokenOut, address(usdg), "sell hop 0 out");
        assertEq(uint256(hops[0].fee), uint256(a.DYNAMIC_FEE_FLAG()), "sell hop 0 fee");
        assertEq(int256(hops[0].tickSpacing), int256(a.QUOTRON_TICK_SPACING()), "sell hop 0 tickSpacing");
        assertEq(hops[0].hooks, a.QUOTRON_STOCK_HOOK(), "sell hop 0 hook");
        assertEq(hops[1].tokenIn, address(usdg), "sell hop 1 in");
        assertEq(hops[1].tokenOut, address(weth), "sell hop 1 out");
        assertEq(uint256(hops[1].fee), 3000, "sell hop 1 fee");
        assertEq(int256(hops[1].tickSpacing), int256(0), "sell hop 1 is V3");
        assertEq(hops[1].hooks, address(0), "sell hop 1 is V3");
    }

    /// @notice Argon's original test: direct call, 5 full standalone vaults.
    function test_All17Contracts_DeployUnderEip170Limit_AndOpenPoolWithUnitZero() public {
        DeployYuzu98V50.DeployParams memory p = _params(5);
        DeployYuzu98V50.DeployedContracts memory d = deployerScript.deployAndWireAll17(p);

        _assertSizes(d);
        assertGt(d.deployedVaults[4].code.length, 20_000, "full vault expected");
        _assertUnitZeroAndPool(d);
        _publicMintUnitOne(d);
    }

    /// @notice Founder decisions of 2026-11-18: 8 routes including kBTC -> WETH, wSPYx priced as an ERC-4626
    ///         wrapper, 24h / 1h freshness windows, and #0000 commissionable only by the Seeder's deployer.
    function test_RegistryDefaults_WrapperPricing_AndUnitZeroCallerCheck() public {
        DeployYuzu98V50.DeployParams memory p = _params(2);
        assertEq(p.initialRoutes.length, 8, "route count");
        DeployYuzu98V50.DeployedContracts memory d = deployerScript.deployAndWireAll17(p);

        // kBTC -> WETH is registered and active
        assertTrue(d.registry.routeFor(address(kbtc), address(weth)).isActive, "kBTC -> WETH route");
        assertEq(d.registry.routeFor(address(kbtc), address(weth)).router, address(router), "kBTC -> WETH router");

        // Founder 2026-11-18 17:48Z: wSPYx routes carry a YuzuSwapRouterAdapter path. One V4Hop is 160 bytes,
        // a two-hop V4Hop[] is 384 bytes, and the crypto routes keep an empty path (V3 at fee 3000).
        assertEq(d.registry.routeFor(address(usdg), address(wspyx)).path.length, 160, "USDG -> wSPYx path");
        assertEq(d.registry.routeFor(address(wspyx), address(usdg)).path.length, 160, "wSPYx -> USDG path");
        assertEq(d.registry.routeFor(address(weth), address(wspyx)).path.length, 384, "WETH -> wSPYx path");
        assertEq(d.registry.routeFor(address(wspyx), address(weth)).path.length, 384, "wSPYx -> WETH path");
        assertEq(d.registry.routeFor(address(weth), address(usdg)).path.length, 0, "WETH -> USDG path");
        _assertWspyxPathsMatchAdapter(d.registry);

        // Freshness windows and the wrapper flag
        (bool w, uint32 age) = _cfg(d.registry, address(weth));
        assertFalse(w, "WETH is not a wrapper");
        assertEq(age, 86_400, "WETH maxAge");
        (w, age) = _cfg(d.registry, address(kbtc));
        assertEq(age, 86_400, "kBTC maxAge");
        (w, age) = _cfg(d.registry, address(usdg));
        assertEq(age, 86_400, "USDG maxAge");
        (w, age) = _cfg(d.registry, address(wspyx));
        assertTrue(w, "wSPYx is a wrapper");
        assertEq(age, 3_600, "wSPYx maxAge");

        // wSPYx is priced at the SPY feed times convertToAssets(1 share)
        assertEq(d.lens.requireFresh(address(wspyx)), 500e18, "wSPYx at 1.00x");
        wspyx.setMultiplier(1.05e18);
        assertEq(d.lens.requireFresh(address(wspyx)), 525e18, "wSPYx at 1.05x");

        // #0000 can only be commissioned by the account that deployed the Seeder (here the script contract)
        assertEq(d.seeder.deployer(), address(deployerScript), "seeder deployer");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(YuzuSeeder.OnlyDeployer.selector);
        d.seeder.commissionFounderUnitZero{value: 0.15 ether}(alice, guardian, recovery, new bytes[](0));

        // Two hours later with no feed update: WETH is still inside its 24h window, wSPYx is outside its 1h window
        vm.warp(block.timestamp + 2 hours);
        d.lens.requireFresh(address(weth));
        vm.expectRevert();
        d.lens.requireFresh(address(wspyx));
    }

    /// @notice Measures the execution gas of deploying one full standalone vault (code storage included,
    ///         transaction calldata and the L1 data fee not included).
    function test_GasPerStandaloneVault() public {
        DeployYuzu98V50.DeployedContracts memory d = deployerScript.deployAndWireAll17(_params(1));
        uint256 g = gasleft();
        YuzuAccount v = new YuzuAccount(
            address(d.mainframe),
            address(d.lens),
            address(d.registry),
            address(d.socketBay),
            address(d.distributor),
            address(d.treasury),
            address(d.hook),
            address(pyth),
            address(weth),
            address(d.yuzuToken),
            address(d.seeder),
            address(d.cartridge),
            address(d.rsAdapter),
            address(d.companion)
        );
        uint256 used = g - gasleft();
        emit log_named_uint("GAS_PER_VAULT", used);
        emit log_named_uint("VAULT_RUNTIME_BYTES", address(v).code.length);
        assertLt(used, 10_000_000, "vault deploy gas");
    }

    /// @notice The real deploy path: run() reading the environment, sending from a private key, with the hook
    ///         deployed through the CREATE2 factory. Forge runs the broadcast inside the test; nothing is sent.
    function test_Run_FromEnvironment_WithBroadcastKey() public {
        uint256 pk = 0xA11CE5EED;
        address eoa = vm.addr(pk);
        vm.deal(eoa, 1 ether);
        if (CREATE2_FACTORY.code.length == 0) {
            vm.etch(
                CREATE2_FACTORY,
                hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
            );
        }

        vm.setEnv("PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("MULTISIG_ADMIN", vm.toString(multisig));
        vm.setEnv("TEAM_RECIPIENT", vm.toString(teamRecipient));
        vm.setEnv("FOUNDER_RECIPIENT", vm.toString(founder));
        vm.setEnv("INITIAL_GUARDIAN", vm.toString(guardian));
        vm.setEnv("RECOVERY_ADDRESS", vm.toString(recovery));
        vm.setEnv("POOL_MANAGER", vm.toString(address(poolManager)));
        vm.setEnv("PYTH_CONTRACT", vm.toString(address(pyth)));
        vm.setEnv("WETH_TOKEN", vm.toString(address(weth)));
        vm.setEnv("KBTC_TOKEN", vm.toString(address(kbtc)));
        vm.setEnv("USDG_TOKEN", vm.toString(address(usdg)));
        vm.setEnv("WSPYX_TOKEN", vm.toString(address(wspyx)));
        vm.setEnv("ETH_CL_FEED", vm.toString(address(ethFeed)));
        vm.setEnv("BTC_CL_FEED", vm.toString(address(btcFeed)));
        vm.setEnv("USDG_CL_FEED", vm.toString(address(usdgFeed)));
        vm.setEnv("SPY_CL_FEED", vm.toString(address(spyFeed)));
        vm.setEnv("ETH_PYTH_ID", vm.toString(PYTH_ETH));
        vm.setEnv("BTC_PYTH_ID", vm.toString(PYTH_BTC));
        vm.setEnv("USDG_PYTH_ID", vm.toString(PYTH_USDG));
        vm.setEnv("SPY_PYTH_ID", vm.toString(PYTH_SPY));
        // CHANGE (2026-11-18 20:30Z): SWAP_ROUTER is left unset and V3_SWAP_ROUTER is given, so this run deploys
        // the real YuzuSwapRouterAdapter from the broadcasting key and seeds #0000 and #0001 through it.
        vm.setEnv("V3_SWAP_ROUTER", vm.toString(address(v3Router)));
        // CHANGE (2026-11-18): optional Pyth update blob. MockPyth charges 1 wei per blob and ignores its content,
        // so this checks the fee is added to #0000's payment, not that real Pyth data is accepted.
        vm.setEnv("PYTH_UPDATE_HEX", "0x1234");
        // Vault count for this simulated run. 40 by default to keep the test light; set YUZU_TEST_RUN_BATCH=1000
        // in the shell to run the full fleet of standalone vaults.
        uint256 runBatch = vm.envOr("YUZU_TEST_RUN_BATCH", uint256(40));
        vm.setEnv("INITIAL_VAULT_BATCH", vm.toString(runBatch));

        DeployYuzu98V50.DeployedContracts memory d = deployerScript.run();

        _assertSizes(d);
        assertEq(d.deployedVaults.length, runBatch, "vault count");
        assertEq(d.mainframe.getVaultAddress(runBatch - 1), d.deployedVaults[runBatch - 1], "last vault registered");
        assertTrue(d.mainframe.isYuzuVault(d.deployedVaults[runBatch - 1]), "last vault flagged");
        assertGt(d.deployedVaults[runBatch - 1].code.length, 20_000, "last vault is a full standalone vault");
        assertEq(d.seeder.deployer(), eoa, "seeder deployed by the broadcasting key");
        // ADDED (2026-11-18 20:30Z): run() deployed the adapter and registered it as the router
        assertGt(address(d.swapRouterAdapter).code.length, 0, "adapter deployed by run()");
        assertEq(d.swapRouterAdapter.v3Router(), address(v3Router), "adapter v3Router from V3_SWAP_ROUTER");
        assertEq(
            d.registry.routeFor(address(weth), address(kbtc)).router,
            address(d.swapRouterAdapter),
            "WETH -> kBTC router is the adapter"
        );
        assertEq(
            d.registry.routeFor(address(weth), address(wspyx)).router,
            address(d.swapRouterAdapter),
            "WETH -> wSPYx router is the adapter"
        );
        _assertUnitZeroAndPool(d);

        // The key's account ends with no $YUZU and paid exactly 0.15 ETH; the Seeder holds the rest of its share
        assertEq(d.yuzuToken.balanceOf(eoa), 0, "deployer keeps no $YUZU");
        assertEq(d.yuzuToken.balanceOf(address(deployerScript)), 0, "script keeps no $YUZU");
        assertEq(d.yuzuToken.balanceOf(address(d.seeder)), 150_100_000e18 - 250_000e18, "seeder $YUZU");
        assertEq(eoa.balance, 1 ether - 0.15 ether - 1, "deployer paid 0.15 ETH + 1 wei Pyth fee");

        _publicMintUnitOne(d);
    }

    /// @notice ADDED (bankr 2026-11-18 20:30Z, founder request): with no swap router supplied, the script deploys
    ///         the real YuzuSwapRouterAdapter over the PoolManager and the V3 router, registers it on all 8 routes,
    ///         and units are seeded through it: #0000 and #0001 (US_BASKET: kBTC and USDG legs, V3 single hop)
    ///         and #0002 (NON_US_XSTOCK: the registered WETH -> USDG -> wSPYx two-hop, V3 then the v4 pool at the
    ///         Quotrons pool key). Mock pool manager, mock V3 router and a pass-through hook: not real v4, not Ink.
    function test_AutoDeploysSwapRouterAdapter_AndSeedsUnitsThroughIt() public {
        (bytes32 qPoolId, bool usdgIs0) = _openMockQuotronPool();

        DeployYuzu98V50.DeployParams memory p = _paramsAutoAdapter(3);
        assertEq(p.initialRoutes[0].route.router, address(0), "routes built without a router");
        DeployYuzu98V50.DeployedContracts memory d = deployerScript.deployAndWireAll17(p);

        // The adapter exists, is wired to this PoolManager and V3 router, and is the router on every route
        address adapter = address(d.swapRouterAdapter);
        assertGt(adapter.code.length, 0, "adapter deployed");
        assertEq(address(d.swapRouterAdapter.poolManager()), address(poolManager), "adapter poolManager");
        assertEq(d.swapRouterAdapter.v3Router(), address(v3Router), "adapter v3Router");
        assertEq(d.registry.routeFor(address(weth), address(kbtc)).router, adapter, "WETH -> kBTC router");
        assertEq(d.registry.routeFor(address(weth), address(usdg)).router, adapter, "WETH -> USDG router");
        assertEq(d.registry.routeFor(address(weth), address(wspyx)).router, adapter, "WETH -> wSPYx router");
        assertEq(d.registry.routeFor(address(usdg), address(wspyx)).router, adapter, "USDG -> wSPYx router");
        assertEq(d.registry.routeFor(address(wspyx), address(usdg)).router, adapter, "wSPYx -> USDG router");
        assertEq(d.registry.routeFor(address(wspyx), address(weth)).router, adapter, "wSPYx -> WETH router");
        assertEq(d.registry.routeFor(address(usdg), address(weth)).router, adapter, "USDG -> WETH router");
        assertEq(d.registry.routeFor(address(kbtc), address(weth)).router, adapter, "kBTC -> WETH router");
        _assertWspyxPathsMatchAdapter(d.registry);

        // #0000 was seeded through the adapter during the deployment; #0001 is a public US_BASKET mint
        _assertUnitZeroAndPool(d);
        _publicMintUnitOne(d);
        assertEq(kbtc.balanceOf(d.deployedVaults[1]), 60_000, "#0001 kBTC: 0.03 WETH at $2,000 / $100,000");
        assertEq(usdg.balanceOf(d.deployedVaults[1]), 30e6, "#0001 USDG: 0.015 WETH at $2,000");

        // #0002 is a public NON_US_XSTOCK mint: 0.075 WETH -> 150 USDG on V3 -> wSPYx in the v4 pool
        (,, uint256 r0, uint256 r1,,,) = poolManager.pools(qPoolId);
        (uint256 rU, uint256 rW) = usdgIs0 ? (r0, r1) : (r1, r0);
        uint256 netIn = (uint256(150e6) * 9900) / 10000; // the mock pool's 1.00% fee
        uint256 expectedWspyx = (rW * netIn) / (rU + netIn);

        vm.prank(alice);
        d.seeder.commissionMainframe{value: 0.15 ether}(1, SeedMode.NON_US_XSTOCK, guardian, recovery, new bytes[](0));
        assertEq(d.mainframe.ownerOf(2), alice, "#0002 owner");
        assertEq(wspyx.balanceOf(d.deployedVaults[2]), expectedWspyx, "#0002 wSPYx seed through the two-hop path");
        assertGt(expectedWspyx, 0.2955e18, "above the Seeder's 1.50% floor on 0.3 wSPYx");

        // The adapter keeps nothing and leaves no approval on the V3 router
        assertEq(weth.balanceOf(adapter), 0, "adapter WETH");
        assertEq(kbtc.balanceOf(adapter), 0, "adapter kBTC");
        assertEq(usdg.balanceOf(adapter), 0, "adapter USDG");
        assertEq(wspyx.balanceOf(adapter), 0, "adapter wSPYx");
        assertEq(weth.allowance(adapter, address(v3Router)), 0, "adapter WETH approval");
    }

    /// @notice ADDED (bankr 2026-11-18 20:30Z): with neither a swap router nor a V3 router the deployment reverts
    ///         before the registry is built.
    function test_RevertsWhenNoSwapRouterAndNoV3Router() public {
        DeployYuzu98V50.DeployParams memory p = _params(1);
        p.swapRouter = address(0);
        vm.expectRevert(DeployYuzu98V50.NoSwapRouterConfigured.selector);
        deployerScript.deployAndWireAll17(p);
    }

    /// @notice #0000 is never skipped: with less than 0.15 ETH the whole deployment reverts.
    function test_RevertsWhenSenderCannotPayForUnitZero() public {
        vm.deal(address(deployerScript), 0.1 ether);
        DeployYuzu98V50.DeployParams memory p = _params(1);
        vm.expectRevert(
            abi.encodeWithSelector(DeployYuzu98V50.InsufficientEthForUnitZero.selector, 0.1 ether, 0.15 ether)
        );
        deployerScript.deployAndWireAll17(p);
    }
}
