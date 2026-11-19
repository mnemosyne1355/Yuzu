// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IWETH,
    IPythMinimal,
    IYuzuNavLensMinimal,
    IYuzuSocketBayMinimal,
    IYuzuTreasuryMinimal,
    IYuzuAccountMinimal
} from "./interfaces/IYuzuPhase3Interfaces.sol";
import {Yuzu98v2} from "./Yuzu98v2.sol";

/// @title YuzuDistributor — Contract 08 of 16 (YUZU-98 Master Specification v4.9, Sections 2.1, 2.4, 9.1)
/// @notice Non-upgradeable Weekly Epoch Reward Pool and 26-Week Locked Farm Credit Ledger.
///         - Releases 4.00% of its free WETH balance and 4.00% of its free $YUZU balance each 7-day epoch.
///         - Enforces the 6-hour checkpoint window, $10,000 NAV cap, and Priced-only `noteOutflow()` ratchet
///           (updating unclosed prior epochs if an outflow occurs during the 6-hour boundary window).
///         - Pulls weekly $YUZU farm emissions from `YuzuTreasury` (under the 1:1 Farm Gate) and credits them
///           by `farmWeight` (`EpochWeight * FoundingSerialMultiplier`, #0000 excluded) under a strict 26-week lock.
///         - Cancels locked farm credit on Seed Raid (`cancelLockedCreditOnRaid`) and routes that $YUZU into
///           the active reward pool.
contract YuzuDistributor is ReentrancyGuard {
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant CHECKPOINT_WINDOW = 6 hours;
    uint256 public constant RELEASE_BPS = 400;               // 4.00% of pool per epoch
    uint256 public constant NAV_CAP_USD = 10_000e18;         // $10,000 cap per unit
    uint256 public constant CLAIM_EXPIRY_EPOCHS = 8;         // Unclaimed shares return to pool after 8 epochs
    uint256 public constant FARM_LOCK_EPOCHS = 26;           // 26-week strict lock on farm credit

    Yuzu98v2 public immutable mainframe;
    IYuzuSocketBayMinimal public immutable socketBay;
    IYuzuTreasuryMinimal public immutable treasury;
    IYuzuNavLensMinimal public immutable lens;
    IPythMinimal public immutable pyth;
    IWETH public immutable weth;
    IERC20 public immutable yuzuToken;

    uint256 public epoch1Start;

    // Accounting for locked farm credits and unclaimed epoch pools so 4% release applies only to free pool balances
    uint256 public totalLockedFarmCredit;
    uint256 public totalUnclaimedWeth;
    uint256 public totalUnclaimedYuzu;
    uint256 public totalUnclaimedFarmYuzu;

    struct EpochPool {
        bool finalized;
        uint256 totalWeight;
        uint256 totalFarmWeight;
        uint256 wethReleased;
        uint256 yuzuReleased;
        uint256 farmYuzuEmitted;
        uint256 wethClaimed;
        uint256 yuzuClaimed;
        uint256 farmYuzuClaimed;
        bool expiredSwept;
    }

    mapping(uint256 epoch => EpochPool) public epochPools;

    // Per-epoch, per-unit checkpoint & weight records
    mapping(uint256 epoch => mapping(uint256 tokenId => bool)) public hasOpeningCheckpoint;
    mapping(uint256 epoch => mapping(uint256 tokenId => bool)) public isClosed;
    mapping(uint256 epoch => mapping(uint256 tokenId => uint256)) public qualifyingNav;
    mapping(uint256 epoch => mapping(uint256 tokenId => uint8)) public openingRamTier;
    mapping(uint256 epoch => mapping(uint256 tokenId => uint256)) public unitWeight;
    mapping(uint256 epoch => mapping(uint256 tokenId => uint256)) public unitFarmWeight;
    mapping(uint256 epoch => mapping(uint256 tokenId => bool)) public epochClaimed;

    // Farm credit ledger: epoch => tokenId => locked $YUZU credit
    mapping(uint256 epoch => mapping(uint256 tokenId => uint256)) public farmCredit;
    mapping(uint256 epoch => mapping(uint256 tokenId => bool)) public farmCreditReleased;
    mapping(uint256 tokenId => uint256[]) private _unitCreditEpochs;

    event Epoch1Initialized(uint256 epoch1Start);
    event UnitCheckpointed(uint256 indexed epoch, uint256 indexed tokenId, uint256 closedWeight, uint256 newOpeningNav);
    event OutflowNoted(uint256 indexed epoch, uint256 indexed tokenId, uint256 navAfter);
    event EpochFinalized(uint256 indexed epoch, uint256 wethReleased, uint256 yuzuReleased, uint256 farmEmitted, uint256 totalWeight);
    event EpochRewardClaimed(uint256 indexed epoch, uint256 indexed tokenId, address indexed vault, uint256 wethPaid, uint256 yuzuPaid, uint256 farmCredited);
    event FarmCreditUnlocked(uint256 indexed tokenId, address indexed vault, uint256 yuzuUnlocked);
    event RaidCreditCancelled(uint256 indexed tokenId, uint256 cancelledYuzuToPool);

    error ZeroAddress();
    error Epoch1NotStarted();
    error OutsideCheckpointWindow();
    error EpochWindowStillOpen();
    error OnlyUnitVault();
    error AlreadyClaimed();
    error ClaimExpired();
    error NothingToClaim();
    error InsufficientEthSent();
    error EthRefundFailed();

    constructor(
        address mainframe_,
        address socketBay_,
        address treasury_,
        address lens_,
        address pyth_,
        address weth_,
        address yuzuToken_
    ) {
        if (
            mainframe_ == address(0) || socketBay_ == address(0) || treasury_ == address(0)
                || lens_ == address(0) || pyth_ == address(0) || weth_ == address(0) || yuzuToken_ == address(0)
        ) revert ZeroAddress();

        mainframe = Yuzu98v2(mainframe_);
        socketBay = IYuzuSocketBayMinimal(socketBay_);
        treasury = IYuzuTreasuryMinimal(treasury_);
        lens = IYuzuNavLensMinimal(lens_);
        pyth = IPythMinimal(pyth_);
        weth = IWETH(weth_);
        yuzuToken = IERC20(yuzuToken_);
    }

    /// @notice Initializes `epoch1Start` to the first 7-day boundary after the first public commissioning (#0001).
    function syncEpoch1Start() public {
        if (epoch1Start != 0) return;
        uint256 firstPub = mainframe.firstPublicCommissionAt();
        if (firstPub != 0) {
            epoch1Start = ((firstPub / EPOCH_DURATION) + 1) * EPOCH_DURATION;
            emit Epoch1Initialized(epoch1Start);
        }
    }

    /// @notice Returns the current epoch number (0 before Epoch 1 opens, 1 during Epoch 1, etc.).
    function currentEpoch() public view returns (uint256) {
        uint256 start = epoch1Start;
        if (start == 0) {
            uint256 firstPub = mainframe.firstPublicCommissionAt();
            if (firstPub == 0) return 0;
            start = ((firstPub / EPOCH_DURATION) + 1) * EPOCH_DURATION;
        }
        if (block.timestamp < start) return 0;
        return ((block.timestamp - start) / EPOCH_DURATION) + 1;
    }

    /// @notice Returns the founding-serial farm multiplier in basis points (Section 2.4):
    ///         #0000 = 0 (excluded from farm), #0001-#0100 = 3.0x (30000), #0101-#0250 = 2.0x (20000),
    ///         #0251-#0500 = 1.5x (15000), #0501-#0999 = 1.0x (10000).
    function foundingSerialMultiplierBps(uint256 tokenId) public pure returns (uint256) {
        if (tokenId == 0) return 0;
        if (tokenId <= 100) return 30000;
        if (tokenId <= 250) return 20000;
        if (tokenId <= 500) return 15000;
        return 10000;
    }

    // =========================================================================
    // 1. CHECKPOINTS & PRICED-ONLY OUTFLOW RATCHET (Section 2.1)
    // =========================================================================

    /// @notice Callable by anyone during the 6-hour boundary window opening Epoch `ep` (closing Epoch `ep - 1`).
    function checkpoint(uint256 tokenId) external {
        syncEpoch1Start();
        if (epoch1Start == 0 || block.timestamp < epoch1Start) revert Epoch1NotStarted();

        uint256 ep = currentEpoch();
        uint256 boundaryStart = epoch1Start + (ep - 1) * EPOCH_DURATION;
        if (block.timestamp > boundaryStart + CHECKPOINT_WINDOW) revert OutsideCheckpointWindow();

        address vault = mainframe.getVaultAddress(tokenId);
        uint256 liveNav = (vault == address(0) || mainframe.isGutted(tokenId) || mainframe.grade(tokenId) == 0)
            ? 0
            : lens.getLiquidNavUsd(vault);

        uint256 closedWeight = 0;

        // 1. Close Epoch (ep - 1) if the unit had an opening checkpoint in (ep - 1)
        if (ep > 1) {
            uint256 prevEp = ep - 1;
            if (hasOpeningCheckpoint[prevEp][tokenId] && !isClosed[prevEp][tokenId]) {
                isClosed[prevEp][tokenId] = true;
                uint256 qNav = qualifyingNav[prevEp][tokenId];
                if (liveNav < qNav) {
                    qNav = liveNav;
                    qualifyingNav[prevEp][tokenId] = liveNav;
                }
                if (qNav > NAV_CAP_USD) qNav = NAV_CAP_USD;

                uint256 gMult = mainframe.gradeMultiplierBps(tokenId);
                uint8 rTier = openingRamTier[prevEp][tokenId];
                uint256 rMult = rTier == 0 ? 0 : (10000 + uint256(rTier - 1) * 2500);

                if (!mainframe.isGutted(tokenId) && gMult > 0 && rMult > 0 && qNav > 0) {
                    closedWeight = (qNav * gMult * rMult) / 1e8;
                    unitWeight[prevEp][tokenId] = closedWeight;
                    epochPools[prevEp].totalWeight += closedWeight;

                    uint256 fMult = foundingSerialMultiplierBps(tokenId);
                    if (fMult > 0) {
                        uint256 fWeight = (closedWeight * fMult) / 10000;
                        unitFarmWeight[prevEp][tokenId] = fWeight;
                        epochPools[prevEp].totalFarmWeight += fWeight;
                    }
                }
            }
        }

        // 2. Open Epoch `ep` for `tokenId`
        if (!hasOpeningCheckpoint[ep][tokenId]) {
            hasOpeningCheckpoint[ep][tokenId] = true;
            qualifyingNav[ep][tokenId] = liveNav;
            openingRamTier[ep][tokenId] = socketBay.ramTier(tokenId);
        }

        emit UnitCheckpointed(ep, tokenId, closedWeight, liveNav);
    }

    /// @notice Called by `YuzuAccount` at the end of every Tier-2 withdrawal and every Priced ERC-20 Tier-3 withdrawal.
    ///         Updates both the closing epoch (if unclosed during the 6h window) and the current epoch.
    function noteOutflow(uint256 tokenId, uint256 navAfter) external {
        if (msg.sender != mainframe.getVaultAddress(tokenId)) revert OnlyUnitVault();
        uint256 ep = currentEpoch();
        if (ep == 0) return;

        if (ep > 1) {
            uint256 prevEp = ep - 1;
            if (hasOpeningCheckpoint[prevEp][tokenId] && !isClosed[prevEp][tokenId]) {
                if (navAfter < qualifyingNav[prevEp][tokenId]) {
                    qualifyingNav[prevEp][tokenId] = navAfter;
                }
            }
        }

        if (hasOpeningCheckpoint[ep][tokenId] && navAfter < qualifyingNav[ep][tokenId]) {
            qualifyingNav[ep][tokenId] = navAfter;
        }

        emit OutflowNoted(ep, tokenId, navAfter);
    }

    // =========================================================================
    // 2. EPOCH FINALIZATION, CLAIMS & 26-WEEK FARM CREDIT LEDGER
    // =========================================================================

    /// @notice Finalizes closed Epoch `epoch` once its closing 6-hour checkpoint window has ended.
    function finalizeEpoch(uint256 epoch) public {
        EpochPool storage p = epochPools[epoch];
        if (p.finalized) return;

        syncEpoch1Start();
        uint256 curEp = currentEpoch();
        if (epoch == 0 || curEp <= epoch) revert EpochWindowStillOpen();

        uint256 closeWindowEnd = epoch1Start + epoch * EPOCH_DURATION + CHECKPOINT_WINDOW;
        if (block.timestamp <= closeWindowEnd) revert EpochWindowStillOpen();

        p.finalized = true;
        if (p.totalWeight == 0) return;

        uint256 freeWeth = _freeWethBalance();
        uint256 freeYuzu = _freeYuzuBalance();

        uint256 wethRel = (freeWeth * RELEASE_BPS) / 10000;
        uint256 yuzuRel = (freeYuzu * RELEASE_BPS) / 10000;

        p.wethReleased = wethRel;
        p.yuzuReleased = yuzuRel;
        totalUnclaimedWeth += wethRel;
        totalUnclaimedYuzu += yuzuRel;

        if (p.totalFarmWeight > 0) {
            uint256 farmEmitted = treasury.emitWeeklyFarm(epoch);
            p.farmYuzuEmitted = farmEmitted;
            totalUnclaimedFarmYuzu += farmEmitted;
        }

        emit EpochFinalized(epoch, wethRel, yuzuRel, p.farmYuzuEmitted, p.totalWeight);
    }

    /// @notice Permissionless claim for `tokenId` in closed `epoch`.
    ///         Pays WETH and $YUZU directly to the unit's vault, triggers `vault.onRewardPaid(wethPaid)`
    ///         (which auto-compounds inside a non-reverting try/catch), and records 26-week locked farm credit.
    function claim(uint256 epoch, uint256 tokenId, bytes[] calldata pythUpdateData) external payable nonReentrant {
        if (!epochPools[epoch].finalized) {
            finalizeEpoch(epoch);
        }
        EpochPool storage p = epochPools[epoch];
        if (epochClaimed[epoch][tokenId]) revert AlreadyClaimed();

        uint256 curEp = currentEpoch();
        if (curEp > epoch + CLAIM_EXPIRY_EPOCHS) revert ClaimExpired();

        uint256 uWeight = unitWeight[epoch][tokenId];
        if (uWeight == 0 || p.totalWeight == 0) revert NothingToClaim();

        epochClaimed[epoch][tokenId] = true;

        uint256 fee = 0;
        if (pythUpdateData.length > 0) {
            fee = pyth.getUpdateFee(pythUpdateData);
            if (msg.value < fee) revert InsufficientEthSent();
            pyth.updatePriceFeeds{value: fee}(pythUpdateData);
        }
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            if (!ok) revert EthRefundFailed();
        }

        uint256 wethShare = (p.wethReleased * uWeight) / p.totalWeight;
        uint256 yuzuShare = (p.yuzuReleased * uWeight) / p.totalWeight;

        p.wethClaimed += wethShare;
        p.yuzuClaimed += yuzuShare;
        totalUnclaimedWeth = totalUnclaimedWeth >= wethShare ? totalUnclaimedWeth - wethShare : 0;
        totalUnclaimedYuzu = totalUnclaimedYuzu >= yuzuShare ? totalUnclaimedYuzu - yuzuShare : 0;

        address vault = mainframe.getVaultAddress(tokenId);
        if (wethShare > 0) weth.transfer(vault, wethShare);
        if (yuzuShare > 0) yuzuToken.transfer(vault, yuzuShare);

        // Record 26-week locked farm credit (or forfeit directly to free pool if unit was gutted before claiming)
        uint256 fCredited = 0;
        uint256 fWeight = unitFarmWeight[epoch][tokenId];
        if (fWeight > 0 && p.farmYuzuEmitted > 0 && p.totalFarmWeight > 0) {
            uint256 farmShare = (p.farmYuzuEmitted * fWeight) / p.totalFarmWeight;
            if (farmShare > 0) {
                p.farmYuzuClaimed += farmShare;
                totalUnclaimedFarmYuzu = totalUnclaimedFarmYuzu >= farmShare ? totalUnclaimedFarmYuzu - farmShare : 0;
                if (mainframe.isGutted(tokenId)) {
                    emit RaidCreditCancelled(tokenId, farmShare);
                } else {
                    fCredited = farmShare;
                    farmCredit[epoch][tokenId] = farmShare;
                    totalLockedFarmCredit += farmShare;
                    _unitCreditEpochs[tokenId].push(epoch);
                }
            }
        }

        // Trigger vault auto-compound hook (non-reverting)
        if (wethShare > 0 && vault.code.length > 0) {
            try IYuzuAccountMinimal(vault).onRewardPaid(wethShare) {} catch {}
        }

        emit EpochRewardClaimed(epoch, tokenId, vault, wethShare, yuzuShare, fCredited);
    }

    /// @notice Sweeps unclaimed shares from an epoch older than 8 epochs back into the active reward pool.
    function sweepExpiredEpoch(uint256 epoch) external {
        EpochPool storage p = epochPools[epoch];
        if (!p.finalized || p.expiredSwept) revert NothingToClaim();
        if (currentEpoch() <= epoch + CLAIM_EXPIRY_EPOCHS) revert EpochWindowStillOpen();

        p.expiredSwept = true;
        uint256 remWeth = p.wethReleased - p.wethClaimed;
        uint256 remYuzu = p.yuzuReleased - p.yuzuClaimed;
        uint256 remFarm = p.farmYuzuEmitted - p.farmYuzuClaimed;

        totalUnclaimedWeth = totalUnclaimedWeth >= remWeth ? totalUnclaimedWeth - remWeth : 0;
        totalUnclaimedYuzu = totalUnclaimedYuzu >= remYuzu ? totalUnclaimedYuzu - remYuzu : 0;
        totalUnclaimedFarmYuzu = totalUnclaimedFarmYuzu >= remFarm ? totalUnclaimedFarmYuzu - remFarm : 0;
    }

    /// @notice Releases all farm credit for `tokenId` that was earned at least 26 epochs ago to the unit's vault.
    function releaseCredit(uint256 tokenId) external nonReentrant returns (uint256 totalUnlocked) {
        uint256 curEp = currentEpoch();
        uint256[] storage epochs = _unitCreditEpochs[tokenId];

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 ep = epochs[i];
            if (!farmCreditReleased[ep][tokenId] && curEp >= ep + FARM_LOCK_EPOCHS) {
                uint256 amt = farmCredit[ep][tokenId];
                if (amt > 0) {
                    farmCreditReleased[ep][tokenId] = true;
                    farmCredit[ep][tokenId] = 0;
                    totalUnlocked += amt;
                }
            }
        }

        if (totalUnlocked == 0) revert NothingToClaim();
        totalLockedFarmCredit = totalLockedFarmCredit >= totalUnlocked ? totalLockedFarmCredit - totalUnlocked : 0;

        address vault = mainframe.getVaultAddress(tokenId);
        yuzuToken.transfer(vault, totalUnlocked);

        emit FarmCreditUnlocked(tokenId, vault, totalUnlocked);
    }

    /// @notice Called by the unit's vault during Seed Raid (`decommissionAndRaidSeed`):
    ///         Cancels all farm credit that has not yet reached its 26-week unlock date;
    ///         that $YUZU becomes part of the free reward pool for active machines.
    function cancelLockedCreditOnRaid(uint256 tokenId) external returns (uint256 cancelled) {
        if (msg.sender != mainframe.getVaultAddress(tokenId)) revert OnlyUnitVault();
        uint256 curEp = currentEpoch();
        uint256[] storage epochs = _unitCreditEpochs[tokenId];

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 ep = epochs[i];
            if (!farmCreditReleased[ep][tokenId] && curEp < ep + FARM_LOCK_EPOCHS) {
                uint256 amt = farmCredit[ep][tokenId];
                if (amt > 0) {
                    farmCreditReleased[ep][tokenId] = true;
                    farmCredit[ep][tokenId] = 0;
                    cancelled += amt;
                }
            }
        }

        if (cancelled > 0) {
            totalLockedFarmCredit = totalLockedFarmCredit >= cancelled ? totalLockedFarmCredit - cancelled : 0;
            emit RaidCreditCancelled(tokenId, cancelled);
        }
    }

    function _freeWethBalance() internal view returns (uint256) {
        uint256 bal = weth.balanceOf(address(this));
        return bal > totalUnclaimedWeth ? bal - totalUnclaimedWeth : 0;
    }

    function _freeYuzuBalance() internal view returns (uint256) {
        uint256 bal = yuzuToken.balanceOf(address(this));
        uint256 reserved = totalLockedFarmCredit + totalUnclaimedYuzu + totalUnclaimedFarmYuzu;
        return bal > reserved ? bal - reserved : 0;
    }
}
