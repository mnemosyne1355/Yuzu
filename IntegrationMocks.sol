// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20_4, MockWETH4, MockLens4, MockRegistry4, MockSocketBay4} from "./Phase4Mocks.sol";

/// @notice Mocks for test/YuzuIntegration.t.sol, which runs the real YuzuAccount, YuzuAccountCompanion,
///         YuzuCartridge and YuzuTreasury against each other. Each mock here serves two real contracts at once,
///         which is what the per-phase mocks could not do.

contract MockLensI is MockLens4 {
    address public pyth;

    constructor(address pyth_) {
        pyth = pyth_;
    }

    /// @dev Sets a price without re-listing the asset. A price of 0 makes requireFresh revert (a stale feed).
    function setPriceRaw(address a, uint256 p18) external {
        prices18[a] = p18;
    }
}

contract MockRegistryI is MockRegistry4 {
    struct VenueInfo {
        bool isListed;
        bool isPaused;
        bool isLendingMarket;
        address receiptToken;
    }

    mapping(address => VenueInfo) private _venues;
    address[] private _priced;

    constructor(address router_) MockRegistry4(router_) {}

    function listPriced(address a) external {
        _priced.push(a);
    }

    function getPricedAssets() external view returns (address[] memory) {
        return _priced;
    }

    function setVenue(address v, bool listed, bool paused, bool lending, address receipt) external {
        _venues[v] = VenueInfo(listed, paused, lending, receipt);
    }

    function venues(address v) external view returns (bool, bool, bool, address) {
        VenueInfo memory info = _venues[v];
        return (info.isListed, info.isPaused, info.isLendingMarket, info.receiptToken);
    }
}

contract MockSocketBayI is MockSocketBay4 {
    mapping(uint256 => uint8) public ramTier;

    constructor(MockERC20_4 y, MockWETH4 w) MockSocketBay4(y, w) {}

    function setTier(uint256 id, uint8 t) external {
        ramTier[id] = t;
    }

    function setRomBond(uint256 id, uint256 amt) external {
        romBond[id] = amt;
    }
}

contract MockStrategyI {
    address public tokenIn;
    address public tokenOut;
    uint256 public amountIn;

    constructor(address tokenIn_, address tokenOut_, uint256 amountIn_) {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        amountIn = amountIn_;
    }

    function strategyName() external pure returns (string memory) {
        return "MOCK";
    }

    function evaluate(address, bytes calldata) external view returns (bool, address, address, uint256) {
        return (true, tokenIn, tokenOut, amountIn);
    }
}
