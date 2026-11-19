// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    BoltState,
    IWETH,
    IYuzu98v2Minimal,
    IYuzuAccountMinimal,
    IYuzuSocketBayMinimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuTreasuryMinimal,
    IYuzuPriceArchiveMinimal,
    IOptionsVenueAdapter,
    ILendingMarketAdapter
} from "../../src/interfaces/IYuzuPhase5Interfaces.sol";

contract MockERC20_5 is ERC20 {
    uint8 private _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function burn(address from, uint256 amt) external { _burn(from, amt); }
}

contract MockWETH5 is MockERC20_5, IWETH {
    constructor() MockERC20_5("Wrapped Ether", "WETH", 18) {}
    function deposit() external payable override { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
    function transfer(address to, uint256 value) public override(ERC20, IWETH) returns (bool) {
        return super.transfer(to, value);
    }
    function transferFrom(address from, address to, uint256 value) public override(ERC20, IWETH) returns (bool) {
        return super.transferFrom(from, to, value);
    }
    function balanceOf(address account) public view override(ERC20, IWETH) returns (uint256) {
        return super.balanceOf(account);
    }
    function approve(address spender, uint256 value) public override(ERC20, IWETH) returns (bool) {
        return super.approve(spender, value);
    }
}

contract MockMainframe5 is IYuzu98v2Minimal {
    mapping(uint256 => address) public override ownerOf;
    mapping(uint256 => bool) public override isGutted;
    mapping(uint256 => BoltState) public override boltState;
    mapping(uint256 => address) public override getVaultAddress;

    function setUnit(uint256 id, address o, address v) external {
        ownerOf[id] = o;
        getVaultAddress[id] = v;
    }
}

contract MockVault5 is IYuzuAccountMinimal {
    bool public override guardianFrozen;
    address public override aiSessionKey;
    uint256 public override aiSessionExpiry;
    mapping(address => uint256) public override seedUnits;

    function setAiKey(address k, uint256 exp) external {
        aiSessionKey = k;
        aiSessionExpiry = exp;
    }

    function setSeed(address a, uint256 amt) external {
        seedUnits[a] = amt;
    }

    function pullSlot2Asset(address asset, uint256 amount, address to) external override {
        ERC20(asset).transfer(to, amount);
    }
}

contract MockSocketBay5 is IYuzuSocketBayMinimal {
    mapping(uint256 => uint8) public override ramTier;
    function setTier(uint256 id, uint8 t) external { ramTier[id] = t; }
}

contract MockLens5 is IYuzuNavLensMinimal {
    address[] public assets;
    mapping(address => uint256) public prices18;
    mapping(address => uint8) public decs;

    function setPrice(address a, uint256 p18, uint8 d) external {
        if (prices18[a] == 0) assets.push(a);
        prices18[a] = p18;
        decs[a] = d;
    }

    function requireFresh(address a) external view override returns (uint256) {
        require(prices18[a] > 0, "STALE");
        return prices18[a];
    }

    function valueOf(address a, uint256 amt) public view override returns (uint256) {
        if (prices18[a] == 0 || amt == 0) return 0;
        return (amt * prices18[a]) / (10 ** decs[a]);
    }

    function getLiquidNavUsd(address vault) external view override returns (uint256 total) {
        for (uint256 i = 0; i < assets.length; i++) {
            address a = assets[i];
            total += valueOf(a, ERC20(a).balanceOf(vault));
        }
    }
}

contract MockRegistry5 is IYuzuRegistryMinimal {
    address[] public pricedList;
    mapping(address => bool) public override isPricedAsset;
    mapping(address => VenueInfo) private _venues;

    struct VenueInfo {
        bool isListed;
        bool isPaused;
        bool isLendingMarket;
        address receiptToken;
    }

    function addPricedAsset(address a) external {
        if (!isPricedAsset[a]) pricedList.push(a);
        isPricedAsset[a] = true;
    }

    function setVenue(address v, bool listed, bool paused, bool lending, address receipt) external {
        _venues[v] = VenueInfo(listed, paused, lending, receipt);
    }

    function getPricedAssets() external view override returns (address[] memory) {
        return pricedList;
    }

    function venues(address v) external view override returns (bool, bool, bool, address) {
        VenueInfo memory info = _venues[v];
        return (info.isListed, info.isPaused, info.isLendingMarket, info.receiptToken);
    }
}

contract MockTreasury5 is IYuzuTreasuryMinimal {
    MockWETH5 public weth;
    uint256 public distWeth;
    uint256 public buybackWeth;
    mapping(address => uint256) public feeEscrow;

    constructor(MockWETH5 w) { weth = w; }

    function recordProtocolFeeWeth(uint256 toDist, uint256 toBuy) external override {
        weth.transferFrom(msg.sender, address(this), toDist + toBuy);
        distWeth += toDist;
        buybackWeth += toBuy;
    }

    function receiveFeeEscrow(address a, uint256 amt) external override {
        feeEscrow[a] += amt;
    }

    function receiveSkimEscrow(address a, uint256 amt) external override {
        feeEscrow[a] += amt;
    }
}

contract MockArchive5 is IYuzuPriceArchiveMinimal {
    mapping(address => int256) public returnsBps;
    mapping(address => bool) public isValid;

    function setReturn(address a, bool v, int256 bps) external {
        isValid[a] = v;
        returnsBps[a] = bps;
    }

    function get14DayReturnBps(address a) external view override returns (bool, int256) {
        return (isValid[a], returnsBps[a]);
    }
}

contract MockHypercallAdapter is IOptionsVenueAdapter {
    uint256 public nextVenueCallId = 1;
    uint256 public simulatedPremium;

    struct VenueCall {
        address vault;
        address collateralAsset;
        uint256 collateralAmount;
        bool settled;
    }
    mapping(uint256 => VenueCall) public calls;

    function setSimulatedPremium(uint256 p) external { simulatedPremium = p; }

    function writeCall(
        address vault,
        address collateralAsset,
        uint256 collateralAmount,
        uint256,
        uint64,
        address premiumAsset,
        uint256
    ) external override returns (uint256 venueCallId, uint256 grossPremium) {
        ERC20(collateralAsset).transferFrom(msg.sender, address(this), collateralAmount);
        venueCallId = nextVenueCallId++;
        calls[venueCallId] = VenueCall(vault, collateralAsset, collateralAmount, false);
        grossPremium = simulatedPremium;
        MockERC20_5(premiumAsset).mint(msg.sender, grossPremium);
    }

    function settleOrExpireCall(uint256 venueCallId, address vault) external override returns (bool) {
        VenueCall storage c = calls[venueCallId];
        require(!c.settled, "ALREADY_SETTLED");
        c.settled = true;
        // Return unexercised collateral to vault
        ERC20(c.collateralAsset).transfer(vault, c.collateralAmount);
        return true;
    }
}

contract MockTydroLendingAdapter is ILendingMarketAdapter {
    MockERC20_5 public receiptToken;
    uint256 public simulatedYieldBps = 500; // +5.00% simulated interest on withdrawal

    constructor(MockERC20_5 r) { receiptToken = r; }

    function supplyForVault(address underlyingAsset, uint256 amount, address vault)
        external
        override
        returns (uint256 shares)
    {
        ERC20(underlyingAsset).transferFrom(msg.sender, address(this), amount);
        shares = amount;
        receiptToken.mint(vault, shares);
    }

    function withdrawForVault(address underlyingAsset, uint256 shares, address recipient)
        external
        override
        returns (uint256 redeemed)
    {
        receiptToken.transferFrom(msg.sender, address(this), shares);
        receiptToken.burn(address(this), shares);
        redeemed = (shares * (10000 + simulatedYieldBps)) / 10000;
        MockERC20_5(underlyingAsset).mint(recipient, redeemed);
    }
}
