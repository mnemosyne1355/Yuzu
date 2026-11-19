# YUZU-98 v4.9 contracts: review findings (updated 2026-11-17 14:24Z)

Source: argon's 16 contracts + 6 test files uploaded to the file root on 2026-11-17. This folder holds the same code with the fixes listed below. The root uploads are unchanged.

Update 2026-11-18 02:54Z: 38 of 38 tests pass with argon's third deploy script (two fixes, marked in the file). `test/YuzuFull17Integration.t.sol` now has 4 tests: full vaults, 1,000 EIP-1167 vault clones, `run()` from the environment with the hook mined to 0x2880 through the CREATE2 factory, and the revert when #0000 cannot be paid for; each deploy also commissions public unit #0001. Vault clones are new behaviour AWAITING FOUNDER REVIEW (they use `delegatecall`). Open items in `script/DEPLOY_SCRIPT_NOTES.md` section 5.

Update 2026-11-18 01:06Z: 35 of 35 tests pass. The new one is `test/YuzuFull17Integration.t.sol` (argon's, with fixes), which runs `script/DeployYuzu98V50.s.sol` to deploy and wire all 17 contracts and commission #0000 against the mock pool manager. Details and open items in `script/DEPLOY_SCRIPT_NOTES.md`.

Status: 17 contracts, all under the 24,576-byte limit. Compiles with `via_ir = true`; 34 of 34 tests pass (the original 24 plus 10 new ones in `test/YuzuIntegration.t.sol`). Local Foundry only (solc 0.8.24, cancun, OpenZeppelin 5.0.2, forge-std 1.9.6 expected at `lib/forge-std-1.9.6`). Nothing deployed, nothing run on Ink, not audited.

Runtime sizes (bytes, limit 24,576): YuzuAccount 23,332; YuzuTreasury 19,539; YuzuSeeder 15,320; YuzuCartridge 14,254; YuzuAccountCompanion 10,616; Yuzu98v2 10,185; the other eleven are under 9,200.

How far the review went: every contract compiled and tested; every function the other contracts call on the vault checked by script against the vault source (26 interface functions, none missing); `YuzuAccount.sol` read in full. NOT yet read line by line: YuzuPoolHook, YuzuSocketBay, YuzuDistributor, YuzuSeeder, YuzuRegistry, YuzuNavLens, and the parts of YuzuTreasury and YuzuCartridge that this pass did not touch.

## Done in this pass (2026-11-17, founder: "split the vault and wire in the missing pieces")

1. **The vault fits.** 33,298 bytes -> 23,332 (1,244 under the limit). How:
   - New contract 17, `YuzuAccountCompanion.sol`: one shared helper for every vault. No owner, no admin, no storage. The vault reaches it with plain calls only, never delegatecall, so it cannot touch vault storage.
   - Moved into the companion: the swap leg of every vault swap (Fences F2, F3, F4, F6, F8 and the 0.25% desk fee), desk-fee routing, Seed Raid salvage routing, the Slot-4 run-fee split, Guardian signature recovery, and the telemetry view (`companion.accountTelemetry(vault)` replaces `vault.getAccountTelemetry()`).
   - Kept in the vault: Fence F5 (NAV invariant and Loss Budget), the seed reserve check, Fence F7, the Tier-3 queue and every authority check.
   - The four modifiers became internal functions with the same checks (one copy each instead of one per use).
   - Read-only getters removed from the vault: the 22 limit and action-code constants (now readable on the companion, copied verbatim), the 12 wiring addresses (mainframe, lens, registry, socketBay, distributor, treasury, hook, pyth, weth, yuzuToken, seeder, defaultSlot4Adapter), and five storage getters (initialized, seedAssetList, guardianRotationEpoch, slot4Params, lastSlot4RunAt). The values are still there, only the public read functions are gone.
   - The vault constructor takes a 14th argument, the companion address.

2. **Slot 2 is connected to the vault.**
   - `YuzuAccount.pullSlot2Asset(asset, amount, to)`: only the cartridge can call it and only to itself. Refuses when the vault is frozen or the unit is not UNBOLTED, refuses unpriced assets, and re-checks the seed reserve after the transfer.
   - `YuzuAccount.loosenDeskPolicy(...)`: Tier-3 action 11. Needs a Guardian signature or the 48h queue over the hash of the exact policy, then calls `YuzuCartridge.setPolicyFromVaultTier3`.

3. **The treasury escrows exist.** `YuzuTreasury` now has `receiveFeeEscrow`, `receiveSkimEscrow`, `receiveSalvageEscrow`, `convertFees` and `convertSalvage`.
   - Credit is only given for tokens that are actually in the Treasury and not already counted, so the receive functions are open to any caller. WETH and $YUZU are refused.
   - Anyone can convert. The swap must return at least 98.5% of the oracle quote or it reverts and the escrow is untouched.
   - Fee escrow remembers the split it was collected at: 20% to buyback for desk fees, 50% for Slot-2 skims. `YuzuCartridge` now calls `receiveSkimEscrow` for its skim.

4. **A bolted unit cannot be withdrawn from (Fence F7).** `executeTier3Action` reverts unless the unit is UNBOLTED. This covers a fresh Guardian signature and a withdrawal queued before bolting.

5. **Interface file fixed.** `IYuzuV4Interfaces.sol` now declares `IYuzuRegistry.routeFor` and `IYuzuNavLens.requireFresh` with the real return types (old finding 8).

6. **New test file, `test/YuzuIntegration.t.sol`** (10 tests): runs the real YuzuAccount, YuzuAccountCompanion, YuzuCartridge and YuzuTreasury against each other. Covers a covered call through the real vault, the 48h policy queue, the pull guards, a non-WETH desk fee into the escrow and its conversion, a Seed Raid on a stale feed and on a fresh feed, Fence F7, the escrow guards, the run-fee split and the swap leg.

## New behaviour for the founder to review

- **Vault funds pass through the companion during a swap.** The vault transfers the exact input amount to the companion, the companion swaps and pays the output back in the same call. The vault gives it no approval. The companion cannot be changed after deployment, so a bug in it affects every vault at once.
- **Fence F3 (20% exposure cap) is now checked in the companion** against the NAV figure the vault passes in.
- **Every Tier-3 action is blocked while a unit is bolted**, not only withdrawals. That includes raising limits, setting the recovery address, rotating the Guardian and posting a ROM bond. The spec says a bolted vault accepts deposits and reward claims and nothing else, so I applied it to all of them.
- **Salvage swap**: any failure in the swap leg (stale feed, no route, router revert, short output, a zero quote) now rolls back as one unit and the raw token goes to the salvage escrow.
- **Covered-call fix from the first pass** (`VenueCollateralNotTaken`), still awaiting review.
- **Sites and scripts** must read limits and action codes from the companion, and can no longer read the wiring addresses from a vault.

## Still open

- **No test deploys all 17 contracts together.** The integration test uses four real contracts; mainframe, lens, registry, router, socket bay, distributor, hook, Pyth and the two venue adapters are still mocks there.
- **No deployment script** in this folder.
- **The hook has never run against the real Uniswap v4 PoolManager.** It is written against a hand-made interface file and tested only on `MockV4PoolManager` (constant-product maths).
- **The master spec still says 16 contracts.** It has no entry for the companion or for the Treasury conversion functions.
- **Not audited.** Seven contracts have not been read line by line (list above).

## Fixed in the first pass

- **YuzuCartridge.writeCoveredCall underflow.** When the premium is paid in the collateral asset, the premium was measured against a balance that still included the collateral, so the subtraction underflowed and every such call reverted. The baseline now excludes the collateral, and the call reverts with `VenueCollateralNotTaken` if the venue leaves any of the approved collateral behind.
- **Yuzu98v2.sol** declared `boltState` twice (a public mapping and a function). Removed the unused public mapping; `_boltState` and the function remain.
- **foundry.toml**: `via_ir = true`. YuzuAccount, YuzuCartridge, YuzuRenderer and YuzuRelativeStrengthAdapter fail with "stack too deep" without it.

## Test fixes from the first pass (the contracts were right)

- Phase1 farm gate: the test bought 350,000 $YUZU from a pool holding 300,000. It now adds three more units of commissioning liquidity first. The 1:1 Farm Gate assertion passes.
- Phase3 commit-reveal: the test paid 0.15 ETH for two units (0.30 needed).
- Phase4 tier 2/3: `vm.prank` and `vm.expectRevert` were consumed by the `vault.ACTION_*()` getter evaluated as an argument, so the real call ran unpranked.
- Phase2 / Phase5 mocks: a missing `virtual` and a wrong struct reference.

## Housekeeping

`wip-split/` holds the patch scripts and fragments that produced this pass (`patch.mjs` then `patch2.mjs`, applied to the first-pass source). `src/` and `test/` already contain the result, so the folder can be deleted.
