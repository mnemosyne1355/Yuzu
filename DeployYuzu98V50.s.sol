// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {PoolKey} from "../src/interfaces/IYuzuV4Interfaces.sol";
import {YuzuToken} from "../src/YuzuToken.sol";
import {YuzuRegistry} from "../src/YuzuRegistry.sol";
import {YuzuNavLens} from "../src/YuzuNavLens.sol";
import {YuzuPriceArchive} from "../src/YuzuPriceArchive.sol";
import {YuzuRelativeStrengthAdapter} from "../src/adapters/YuzuRelativeStrengthAdapter.sol";
import {YuzuRenderer} from "../src/YuzuRenderer.sol";
import {Yuzu98v2} from "../src/Yuzu98v2.sol";
import {YuzuPoolHook} from "../src/YuzuPoolHook.sol";
import {YuzuSocketBay} from "../src/YuzuSocketBay.sol";
import {YuzuDistributor} from "../src/YuzuDistributor.sol";
import {YuzuTreasury} from "../src/YuzuTreasury.sol";
import {YuzuCartridge} from "../src/YuzuCartridge.sol";
import {YuzuAccountCompanion} from "../src/YuzuAccountCompanion.sol";
import {YuzuSeeder} from "../src/YuzuSeeder.sol";
import {YuzuAccount} from "../src/YuzuAccount.sol";
// CHANGE (founder 2026-11-18 17:48Z): imported for its V4Hop struct, so the registry paths are encoded with the
// same type the adapter decodes.
import {YuzuSwapRouterAdapter} from "../src/adapters/YuzuSwapRouterAdapter.sol";

/// @dev CHANGE (founder 2026-11-18): added so step 15 can add the Pyth update fee to #0000's payment.
interface IPythUpdateFee {
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
}

/// @title DeployYuzu98V50 — Complete 17-Contract Deployment, CREATE2 Hook Mining (0x2880), Vault Registration & #0000 Pool Open
/// @dev Third version from argon, pasted by the founder 2026-11-18 02:34Z. Changes made when saving are marked
///      `FIX (bankr 2026-11-18)`. See DEPLOY_SCRIPT_NOTES.md in this folder.
contract DeployYuzu98V50 is Script {
    uint256 public constant SEEDER_SUPPLY_SHARE = 150_100_000e18;   // 15.01% (999 * 150k + 250k #0000 T5 RAM)
    uint256 public constant TREASURY_SUPPLY_SHARE = 849_900_000e18; // 84.99% (250M LP + 349.9M Farm + 50M R&D + 200M Team)
    uint160 public constant HOOK_ALL_FLAGS_MASK = 0x3FFF;           // Low 14 bits for Uniswap v4 hook permissions
    // beforeInitialize (1 << 13 = 0x2000) | beforeAddLiquidity (1 << 11 = 0x0800) | beforeSwap (1 << 7 = 0x0080) = 0x2880
    uint160 public constant DEFAULT_HOOK_PERMISSION_MASK = 0x2880;
    uint256 public constant VAULT_REGISTER_CHUNK = 250;
    // CHANGE (founder 2026-11-18 17:48Z): wSPYx routes go through the Quotrons v4 xStock/USDG pool. The first three
    // values repeat the constants in YuzuSwapRouterAdapter and must stay equal to them. The hook address is the
    // one argon supplied. Read on Ink (57073) through the public RPC on 2026-11-18 20:24Z: there is code at this
    // address, and the USDG / wSPYx pool with this fee flag, tick spacing and hook is initialized with liquidity
    // in the PoolManager. What the hook does on a swap was not read.
    uint24 public constant QUOTRON_DYNAMIC_FEE_FLAG = 0x800000;
    int24 public constant QUOTRON_TICK_SPACING = 60;
    address public constant QUOTRON_STOCK_HOOK = 0x8bb4516059F9149Bc3b89018Fc7537f1F14a30cc;
    uint24 public constant V3_WETH_USDG_FEE = 3000;
    // CHANGE (founder 2026-11-18): per-asset freshness windows. 24h for the crypto legs (WETH, kBTC, USDG),
    // 1h for wSPYx. The lens applies the window to both the Chainlink and the Pyth timestamp.
    uint32 public constant CRYPTO_MAX_AGE_SECONDS = 86_400;
    uint32 public constant XSTOCK_MAX_AGE_SECONDS = 3_600;
    uint256 public constant UNIT_ZERO_PRICE = 0.15 ether;

    error ZeroCriticalAddress();
    error HookSaltNotFound();
    error HookCreate2AddressMismatch(address actual, address predicted);
    error InsufficientEthForUnitZero(uint256 available, uint256 required);
    error PoolNotOpenedAfterUnitZero();
    error NoSwapRouterConfigured();

    struct DeployParams {
        address create2Deployer;        // CREATE2_FACTORY (0x4e59...956C) on broadcast; address(this) on direct test call
        address multisig;
        address teamRecipient;
        address founderRecipient;
        address initialGuardian;
        address recoveryAddress;
        address poolManager;
        address pyth;
        address weth;
        address kbtc;
        address usdg;
        address wspyx;
        uint160 hookPermissionMask;     // Defaults to 0x2880 (beforeInitialize | beforeAddLiquidity | beforeSwap)
        uint256 initialVaultBatchCount; // Defaults to 1000 (full fleet) on run()
        // CHANGE (founder 2026-11-18): the EIP-1167 clone flag is removed. Every vault is a full standalone
        // YuzuAccount, so there is no delegatecall anywhere in the stack.
        YuzuRegistry.InitialAssetInput[] initialAssets;
        YuzuRegistry.InitialRouteInput[] initialRoutes;
        bytes[] pythUpdateData;
        // FIX (bankr 2026-11-18): added. The account that sends the transactions: the broadcasting key's address
        // on run(), or address(0) for this contract when a test calls deployAndWireAll17 directly. It receives
        // the 1B $YUZU mint (it is the account that then transfers it) and pays the 0.15 ETH for #0000.
        address txSender;
        // CHANGE (founder 2026-11-18 20:18Z): swap router selection. swapRouter is an already deployed
        // YuzuSwapRouterAdapter to register on the routes. If it is address(0), deployAndWireAll17 first deploys
        // a new YuzuSwapRouterAdapter(poolManager, v3SwapRouter) and registers that one; v3SwapRouter (the
        // chain's Uniswap Universal Router, called with execute(bytes,bytes[]); changed 2026-11-19, it was SwapRouter02) is then required. v3SwapRouter is ignored when
        // swapRouter is supplied.
        address swapRouter;
        address v3SwapRouter;
    }

    struct V4PoolSpec {
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct DeployedContracts {
        YuzuToken yuzuToken;
        YuzuRegistry registry;
        YuzuNavLens lens;
        YuzuPriceArchive archive;
        YuzuRelativeStrengthAdapter rsAdapter;
        Yuzu98v2 mainframe;
        YuzuSocketBay socketBay;
        YuzuRenderer renderer;
        YuzuTreasury treasury;
        YuzuPoolHook hook;
        YuzuDistributor distributor;
        YuzuCartridge cartridge;
        YuzuAccountCompanion companion;
        YuzuSeeder seeder;
        address[] deployedVaults;
        // CHANGE (founder 2026-11-18 20:18Z): the adapter this run deployed, or address(0) when
        // DeployParams.swapRouter was supplied.
        YuzuSwapRouterAdapter swapRouterAdapter;
    }

    /// @notice Computes the exact opening sqrtPriceX96 for 1 WETH = 6,666,666.67 $YUZU (0.0225 WETH : 150,000 $YUZU)
    ///         based on whether $YUZU sorts below WETH (currency0) or above WETH (currency1).
    ///         sqrt(150,000 / 0.0225) = sqrt(6,666,666.666666...) = 2581.98889747... = 38,729,833 / 15,000.
    function computeOpeningSqrtPriceX96(address yuzuTokenAddr, address wethAddr) public pure returns (uint160) {
        if (yuzuTokenAddr < wethAddr) {
            // currency0 = $YUZU, currency1 = WETH -> price = WETH / $YUZU = 0.0225 / 150,000
            return uint160((uint256(15_000) << 96) / 38_729_833);
        } else {
            // currency0 = WETH, currency1 = $YUZU -> price = $YUZU / WETH = 150,000 / 0.0225
            return uint160((uint256(38_729_833) << 96) / 15_000);
        }
    }

    /// @notice Mines a CREATE2 salt so `new YuzuPoolHook{salt: salt}(...)` deploys at an address whose low 14 bits
    ///         equal `desiredFlagMask`.
    function mineHookSalt(
        address create2Deployer,
        uint160 desiredFlagMask,
        bytes memory creationCodeWithArgs
    ) public pure returns (bytes32 salt, address predictedHook) {
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            predictedHook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, initCodeHash))))
            );
            if ((uint160(predictedHook) & HOOK_ALL_FLAGS_MASK) == desiredFlagMask) {
                return (salt, predictedHook);
            }
        }
        revert HookSaltNotFound();
    }

    /// @notice Builds the standard 4 initial priced assets (WETH, kBTC, USDG, wSPYx) and 8 routes.
    /// @dev FIX (bankr 2026-11-18): the paste filled flat struct fields that do not exist (decimals, isCrypto,
    ///      isErc4626XStock, maxAgeSeconds, maxDivergenceBps on the asset; router, routerType, path on the route),
    ///      so it did not compile. The registry takes InitialAssetInput{asset, config} and
    ///      InitialRouteInput{tokenIn, tokenOut, route}. Values are mapped one to one: isCrypto -> isCryptoLeg,
    ///      isErc4626XStock -> isWrapper, maxAgeSeconds -> maxAge. maxDivergenceBps is dropped: the registry has
    ///      no such field and the lens uses a fixed 150 bps.
    function buildDefaultRegistryInputs(
        address weth,
        address kbtc,
        address usdg,
        address wspyx,
        address ethClFeed,
        address btcClFeed,
        address usdgClFeed,
        address spyClFeed,
        bytes32 ethPythId,
        bytes32 btcPythId,
        bytes32 usdgPythId,
        bytes32 spyPythId,
        address swapRouter
    )
        public
        pure
        returns (
            YuzuRegistry.InitialAssetInput[] memory assets,
            YuzuRegistry.InitialRouteInput[] memory routes
        )
    {
        assets = new YuzuRegistry.InitialAssetInput[](4);
        assets[0] = _assetInput(weth,  true,  false, 18, CRYPTO_MAX_AGE_SECONDS, ethClFeed,  ethPythId);
        assets[1] = _assetInput(kbtc,  true,  false, 8,  CRYPTO_MAX_AGE_SECONDS, btcClFeed,  btcPythId);
        assets[2] = _assetInput(usdg,  true,  false, 6,  CRYPTO_MAX_AGE_SECONDS, usdgClFeed, usdgPythId);
        // CHANGE (founder 2026-11-18): wSPYx is flagged as an ERC-4626 wrapper, so the lens multiplies the SPY
        // feed by wSPYx.convertToAssets(1 share). The token at WSPYX_TOKEN must implement convertToAssets.
        assets[3] = _assetInput(wspyx, false, true,  18, XSTOCK_MAX_AGE_SECONDS, spyClFeed,  spyPythId);

        routes = new YuzuRegistry.InitialRouteInput[](8);
        routes[0] = _routeInput(weth,  kbtc,  swapRouter);
        routes[1] = _routeInput(weth,  usdg,  swapRouter);
        // CHANGE (founder 2026-11-18 17:48Z): the four wSPYx routes carry a path for YuzuSwapRouterAdapter instead
        // of an empty one (an empty path is a V3 swap at fee 3000, and wSPYx trades in the Quotrons v4 pool).
        //   USDG <-> wSPYx: one 160-byte V4Hop on the Quotrons v4 pool.
        //   WETH <-> wSPYx: a two-hop V4Hop[] (WETH <-> USDG on V3 at fee 3000, USDG <-> wSPYx on Quotrons v4).
        // The router on these routes must therefore be a YuzuSwapRouterAdapter. Call this with swapRouter =
        // address(0) to have deployAndWireAll17 point the routes at the adapter it deploys (DeployParams.swapRouter).
        routes[2] = _routeInputWithPath(weth,  wspyx, swapRouter, _twoHopPath(weth, usdg, wspyx, true));
        routes[3] = _routeInputWithPath(usdg,  wspyx, swapRouter, _quotronHopPath(usdg, wspyx));
        routes[4] = _routeInputWithPath(wspyx, usdg,  swapRouter, _quotronHopPath(wspyx, usdg));
        routes[5] = _routeInputWithPath(wspyx, weth,  swapRouter, _twoHopPath(wspyx, usdg, weth, false));
        routes[6] = _routeInput(usdg,  weth,  swapRouter);
        // CHANGE (founder 2026-11-18): 8th route. Salvage routing and fee/salvage conversion look up
        // asset -> WETH, and kBTC is in every US_BASKET seed.
        routes[7] = _routeInput(kbtc,  weth,  swapRouter);
    }

    /// @notice Builds the 4 initial priced assets and 8 all-v4 routes for Ink Mainnet (57073):
    ///         - WETH <-> kBTC : 1-hop Ink v4 pool (0x5697efeb...)
    ///         - WETH <-> USDG : 2-hop Ink v4 route WETH <-> USDC (0xa440c7fd...) <-> USDG (0xf58608d5...)
    ///         - USDG <-> wSPYx: 1-hop Quotrons v4 pool (0x84b421dc...)
    ///         - WETH <-> wSPYx: 3-hop pure Ink v4 route WETH <-> USDC <-> USDG <-> wSPYx
    function buildV4RegistryInputs(
        address weth,
        address kbtc,
        address usdc,
        address usdg,
        address wspyx,
        address ethClFeed,
        address btcClFeed,
        address usdgClFeed,
        address spyClFeed,
        bytes32 ethPythId,
        bytes32 btcPythId,
        bytes32 usdgPythId,
        bytes32 spyPythId,
        address swapRouter,
        V4PoolSpec memory wethKbtcPool,
        V4PoolSpec memory wethUsdcPool,
        V4PoolSpec memory usdcUsdgPool
    )
        public
        pure
        returns (
            YuzuRegistry.InitialAssetInput[] memory assets,
            YuzuRegistry.InitialRouteInput[] memory routes
        )
    {
        assets = new YuzuRegistry.InitialAssetInput[](4);
        assets[0] = _assetInput(weth,  true,  false, 18, CRYPTO_MAX_AGE_SECONDS, ethClFeed,  ethPythId);
        assets[1] = _assetInput(kbtc,  true,  false, 8,  CRYPTO_MAX_AGE_SECONDS, btcClFeed,  btcPythId);
        assets[2] = _assetInput(usdg,  true,  false, 6,  CRYPTO_MAX_AGE_SECONDS, usdgClFeed, usdgPythId);
        assets[3] = _assetInput(wspyx, false, true,  18, XSTOCK_MAX_AGE_SECONDS, spyClFeed,  spyPythId);

        routes = new YuzuRegistry.InitialRouteInput[](8);
        // 0 & 7: WETH <-> kBTC (1-hop v4)
        routes[0] = _routeInputWithPath(weth, kbtc, swapRouter, _v4SinglePath(weth, kbtc, wethKbtcPool));
        routes[7] = _routeInputWithPath(kbtc, weth, swapRouter, _v4SinglePath(kbtc, weth, wethKbtcPool));

        // 1 & 6: WETH <-> USDG (2-hop v4 via USDC)
        routes[1] = _routeInputWithPath(
            weth, usdg, swapRouter, _v4TwoHopPath(weth, usdc, usdg, wethUsdcPool, usdcUsdgPool)
        );
        routes[6] = _routeInputWithPath(
            usdg, weth, swapRouter, _v4TwoHopPath(usdg, usdc, weth, usdcUsdgPool, wethUsdcPool)
        );

        // 3 & 4: USDG <-> wSPYx (1-hop Quotrons v4)
        routes[3] = _routeInputWithPath(usdg,  wspyx, swapRouter, _quotronHopPath(usdg, wspyx));
        routes[4] = _routeInputWithPath(wspyx, usdg,  swapRouter, _quotronHopPath(wspyx, usdg));

        // 2 & 5: WETH <-> wSPYx (3-hop pure v4: WETH <-> USDC <-> USDG <-> wSPYx)
        routes[2] = _routeInputWithPath(
            weth, wspyx, swapRouter, _v4ThreeHopBuyXStock(weth, usdc, usdg, wspyx, wethUsdcPool, usdcUsdgPool)
        );
        routes[5] = _routeInputWithPath(
            wspyx, weth, swapRouter, _v4ThreeHopSellXStock(wspyx, usdg, usdc, weth, usdcUsdgPool, wethUsdcPool)
        );
    }

    function _v4SinglePath(address tokenIn, address tokenOut, V4PoolSpec memory p)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            YuzuSwapRouterAdapter.V4Hop({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: p.fee,
                tickSpacing: p.tickSpacing,
                hooks: p.hooks
            })
        );
    }

    function _v4TwoHopPath(
        address a,
        address b,
        address c,
        V4PoolSpec memory ab,
        V4PoolSpec memory bc
    ) internal pure returns (bytes memory) {
        YuzuSwapRouterAdapter.V4Hop[] memory hops = new YuzuSwapRouterAdapter.V4Hop[](2);
        hops[0] = YuzuSwapRouterAdapter.V4Hop(a, b, ab.fee, ab.tickSpacing, ab.hooks);
        hops[1] = YuzuSwapRouterAdapter.V4Hop(b, c, bc.fee, bc.tickSpacing, bc.hooks);
        return abi.encode(hops);
    }

    function _v4ThreeHopBuyXStock(
        address weth,
        address usdc,
        address usdg,
        address xStock,
        V4PoolSpec memory wethUsdc,
        V4PoolSpec memory usdcUsdg
    ) internal pure returns (bytes memory) {
        YuzuSwapRouterAdapter.V4Hop[] memory hops = new YuzuSwapRouterAdapter.V4Hop[](3);
        hops[0] = YuzuSwapRouterAdapter.V4Hop(weth, usdc, wethUsdc.fee, wethUsdc.tickSpacing, wethUsdc.hooks);
        hops[1] = YuzuSwapRouterAdapter.V4Hop(usdc, usdg, usdcUsdg.fee, usdcUsdg.tickSpacing, usdcUsdg.hooks);
        hops[2] = _quotronHop(usdg, xStock);
        return abi.encode(hops);
    }

    function _v4ThreeHopSellXStock(
        address xStock,
        address usdg,
        address usdc,
        address weth,
        V4PoolSpec memory usdcUsdg,
        V4PoolSpec memory wethUsdc
    ) internal pure returns (bytes memory) {
        YuzuSwapRouterAdapter.V4Hop[] memory hops = new YuzuSwapRouterAdapter.V4Hop[](3);
        hops[0] = _quotronHop(xStock, usdg);
        hops[1] = YuzuSwapRouterAdapter.V4Hop(usdg, usdc, usdcUsdg.fee, usdcUsdg.tickSpacing, usdcUsdg.hooks);
        hops[2] = YuzuSwapRouterAdapter.V4Hop(usdc, weth, wethUsdc.fee, wethUsdc.tickSpacing, wethUsdc.hooks);
        return abi.encode(hops);
    }

    function _assetInput(
        address asset,
        bool isCryptoLeg,
        bool isWrapper,
        uint8 decimals_,
        uint32 maxAge_,
        address chainlinkFeed,
        bytes32 pythFeedId
    ) internal pure returns (YuzuRegistry.InitialAssetInput memory a) {
        a.asset = asset;
        a.config = YuzuRegistry.AssetConfig({
            isRegistered: true,
            isPaused: false,
            isWrapper: isWrapper,
            isCryptoLeg: isCryptoLeg,
            tokenDecimals: decimals_,
            maxAge: maxAge_,
            chainlinkFeed: chainlinkFeed,
            pythFeedId: pythFeedId
        });
    }

    function _routeInput(address tokenIn, address tokenOut, address swapRouter)
        internal
        pure
        returns (YuzuRegistry.InitialRouteInput memory r)
    {
        r.tokenIn = tokenIn;
        r.tokenOut = tokenOut;
        r.route = YuzuRegistry.Route({router: swapRouter, routerType: 1, path: "", isActive: true});
    }

    /// @dev CHANGE (founder 2026-11-18 17:48Z): a route with an encoded hop path. routerType 2 is the registry's
    ///      label for V4/Quotrons; no contract in src reads routerType, the adapter decides by path length.
    function _routeInputWithPath(address tokenIn, address tokenOut, address swapRouter, bytes memory path)
        internal
        pure
        returns (YuzuRegistry.InitialRouteInput memory r)
    {
        r.tokenIn = tokenIn;
        r.tokenOut = tokenOut;
        r.route = YuzuRegistry.Route({router: swapRouter, routerType: 2, path: path, isActive: true});
    }

    function _quotronHop(address tokenIn, address tokenOut)
        internal
        pure
        returns (YuzuSwapRouterAdapter.V4Hop memory)
    {
        return YuzuSwapRouterAdapter.V4Hop({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: QUOTRON_DYNAMIC_FEE_FLAG,
            tickSpacing: QUOTRON_TICK_SPACING,
            hooks: QUOTRON_STOCK_HOOK
        });
    }

    /// @dev A hop with tickSpacing 0 and hooks 0 is what the adapter sends to the V3 router.
    function _v3Hop(address tokenIn, address tokenOut)
        internal
        pure
        returns (YuzuSwapRouterAdapter.V4Hop memory)
    {
        return YuzuSwapRouterAdapter.V4Hop({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: V3_WETH_USDG_FEE,
            tickSpacing: 0,
            hooks: address(0)
        });
    }

    /// @dev One V4Hop, 160 bytes: the adapter's single-hop v4 branch.
    function _quotronHopPath(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        return abi.encode(_quotronHop(tokenIn, tokenOut));
    }

    /// @dev A V4Hop[] of two hops through `mid` (USDG), 384 bytes. v3First: V3 then Quotrons v4 (buying the
    ///      xStock); otherwise Quotrons v4 then V3 (selling it).
    function _twoHopPath(address tokenIn, address mid, address tokenOut, bool v3First)
        internal
        pure
        returns (bytes memory)
    {
        YuzuSwapRouterAdapter.V4Hop[] memory hops = new YuzuSwapRouterAdapter.V4Hop[](2);
        if (v3First) {
            hops[0] = _v3Hop(tokenIn, mid);
            hops[1] = _quotronHop(mid, tokenOut);
        } else {
            hops[0] = _quotronHop(tokenIn, mid);
            hops[1] = _v3Hop(mid, tokenOut);
        }
        return abi.encode(hops);
    }

    function run() external returns (DeployedContracts memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        DeployParams memory p;
        // On broadcast, Foundry routes salted CREATE2 deployments through CREATE2_FACTORY (0x4e59...956C)
        p.create2Deployer = CREATE2_FACTORY;
        // FIX (bankr 2026-11-18): added, see DeployParams.txSender.
        p.txSender = vm.addr(pk);

        // Strict envAddress checks with zero fallback to deployer
        p.multisig = vm.envAddress("MULTISIG_ADMIN");
        p.teamRecipient = vm.envAddress("TEAM_RECIPIENT");
        p.founderRecipient = vm.envAddress("FOUNDER_RECIPIENT");
        p.initialGuardian = vm.envAddress("INITIAL_GUARDIAN");
        p.recoveryAddress = vm.envAddress("RECOVERY_ADDRESS");
        p.poolManager = vm.envAddress("POOL_MANAGER");
        p.pyth = vm.envAddress("PYTH_CONTRACT");
        p.weth = vm.envAddress("WETH_TOKEN");
        p.kbtc = vm.envAddress("KBTC_TOKEN");
        p.usdg = vm.envAddress("USDG_TOKEN");
        p.wspyx = vm.envAddress("WSPYX_TOKEN");

        if (
            p.multisig == address(0) || p.teamRecipient == address(0) || p.founderRecipient == address(0)
                || p.initialGuardian == address(0) || p.recoveryAddress == address(0)
        ) revert ZeroCriticalAddress();

        p.hookPermissionMask = uint160(vm.envOr("HOOK_PERMISSION_MASK", uint256(DEFAULT_HOOK_PERMISSION_MASK)));
        p.initialVaultBatchCount = vm.envOr("INITIAL_VAULT_BATCH", uint256(1000));

        // CHANGE (founder 2026-11-18 20:18Z): SWAP_ROUTER is now optional. Unset (or zero) means this run deploys
        // its own YuzuSwapRouterAdapter over POOL_MANAGER and V3_SWAP_ROUTER, which is then required. If
        // SWAP_ROUTER is set it is used as is and V3_SWAP_ROUTER is ignored.
        p.swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        p.v3SwapRouter = vm.envOr("V3_SWAP_ROUTER", address(0));
        if (p.swapRouter == address(0) && p.v3SwapRouter == address(0)) revert NoSwapRouterConfigured();

        // Populate initial registry assets & routes from environment. With no SWAP_ROUTER the routes are built
        // with router address(0) and deployAndWireAll17 points them at the adapter it deploys.
        (p.initialAssets, p.initialRoutes) = buildDefaultRegistryInputs(
            p.weth,
            p.kbtc,
            p.usdg,
            p.wspyx,
            vm.envAddress("ETH_CL_FEED"),
            vm.envAddress("BTC_CL_FEED"),
            vm.envAddress("USDG_CL_FEED"),
            vm.envAddress("SPY_CL_FEED"),
            vm.envBytes32("ETH_PYTH_ID"),
            vm.envBytes32("BTC_PYTH_ID"),
            vm.envBytes32("USDG_PYTH_ID"),
            vm.envBytes32("SPY_PYTH_ID"),
            p.swapRouter
        );
        // CHANGE (founder 2026-11-18): optional Pyth update for #0000's commissioning, as one hex blob.
        // Empty means no update is sent and the on-chain Pyth prices must already be inside their windows.
        bytes memory pythUpdateHex = vm.envOr("PYTH_UPDATE_HEX", bytes(""));
        if (pythUpdateHex.length > 0) {
            p.pythUpdateData = new bytes[](1);
            p.pythUpdateData[0] = pythUpdateHex;
        } else {
            p.pythUpdateData = new bytes[](0);
        }

        vm.startBroadcast(pk);
        d = deployAndWireAll17(p);
        vm.stopBroadcast();
    }

    function deployAndWireAll17(DeployParams memory p) public payable returns (DeployedContracts memory d) {
        if (
            p.multisig == address(0) || p.teamRecipient == address(0) || p.founderRecipient == address(0)
        ) revert ZeroCriticalAddress();

        // FIX (bankr 2026-11-18): the paste minted the 1B $YUZU to address(this) and checked address(this).balance.
        // On a broadcast the transfers in step 12 and the 0.15 ETH in step 15 are sent by the broadcasting key,
        // not by this script, so the mint goes to that account and its balance is the one checked.
        address txSender = p.txSender == address(0) ? address(this) : p.txSender;

        // 1. Deploy YuzuToken(txSender) -> mints 1B $YUZU to the sending account for immediate split
        d.yuzuToken = new YuzuToken(txSender);

        // 2. Compute exact opening sqrtPriceX96 for 1 WETH = 6,666,666.67 $YUZU (38,729,833 / 15,000)
        uint160 openingSqrtPriceX96 = computeOpeningSqrtPriceX96(address(d.yuzuToken), p.weth);

        // CHANGE (founder 2026-11-18 20:18Z): resolve the swap router before the registry is built. With no router
        // supplied, deploy YuzuSwapRouterAdapter over this chain's PoolManager and V3 router. Routes built with
        // router address(0) are then pointed at the resolved router; routes that already name a router are left
        // as they are.
        address resolvedRouter = p.swapRouter;
        if (resolvedRouter == address(0)) {
            if (p.v3SwapRouter == address(0)) revert NoSwapRouterConfigured();
            d.swapRouterAdapter = new YuzuSwapRouterAdapter(p.poolManager, p.v3SwapRouter);
            resolvedRouter = address(d.swapRouterAdapter);
        }
        for (uint256 i = 0; i < p.initialRoutes.length; i++) {
            if (p.initialRoutes[i].route.router == address(0)) {
                p.initialRoutes[i].route.router = resolvedRouter;
            }
        }

        // 3. Deploy YuzuRegistry with initial priced assets & verified swap routes
        d.registry = new YuzuRegistry(p.multisig, p.initialAssets, p.initialRoutes);

        // 4. Deploy YuzuNavLens, YuzuPriceArchive & YuzuRelativeStrengthAdapter(registry, lens, archive)
        d.lens = new YuzuNavLens(address(d.registry), p.pyth);
        d.archive = new YuzuPriceArchive(address(d.lens));
        d.rsAdapter = new YuzuRelativeStrengthAdapter(address(d.registry), address(d.lens), address(d.archive));

        // 5. Deploy Yuzu98v2(), YuzuSocketBay(poolManager, yuzuToken, weth) & YuzuRenderer(mainframe, socketBay, lens)
        d.mainframe = new Yuzu98v2();
        d.socketBay = new YuzuSocketBay(p.poolManager, address(d.yuzuToken), p.weth);
        d.renderer = new YuzuRenderer(address(d.mainframe), address(d.socketBay), address(d.lens));

        // 6. Deploy YuzuTreasury(poolManager, yuzuToken, weth, multisig, teamRecipient, openingSqrtPriceX96)
        d.treasury = new YuzuTreasury(
            p.poolManager,
            address(d.yuzuToken),
            p.weth,
            p.multisig,
            p.teamRecipient,
            openingSqrtPriceX96
        );

        // 7. Mine CREATE2 salt & deploy YuzuPoolHook at an address matching p.hookPermissionMask (0x2880)
        address hookDeployer = p.create2Deployer == address(0) ? address(this) : p.create2Deployer;
        bytes memory hookCreationCode = abi.encodePacked(
            type(YuzuPoolHook).creationCode,
            abi.encode(
                p.poolManager,
                address(d.yuzuToken),
                p.weth,
                address(d.treasury),
                address(d.socketBay),
                address(d.mainframe),
                openingSqrtPriceX96
            )
        );
        (bytes32 hookSalt, address predictedHook) =
            mineHookSalt(hookDeployer, p.hookPermissionMask, hookCreationCode);
        d.hook = new YuzuPoolHook{salt: hookSalt}(
            p.poolManager,
            address(d.yuzuToken),
            p.weth,
            address(d.treasury),
            address(d.socketBay),
            address(d.mainframe),
            openingSqrtPriceX96
        );
        if (address(d.hook) != predictedHook) {
            revert HookCreate2AddressMismatch(address(d.hook), predictedHook);
        }

        // 8. Deploy YuzuDistributor(mainframe, socketBay, treasury, lens, pyth, weth, yuzuToken)
        d.distributor = new YuzuDistributor(
            address(d.mainframe),
            address(d.socketBay),
            address(d.treasury),
            address(d.lens),
            p.pyth,
            p.weth,
            address(d.yuzuToken)
        );

        // 9. Deploy YuzuCartridge(mainframe, socketBay, lens, registry, treasury, weth)
        d.cartridge = new YuzuCartridge(
            address(d.mainframe),
            address(d.socketBay),
            address(d.lens),
            address(d.registry),
            address(d.treasury),
            p.weth
        );

        // 10. Deploy Contract 17: YuzuAccountCompanion
        d.companion = new YuzuAccountCompanion(
            address(d.mainframe),
            address(d.lens),
            address(d.registry),
            address(d.socketBay),
            address(d.distributor),
            address(d.treasury),
            p.weth,
            address(d.yuzuToken)
        );

        // 11. Deploy YuzuSeeder (12 arguments)
        d.seeder = new YuzuSeeder(
            address(d.mainframe),
            address(d.socketBay),
            address(d.treasury),
            address(d.distributor),
            address(d.lens),
            address(d.registry),
            p.pyth,
            p.weth,
            address(d.yuzuToken),
            p.kbtc,
            p.usdg,
            p.wspyx
        );

        // 12. Distribute the 1,000,000,000 $YUZU supply: 150.1M to YuzuSeeder, 849.9M to YuzuTreasury
        d.yuzuToken.transfer(address(d.seeder), SEEDER_SUPPLY_SHARE);
        d.yuzuToken.transfer(address(d.treasury), TREASURY_SUPPLY_SHARE);

        // 13. Pre-deploy and register all requested YuzuAccount vaults BEFORE calling d.mainframe.configureCore(...)
        d.deployedVaults = new address[](p.initialVaultBatchCount);
        // CHANGE (founder 2026-11-18): full standalone vaults only. The EIP-1167 clone path is removed, so there
        // is no delegatecall anywhere in the stack. On a broadcast each vault is its own transaction.
        for (uint256 i = 0; i < p.initialVaultBatchCount; i++) {
            YuzuAccount v = new YuzuAccount(
                address(d.mainframe),
                address(d.lens),
                address(d.registry),
                address(d.socketBay),
                address(d.distributor),
                address(d.treasury),
                address(d.hook),
                p.pyth,
                p.weth,
                address(d.yuzuToken),
                address(d.seeder),
                address(d.cartridge),
                address(d.rsAdapter),
                address(d.companion)
            );
            d.deployedVaults[i] = address(v);
        }

        // Register vault addresses in chunks of 250 so 1,000 vaults register cleanly
        uint256 registered = 0;
        while (registered < p.initialVaultBatchCount) {
            uint256 chunkLen = p.initialVaultBatchCount - registered;
            if (chunkLen > VAULT_REGISTER_CHUNK) chunkLen = VAULT_REGISTER_CHUNK;
            address[] memory chunk = new address[](chunkLen);
            for (uint256 j = 0; j < chunkLen; j++) {
                chunk[j] = d.deployedVaults[registered + j];
            }
            d.mainframe.registerVaultAddresses(registered, chunk);
            registered += chunkLen;
        }

        // 14. Configure core wiring on YuzuTreasury, YuzuSocketBay, and Yuzu98v2
        PoolKey memory poolKey = PoolKey({
            currency0: address(d.yuzuToken) < p.weth ? address(d.yuzuToken) : p.weth,
            currency1: address(d.yuzuToken) < p.weth ? p.weth : address(d.yuzuToken),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(d.hook)
        });

        d.treasury.configureCore(
            address(d.hook),
            address(d.socketBay),
            address(d.mainframe),
            address(d.seeder),
            address(d.distributor),
            address(d.lens),
            address(d.registry),
            poolKey
        );

        d.socketBay.configureCore(
            address(d.mainframe),
            address(d.seeder),
            address(d.distributor),
            poolKey
        );

        d.mainframe.configureCore(
            address(d.seeder),
            address(d.treasury),
            address(d.cartridge),
            address(d.renderer)
        );

        // 15. Mandatory Unit #0000 commissioning in the same run (never silently skipped!)
        // FIX (bankr 2026-11-18): checks the sending account's balance, not address(this).balance.
        // CHANGE (founder 2026-11-18): the Seeder charges 0.15 ETH plus the Pyth update fee, so the fee is added
        // when update data is supplied (sending exactly 0.15 ETH would revert). The Seeder only accepts this
        // call from the account that deployed it, which is the account sending these transactions.
        uint256 unitZeroValue = UNIT_ZERO_PRICE;
        if (p.pythUpdateData.length > 0) {
            unitZeroValue += IPythUpdateFee(p.pyth).getUpdateFee(p.pythUpdateData);
        }
        if (txSender.balance < unitZeroValue) {
            revert InsufficientEthForUnitZero(txSender.balance, unitZeroValue);
        }
        d.seeder.commissionFounderUnitZero{value: unitZeroValue}(
            p.founderRecipient,
            p.initialGuardian,
            p.recoveryAddress,
            p.pythUpdateData
        );
        if (!d.treasury.poolOpened()) revert PoolNotOpenedAfterUnitZero();
    }
}
