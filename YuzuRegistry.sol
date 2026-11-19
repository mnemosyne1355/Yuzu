// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title YuzuRegistry — Contract 13 of 16 (YUZU-98 Master Specification v4.9, Sections 5, 6, 8.1)
/// @notice Non-upgradeable protocol registry storing:
///         1. Priced ERC-20 assets, their Chainlink & Pyth feeds, maxAge, ERC-4626 wrapper flags, and crypto-leg flags.
///         2. Exactly one swap route per pair of priced assets (Fence F2).
///         3. Approved Slot-4 strategy cartridges (address, codeHash, authorTokenId, runPriceYuzu).
///         4. Approved Slot-2 covered-call & cash-leg lending venues.
///         5. Approved Pillar-4 Cultural NFT collections and optional floor feeds.
///         Constructor initializes launch assets and routes immediately; post-launch additions/updates require a
///         48-hour public timelock, while pausing or removing any entry is instant for the 3-of-5 multisig.
contract YuzuRegistry {
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant ADMIN_ROTATION_DELAY = 7 days;
    uint256 public constant EXPIRY_WINDOW = 7 days;

    struct AssetConfig {
        bool isRegistered;
        bool isPaused;
        bool isWrapper;          // True for ERC-4626 wrapped xStocks (e.g., wSPYx, wNVDAx)
        bool isCryptoLeg;        // True for WETH, kBTC, USDG, USDC (eligible to pay the 0.25% desk fee)
        uint8 tokenDecimals;
        uint32 maxAge;           // Per-asset freshness window in seconds
        address chainlinkFeed;   // address(0) if Pyth-only
        bytes32 pythFeedId;      // bytes32(0) if Chainlink-only
    }

    struct Route {
        address router;
        uint8 routerType;        // 1 = V3 exactInput, 2 = V4/Quotrons, etc.
        bytes path;
        bool isActive;
    }

    struct CartridgeConfig {
        bool isListed;
        bool isPaused;
        bytes32 codeHash;
        uint256 authorTokenId;
        uint256 runPriceYuzu;    // Fixed at listing; can never be raised
    }

    struct VenueConfig {
        bool isListed;
        bool isPaused;
        bool isLendingMarket;    // False = Covered-call venue, True = Cash-leg lending market
        address receiptToken;    // For lending markets, the priced receipt token
    }

    struct NftCollectionConfig {
        bool isListed;
        bool isPaused;
        address floorFeed;       // Optional Chainlink-format floor feed in USD (18 decimals or feed decimals)
        uint32 maxAge;
    }

    struct InitialAssetInput {
        address asset;
        AssetConfig config;
    }

    struct InitialRouteInput {
        address tokenIn;
        address tokenOut;
        Route route;
    }

    address public admin;
    address public pendingAdmin;
    uint256 public adminRotationEta;

    address[] public pricedAssets;
    mapping(address asset => uint256 indexPlusOne) private _assetIndex;
    mapping(address asset => AssetConfig) public assetConfigs;

    mapping(address tokenIn => mapping(address tokenOut => Route)) private _routes;

    mapping(address cartridge => CartridgeConfig) public cartridges;
    mapping(address venue => VenueConfig) public venues;

    address[] public nftCollections;
    mapping(address collection => uint256 indexPlusOne) private _nftIndex;
    mapping(address collection => NftCollectionConfig) public nftConfigs;

    // 48h public timelock queue for additions & modifications
    mapping(bytes32 opHash => uint256 readyAt) public queuedOps;

    event OperationQueued(bytes32 indexed opHash, uint256 readyAt, string label);
    event OperationCancelled(bytes32 indexed opHash);
    event OperationExecuted(bytes32 indexed opHash);
    event AssetConfigured(address indexed asset, bool isWrapper, bool isCryptoLeg, uint32 maxAge, address chainlinkFeed, bytes32 pythFeedId);
    event AssetPauseSet(address indexed asset, bool isPaused);
    event AssetRemoved(address indexed asset);
    event RouteConfigured(address indexed tokenIn, address indexed tokenOut, address router, uint8 routerType);
    event RouteRemoved(address indexed tokenIn, address indexed tokenOut);
    event CartridgeListed(address indexed cartridge, bytes32 codeHash, uint256 authorTokenId, uint256 runPriceYuzu);
    event CartridgePauseSet(address indexed cartridge, bool isPaused);
    event VenueConfigured(address indexed venue, bool isLendingMarket, address receiptToken);
    event VenuePauseSet(address indexed venue, bool isPaused);
    event NftCollectionConfigured(address indexed collection, address floorFeed, uint32 maxAge);
    event AdminRotationQueued(address indexed newAdmin, uint256 readyAt);
    event AdminRotated(address indexed oldAdmin, address indexed newAdmin);

    error ZeroAddress();
    error OnlyAdmin();
    error OnlyPendingAdmin();
    error InvalidAssetConfig();
    error InvalidRoute();
    error InvalidCartridge();
    error RunPriceCannotIncrease();
    error OpAlreadyQueued();
    error OpNotQueued();
    error OpNotReady();
    error OpExpired();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(
        address admin_,
        InitialAssetInput[] memory initialAssets,
        InitialRouteInput[] memory initialRoutes
    ) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;

        for (uint256 i = 0; i < initialAssets.length; i++) {
            _setAsset(initialAssets[i].asset, initialAssets[i].config);
        }
        for (uint256 i = 0; i < initialRoutes.length; i++) {
            _setRoute(initialRoutes[i].tokenIn, initialRoutes[i].tokenOut, initialRoutes[i].route);
        }
    }

    // =========================================================================
    // 1. TIMELOCK QUEUE MANAGEMENT (48h on Additions / Updates)
    // =========================================================================

    function queueOperation(bytes32 opHash, string calldata label) external onlyAdmin returns (uint256 readyAt) {
        if (queuedOps[opHash] != 0) revert OpAlreadyQueued();
        readyAt = block.timestamp + TIMELOCK_DELAY;
        queuedOps[opHash] = readyAt;
        emit OperationQueued(opHash, readyAt, label);
    }

    function cancelOperation(bytes32 opHash) external onlyAdmin {
        if (queuedOps[opHash] == 0) revert OpNotQueued();
        delete queuedOps[opHash];
        emit OperationCancelled(opHash);
    }

    function _consumeTimelock(bytes32 opHash) internal {
        uint256 readyAt = queuedOps[opHash];
        if (readyAt == 0) revert OpNotQueued();
        if (block.timestamp < readyAt) revert OpNotReady();
        if (block.timestamp > readyAt + EXPIRY_WINDOW) revert OpExpired();
        delete queuedOps[opHash];
        emit OperationExecuted(opHash);
    }

    // =========================================================================
    // 2. TIMELOCKED ADDITIONS & MODIFICATIONS (48h Delay)
    // =========================================================================

    function executeSetAsset(address asset, AssetConfig calldata config) external onlyAdmin {
        bytes32 opHash = keccak256(abi.encode("SET_ASSET", asset, config));
        _consumeTimelock(opHash);
        _setAsset(asset, config);
    }

    function executeSetRoute(address tokenIn, address tokenOut, Route calldata route) external onlyAdmin {
        bytes32 opHash = keccak256(abi.encode("SET_ROUTE", tokenIn, tokenOut, route));
        _consumeTimelock(opHash);
        _setRoute(tokenIn, tokenOut, route);
    }

    function executeListCartridge(
        address cartridge,
        uint256 authorTokenId,
        uint256 runPriceYuzu
    ) external onlyAdmin {
        bytes32 opHash = keccak256(abi.encode("LIST_CARTRIDGE", cartridge, authorTokenId, runPriceYuzu));
        _consumeTimelock(opHash);

        if (cartridge == address(0) || cartridge.code.length == 0) revert InvalidCartridge();
        CartridgeConfig storage existing = cartridges[cartridge];
        if (existing.isListed && runPriceYuzu > existing.runPriceYuzu) {
            revert RunPriceCannotIncrease();
        }

        bytes32 codeHash = cartridge.codehash;
        cartridges[cartridge] = CartridgeConfig({
            isListed: true,
            isPaused: false,
            codeHash: codeHash,
            authorTokenId: authorTokenId,
            runPriceYuzu: runPriceYuzu
        });

        emit CartridgeListed(cartridge, codeHash, authorTokenId, runPriceYuzu);
    }

    function executeSetVenue(address venue, bool isLendingMarket, address receiptToken) external onlyAdmin {
        bytes32 opHash = keccak256(abi.encode("SET_VENUE", venue, isLendingMarket, receiptToken));
        _consumeTimelock(opHash);
        if (venue == address(0)) revert ZeroAddress();

        venues[venue] = VenueConfig({
            isListed: true,
            isPaused: false,
            isLendingMarket: isLendingMarket,
            receiptToken: receiptToken
        });

        emit VenueConfigured(venue, isLendingMarket, receiptToken);
    }

    function executeSetNftCollection(address collection, address floorFeed, uint32 maxAge) external onlyAdmin {
        bytes32 opHash = keccak256(abi.encode("SET_NFT", collection, floorFeed, maxAge));
        _consumeTimelock(opHash);
        if (collection == address(0)) revert ZeroAddress();

        if (_nftIndex[collection] == 0) {
            nftCollections.push(collection);
            _nftIndex[collection] = nftCollections.length;
        }
        nftConfigs[collection] = NftCollectionConfig({
            isListed: true,
            isPaused: false,
            floorFeed: floorFeed,
            maxAge: maxAge
        });

        emit NftCollectionConfigured(collection, floorFeed, maxAge);
    }

    // =========================================================================
    // 3. INSTANT PAUSE & REMOVAL ACTIONS (Emergency Safety)
    // =========================================================================

    function setAssetPaused(address asset, bool paused) external onlyAdmin {
        if (!assetConfigs[asset].isRegistered) revert InvalidAssetConfig();
        assetConfigs[asset].isPaused = paused;
        emit AssetPauseSet(asset, paused);
    }

    function removeAsset(address asset) external onlyAdmin {
        uint256 idxPlusOne = _assetIndex[asset];
        if (idxPlusOne == 0) revert InvalidAssetConfig();

        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = pricedAssets.length - 1;
        if (idx != lastIdx) {
            address lastAsset = pricedAssets[lastIdx];
            pricedAssets[idx] = lastAsset;
            _assetIndex[lastAsset] = idx + 1;
        }
        pricedAssets.pop();
        delete _assetIndex[asset];
        delete assetConfigs[asset];

        emit AssetRemoved(asset);
    }

    function removeRoute(address tokenIn, address tokenOut) external onlyAdmin {
        delete _routes[tokenIn][tokenOut];
        emit RouteRemoved(tokenIn, tokenOut);
    }

    function setCartridgePaused(address cartridge, bool paused) external onlyAdmin {
        if (!cartridges[cartridge].isListed) revert InvalidCartridge();
        cartridges[cartridge].isPaused = paused;
        emit CartridgePauseSet(cartridge, paused);
    }

    function setVenuePaused(address venue, bool paused) external onlyAdmin {
        if (!venues[venue].isListed) revert ZeroAddress();
        venues[venue].isPaused = paused;
        emit VenuePauseSet(venue, paused);
    }

    function setNftCollectionPaused(address collection, bool paused) external onlyAdmin {
        if (!nftConfigs[collection].isListed) revert ZeroAddress();
        nftConfigs[collection].isPaused = paused;
    }

    // =========================================================================
    // 4. ADMIN ROTATION (7-Day Delay)
    // =========================================================================

    function queueAdminRotation(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        adminRotationEta = block.timestamp + ADMIN_ROTATION_DELAY;
        emit AdminRotationQueued(newAdmin, adminRotationEta);
    }

    function executeAdminRotation() external {
        if (pendingAdmin == address(0) || block.timestamp < adminRotationEta) revert OpNotReady();
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        adminRotationEta = 0;
        emit AdminRotated(old, admin);
    }

    // =========================================================================
    // 5. PROTOCOL VIEWS (Used by YuzuNavLens, YuzuAccount, YuzuCartridge)
    // =========================================================================

    function isPricedAsset(address asset) external view returns (bool) {
        return assetConfigs[asset].isRegistered;
    }

    function isPaused(address asset) external view returns (bool) {
        return assetConfigs[asset].isPaused;
    }

    function isCryptoAsset(address asset) external view returns (bool) {
        AssetConfig storage cfg = assetConfigs[asset];
        return cfg.isRegistered && cfg.isCryptoLeg;
    }

    function maxAgeOf(address asset) external view returns (uint32) {
        return assetConfigs[asset].maxAge;
    }

    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return assetConfigs[asset];
    }

    function getPricedAssets() external view returns (address[] memory) {
        return pricedAssets;
    }

    function getNftCollections() external view returns (address[] memory) {
        return nftCollections;
    }

    function routeFor(address tokenIn, address tokenOut) external view returns (Route memory r) {
        r = _routes[tokenIn][tokenOut];
        if (!r.isActive || r.router == address(0)) revert InvalidRoute();
    }

    function hasActiveRoute(address tokenIn, address tokenOut) external view returns (bool) {
        Route storage r = _routes[tokenIn][tokenOut];
        return r.isActive && r.router != address(0);
    }

    function isCartridgeExecutable(address cartridge)
        external
        view
        returns (bool ok, uint256 authorTokenId, uint256 runPriceYuzu)
    {
        CartridgeConfig storage c = cartridges[cartridge];
        if (!c.isListed || c.isPaused || cartridge.code.length == 0 || cartridge.codehash != c.codeHash) {
            return (false, 0, 0);
        }
        return (true, c.authorTokenId, c.runPriceYuzu);
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    function _setAsset(address asset, AssetConfig memory config) internal {
        if (asset == address(0) || config.maxAge == 0) revert InvalidAssetConfig();
        if (config.chainlinkFeed == address(0) && config.pythFeedId == bytes32(0)) {
            revert InvalidAssetConfig();
        }
        config.isRegistered = true;

        if (_assetIndex[asset] == 0) {
            pricedAssets.push(asset);
            _assetIndex[asset] = pricedAssets.length;
        }
        assetConfigs[asset] = config;

        emit AssetConfigured(
            asset,
            config.isWrapper,
            config.isCryptoLeg,
            config.maxAge,
            config.chainlinkFeed,
            config.pythFeedId
        );
    }

    function _setRoute(address tokenIn, address tokenOut, Route memory route) internal {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || route.router == address(0)) {
            revert InvalidRoute();
        }
        route.isActive = true;
        _routes[tokenIn][tokenOut] = route;
        emit RouteConfigured(tokenIn, tokenOut, route.router, route.routerType);
    }
}
