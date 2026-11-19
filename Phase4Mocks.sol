// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    SeedMode,
    BoltState,
    IWETH,
    IPythMinimal,
    IYuzu98v2Minimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuSwapRouter,
    IYuzuSocketBayMinimal,
    IYuzuDistributorMinimal,
    IYuzuTreasuryMinimal,
    IYuzuPoolHookMinimal,
    IYuzuCustomStrategy
} from "../../src/interfaces/IYuzuPhase4Interfaces.sol";

contract MockERC20_4 is ERC20 {
    uint8 private _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockWETH4 is MockERC20_4, IWETH {
    constructor() MockERC20_4("Wrapped Ether", "WETH", 18) {}
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

contract MockPyth4 is IPythMinimal {
    function getUpdateFee(bytes[] calldata d) external pure override returns (uint256) { return d.length; }
    function updatePriceFeeds(bytes[] calldata) external payable override {}
}

contract MockMainframe4 is IYuzu98v2Minimal {
    mapping(uint256 => address) public override ownerOf;
    mapping(uint256 => bool) public override isGutted;
    mapping(uint256 => BoltState) public override boltState;
    mapping(uint256 => address) public getVaultAddress;

    function setUnit(uint256 id, address o, address v) external {
        ownerOf[id] = o;
        getVaultAddress[id] = v;
    }

    function boltForSaleFromVault(uint256 id) external override { boltState[id] = BoltState.BOLTED; }
    function guardianForceUnbolt(uint256 id) external override { boltState[id] = BoltState.UNBOLTED; }
    function setGuttedFromVault(uint256 id) external override { isGutted[id] = true; }
}

contract MockRegistry4 is IYuzuRegistryMinimal {
    address public router;
    mapping(address => bool) public override isPricedAsset;
    mapping(address => bool) public override isCryptoAsset;

    constructor(address r) { router = r; }

    function setAsset(address a, bool priced, bool crypto) external {
        isPricedAsset[a] = priced;
        isCryptoAsset[a] = crypto;
    }

    function routeFor(address, address) external view override returns (Route memory) {
        return Route({router: router, routerType: 1, path: "", isActive: true});
    }

    function hasActiveRoute(address, address) external pure override returns (bool) { return true; }

    function isCartridgeExecutable(address) external pure override returns (bool, uint256, uint256) {
        return (true, 0, 100e18);
    }
}

contract MockLens4 is IYuzuNavLensMinimal {
    address[] public pricedList;
    mapping(address => uint256) public prices18;
    mapping(address => uint8) public decs;

    function addAsset(address a, uint256 p18, uint8 d) external {
        if (prices18[a] == 0) pricedList.push(a);
        prices18[a] = p18;
        decs[a] = d;
    }

    function requireFresh(address a) public view override returns (uint256) {
        require(prices18[a] > 0, "STALE");
        return prices18[a];
    }

    function priceOf(address a) public view override returns (uint256, uint256) {
        return (prices18[a], block.timestamp);
    }

    function valueOf(address a, uint256 amt) public view override returns (uint256) {
        if (prices18[a] == 0 || amt == 0) return 0;
        return (amt * prices18[a]) / (10 ** decs[a]);
    }

    function quote(address tIn, address tOut, uint256 amtIn) external view override returns (uint256) {
        uint256 usd = valueOf(tIn, amtIn);
        return (usd * (10 ** decs[tOut])) / requireFresh(tOut);
    }

    function getLiquidNavUsd(address vault) public view override returns (uint256 total) {
        for (uint256 i = 0; i < pricedList.length; i++) {
            address a = pricedList[i];
            total += valueOf(a, ERC20(a).balanceOf(vault));
        }
    }

    function tryGetNav(address vault) external view override returns (uint256, uint256, bool) {
        uint256 n = getLiquidNavUsd(vault);
        return (n, n, false);
    }
}

contract MockRouter4 is IYuzuSwapRouter {
    MockLens4 public lens;
    uint256 public slippageBps = 30; // 0.30% default pool slippage/fee

    constructor(MockLens4 l) { lens = l; }
    function setSlippageBps(uint256 bps) external { slippageBps = bps; }

    function swapExactIn(
        address tIn,
        address tOut,
        uint256 amtIn,
        uint256 minOut,
        address recipient,
        bytes calldata
    ) external override returns (uint256 out) {
        ERC20(tIn).transferFrom(msg.sender, address(this), amtIn);
        uint256 fair = lens.quote(tIn, tOut, amtIn);
        out = (fair * (10000 - slippageBps)) / 10000;
        require(out >= minOut, "ROUTER_SLIPPAGE");
        MockERC20_4(tOut).mint(recipient, out);
    }
}

contract MockSocketBay4 is IYuzuSocketBayMinimal {
    MockERC20_4 public yuzu;
    MockWETH4 public weth;
    mapping(uint256 => uint256) public override romBond;
    mapping(address => uint256) public override gateBought;
    uint256 public forfeitedTokenId;

    constructor(MockERC20_4 y, MockWETH4 w) { yuzu = y; weth = w; }

    function seatBladesFromVault(uint256, uint8 blades) external override {
        yuzu.transferFrom(msg.sender, address(this), uint256(blades) * 25_000e18);
    }

    function postBondFromVault(uint256 tokenId) external override {
        yuzu.transferFrom(msg.sender, address(this), 250_000e18);
        romBond[tokenId] = 250_000e18;
    }

    function buyBufferFor(uint256, uint256 yuzuAmount, uint256 maxWethIn) external override returns (uint256 spent) {
        spent = maxWethIn / 2;
        weth.transferFrom(msg.sender, address(this), spent);
        gateBought[msg.sender] += yuzuAmount;
        yuzu.mint(msg.sender, yuzuAmount);
    }

    function forfeit(uint256 tokenId) external override returns (uint256) {
        forfeitedTokenId = tokenId;
        return 150_000e18;
    }
}

contract MockDistributor4 is IYuzuDistributorMinimal {
    uint256 public outflowCallCount;
    uint256 public lastNavNoted;
    uint256 public raidCancelledTokenId;

    function noteOutflow(uint256, uint256 navAfter) external override {
        outflowCallCount += 1;
        lastNavNoted = navAfter;
    }

    function cancelLockedCreditOnRaid(uint256 tokenId) external override returns (uint256) {
        raidCancelledTokenId = tokenId;
        return 0;
    }
}

contract MockTreasury4 is IYuzuTreasuryMinimal {
    MockWETH4 public weth;
    address public distributor;
    uint256 public buybackWeth;
    mapping(address => uint256) public feeEscrow;
    mapping(address => uint256) public salvageEscrow;

    constructor(MockWETH4 w, address d) { weth = w; distributor = d; }

    function recordProtocolFeeWeth(uint256 toDist, uint256 toBuy) external override {
        if (toDist > 0) weth.transferFrom(msg.sender, distributor, toDist);
        if (toBuy > 0) {
            weth.transferFrom(msg.sender, address(this), toBuy);
            buybackWeth += toBuy;
        }
    }

    function receiveFeeEscrow(address a, uint256 amt) external override { feeEscrow[a] += amt; }
    function receiveSalvageEscrow(address a, uint256 amt) external override { salvageEscrow[a] += amt; }
}

contract MockHook4 is IYuzuPoolHookMinimal {
    bool public override gateLifted;
    function setGateLifted(bool l) external { gateLifted = l; }
}
