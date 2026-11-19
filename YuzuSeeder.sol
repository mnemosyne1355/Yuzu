// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SeedMode,
    BoltState,
    IWETH,
    IPythMinimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuSwapRouter,
    IYuzuSocketBayMinimal,
    IYuzuTreasuryMinimal,
    IYuzuAccountMinimal
} from "./interfaces/IYuzuPhase3Interfaces.sol";
import {Yuzu98v2} from "./Yuzu98v2.sol";

/// @title YuzuSeeder — Contract 03 of 16 (YUZU-98 Master Specification v4.9, Sections 2, 2.3, 9.1.1)
/// @notice Non-upgradeable 0.15 ETH Commissioning Router and 0.090 ETH + 150,000 $YUZU Refurbishment Router.
///         - Holds the diminishing 150,100,000 $YUZU starter-blade & #0000 reserve (no admin withdrawal function).
///         - Splits every 0.15 ETH commissioning 4 ways:
///           1. 50.0% (0.0750 ETH) Factory Vault Seed (40% WETH / 40% kBTC / 20% USDG or 100% wSPYx, <= 1.50% slippage).
///           2. 15.0% (0.0225 ETH) Starter $YUZU RAM Blade (150k $YUZU to SocketBay) + WETH to Treasury LP Reserve.
///           3. 10.0% (0.0150 ETH) Weekly Epoch Reward Pool (`YuzuDistributor.sol`).
///           4. 25.0% (0.0375 ETH) Yuzu Heavy Industries Treasury (`YuzuTreasury.sol`).
///         - Supports `recommissionMainframe` (wallet $YUZU starter blade) and `recommissionWithPoolBlade` (pool buy during gate).
contract YuzuSeeder is ReentrancyGuard {
    uint256 public constant COMMISSION_PRICE = 0.1500 ether;
    uint256 public constant SEED_SHARE = 0.0750 ether;
    uint256 public constant LP_SHARE = 0.0225 ether;
    uint256 public constant DISTRIBUTOR_SHARE = 0.0150 ether;
    uint256 public constant TREASURY_SHARE = 0.0375 ether;

    uint256 public constant US_BASKET_WETH_LEG = 0.0300 ether; // 40% of 0.0750 ETH
    uint256 public constant US_BASKET_KBTC_LEG = 0.0300 ether; // 40% of 0.0750 ETH
    uint256 public constant US_BASKET_USDG_LEG = 0.0150 ether; // 20% of 0.0750 ETH

    uint256 public constant RECOMMISSION_PRICE = 0.0900 ether;
    uint256 public constant RECOMMISSION_FEE_HALF = 0.0075 ether;

    uint256 public constant STARTER_BLADE_YUZU = 150_000e18;
    uint256 public constant FOUNDER_UNIT_ZERO_YUZU = 250_000e18;
    uint256 public constant MAX_MINT_BATCH = 5;
    uint256 public constant MAX_FLEET = 1_000;
    uint256 public constant SEED_SLIPPAGE_BPS = 150; // 1.50% oracle check

    Yuzu98v2 public immutable mainframe;
    IYuzuSocketBayMinimal public immutable socketBay;
    IYuzuTreasuryMinimal public immutable treasury;
    address public immutable distributor;
    IYuzuNavLensMinimal public immutable lens;
    IYuzuRegistryMinimal public immutable registry;
    IPythMinimal public immutable pyth;

    IWETH public immutable weth;
    IERC20 public immutable yuzuToken;
    address public immutable kbtc;
    address public immutable usdg;
    address public immutable wspyx;

    uint256 public nextPublicTokenId = 1;
    bool public unitZeroCommissioned;
    /// @notice CHANGE (founder 2026-11-18): the account that deployed this contract. Only it may commission #0000,
    ///         so nobody can take #0000 between the wiring transactions and the #0000 transaction.
    address public immutable deployer = msg.sender;

    event UnitCommissioned(uint256 indexed tokenId, address indexed minter, SeedMode mode, address guardian, address recovery);
    event UnitRecommissioned(uint256 indexed tokenId, address indexed owner, SeedMode newMode, bool poolSourcedBlade);

    error ZeroAddress();
    error InvalidQuantity();
    error FleetSoldOut();
    error UnitZeroAlreadyCommissioned();
    error OnlyDeployer();
    error UnitZeroMustBeCommissionedFirst();
    error InsufficientEthSent();
    error SeedMinOutInsufficient(address tokenOut, uint256 received, uint256 minOut);
    error NotUnitOwner();
    error UnitNotGutted();
    error UnitMustBeUnbolted();
    error EthRefundFailed();

    constructor(
        address mainframe_,
        address socketBay_,
        address treasury_,
        address distributor_,
        address lens_,
        address registry_,
        address pyth_,
        address weth_,
        address yuzuToken_,
        address kbtc_,
        address usdg_,
        address wspyx_
    ) {
        if (
            mainframe_ == address(0) || socketBay_ == address(0) || treasury_ == address(0)
                || distributor_ == address(0) || lens_ == address(0) || registry_ == address(0)
                || pyth_ == address(0) || weth_ == address(0) || yuzuToken_ == address(0)
                || kbtc_ == address(0) || usdg_ == address(0) || wspyx_ == address(0)
        ) revert ZeroAddress();

        mainframe = Yuzu98v2(mainframe_);
        socketBay = IYuzuSocketBayMinimal(socketBay_);
        treasury = IYuzuTreasuryMinimal(treasury_);
        distributor = distributor_;
        lens = IYuzuNavLensMinimal(lens_);
        registry = IYuzuRegistryMinimal(registry_);
        pyth = IPythMinimal(pyth_);
        weth = IWETH(weth_);
        yuzuToken = IERC20(yuzuToken_);
        kbtc = kbtc_;
        usdg = usdg_;
        wspyx = wspyx_;
    }

    /// @notice Commissions Token #0000 (HQ Founder Mainframe) at deployment in `SeedMode.US_BASKET` with Tier-5 RAM.
    function commissionFounderUnitZero(
        address founderRecipient,
        address initialGuardian,
        address recoveryAddress,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (unitZeroCommissioned) revert UnitZeroAlreadyCommissioned();
        if (founderRecipient == address(0)) revert ZeroAddress();

        uint256 pythFee = _updatePyth(pythUpdateData);
        if (msg.value < COMMISSION_PRICE + pythFee) revert InsufficientEthSent();

        unitZeroCommissioned = true;
        _commissionSingle(0, founderRecipient, SeedMode.US_BASKET, initialGuardian, recoveryAddress, true);

        uint256 excess = msg.value - (COMMISSION_PRICE + pythFee);
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert EthRefundFailed();
        }
    }

    /// @notice Commissions 1 to 5 mainframes (#0001 - #0999) in `US_BASKET` or `NON_US_XSTOCK` mode.
    function commissionMainframe(
        uint256 quantity,
        SeedMode mode,
        address initialGuardian,
        address recoveryAddress,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        if (!unitZeroCommissioned) revert UnitZeroMustBeCommissionedFirst();
        if (quantity == 0 || quantity > MAX_MINT_BATCH) revert InvalidQuantity();
        if (nextPublicTokenId + quantity > MAX_FLEET) revert FleetSoldOut();

        uint256 pythFee = _updatePyth(pythUpdateData);
        uint256 totalCost = COMMISSION_PRICE * quantity + pythFee;
        if (msg.value < totalCost) revert InsufficientEthSent();

        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = nextPublicTokenId++;
            _commissionSingle(tokenId, msg.sender, mode, initialGuardian, recoveryAddress, false);
        }

        uint256 excess = msg.value - totalCost;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert EthRefundFailed();
        }
    }

    /// @notice Factory Refurbishment (0.090 ETH + 150,000 $YUZU supplied from caller's wallet).
    function recommissionMainframe(
        uint256 tokenId,
        SeedMode newMode,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        if (mainframe.ownerOf(tokenId) != msg.sender) revert NotUnitOwner();
        if (!mainframe.isGutted(tokenId)) revert UnitNotGutted();
        if (mainframe.boltState(tokenId) != BoltState.UNBOLTED) revert UnitMustBeUnbolted();

        uint256 pythFee = _updatePyth(pythUpdateData);
        if (msg.value < RECOMMISSION_PRICE + pythFee) revert InsufficientEthSent();

        yuzuToken.transferFrom(msg.sender, address(socketBay), STARTER_BLADE_YUZU);
        socketBay.recommissionStarterBlade(tokenId);

        _executeRecommissionSeedAndFees(tokenId, newMode);

        uint256 excess = msg.value - (RECOMMISSION_PRICE + pythFee);
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert EthRefundFailed();
        }

        emit UnitRecommissioned(tokenId, msg.sender, newMode, false);
    }

    /// @notice Factory Refurbishment during the Launch Gate: buys the 150,000 $YUZU starter blade from the pool via SocketBay.
    function recommissionWithPoolBlade(
        uint256 tokenId,
        SeedMode newMode,
        uint256 maxStarterWethCost,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        if (mainframe.ownerOf(tokenId) != msg.sender) revert NotUnitOwner();
        if (!mainframe.isGutted(tokenId)) revert UnitNotGutted();
        if (mainframe.boltState(tokenId) != BoltState.UNBOLTED) revert UnitMustBeUnbolted();

        uint256 pythFee = _updatePyth(pythUpdateData);
        uint256 requiredEth = RECOMMISSION_PRICE + maxStarterWethCost + pythFee;
        if (msg.value < requiredEth) revert InsufficientEthSent();

        uint256 wethSpent = socketBay.buyStarterBlade{value: maxStarterWethCost}(tokenId, maxStarterWethCost);
        _executeRecommissionSeedAndFees(tokenId, newMode);

        uint256 totalUsed = RECOMMISSION_PRICE + wethSpent + pythFee;
        if (msg.value > totalUsed) {
            (bool ok,) = msg.sender.call{value: msg.value - totalUsed}("");
            if (!ok) revert EthRefundFailed();
        }

        emit UnitRecommissioned(tokenId, msg.sender, newMode, true);
    }

    // =========================================================================
    // INTERNAL COMMISSIONING & SEED SWAP LOGIC
    // =========================================================================

    function _commissionSingle(
        uint256 tokenId,
        address recipient,
        SeedMode mode,
        address initialGuardian,
        address recoveryAddress,
        bool isFounderZero
    ) internal {
        address vault = mainframe.getVaultAddress(tokenId);
        mainframe.mintFromSeeder(tokenId, recipient, vault);

        if (vault.code.length > 0) {
            IYuzuAccountMinimal(vault).initializeFromSeeder(tokenId, initialGuardian, recoveryAddress);
        }

        // Wrap full 0.15 ETH to WETH
        weth.deposit{value: COMMISSION_PRICE}();

        // 1. Starter RAM blade (#0000 gets 250k Tier 5; #0001-#0999 get 150k Tier 1)
        uint256 ramAmount = isFounderZero ? FOUNDER_UNIT_ZERO_YUZU : STARTER_BLADE_YUZU;
        uint8 initialTier = isFounderZero ? 5 : 1;
        yuzuToken.transfer(address(socketBay), ramAmount);
        socketBay.seedInitialRam(tokenId, initialTier);

        // 2. 10% (0.0150 WETH) to Weekly Epoch Reward Pool
        weth.transfer(distributor, DISTRIBUTOR_SHARE);

        // 3. 15% LP Share (0.0225 WETH) + 25% Treasury Share (0.0375 WETH) = 0.0600 WETH to YuzuTreasury
        weth.transfer(address(treasury), LP_SHARE + TREASURY_SHARE);
        treasury.receiveCommissioningWeth(LP_SHARE, TREASURY_SHARE);

        // 4. 50% (0.0750 WETH) Factory Vault Seed
        _deliverSeed(vault, mode);

        emit UnitCommissioned(tokenId, recipient, mode, initialGuardian, recoveryAddress);
    }

    function _executeRecommissionSeedAndFees(uint256 tokenId, SeedMode newMode) internal {
        weth.deposit{value: RECOMMISSION_PRICE}();
        weth.transfer(distributor, RECOMMISSION_FEE_HALF);
        weth.transfer(address(treasury), RECOMMISSION_FEE_HALF);
        treasury.receiveCommissioningWeth(0, RECOMMISSION_FEE_HALF);

        address vault = mainframe.getVaultAddress(tokenId);
        if (vault.code.length > 0) {
            IYuzuAccountMinimal(vault).clearSeedStorageForRecommission();
        }
        _deliverSeed(vault, newMode);
        mainframe.clearGuttedFromSeeder(tokenId);
    }

    function _deliverSeed(address vault, SeedMode mode) internal {
        if (mode == SeedMode.US_BASKET) {
            weth.transfer(vault, US_BASKET_WETH_LEG);
            if (vault.code.length > 0) {
                IYuzuAccountMinimal(vault).recordSeed(address(weth), US_BASKET_WETH_LEG, mode);
            }
            _seedLeg(vault, kbtc, US_BASKET_KBTC_LEG, mode);
            _seedLeg(vault, usdg, US_BASKET_USDG_LEG, mode);
        } else {
            _seedLeg(vault, wspyx, SEED_SHARE, mode);
        }
    }

    function _seedLeg(address vault, address tokenOut, uint256 wethIn, SeedMode mode) internal {
        lens.requireFresh(address(weth));
        lens.requireFresh(tokenOut);

        uint256 fairOut = lens.quote(address(weth), tokenOut, wethIn);
        uint256 minOut = (fairOut * (10000 - SEED_SLIPPAGE_BPS)) / 10000;

        IYuzuRegistryMinimal.Route memory r = registry.routeFor(address(weth), tokenOut);
        uint256 balBefore = IERC20(tokenOut).balanceOf(vault);

        weth.approve(r.router, wethIn);
        IYuzuSwapRouter(r.router).swapExactIn(address(weth), tokenOut, wethIn, minOut, vault, r.path);
        weth.approve(r.router, 0);

        uint256 received = IERC20(tokenOut).balanceOf(vault) - balBefore;
        if (received < minOut) revert SeedMinOutInsufficient(tokenOut, received, minOut);

        if (vault.code.length > 0) {
            IYuzuAccountMinimal(vault).recordSeed(tokenOut, received, mode);
        }
    }

    function _updatePyth(bytes[] calldata pythUpdateData) internal returns (uint256 fee) {
        if (pythUpdateData.length > 0) {
            fee = pyth.getUpdateFee(pythUpdateData);
            pyth.updatePriceFeeds{value: fee}(pythUpdateData);
        }
    }

    receive() external payable {}
}
