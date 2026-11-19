// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared structs and interfaces for YUZU-98 Phase 6 (`YuzuSvgCrateLib`, `YuzuSvgChassisLib`, `YuzuRenderer`, v4.9).

enum SeedMode {
    US_BASKET,
    NON_US_XSTOCK
}

enum BoltState {
    UNBOLTED,
    BOLTED,
    UNBOLTING
}

struct ChassisRenderData {
    uint256 tokenId;
    uint8 grade;
    uint8 ramTier;
    uint256 ramLockedYuzu;
    uint256 romBondYuzu;
    uint256 liquidNavUsd18;
    uint256 displayNavUsd18;
    bool anyStale;
    bool isGutted;
    bool isFrozen;
    BoltState boltState;
    bool hasGuardian;
    uint256 boltEpoch;
    bool aiActive;
    SeedMode seedMode;
}

interface IYuzu98v2View {
    function grade(uint256 tokenId) external view returns (uint8);
    function isGutted(uint256 tokenId) external view returns (bool);
    function boltState(uint256 tokenId) external view returns (BoltState);
    function boltEpoch(uint256 tokenId) external view returns (uint256);
    function getVaultAddress(uint256 tokenId) external view returns (address);
}

interface IYuzuSocketBayView {
    function ramTier(uint256 tokenId) external view returns (uint8);
    function ramLocked(uint256 tokenId) external view returns (uint256);
    function romBond(uint256 tokenId) external view returns (uint256);
}

interface IYuzuNavLensView {
    function tryGetNav(address vault) external view returns (uint256 liquidNav, uint256 displayNav, bool anyStale);
}

interface IYuzuAccountView {
    function coldGuardian() external view returns (address);
    function guardianFrozen() external view returns (bool);
    function seedMode() external view returns (SeedMode);
    function aiSessionKey() external view returns (address);
    function aiSessionExpiry() external view returns (uint256);
}
