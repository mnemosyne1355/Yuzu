// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title YuzuSvgCrateLib — Contract 11 of 16 (YUZU-98 Master Specification v4.9, Sections 3.1, 10.1)
/// @notice External SVG library rendering State 0 Sealed Cargo Crates (`未開封`).
library YuzuSvgCrateLib {
    using Strings for uint256;

    function renderSealedCrate(uint256 tokenId, bool isBolted) external pure returns (string memory) {
        string memory serialStr = _padSerial(tokenId);
        string memory boltStatus = isBolted ? "BOLTED // READY FOR TRANSFER" : "UNBOLTED // FACTORY SEALED";

        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 420" width="100%" height="100%">',
                '<defs>',
                '<linearGradient id="crateBg" x1="0" y1="0" x2="1" y2="1">',
                '<stop offset="0%" stop-color="#1A1D24"/><stop offset="100%" stop-color="#0D0F12"/>',
                '</linearGradient>',
                '</defs>',
                '<rect width="360" height="420" fill="url(#crateBg)"/>',
                '<rect x="24" y="24" width="312" height="372" rx="8" fill="#232730" stroke="#FFB000" stroke-width="2"/>',
                '<line x1="24" y1="90" x2="336" y2="90" stroke="#FFB000" stroke-width="1" stroke-dasharray="6,4"/>',
                '<line x1="24" y1="330" x2="336" y2="330" stroke="#FFB000" stroke-width="1" stroke-dasharray="6,4"/>',
                '<text x="180" y="62" fill="#FFB000" font-family="monospace" font-size="14" font-weight="bold" text-anchor="middle">',
                'YUZU HEAVY INDUSTRIES // PC-9801 CRATE',
                '</text>',
                '<rect x="60" y="130" width="240" height="140" rx="4" fill="#121418" stroke="#4A5260" stroke-width="2"/>',
                '<text x="180" y="185" fill="#FFB000" font-family="monospace" font-size="22" font-weight="bold" text-anchor="middle">',
                'STATE 0 // SEALED',
                '</text>',
                '<text x="180" y="218" fill="#E2E8F0" font-family="monospace" font-size="14" text-anchor="middle">',
                'SERIAL #',
                serialStr,
                '</text>',
                '<text x="180" y="248" fill="#94A3B8" font-family="monospace" font-size="11" text-anchor="middle">',
                boltStatus,
                '</text>',
                '<circle cx="180" cy="365" r="6" fill="#FFB000">',
                '<animate attributeName="opacity" values="1;0.2;1" dur="2s" repeatCount="indefinite"/>',
                '</circle>',
                '</svg>'
            )
        );
    }

    function _padSerial(uint256 tokenId) internal pure returns (string memory) {
        if (tokenId < 10) return string(abi.encodePacked("000", tokenId.toString()));
        if (tokenId < 100) return string(abi.encodePacked("00", tokenId.toString()));
        if (tokenId < 1000) return string(abi.encodePacked("0", tokenId.toString()));
        return tokenId.toString();
    }
}
