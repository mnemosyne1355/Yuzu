// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IUnlockCallback,
    PoolKey,
    SwapParams,
    IPoolManager,
    IWETH,
    IYuzuUnits,
    V4StateLib
} from "./interfaces/IYuzuV4Interfaces.sol";

/// @title YuzuSocketBay — Contract 04 of 16 (YUZU-98 Master Specification v4.9, Sections 2.2, 6.1, 6.4, 9.1)
/// @notice Permanent $YUZU RAM Bank and ROM Bond Locker.
///         Implements Uniswap v4 IUnlockCallback to buy $YUZU directly from PoolManager during the Launch Gate:
///         1. buyAndSeat(tokenId, blades, maxWethIn) — Owner buys blades with ETH straight into SocketBay.
///         2. buyAndBond(tokenId, maxWethIn) — Owner buys 250,000 $YUZU ROM bond with ETH straight into SocketBay.
///         3. buyStarterBlade(tokenId, maxWethIn) — Seeder-only replacement starter blade (150,000 $YUZU) on refurbishment.
///         4. buyBufferFor(tokenId, yuzuAmount, maxWethIn) — Vault-only run-fee buffer buy (<= 50,000 $YUZU lifetime cap).
///         Also supports seatBladesFromVault, postBondFromVault, seedInitialRam, recommissionStarterBlade, and forfeit.
contract YuzuSocketBay is IUnlockCallback, ReentrancyGuard {
    uint256 public constant STARTER_BLADE_YUZU = 150_000e18;
    uint256 public constant EXPANSION_BLADE_YUZU = 25_000e18;
    uint256 public constant ROM_BOND_YUZU = 250_000e18;
    uint256 public constant VAULT_BUFFER_CAP = 50_000e18;
    uint8 public constant MAX_TIER = 5;

    IPoolManager public immutable poolManager;
    IERC20 public immutable yuzuToken;
    IWETH public immutable weth;
    bool public immutable yuzuIsCurrency0;
    address public immutable deployer;

    IYuzuUnits public units;
    address public seeder;
    address public distributor;
    PoolKey public poolKey;
    bool public coreConfigured;

    // Per-unit permanent hardware state
    mapping(uint256 tokenId => uint8 tier) public ramTier;             // 1..5 (0 if uncommissioned or gutted)
    mapping(uint256 tokenId => uint256 yuzuLocked) public ramLocked;   // Starter + expansion blades locked
    mapping(uint256 tokenId => uint256 bondLocked) public romBond;     // 0 or 250,000e18
    mapping(uint256 tokenId => uint256 postMintSeated) public unitNetSeatedAfterMint; // Expansion blades + bond

    // Per-vault lifetime Launch Gate buffer counter
    mapping(address vault => uint256 amount) public gateBought;

    // Shared net seated counter for the 3/20 R&D Seat Gate and 1:1 Farm Gate (excludes starter blades & #0000 preload)
    uint256 public netSeatedYuzu;

    event CoreConfigured(address units, address seeder, address distributor, address hook);
    event StarterSeated(uint256 indexed tokenId, uint8 tier, uint256 totalRamYuzu);
    event BladesSeated(uint256 indexed tokenId, uint8 bladesAdded, uint8 newTier, uint256 yuzuAdded, bool fromPool);
    event RomBondPosted(uint256 indexed tokenId, uint256 bondAmount, bool fromPool);
    event RunFeeBufferBought(uint256 indexed tokenId, address indexed vault, uint256 yuzuAmount, uint256 wethSpent, uint256 lifetimeTotal);
    event HardwareForfeited(uint256 indexed tokenId, uint256 totalYuzuToDistributor, uint256 netSeatedSubtracted);

    error ZeroAddress();
    error OnlyDeployer();
    error AlreadyConfigured();
    error NotConfigured();
    error OnlySeeder();
    error OnlyUnitOwner();
    error OnlyUnitVault();
    error OnlyPoolManager();
    error UnitIsGutted();
    error UnitNotUnbolted();
    error InvalidBladeCount();
    error MaxTierExceeded();
    error BondAlreadyPosted();
    error VaultBufferCapExceeded(uint256 requestedTotal);
    error SlippageMaxWethExceeded(uint256 wethNeeded, uint256 maxWethIn);
    error InsufficientEthSent();
    error EthRefundFailed();

    constructor(address poolManager_, address yuzuToken_, address weth_) {
        if (poolManager_ == address(0) || yuzuToken_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        yuzuToken = IERC20(yuzuToken_);
        weth = IWETH(weth_);
        yuzuIsCurrency0 = yuzuToken_ < weth_;
        deployer = msg.sender;
    }

    /// @notice One-time wiring called at deployment.
    function configureCore(
        address units_,
        address seeder_,
        address distributor_,
        PoolKey calldata poolKey_
    ) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (coreConfigured) revert AlreadyConfigured();
        if (units_ == address(0) || seeder_ == address(0) || distributor_ == address(0) || poolKey_.hooks == address(0)) {
            revert ZeroAddress();
        }
        units = IYuzuUnits(units_);
        seeder = seeder_;
        distributor = distributor_;
        poolKey = poolKey_;
        coreConfigured = true;
        emit CoreConfigured(units_, seeder_, distributor_, poolKey_.hooks);
    }

    /// @notice Returns the RAM Multiplier in basis points (10000 = 1.00x, 20000 = 2.00x, 0 if gutted/unseated).
    function ramMultiplierBps(uint256 tokenId) external view returns (uint256) {
        uint8 t = ramTier[tokenId];
        if (t == 0) return 0;
        return 10000 + uint256(t - 1) * 2500;
    }

    /// @notice Called by YuzuSeeder during initial commissioning (#0000 gets Tier 5 = 250k; #0001-#0999 get Tier 1 = 150k).
    ///         Starter blades and the #0000 preload do NOT count toward netSeatedYuzu.
    function seedInitialRam(uint256 tokenId, uint8 initialTier) external {
        if (msg.sender != seeder) revert OnlySeeder();
        uint256 amount = STARTER_BLADE_YUZU + uint256(initialTier - 1) * EXPANSION_BLADE_YUZU;
        ramTier[tokenId] = initialTier;
        ramLocked[tokenId] = amount;
        emit StarterSeated(tokenId, initialTier, amount);
    }

    /// @notice Called by YuzuSeeder on factory refurbishment when caller provides 150,000 $YUZU from wallet.
    ///         Does NOT increment netSeatedYuzu (zero Seat-Gate dilution).
    function recommissionStarterBlade(uint256 tokenId) external {
        if (msg.sender != seeder) revert OnlySeeder();
        ramTier[tokenId] = 1;
        ramLocked[tokenId] = STARTER_BLADE_YUZU;
        emit StarterSeated(tokenId, 1, STARTER_BLADE_YUZU);
    }

    /// @notice Called by YuzuSeeder during Launch Gate refurbishment to buy 150,000 $YUZU from the pool into SocketBay.
    function buyStarterBlade(uint256 tokenId, uint256 maxWethIn) external payable nonReentrant returns (uint256 wethSpent) {
        if (msg.sender != seeder) revert OnlySeeder();
        if (msg.value < maxWethIn) revert InsufficientEthSent();

        weth.deposit{value: maxWethIn}();
        wethSpent = _buyExactYuzuFromPool(STARTER_BLADE_YUZU, maxWethIn, address(this));

        ramTier[tokenId] = 1;
        ramLocked[tokenId] = STARTER_BLADE_YUZU;
        emit StarterSeated(tokenId, 1, STARTER_BLADE_YUZU);

        uint256 unused = msg.value - wethSpent;
        if (unused > 0) {
            weth.withdraw(maxWethIn - wethSpent);
            (bool ok,) = msg.sender.call{value: unused}("");
            if (!ok) revert EthRefundFailed();
        }
    }

    /// @notice Owner buys `blades` (1..4) from the pool with ETH and seats them permanently into `tokenId`.
    function buyAndSeat(uint256 tokenId, uint8 blades, uint256 maxWethIn)
        external
        payable
        nonReentrant
        returns (uint256 wethSpent)
    {
        if (units.ownerOf(tokenId) != msg.sender) revert OnlyUnitOwner();
        if (units.isGutted(tokenId)) revert UnitIsGutted();
        if (units.boltState(tokenId) != 0) revert UnitNotUnbolted();
        uint8 currentTier = ramTier[tokenId];
        if (blades == 0 || currentTier == 0) revert InvalidBladeCount();
        if (currentTier + blades > MAX_TIER) revert MaxTierExceeded();
        if (msg.value < maxWethIn) revert InsufficientEthSent();

        uint256 yuzuNeeded = uint256(blades) * EXPANSION_BLADE_YUZU;
        weth.deposit{value: maxWethIn}();
        wethSpent = _buyExactYuzuFromPool(yuzuNeeded, maxWethIn, address(this));

        _recordSeatedBlades(tokenId, blades, yuzuNeeded, true);

        uint256 unused = msg.value - wethSpent;
        if (unused > 0) {
            weth.withdraw(maxWethIn - wethSpent);
            (bool ok,) = msg.sender.call{value: unused}("");
            if (!ok) revert EthRefundFailed();
        }
    }

    /// @notice Vault seats `blades` (1..4) using $YUZU already held inside the unit's vault (Owner-initiated via vault).
    function seatBladesFromVault(uint256 tokenId, uint8 blades) external nonReentrant {
        address vault = units.getVaultAddress(tokenId);
        if (msg.sender != vault) revert OnlyUnitVault();
        if (units.isGutted(tokenId)) revert UnitIsGutted();
        uint8 currentTier = ramTier[tokenId];
        if (blades == 0 || currentTier == 0) revert InvalidBladeCount();
        if (currentTier + blades > MAX_TIER) revert MaxTierExceeded();

        uint256 yuzuNeeded = uint256(blades) * EXPANSION_BLADE_YUZU;
        yuzuToken.transferFrom(vault, address(this), yuzuNeeded);
        _recordSeatedBlades(tokenId, blades, yuzuNeeded, false);
    }

    /// @notice Owner buys a 250,000 $YUZU ROM bond from the pool with ETH and locks it under `tokenId`.
    function buyAndBond(uint256 tokenId, uint256 maxWethIn) external payable nonReentrant returns (uint256 wethSpent) {
        if (units.ownerOf(tokenId) != msg.sender) revert OnlyUnitOwner();
        if (units.isGutted(tokenId) || ramTier[tokenId] == 0) revert UnitIsGutted();
        if (units.boltState(tokenId) != 0) revert UnitNotUnbolted();
        if (romBond[tokenId] != 0) revert BondAlreadyPosted();
        if (msg.value < maxWethIn) revert InsufficientEthSent();

        weth.deposit{value: maxWethIn}();
        wethSpent = _buyExactYuzuFromPool(ROM_BOND_YUZU, maxWethIn, address(this));

        _recordBond(tokenId, true);

        uint256 unused = msg.value - wethSpent;
        if (unused > 0) {
            weth.withdraw(maxWethIn - wethSpent);
            (bool ok,) = msg.sender.call{value: unused}("");
            if (!ok) revert EthRefundFailed();
        }
    }

    /// @notice Vault posts a 250,000 $YUZU ROM bond from its own $YUZU balance (Tier-3 action in YuzuAccount).
    function postBondFromVault(uint256 tokenId) external nonReentrant {
        address vault = units.getVaultAddress(tokenId);
        if (msg.sender != vault) revert OnlyUnitVault();
        if (units.isGutted(tokenId) || ramTier[tokenId] == 0) revert UnitIsGutted();
        if (romBond[tokenId] != 0) revert BondAlreadyPosted();

        yuzuToken.transferFrom(vault, address(this), ROM_BOND_YUZU);
        _recordBond(tokenId, false);
    }

    /// @notice Callable only by the unit's own vault during the Launch Gate to buy up to 50,000 $YUZU lifetime run-fee buffer.
    function buyBufferFor(uint256 tokenId, uint256 yuzuAmount, uint256 maxWethIn)
        external
        nonReentrant
        returns (uint256 wethSpent)
    {
        address vault = units.getVaultAddress(tokenId);
        if (msg.sender != vault) revert OnlyUnitVault();
        if (units.isGutted(tokenId)) revert UnitIsGutted();

        uint256 newTotal = gateBought[vault] + yuzuAmount;
        if (newTotal > VAULT_BUFFER_CAP) revert VaultBufferCapExceeded(newTotal);
        gateBought[vault] = newTotal;

        weth.transferFrom(vault, address(this), maxWethIn);
        wethSpent = _buyExactYuzuFromPool(yuzuAmount, maxWethIn, vault);

        if (maxWethIn > wethSpent) {
            weth.transfer(vault, maxWethIn - wethSpent);
        }

        emit RunFeeBufferBought(tokenId, vault, yuzuAmount, wethSpent, newTotal);
    }

    /// @notice Callable only by the unit's own vault during Seed Raid (decommissionAndRaidSeed).
    ///         Sends all starter RAM, seated expansion blades, and any ROM bond to YuzuDistributor,
    ///         and subtracts the unit's post-mint seated blades and bond from netSeatedYuzu.
    function forfeit(uint256 tokenId) external nonReentrant returns (uint256 totalForfeited) {
        address vault = units.getVaultAddress(tokenId);
        if (msg.sender != vault) revert OnlyUnitVault();

        uint256 ram = ramLocked[tokenId];
        uint256 bond = romBond[tokenId];
        totalForfeited = ram + bond;

        uint256 postMint = unitNetSeatedAfterMint[tokenId];
        if (postMint > 0) {
            netSeatedYuzu = netSeatedYuzu > postMint ? netSeatedYuzu - postMint : 0;
            unitNetSeatedAfterMint[tokenId] = 0;
        }

        ramTier[tokenId] = 0;
        ramLocked[tokenId] = 0;
        romBond[tokenId] = 0;

        if (totalForfeited > 0) {
            yuzuToken.transfer(distributor, totalForfeited);
        }

        emit HardwareForfeited(tokenId, totalForfeited, postMint);
    }

    function _recordSeatedBlades(uint256 tokenId, uint8 blades, uint256 yuzuAdded, bool fromPool) internal {
        uint8 newTier = ramTier[tokenId] + blades;
        ramTier[tokenId] = newTier;
        ramLocked[tokenId] += yuzuAdded;
        unitNetSeatedAfterMint[tokenId] += yuzuAdded;
        netSeatedYuzu += yuzuAdded;
        emit BladesSeated(tokenId, blades, newTier, yuzuAdded, fromPool);
    }

    function _recordBond(uint256 tokenId, bool fromPool) internal {
        romBond[tokenId] = ROM_BOND_YUZU;
        unitNetSeatedAfterMint[tokenId] += ROM_BOND_YUZU;
        netSeatedYuzu += ROM_BOND_YUZU;
        emit RomBondPosted(tokenId, ROM_BOND_YUZU, fromPool);
    }

    function _buyExactYuzuFromPool(uint256 yuzuOut, uint256 maxWethIn, address recipient) internal returns (uint256 wethSpent) {
        if (!coreConfigured) revert NotConfigured();
        bytes memory res = poolManager.unlock(abi.encode(yuzuOut, maxWethIn, recipient));
        wethSpent = abi.decode(res, (uint256));
    }

    /// @notice Uniswap v4 IUnlockCallback: executes exact-output swap for `yuzuOut` and settles WETH directly.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint256 yuzuOut, uint256 maxWethIn, address recipient) = abi.decode(data, (uint256, uint256, address));

        // Buying $YUZU out of the pool (exact-output: amountSpecified > 0 in Uniswap v4)
        bool zeroForOne = !yuzuIsCurrency0;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(yuzuOut),
            sqrtPriceLimitX96: zeroForOne ? V4StateLib.MIN_SQRT_PRICE_PLUS_ONE : V4StateLib.MAX_SQRT_PRICE_MINUS_ONE
        });

        (int128 delta0, int128 delta1) = V4StateLib.unpackDelta(poolManager.swap(poolKey, params, ""));

        // Determine WETH owed to pool (negative delta) and YUZU owed to recipient (positive delta)
        int256 wethDelta = yuzuIsCurrency0 ? delta1 : delta0;
        uint256 wethNeeded = wethDelta < 0 ? uint256(-wethDelta) : uint256(wethDelta);
        if (wethNeeded > maxWethIn) revert SlippageMaxWethExceeded(wethNeeded, maxWethIn);

        // Pay WETH into PoolManager and settle
        poolManager.sync(address(weth));
        weth.transfer(address(poolManager), wethNeeded);
        poolManager.settle();

        // Take exact $YUZU from PoolManager to recipient (SocketBay or Vault)
        poolManager.take(address(yuzuToken), recipient, yuzuOut);

        return abi.encode(wethNeeded);
    }

    receive() external payable {}
}
