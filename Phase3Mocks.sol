// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    SeedMode,
    IWETH,
    IPythMinimal,
    IYuzuNavLensMinimal,
    IYuzuRegistryMinimal,
    IYuzuSwapRouter,
    IYuzuSocketBayMinimal,
    IYuzuTreasuryMinimal,
    IYuzuAccountMinimal,
    IYuzuCartridgeMinimal
} from "../../src/interfaces/IYuzuPhase3Interfaces.sol";

contract MockERC20 is ERC20 {
    uint8 private _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockWETH3 is MockERC20, IWETH {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}
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

contract MockPyth3 is IPythMinimal {
    function getUpdateFee(bytes[] calldata data) external pure override returns (uint256) { return data.length; }
    function updatePriceFeeds(bytes[] calldata) external payable override {}
}

contract MockLens3 is IYuzuNavLensMinimal {
    mapping(address => uint256) public prices18;
    mapping(address => uint8) public decimalsMap;
    mapping(address => uint256) public vaultNavs;

    function setAssetPrice(address asset, uint256 p18, uint8 dec) external {
        prices18[asset] = p18;
        decimalsMap[asset] = dec;
    }

    function setVaultNav(address vault, uint256 nav18) external {
        vaultNavs[vault] = nav18;
    }

    function requireFresh(address asset) public view override returns (uint256) {
        require(prices18[asset] > 0, "STALE_OR_UNPRICED");
        return prices18[asset];
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view override returns (uint256) {
        uint256 pIn = requireFresh(tokenIn);
        uint256 pOut = requireFresh(tokenOut);
        uint256 usd18 = (amountIn * pIn) / (10 ** decimalsMap[tokenIn]);
        return (usd18 * (10 ** decimalsMap[tokenOut])) / pOut;
    }

    function getLiquidNavUsd(address vault) external view override returns (uint256) {
        return vaultNavs[vault];
    }
}

contract MockRouter3 is IYuzuSwapRouter {
    MockLens3 public lens;
    uint256 public slippageBps = 30; // 0.30% simulated pool fee

    constructor(MockLens3 lens_) { lens = lens_; }

    function setSimulatedSlippageBps(uint256 bps) external { slippageBps = bps; }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 fair = lens.quote(tokenIn, tokenOut, amountIn);
        amountOut = (fair * (10000 - slippageBps)) / 10000;
        require(amountOut >= minAmountOut, "ROUTER_MIN_OUT");
        MockERC20(tokenOut).mint(recipient, amountOut);
    }
}

contract MockRegistry3 is IYuzuRegistryMinimal {
    address public router;
    constructor(address router_) { router = router_; }
    function routeFor(address, address) external view override returns (Route memory) {
        return Route({router: router, routerType: 1, path: "", isActive: true});
    }
}

contract MockSocketBay3 is IYuzuSocketBayMinimal {
    mapping(uint256 => uint8) public override ramTier;

    function setRamTier(uint256 tokenId, uint8 tier) external { ramTier[tokenId] = tier; }

    function ramMultiplierBps(uint256 tokenId) external view override returns (uint256) {
        uint8 t = ramTier[tokenId];
        return t == 0 ? 0 : 10000 + uint256(t - 1) * 2500;
    }

    function seedInitialRam(uint256 tokenId, uint8 initialTier) external override {
        ramTier[tokenId] = initialTier;
    }

    function recommissionStarterBlade(uint256 tokenId) external override {
        ramTier[tokenId] = 1;
    }

    function buyStarterBlade(uint256 tokenId, uint256) external payable override returns (uint256) {
        ramTier[tokenId] = 1;
        return msg.value;
    }
}

contract MockTreasury3 is IYuzuTreasuryMinimal {
    MockERC20 public yuzu;
    uint256 public lpWethReceived;
    uint256 public treasuryWethReceived;
    uint256 public farmToEmitPerEpoch = 1_000_000e18;

    constructor(MockERC20 yuzu_) { yuzu = yuzu_; }

    function receiveCommissioningWeth(uint256 lpWeth, uint256 treasuryWeth) external override {
        lpWethReceived += lpWeth;
        treasuryWethReceived += treasuryWeth;
    }

    function emitWeeklyFarm(uint256) external override returns (uint256) {
        if (farmToEmitPerEpoch > 0) {
            yuzu.mint(msg.sender, farmToEmitPerEpoch);
        }
        return farmToEmitPerEpoch;
    }
}

contract MockVault3 is IYuzuAccountMinimal {
    uint256 public tokenId;
    address public guardian;
    address public recovery;
    SeedMode public mode;
    mapping(address => uint256) public seedUnits;
    uint256 public resetCount;
    uint256 public lastRewardPaid;
    bool public allowRecoverySig = true;

    function initializeFromSeeder(uint256 id, address g, address r) external override {
        tokenId = id;
        guardian = g;
        recovery = r;
    }

    function recordSeed(address asset, uint256 amount, SeedMode m) external override {
        seedUnits[asset] += amount;
        mode = m;
    }

    function clearSeedStorageForRecommission() external override {}

    function verifyGuardianRecoverySig(address expectedTarget, uint256, uint256 deadline, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        return allowRecoverySig && expectedTarget == recovery && block.timestamp <= deadline;
    }

    function onNftTransferReset() external override {
        resetCount += 1;
        guardian = address(0);
        recovery = address(0);
    }

    function onRewardPaid(uint256 wethAmount) external override {
        lastRewardPaid = wethAmount;
    }
}

contract MockCartridge3 is IYuzuCartridgeMinimal {
    mapping(uint256 => bool) public override hasOpenCalls;
    mapping(uint256 => uint256) public policyClearedCount;

    function setOpenCalls(uint256 tokenId, bool open) external { hasOpenCalls[tokenId] = open; }
    function clearPolicyOnTransfer(uint256 tokenId) external override { policyClearedCount[tokenId] += 1; }
}
