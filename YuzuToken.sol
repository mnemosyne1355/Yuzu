// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title YuzuToken ($YUZU) — Contract 14 of 16 (YUZU-98 Master Specification v4.9)
/// @notice Plain, non-upgradeable ERC-20 on Ink with a fixed 1,000,000,000 supply.
///         Has no transfer rules, no owner, no admin, and no mint function.
///         The Launch Gate is enforced by YuzuPoolHook.sol on the Uniswap v4 pool.
contract YuzuToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    error ZeroAddress();

    constructor(address initialRecipient) ERC20("Yuzu", "YUZU") {
        if (initialRecipient == address(0)) revert ZeroAddress();
        _mint(initialRecipient, TOTAL_SUPPLY);
    }
}
