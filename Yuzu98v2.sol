// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {
    BoltState,
    IYuzuAccountMinimal,
    IYuzuCartridgeMinimal,
    IYuzuRendererMinimal
} from "./interfaces/IYuzuPhase3Interfaces.sol";

/// @title Yuzu98v2 — Contract 01 of 16 (YUZU-98 Master Specification v4.9, Sections 3, 4, 7.4, 9.2, 9.3, 10)
/// @notice Non-upgradeable ERC-721 mainframe contract (#0000 - #0999) implementing:
///         1. Two-block commit-reveal unsealing (`mod 999`) with 256-block production fallback.
///         2. Five chassis grades (`1.00x` to `2.50x` multiplier) and live `gradeCount`.
///         3. Three-state Listing Bolt (`UNBOLTED`, `BOLTED`, `UNBOLTING`), 24h unbolt freeze, and 24h re-bolt cooldown.
///         4. `guardianRecoveryTransfer` bypassing bolt state and open Slot-2 calls to the stored `recoveryAddress`.
///         5. Hard block on transferring any YUZU-98 unit into any YUZU-98 vault (`isYuzuVault`).
///         6. ERC-2981 5.00% royalty signal to `YuzuTreasury.sol`.
contract Yuzu98v2 is ERC721, IERC2981 {
    uint256 public constant MAX_FLEET = 1_000;
    uint256 public constant ROYALTY_BPS = 500; // 5.00% ERC-2981 signal
    uint256 public constant UNBOLT_DURATION = 24 hours;
    uint256 public constant REBOLT_COOLDOWN = 24 hours;

    uint8 public constant GRADE_SEALED = 0;
    uint8 public constant GRADE_PRODUCTION = 1;  // 1.00x (10000 bps)
    uint8 public constant GRADE_COMMERCIAL = 2;  // 1.25x (12500 bps)
    uint8 public constant GRADE_LABORATORY = 3;  // 1.60x (16000 bps)
    uint8 public constant GRADE_PROTOTYPE = 4;   // 2.50x (25000 bps)
    uint8 public constant GRADE_HQ_FOUNDER = 5;  // 2.50x (25000 bps, #0000 only)

    address public immutable deployer;

    address public seeder;
    address public treasury;
    address public cartridge;
    address public renderer;
    bool public coreConfigured;

    uint256 public commissionedCount;
    uint256 public firstPublicCommissionAt;

    // Deterministic vault registry (prevents any YUZU-98 unit from being transferred into any YUZU-98 vault)
    mapping(uint256 tokenId => address vault) public getVaultAddress;
    mapping(address account => bool) public isYuzuVault;

    // Hardware & unsealing state
    mapping(uint256 tokenId => uint8) public grade;
    mapping(uint8 gradeId => uint256 count) public gradeCount;
    mapping(uint256 tokenId => uint256 targetBlock) public unsealCommitBlock;
    mapping(uint256 tokenId => bool) public isGutted;

    // Listing Bolt state
    mapping(uint256 tokenId => uint256) public boltEpoch;
    mapping(uint256 tokenId => uint256) public boltedAt;
    mapping(uint256 tokenId => uint256) public unboltReadyAt;
    mapping(uint256 tokenId => uint256) public reboltAllowedAt;

    bool private _inRecoveryTransfer;

    event CoreConfigured(address seeder, address treasury, address cartridge, address renderer);
    event MainframeMinted(uint256 indexed tokenId, address indexed owner, address vault);
    event UnsealCommitted(uint256 indexed tokenId, uint256 targetBlock);
    event UnsealRevealed(uint256 indexed tokenId, uint8 grade, uint256 roll, bool windowMissed);
    event UnitBoltedForSale(uint256 indexed tokenId, uint256 boltEpoch, uint256 timestamp);
    event UnboltRequested(uint256 indexed tokenId, uint256 readyAt);
    event UnitUnbolted(uint256 indexed tokenId, bool forcedByGuardian);
    event UnitGuttedSet(uint256 indexed tokenId, bool isGutted);
    event GuardianRecoveryExecuted(uint256 indexed tokenId, address indexed from, address indexed recoveryAddress);

    error ZeroAddress();
    error OnlyDeployer();
    error AlreadyConfigured();
    error NotConfigured();
    error OnlySeeder();
    error OnlyUnitVault();
    error NotUnitOwner();
    error InvalidVaultBatch();
    error AlreadyCommittedOrUnsealed();
    error UnitNotUnbolted();
    error PendingUnsealCommit();
    error NoPendingCommit();
    error RevealTooEarly();
    error ReboltCooldownActive(uint256 allowedAt);
    error OpenSlot2CallsExist();
    error NotBoltedOrUnbolting();
    error UnboltDelayNotElapsed();
    error TransferRequiresBoltedState();
    error NoUnitInVault();
    error InvalidRecoverySignature();

    constructor() ERC721("YUZU-98 Sovereign Mainframe", "YUZU98") {
        deployer = msg.sender;
    }

    /// @notice Pre-registers deterministic ERC-6551 vault addresses in batches before locking configuration.
    function registerVaultAddresses(uint256 startTokenId, address[] calldata vaults) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (coreConfigured) revert AlreadyConfigured();
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 tokenId = startTokenId + i;
            address v = vaults[i];
            if (v == address(0) || tokenId >= MAX_FLEET) revert InvalidVaultBatch();
            getVaultAddress[tokenId] = v;
            isYuzuVault[v] = true;
        }
    }

    /// @notice One-time wiring called at deployment; permanently locks admin powers.
    function configureCore(
        address seeder_,
        address treasury_,
        address cartridge_,
        address renderer_
    ) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (coreConfigured) revert AlreadyConfigured();
        if (seeder_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        seeder = seeder_;
        treasury = treasury_;
        cartridge = cartridge_;
        renderer = renderer_;
        coreConfigured = true;
        emit CoreConfigured(seeder_, treasury_, cartridge_, renderer_);
    }

    /// @notice Alias matching IYuzuUnits interface from Phase 1.
    function isVault(address account) external view returns (bool) {
        return isYuzuVault[account];
    }

    /// @notice Returns the chassis Grade Multiplier in basis points (10000 = 1.00x, 25000 = 2.50x, 0 if sealed/gutted).
    function gradeMultiplierBps(uint256 tokenId) public view returns (uint256) {
        if (isGutted[tokenId]) return 0;
        uint8 g = grade[tokenId];
        if (g == GRADE_PRODUCTION) return 10000;
        if (g == GRADE_COMMERCIAL) return 12500;
        if (g == GRADE_LABORATORY) return 16000;
        if (g == GRADE_PROTOTYPE || g == GRADE_HQ_FOUNDER) return 25000;
        return 0;
    }

    // =========================================================================
    // 1. COMMISSIONING MINT & REFURBISHMENT HOOKS (Seeder Only)
    // =========================================================================

    function mintFromSeeder(uint256 tokenId, address to, address vault) external {
        if (msg.sender != seeder) revert OnlySeeder();
        if (!coreConfigured) revert NotConfigured();
        if (getVaultAddress[tokenId] == address(0)) {
            if (vault == address(0)) revert ZeroAddress();
            getVaultAddress[tokenId] = vault;
            isYuzuVault[vault] = true;
        }

        commissionedCount += 1;
        if (tokenId == 0) {
            grade[0] = GRADE_HQ_FOUNDER;
            gradeCount[GRADE_HQ_FOUNDER] = 1;
        } else if (firstPublicCommissionAt == 0) {
            firstPublicCommissionAt = block.timestamp;
        }

        _mint(to, tokenId);
        emit MainframeMinted(tokenId, to, getVaultAddress[tokenId]);
    }

    function setGuttedFromVault(uint256 tokenId) external {
        if (msg.sender != getVaultAddress[tokenId]) revert OnlyUnitVault();
        isGutted[tokenId] = true;
        emit UnitGuttedSet(tokenId, true);
    }

    function clearGuttedFromSeeder(uint256 tokenId) external {
        if (msg.sender != seeder) revert OnlySeeder();
        isGutted[tokenId] = false;
        emit UnitGuttedSet(tokenId, false);
    }

    // =========================================================================
    // 2. TWO-BLOCK COMMIT-REVEAL UNSEALING (mod 999, Section 3.2)
    // =========================================================================

    function commitUnseal(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotUnitOwner();
        if (grade[tokenId] != GRADE_SEALED || unsealCommitBlock[tokenId] != 0) revert AlreadyCommittedOrUnsealed();
        if (boltState(tokenId) != BoltState.UNBOLTED) revert UnitNotUnbolted();

        uint256 target = block.number + 2;
        unsealCommitBlock[tokenId] = target;
        emit UnsealCommitted(tokenId, target);
    }

    function revealUnseal(uint256 tokenId) external {
        uint256 commitBlock = unsealCommitBlock[tokenId];
        if (commitBlock == 0 || grade[tokenId] != GRADE_SEALED) revert NoPendingCommit();
        if (block.number <= commitBlock) revert RevealTooEarly();

        bytes32 bh = blockhash(commitBlock);
        uint8 resolvedGrade;
        uint256 roll;
        bool missed;

        if (bh == bytes32(0)) {
            resolvedGrade = GRADE_PRODUCTION;
            missed = true;
        } else {
            roll = uint256(keccak256(abi.encode(bh, tokenId))) % 999;
            resolvedGrade = _gradeFromRoll(roll);
        }

        grade[tokenId] = resolvedGrade;
        gradeCount[resolvedGrade] += 1;
        emit UnsealRevealed(tokenId, resolvedGrade, roll, missed);
    }

    function _gradeFromRoll(uint256 roll) internal pure returns (uint8) {
        if (roll <= 28) return GRADE_PROTOTYPE;     // 000 - 028 (29 / 999 = 2.90%)
        if (roll <= 148) return GRADE_LABORATORY;   // 029 - 148 (120 / 999 = 12.01%)
        if (roll <= 448) return GRADE_COMMERCIAL;   // 149 - 448 (300 / 999 = 30.03%)
        return GRADE_PRODUCTION;                    // 449 - 998 (550 / 999 = 55.06%)
    }

    // =========================================================================
    // 3. THREE-STATE LISTING BOLT & GUARDIAN RECOVERY (Sections 7.4, 9.2)
    // =========================================================================

    /// @notice Returns the effective BoltState of `tokenId` (automatically transitions UNBOLTING -> UNBOLTED after 24h).
    function boltState(uint256 tokenId) public view returns (BoltState) {
        BoltState s = _boltState[tokenId];
        if (s == BoltState.UNBOLTING && block.timestamp >= unboltReadyAt[tokenId]) {
            return BoltState.UNBOLTED;
        }
        return s;
    }

    mapping(uint256 tokenId => BoltState) private _boltState;

    /// @notice Called by the unit's own vault after Tier-3 authorization to bolt the unit for sale.
    function boltForSaleFromVault(uint256 tokenId) external {
        if (msg.sender != getVaultAddress[tokenId]) revert OnlyUnitVault();
        if (boltState(tokenId) != BoltState.UNBOLTED) revert UnitNotUnbolted();
        if (unsealCommitBlock[tokenId] != 0 && grade[tokenId] == GRADE_SEALED) revert PendingUnsealCommit();
        if (block.timestamp < reboltAllowedAt[tokenId]) revert ReboltCooldownActive(reboltAllowedAt[tokenId]);
        if (cartridge != address(0) && IYuzuCartridgeMinimal(cartridge).hasOpenCalls(tokenId)) {
            revert OpenSlot2CallsExist();
        }

        _boltState[tokenId] = BoltState.BOLTED;
        boltEpoch[tokenId] += 1;
        boltedAt[tokenId] = block.timestamp;
        emit UnitBoltedForSale(tokenId, boltEpoch[tokenId], block.timestamp);
    }

    /// @notice Owner requests unbolting: immediately blocks sale and starts the 24h vault/re-bolt cooldown.
    function requestUnbolt(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotUnitOwner();
        if (_boltState[tokenId] != BoltState.BOLTED) revert NotBoltedOrUnbolting();

        _boltState[tokenId] = BoltState.UNBOLTING;
        uint256 ready = block.timestamp + UNBOLT_DURATION;
        unboltReadyAt[tokenId] = ready;
        reboltAllowedAt[tokenId] = block.timestamp + REBOLT_COOLDOWN;
        emit UnboltRequested(tokenId, ready);
    }

    /// @notice Finalizes storage from UNBOLTING to UNBOLTED once the 24h window has elapsed.
    function finalizeUnbolt(uint256 tokenId) external {
        if (_boltState[tokenId] != BoltState.UNBOLTING) revert NotBoltedOrUnbolting();
        if (block.timestamp < unboltReadyAt[tokenId]) revert UnboltDelayNotElapsed();
        _boltState[tokenId] = BoltState.UNBOLTED;
        emit UnitUnbolted(tokenId, false);
    }

    /// @notice Called by the unit's vault during `guardianPanicFreeze` or `guardianForceUnbolt`.
    ///         Immediately returns a BOLTED or UNBOLTING unit to UNBOLTED and enforces the 24h re-bolt lock.
    function guardianForceUnbolt(uint256 tokenId) external {
        if (msg.sender != getVaultAddress[tokenId]) revert OnlyUnitVault();
        BoltState current = _boltState[tokenId];
        if (current == BoltState.BOLTED || current == BoltState.UNBOLTING) {
            _boltState[tokenId] = BoltState.UNBOLTED;
            unboltReadyAt[tokenId] = 0;
            reboltAllowedAt[tokenId] = block.timestamp + REBOLT_COOLDOWN;
            emit UnitUnbolted(tokenId, true);
        }
    }

    /// @notice Instant Cold Guardian recovery transfer to the pre-set `recoveryAddress` stored in the vault.
    ///         Works from ANY bolt state and even if Slot-2 covered calls are open.
    function guardianRecoveryTransfer(
        uint256 tokenId,
        address recoveryAddress,
        uint256 deadline,
        bytes calldata guardianSig
    ) external {
        if (recoveryAddress == address(0) || isYuzuVault[recoveryAddress]) revert ZeroAddress();
        if (unsealCommitBlock[tokenId] != 0 && grade[tokenId] == GRADE_SEALED) revert PendingUnsealCommit();

        address vault = getVaultAddress[tokenId];
        bool valid = IYuzuAccountMinimal(vault).verifyGuardianRecoverySig(
            recoveryAddress, tokenId, deadline, guardianSig
        );
        if (!valid) revert InvalidRecoverySignature();

        address prevOwner = ownerOf(tokenId);
        _inRecoveryTransfer = true;
        _transfer(prevOwner, recoveryAddress, tokenId);
        _inRecoveryTransfer = false;

        emit GuardianRecoveryExecuted(tokenId, prevOwner, recoveryAddress);
    }

    // =========================================================================
    // 4. TRANSFER ENFORCEMENT & CHANGE-OF-OWNER RESET (Sections 9.2, 9.3)
    // =========================================================================

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        if (isYuzuVault[to]) revert NoUnitInVault();

        from = _ownerOf(tokenId);
        // If not minting (from != address(0)), enforce Listing Bolt & reset vault authority state
        if (from != address(0)) {
            if (unsealCommitBlock[tokenId] != 0 && grade[tokenId] == GRADE_SEALED) {
                revert PendingUnsealCommit();
            }
            if (!_inRecoveryTransfer && boltState(tokenId) != BoltState.BOLTED) {
                revert TransferRequiresBoltedState();
            }

            if (_boltState[tokenId] == BoltState.BOLTED || _boltState[tokenId] == BoltState.UNBOLTING) {
                reboltAllowedAt[tokenId] = block.timestamp + REBOLT_COOLDOWN;
            }
            _boltState[tokenId] = BoltState.UNBOLTED;
            unboltReadyAt[tokenId] = 0;

            address vault = getVaultAddress[tokenId];
            if (vault != address(0) && vault.code.length > 0) {
                IYuzuAccountMinimal(vault).onNftTransferReset();
            }
            if (cartridge != address(0) && cartridge.code.length > 0) {
                IYuzuCartridgeMinimal(cartridge).clearPolicyOnTransfer(tokenId);
            }
        }

        return super._update(to, tokenId, auth);
    }

    // =========================================================================
    // 5. ERC-2981 ROYALTY SIGNAL (5.00%) & ON-CHAIN RENDERER BRIDGE
    // =========================================================================

    function royaltyInfo(uint256, uint256 salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        return (treasury, (salePrice * ROYALTY_BPS) / 10000);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (renderer == address(0)) return "";
        return IYuzuRendererMinimal(renderer).tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
