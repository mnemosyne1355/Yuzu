// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {
    SeedMode,
    BoltState,
    ChassisRenderData,
    IYuzu98v2View,
    IYuzuSocketBayView,
    IYuzuNavLensView,
    IYuzuAccountView
} from "./interfaces/IYuzuPhase6Interfaces.sol";
import {YuzuSvgCrateLib} from "./libraries/YuzuSvgCrateLib.sol";
import {YuzuSvgChassisLib} from "./libraries/YuzuSvgChassisLib.sol";

/// @title YuzuRenderer — Contract 10 of 16 (YUZU-98 Master Specification v4.9, Sections 10.1, 10.2)
/// @notice Master on-chain CRT screen SVG and Base64 JSON metadata assembler.
///         - Calls `lens.tryGetNav(vault)` which never reverts; displays a `STALE` marker when any held asset feed is stale.
///         - Exposes `Vault NAV (USD)` strictly as Liquid NAV, the same number the hardware fences enforce.
contract YuzuRenderer {
    using Strings for uint256;

    IYuzu98v2View public immutable mainframe;
    IYuzuSocketBayView public immutable socketBay;
    IYuzuNavLensView public immutable lens;

    error ZeroAddress();

    constructor(address mainframe_, address socketBay_, address lens_) {
        if (mainframe_ == address(0) || socketBay_ == address(0) || lens_ == address(0)) revert ZeroAddress();
        mainframe = IYuzu98v2View(mainframe_);
        socketBay = IYuzuSocketBayView(socketBay_);
        lens = IYuzuNavLensView(lens_);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        ChassisRenderData memory d = _collectRenderData(tokenId);

        string memory svg;
        if (d.grade == 0) {
            svg = YuzuSvgCrateLib.renderSealedCrate(tokenId, d.boltState == BoltState.BOLTED);
        } else {
            string memory crtInner = _renderCrtTelemetry(d);
            svg = YuzuSvgChassisLib.renderChassisAndDeck(d, crtInner);
        }

        string memory imageUri = string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svg))));
        string memory json = _buildMetadataJson(d, imageUri);

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function _collectRenderData(uint256 tokenId) internal view returns (ChassisRenderData memory d) {
        d.tokenId = tokenId;
        d.grade = mainframe.grade(tokenId);
        d.isGutted = mainframe.isGutted(tokenId);
        d.boltState = mainframe.boltState(tokenId);
        d.boltEpoch = mainframe.boltEpoch(tokenId);
        d.ramTier = socketBay.ramTier(tokenId);
        d.ramLockedYuzu = socketBay.ramLocked(tokenId) / 1e18;
        d.romBondYuzu = socketBay.romBond(tokenId) / 1e18;

        address vault = mainframe.getVaultAddress(tokenId);
        if (vault != address(0)) {
            (d.liquidNavUsd18, d.displayNavUsd18, d.anyStale) = lens.tryGetNav(vault);
            if (vault.code.length > 0) {
                IYuzuAccountView acc = IYuzuAccountView(vault);
                try acc.coldGuardian() returns (address g) {
                    d.hasGuardian = (g != address(0));
                } catch {}
                try acc.guardianFrozen() returns (bool f) {
                    d.isFrozen = f;
                } catch {}
                try acc.seedMode() returns (SeedMode m) {
                    d.seedMode = m;
                } catch {}
                try acc.aiSessionKey() returns (address ai) {
                    if (ai != address(0)) {
                        try acc.aiSessionExpiry() returns (uint256 exp) {
                            d.aiActive = (block.timestamp <= exp);
                        } catch {}
                    }
                } catch {}
            }
        }
    }

    function _renderCrtTelemetry(ChassisRenderData memory d) internal pure returns (string memory) {
        string memory pColor = YuzuSvgChassisLib.phosphorColor(d.grade);
        string memory gName = YuzuSvgChassisLib.gradeName(d.grade);
        uint256 navDollars = d.liquidNavUsd18 / 1e18;
        string memory staleTag = d.anyStale ? " [STALE]" : " [LIVE]";
        string memory secState = _securityStateString(d);
        string memory guardTag = d.hasGuardian ? "GUARDIAN: BOUND" : "GUARDIAN: UNBOUND";

        // Oscilloscope waveform: flatline if gutted, animated phosphor wave if live
        string memory wave = d.isGutted
            ? string(abi.encodePacked('<line x1="56" y1="186" x2="304" y2="186" stroke="#EF4444" stroke-width="2"/>'))
            : string(
                abi.encodePacked(
                    '<polyline fill="none" stroke="',
                    pColor,
                    '" stroke-width="2" points="56,186 90,170 125,198 160,164 195,194 230,172 265,190 304,186"/>'
                )
            );

        return string(
            abi.encodePacked(
                '<text x="58" y="58" fill="',
                pColor,
                '" font-family="monospace" font-size="11" font-weight="bold">YUZU-98 #',
                d.tokenId.toString(),
                " // ",
                gName,
                '</text>',
                '<text x="58" y="84" fill="',
                pColor,
                '" font-family="monospace" font-size="13" font-weight="bold">LIQUID NAV: $',
                navDollars.toString(),
                staleTag,
                '</text>',
                '<text x="58" y="108" fill="',
                pColor,
                '" font-family="monospace" font-size="10">RAM: T',
                uint256(d.ramTier).toString(),
                " (",
                d.ramLockedYuzu.toString(),
                " YUZU)</text>",
                '<text x="58" y="128" fill="',
                pColor,
                '" font-family="monospace" font-size="10">STATE: ',
                secState,
                '</text>',
                '<text x="58" y="148" fill="',
                pColor,
                '" font-family="monospace" font-size="10">',
                guardTag,
                '</text>',
                wave
            )
        );
    }

    function _buildMetadataJson(ChassisRenderData memory d, string memory imageUri)
        internal
        pure
        returns (string memory)
    {
        string memory gName = YuzuSvgChassisLib.gradeName(d.grade);
        string memory modeStr = d.seedMode == SeedMode.US_BASKET ? "US_BASKET" : "NON_US_XSTOCK";
        string memory secState = _securityStateString(d);
        string memory guardStr = d.hasGuardian ? "BOUND" : "UNBOUND";
        string memory aiStr = d.aiActive ? "ACTIVE" : "INACTIVE";
        uint256 navDollars = d.liquidNavUsd18 / 1e18;

        return string(
            abi.encodePacked(
                '{"name":"YUZU-98 #',
                d.tokenId.toString(),
                " // ",
                gName,
                '","description":"Yuzu Heavy Industries (A Division of Yuzu Corp) - ERC-6551 Sovereign Multi-Asset Mainframe on Ink L2.","image":"',
                imageUri,
                '","animation_url":"',
                imageUri,
                '","attributes":[',
                '{"trait_type":"Chassis Grade","value":"',
                gName,
                '"},{"trait_type":"Seed Mode","value":"',
                modeStr,
                '"},{"trait_type":"RAM Bank Tier","value":"Tier ',
                uint256(d.ramTier).toString(),
                '"},{"trait_type":"RAM Locked ($YUZU)","display_type":"number","value":',
                d.ramLockedYuzu.toString(),
                '},{"trait_type":"ROM Bond ($YUZU)","display_type":"number","value":',
                d.romBondYuzu.toString(),
                '},{"trait_type":"Vault NAV (USD)","display_type":"number","value":',
                navDollars.toString(),
                '},{"trait_type":"Security State","value":"',
                secState,
                '"},{"trait_type":"Guardian","value":"',
                guardStr,
                '"},{"trait_type":"Bolt Epoch","display_type":"number","value":',
                d.boltEpoch.toString(),
                '},{"trait_type":"AI Co-Processor","value":"',
                aiStr,
                '"}]}'
            )
        );
    }

    function _securityStateString(ChassisRenderData memory d) internal pure returns (string memory) {
        if (d.isGutted) return "GUTTED";
        if (d.isFrozen) return "FROZEN";
        if (d.boltState == BoltState.BOLTED) return "BOLTED";
        if (d.boltState == BoltState.UNBOLTING) return "UNBOLTING";
        return "UNBOLTED";
    }
}
