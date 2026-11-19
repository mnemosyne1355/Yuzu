// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAggregatorV3, PythPrice, IPyth, IERC4626Wrapper} from "../../src/interfaces/IYuzuPhase2Interfaces.sol";

contract MockChainlinkFeed is IAggregatorV3 {
    uint8 public override decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 initialAnswer) {
        decimals = decimals_;
        answer = initialAnswer;
        updatedAt = block.timestamp;
    }

    function setRoundData(int256 newAnswer, uint256 newUpdatedAt) external {
        answer = newAnswer;
        updatedAt = newUpdatedAt;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockPyth is IPyth {
    mapping(bytes32 => PythPrice) public prices;
    uint256 public fee = 1 wei;

    function setPrice(bytes32 id, int64 price, int32 expo, uint256 publishTime) external {
        prices[id] = PythPrice({price: price, conf: 1, expo: expo, publishTime: publishTime});
    }

    function getPriceUnsafe(bytes32 id) external view override returns (PythPrice memory) {
        return prices[id];
    }

    function getUpdateFee(bytes[] calldata updateData) external view override returns (uint256) {
        return updateData.length * fee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {}
}

contract MockERC20Asset is ERC20 {
    uint8 private _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockXStockWrapper is MockERC20Asset, IERC4626Wrapper {
    address public override asset;
    uint256 public multiplierRay = 1e18; // 1.00x default, e.g. 1.05e18 after reinvested dividends

    constructor(string memory name_, string memory symbol_, uint8 dec_, address underlying_)
        MockERC20Asset(name_, symbol_, dec_)
    {
        asset = underlying_;
    }

    function decimals() public view override(MockERC20Asset, IERC4626Wrapper) returns (uint8) {
        return super.decimals();
    }

    function setMultiplier(uint256 newMultiplier18) external {
        multiplierRay = newMultiplier18;
    }

    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return (shares * multiplierRay) / 1e18;
    }
}

contract MockCartridge {
    function strategyName() external pure returns (string memory) {
        return "MockMomentum";
    }
}
