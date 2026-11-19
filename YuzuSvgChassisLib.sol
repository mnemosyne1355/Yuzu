// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ChassisRenderData} from "../interfaces/IYuzuPhase6Interfaces.sol";

/// @title YuzuSvgChassisLib — Contract 12 of 16 (YUZU-98 Master Specification v4.9, Sections 4.1, 10.1)
/// @notice External SVG library rendering the physical bezel and lower CPU deck of the 5 unsealed PC-9801 chassis grades:
///         - Grade 5 HQ_MAINFRAME (#0000): Matte Obsidian housing, 24K Gold sweep, gold rivets/keylock/eject buttons.
///         - Grade 4 PROTOTYPE: Brushed Titanium housing, Prototype sweep (4.5s), cyan phosphor (#00E5FF).
///         - Grade 3 LABORATORY: 1998 SGI Cleanroom Ceramic Teal-Cobalt (#2C5C70), neon-green CRT (#33FF77).
///         - Grade 2 COMMERCIAL: Gunmetal Slate (#2E3238), warm cream-amber CRT (#FFF0C2).
///         - Grade 1 PRODUCTION: Classic 1998 NEC Warm Beige (#DFD9CA), classic Yuzu amber CRT (#FFB000).
///         Also renders the centered swivel pedestal (x=180), Dual 3.5" Floppy Disk Drives (A: & B:),
///         the 5-socket RAM bank LEDs, and the physical `|` / `O` power rocker switch.
library YuzuSvgChassisLib {
    using Strings for uint256;

    function gradeName(uint8 grade) public pure returns (string memory) {
        if (grade == 5) return "HQ_MAINFRAME";
        if (grade == 4) return "PROTOTYPE";
        if (grade == 3) return "LABORATORY";
        if (grade == 2) return "COMMERCIAL";
        if (grade == 1) return "PRODUCTION";
        return "SEALED";
    }

    function phosphorColor(uint8 grade) public pure returns (string memory) {
        if (grade == 5) return "#FFD700"; // 24K Gold phosphor for #0000
        if (grade == 4) return "#00E5FF"; // Cyan phosphor
        if (grade == 3) return "#33FF77"; // Neon-green phosphor
        if (grade == 2) return "#FFF0C2"; // Cream-amber phosphor
        return "#FFB000";                 // Classic Yuzu amber phosphor
    }

    function housingColor(uint8 grade) public pure returns (string memory) {
        if (grade == 5) return "#141418"; // Matte Obsidian
        if (grade == 4) return "#7A828C"; // Brushed Titanium
        if (grade == 3) return "#2C5C70"; // SGI Cleanroom Ceramic Teal-Cobalt
        if (grade == 2) return "#2E3238"; // Gunmetal Slate
        return "#DFD9CA";                 // Classic 1998 NEC Warm Beige
    }

    function renderChassisAndDeck(ChassisRenderData memory d, string memory innerCrtSvg)
        external
        pure
        returns (string memory)
    {
        string memory hColor = housingColor(d.grade);
        string memory pColor = phosphorColor(d.grade);
        string memory accentColor = d.grade == 5 ? "#FFD700" : "#475569";

        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 420" width="100%" height="100%">',
                _renderDefs(d.grade),
                '<rect width="360" height="420" fill="#0B0D10"/>',
                // Upper CRT Monitor Bezel
                '<rect x="28" y="18" width="304" height="236" rx="10" fill="',
                hColor,
                '" stroke="',
                accentColor,
                '" stroke-width="2"/>',
                // Inner CRT Screen Recess
                '<rect x="44" y="34" width="272" height="196" rx="6" fill="#080A0C" stroke="#1E293B" stroke-width="2"/>',
                innerCrtSvg,
                // Centered Monitor-to-Deck Swivel Pedestal (x=180)
                '<rect x="130" y="254" width="100" height="16" fill="',
                hColor,
                '" stroke="',
                accentColor,
                '" stroke-width="1.5"/>',
                '<line x1="180" y1="254" x2="180" y2="270" stroke="',
                accentColor,
                '" stroke-width="1"/>',
                // Lower CPU Deck & NEC C-Bus Backplane
                _renderLowerCpuDeck(d, hColor, pColor, accentColor),
                _renderSweepOverlay(d.grade),
                '</svg>'
            )
        );
    }

    function _renderDefs(uint8 grade) internal pure returns (string memory) {
        if (grade == 5) {
            return '<defs><linearGradient id="goldSweep" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#FFD700" stop-opacity="0.22"/><stop offset="50%" stop-color="#FFF8DC" stop-opacity="0.0"/><stop offset="100%" stop-color="#FFD700" stop-opacity="0.18"/></linearGradient></defs>';
        }
        if (grade == 4) {
            return '<defs><linearGradient id="protoSweep" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#00E5FF" stop-opacity="0.18"/><stop offset="100%" stop-color="#00E5FF" stop-opacity="0.0"/></linearGradient></defs>';
        }
        return "";
    }

    function _renderLowerCpuDeck(
        ChassisRenderData memory d,
        string memory hColor,
        string memory pColor,
        string memory accentColor
    ) internal pure returns (string memory) {
        string memory powerLabel = d.isGutted ? "O // OFF" : "| // 98MHz";
        string memory powerLed = d.isGutted ? "#EF4444" : pColor;

        return string(
            abi.encodePacked(
                '<rect x="20" y="270" width="320" height="126" rx="6" fill="',
                hColor,
                '" stroke="',
                accentColor,
                '" stroke-width="2"/>',
                // Dual 3.5" Floppy Disk Drives (A: & B:)
                '<rect x="210" y="284" width="114" height="22" rx="2" fill="#181B20" stroke="',
                accentColor,
                '" stroke-width="1"/>',
                '<text x="218" y="299" fill="#94A3B8" font-family="monospace" font-size="9">A:</text>',
                '<rect x="304" y="290" width="14" height="10" fill="',
                accentColor,
                '"/>',
                '<rect x="210" y="312" width="114" height="22" rx="2" fill="#181B20" stroke="',
                accentColor,
                '" stroke-width="1"/>',
                '<text x="218" y="327" fill="#94A3B8" font-family="monospace" font-size="9">B:</text>',
                '<rect x="304" y="318" width="14" height="10" fill="',
                accentColor,
                '"/>',
                // 5-Socket RAM Bank (T1..T5 LEDs)
                _renderRamBankLeds(d.ramTier, d.isGutted, pColor),
                // Physical Power Rocker Switch (`|` / `O`)
                '<rect x="34" y="284" width="68" height="36" rx="3" fill="#14171C" stroke="',
                powerLed,
                '" stroke-width="1.5"/>',
                '<text x="68" y="306" fill="',
                powerLed,
                '" font-family="monospace" font-size="9" font-weight="bold" text-anchor="middle">',
                powerLabel,
                '</text>'
            )
        );
    }

    function _renderRamBankLeds(uint8 ramTier, bool isGutted, string memory activeColor)
        internal
        pure
        returns (string memory)
    {
        bytes memory leds;
        for (uint8 i = 1; i <= 5; i++) {
            uint256 x = 34 + uint256(i - 1) * 28;
            bool lit = !isGutted && (ramTier >= i);
            string memory fill = lit ? activeColor : "#1E242B";
            leds = abi.encodePacked(
                leds,
                '<rect x="',
                x.toString(),
                '" y="346" width="22" height="32" rx="2" fill="',
                fill,
                '" stroke="#334155" stroke-width="1"/>'
            );
        }
        return string(leds);
    }

    function _renderSweepOverlay(uint8 grade) internal pure returns (string memory) {
        if (grade == 5) {
            return '<rect x="28" y="18" width="304" height="236" rx="10" fill="url(#goldSweep)" pointer-events="none"/>';
        }
        if (grade == 4) {
            return '<rect x="28" y="18" width="304" height="236" rx="10" fill="url(#protoSweep)" pointer-events="none"><animate attributeName="opacity" values="0.3;1;0.3" dur="4.5s" repeatCount="indefinite"/></rect>';
        }
        return "";
    }
}
