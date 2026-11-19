# DeployYuzu98V50.s.sol notes

## 0f. (2026-11-19 04:45Z) V3 leg moved to the Universal Router; full 17-contract deploy run on the Ink fork

Founder request 00:01Z, picked up on his "yes" at 04:20Z. Nothing was deployed or sent; a fork is a local copy of Ink.

**Read on Ink through https://rpc-gel.inkonchain.com (block ~61,563,700 to 61,564,689):**
- Universal Router `0x661E93cca42AfacB172121EF892830cA3b70F08d`: has code, verified on the Ink explorer as UniversalRouter (solc 0.8.26). Its constructor arguments name V3 factory `0x640887A9ba3A9C53Ed27D0F7e8246A4F933f3424`, V3 position manager `0xC0836E5B058BBE22ae2266e1AC488A1A0fD8DCE8`, v4 PoolManager `0x360E...FB32`, WETH `0x4200...0006`.
- The V3 factory the founder supplied, `0xcb2436774C3e191c85056d248EF4260ce5f27A9D`, has NO code on Ink. The factory the router uses (`0x6408...3424`) has code.
- kBTC: the founder has not supplied an address. Used `0x73E0C0d45E048D25Fc26Fa3159b0aA04BfA4Db98`, which has code, symbol() kBTC, 8 decimals. NOT confirmed by the founder as the right token.
- V3 pools on factory `0x6408...3424`:
  - WETH / USDG: no pool at 0.01%, 0.05% or 0.30%. One pool at 1.00%, `0x5A56Ff4B88F0fF5B33d4B0cf541FE76dAf343e46`, holding 0.5707 WETH and 358.86 USDG.
  - WETH / kBTC: one pool at 0.30%, `0xf03B4E8657308CB00467D86Cfae38F3949d716F7`, holding 0.00015 WETH and 1,881 sats of kBTC. No pool at the other three tiers.
  - USDG / kBTC: no pool at any of the four tiers.
- Universal Router source read: `execute(bytes,bytes[])`; command 0x00 = V3_SWAP_EXACT_IN with inputs (recipient, amountIn, amountOutMin, path, payerIsUser, minHopPriceX36); path is tokenIn + 3-byte fee + tokenOut; with payerIsUser false the router pays the pool from its own balance.

**Changed (marked CHANGE / ADDED bankr 2026-11-19):**
- `src/adapters/YuzuSwapRouterAdapter.sol`: `_swapV3Single` now sends the input to the Universal Router and calls `execute` with V3_SWAP_EXACT_IN, payerIsUser false. No ERC-20 or Permit2 approval is given. The router returns nothing, so the output is the recipient's balance change. `IV3SwapRouterMinimal` is replaced by `IUniversalRouterMinimal`. The immutable is still named `v3Router`, and the script's `V3_SWAP_ROUTER` variable now means the Universal Router. Runtime 6,852 bytes (was 5,687).
- NEW BEHAVIOUR FOR FOUNDER REVIEW: new error `V3InputNotFullyUsed(tokenIn, leftover)`. If a V3 pool does not take the whole input (it ran out of liquidity), the swap reverts. Otherwise the remainder would sit in the Universal Router, where anyone can sweep it.
- `test/YuzuAdapters.t.sol` and `test/YuzuFull17Integration.t.sol`: the two stand-in V3 routers now take the Universal Router call. They require the input to already be in the router and pass it on, so the tests fail if the adapter does not fund the router.
- `script/DeployYuzu98V50.s.sol`: one comment only. The default routes are UNCHANGED and still assume WETH / USDG at fee 3000 (`V3_WETH_USDG_FEE`), which does not exist on Ink.
- New `test/YuzuInkForkDeploy.t.sol` (3 tests, skipped without INK_RPC_URL). It runs the script's `deployAndWireAll17` with the real PoolManager, Universal Router, V3 pools, Quotrons pool, WETH, USDG, kBTC and wSPYx. It overrides the four routes that cross WETH / USDG to the 1.00% tier.
- NOT real in that test: the oracles. No Chainlink or Pyth address on Ink has been supplied, so the feeds are MockChainlinkFeed / MockPyth priced at each pool's own spot price at the fork block (ETH $1,781.05, BTC $64,057.26, wSPYx 772.84 USDG). That is the most favourable case for the Seeder's 1.50% check.

**Results, fork block 61,564,689, all run on the changed code:**
1. Adapter V3 leg through the real Universal Router, at the Seeder's three sizes:
   - 0.015 WETH -> USDG (1.00% pool): works. 26.19 USDG received against 26.72 at spot, 1.96% short. That is over the Seeder's 1.50% limit.
   - 0.03 WETH -> kBTC (0.30% pool): REVERTS `V3InputNotFullyUsed`; the pool took 0.0022 of the 0.03 WETH and 0.0278 WETH was left over.
   - 0.075 WETH -> USDG -> wSPYx (V3 1.00% then Quotrons v4): works. 0.1575 wSPYx against 0.1728 at spot, 8.90% short.
2. Full deploy on Ink as it is today (3 vaults): REVERTS with the Universal Router's `V3TooLittleReceived` (0x39d35496) while seeding #0000. Which leg was not decoded; the kBTC leg is the first swap, and result 1 shows that pool cannot fill it.
3. Full deploy after adding 100 WETH of full-range liquidity to each of the two V3 pools at their current price, ON THE FORK ONLY (3 vaults):
   - COMPLETES. The script deploys the adapter over the Universal Router and points the routes at it; hook mined to 0x2880; the YUZU / WETH pool is open on the real PoolManager at the script's price with about 150,000 YUZU; #0000 belongs to the founder address with tier 5 RAM.
   - #0000's seed: 0.03 WETH, 83,137 sats kBTC (83,412 at spot, 0.33% short), 26.44 USDG (26.72 at spot, 1.01% short).
   - #0001, a public US_BASKET mint: works.
   - #0002, a public NON_US_XSTOCK mint: REVERTS `SlippageExceeded`: 0.16799 wSPYx received, 0.17025 required, 0.17284 at spot (2.81% short). The 1.00% V3 fee plus the Quotrons hop is more than the 1.50% limit even with a deep V3 pool.
   - The adapter holds no WETH, USDG, kBTC or wSPYx afterwards.
- Also re-run on the changed adapter: `YuzuAdapters.t.sol` 2 of 2, `YuzuFull17Integration.t.sol` 7 of 7, `YuzuInkFork.t.sol` 2 of 2. NOT re-run: the six phase suites (27) and `YuzuIntegration.t.sol` (10); none of them imports the adapter and the rest of src is unchanged since they passed at 04:17Z.
- Tests 1 and 2 of the new file pass in forge's terms while logging the reverts above; they record what Ink does today, they do not assert that seeding works.

**What this means:** the 17 contracts deploy and wire on Ink's real PoolManager and Universal Router. Seeding does not work on Ink today, because of the pools and not the code: the WETH / kBTC V3 pool is close to empty, the only WETH / USDG V3 pool is the 1.00% tier with about $1,000 in it, and the wSPYx seed cannot meet 1.50% through a 1.00% pool.

**Open, for the founder:**
- Where the seed should trade on Ink. Not checked: any other venue on Ink for WETH / kBTC, WETH / USDG or WETH to wSPYx.
- The 1.50% seed slippage limit against the 1.00% fee tier.
- Confirm the kBTC address. The supplied V3 factory address has no code.
- Chainlink and Pyth addresses and feed ids on Ink: still not supplied, so no real oracle has run.
- The script's default WETH / USDG fee (3000) has no pool on Ink; left unchanged until the venue is decided.
- `run()` (the broadcast path, CREATE2 factory, 1,000 vaults) was not run on the fork; the fork test calls `deployAndWireAll17` directly with 3 vaults.
- The sell-side routes (kBTC -> WETH, USDG -> WETH, wSPYx -> WETH) were not executed on the fork.

Run: `INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-path test/YuzuInkForkDeploy.t.sol -vv`

## 0e. (2026-11-19 04:17Z) Sellout sweep fixed; emitWeeklyFarm caller error

Founder message 03:58Z. Argon is no longer available; the fixes came from a different reviewer model. Its two bug reports were right (confirmed by reading the old code, the old code was not run against the new tests). Its code was NOT applied as pasted, because it did not match this repo.

**The two bugs (old code):**
1. `sweepSelloutLpLeftovers` was `nonReentrant` and called the `nonReentrant` `addMintLiquidity`, so it reverted whenever both LP-reserve buckets were non-zero.
2. After a pairing both buckets normally still hold something (real v4 leaves a few wei of WETH; the fork showed 3 wei at open), and the old `if / else if` handled only exactly one bucket being non-zero, otherwise `NothingToRelease`. Together: the sweep could not run after a sellout, and the unused LP-reserve $YUZU would have stayed in the reserve for good.

**Applied in `src/YuzuTreasury.sol` (marked FIX / ADDED bankr 2026-11-19):**
- `addMintLiquidity()` is now a `nonReentrant` wrapper around internal `_addMintLiquidity()`, which is the old body moved unchanged (band guard, 250,000 $YUZU per unit ceiling, pool-ratio pairing, silent no-op when nothing to pair). It returns false only when the band guard skipped the add.
- `sweepSelloutLpLeftovers()`: sellout check, one-shot check (`lpLeftoversSwept`), pair via `_addMintLiquidity()`, then sweep BOTH buckets (leftover $YUZU to the Ecosystem Vault, leftover WETH to the Distributor), existing `LpLeftoversSwept` event.
- `emitWeeklyFarm`: reverts new `OnlyDistributor()` instead of `OnlySeeder()`. Signature unchanged (`emitWeeklyFarm(uint256 epoch) returns (uint256)`).
- Treasury runtime 19,243 bytes (was 19,368).

**Where the pasted code was not used, and why:**
- Its `_addMintLiquidity` dropped the reference-band guard and the 250,000 $YUZU per unit ceiling and passed the whole reserve to `_addLiquidity` (its own note said to keep the guard). Kept the existing body.
- Its `addMintLiquidity()` reverted `NothingToRelease` when there was nothing to pair. `receiveCommissioningWeth` calls it on every commissioning and on every refurbishment (`lpWeth = 0`), so refurbishments, and any commissioning skipped by the band guard, would have reverted. Kept the silent no-op.
- It dropped the one-shot flag and used names this repo does not have (`FleetNotSoldOut`, two new events, `emitWeeklyFarm(uint256 amount)` with no return value). Kept `SelloutNotReached`, `LpLeftoversSwept`, `lpLeftoversSwept`.
- Its tests could not run here: `mockUnits.setCommissionedCount` does not exist (`units.setCommissioned(count, ts)`), `distributor` is a plain address, and sending 3 wei of WETH to the Treasury does not credit `lpReserveWethPending`.

**NEW BEHAVIOUR FOR FOUNDER REVIEW:** while the pool price is outside the reference band, the sweep reverts `OutsideReferenceBand` and nothing moves (the old code also swept nothing there, with `NothingToRelease`). Reason: otherwise anyone could push the price out of the band for one transaction and send pending LP WETH to the reward pool instead of the pool. Consequence: the sweep waits until the price is back inside the band.

**Tests (all re-run on the changed code, 2026-11-19 04:07Z to 04:17Z):**
- Local 46 of 46: 27 in the six phase suites (Phase1 now 10, 3 new), 2 adapters, 10 integration, 7 full-17. Five separate `--match-path` calls.
- New in `test/YuzuPhase1.t.sol`: `test_SweepSelloutLpLeftovers_PairsThenSweepsBothBuckets` (0.03 WETH pending + $YUZU left: reverts before sellout; after sellout pairs 0.03 WETH with about 200,000 $YUZU, sweeps 249.3M $YUZU to the Ecosystem Vault, both buckets zero, balances match to the wei, second call reverts), `test_SweepSelloutLpLeftovers_WaitsWhilePriceIsOutsideTheBand`, `test_EmitWeeklyFarm_RevertsOnlyDistributor`.
- Fork of Ink 2 of 2 (`test/YuzuInkFork.t.sol`, new step 10): on the real PoolManager with 2 wei of WETH pending and $YUZU left, the sweep succeeds, both buckets end at zero, Treasury ledgers match to the wei. The distributor's WETH rose 3,626,853,231,293 wei in that call; that is mostly its half of the LP fees from the preceding buyback swap, paid out by the add. The fork test does not separate swept WETH from fees.

**Not covered:** a sellout where the $YUZU reserve runs out first (WETH-only leftover) is not tested; the band test moves the mock's tick with `setTickForTest`, not with a real swap.

**Still open from the 00:01Z request (interrupted, not done):** adapt the V3 leg to Ink's Universal Router (`execute(bytes,bytes[])`, not SwapRouter02's `exactInputSingle`) and run the full 17-contract deploy script on the fork. Read so far, 00:03Z to 00:12Z, not acted on: Universal Router 2.1.2 at 0x661E...F08d is verified and its constructor names V3 factory 0x640887A9ba3A9C53Ed27D0F7e8246A4F933f3424, which is NOT the 0xcb24...7A9D factory the founder supplied; Pyth's docs page did not list Ink.

## 0d. (2026-11-19 00:00Z) Hook opening tick fixed (founder: "just do it", 23:48Z)

Closes item 1 of "Found, NOT fixed" in 0c. Item 2 (Quotrons hook owner can pause a pool) is unchanged.

**Change:**
- `src/YuzuPoolHook.sol`: `_tickFromSqrtPrice` now computes the tick from the price with `TickMath.getTickAtSqrtPrice` (marked FIX). It no longer reads the pool's slot0, which the PoolManager has not written yet when `beforeInitialize` runs. The function is now `pure`.
- New `src/libraries/v4/TickMath.sol`, `BitMath.sol`, `CustomRevert.sol`: Uniswap v4-core at tag v4.0.0 (commit e50237c43811bd9b526eff40f26772152a42daba), copied unmodified. This is the same function the PoolManager uses in `initialize`.
- `test/mocks/Phase1Mocks.sol`: MockV4PoolManager.initialize now stores and returns the real opening tick (it stored 0). The mock's tick still does not move with swaps.
- `test/YuzuInkFork.t.sol`: the two logged values are now asserted: `hook.referenceTick()` and `hook.lastRecordedTick()` equal the pool's tick read from the real PoolManager after the open.

**Results, all run on the changed code:**
- Fork of Ink, real PoolManager: 2 of 2. Pool tick 157,134, hook referenceTick 157,134, hook lastRecordedTick 157,134 (both were 0).
- Local: 43 of 43 (24 phase + 10 integration + 7 full-17 + 2 adapters).
- Hook runtime size 7,725 bytes (was 6,225). Treasury 19,368 and socket bay 9,095 unchanged.

**Not checked:** the PoolInitialized event's tick is not asserted on its own; it emits the same variable that is stored.

**Still open / not covered:** everything under "Not covered" in 0c, and 0c item 2.

## 0c. (2026-11-18 23:45Z) v4 alignment pass applied; fork test on Ink passes

Founder messages 20:52Z to 22:09Z (argon's code arrived in the 20:57Z paste, repeated three times, identical).

**Applied (argon's code unless marked):**
- `src/interfaces/IYuzuV4Interfaces.sol`: replaced with argon's file (real IPoolManager: sync + settle(), packed int256 returns, extsload; V4StateLib).
- `src/YuzuTreasury.sol`: `lockedLiquidity`, `_getPoolBalances()` at the three old getPositionBalances sites, real-liquidity add, packed deltas, valid price limit on buyback, sync / transfer / settle().
- `src/YuzuPoolHook.sol`: five slot0 reads through V4StateLib. `src/YuzuSocketBay.sol` and `src/adapters/YuzuSwapRouterAdapter.sol`: price limit, unpackDelta, sync + settle().
- FIX (bankr) in the Treasury, differs from the paste: on real v4 an add also pays out fees the position has accrued, netted against what is owed. As pasted, those fees stayed inside the LP reserve. ADD_LIQUIDITY and COLLECT_FEES now share one branch that returns (wethIntoPosition, yuzuIntoPosition, feeWeth, feeYuzu), and fees paid during an add are split like collectLpFees (new `_addLiquidity`, `_distributeLpFees`, `_settleOrTake`). Fork test step 8 covers it.
- `test/mocks/Phase1Mocks.sol`: MockV4PoolManager rewritten to the real calling convention. Per-caller currency deltas; unlock() reverts with CurrencyNotSettled unless everything is paid; real liquidity units; extsload slot0; a price limit of 0 reverts. New `FullRangeLpHelper`. Still not real v4: one 1.00% fee tier, no tick math, no liquidity removal, hooks called regardless of address flags.
- Tests updated: YuzuPhase1 (pool now opens at the script's price, not 1:1; swapper uses the real convention), YuzuAdapters, YuzuFull17Integration (pools seeded through FullRangeLpHelper; pool amounts asserted within rounding).
- New `test/YuzuInkFork.t.sol` (2 tests, skipped unless INK_RPC_URL is set).
- The patch pieces are kept in `wip-v4/`.

**Results, all run on the aligned code:**
- Local: 43 of 43 (24 phase + 10 integration + 7 full-17 + 2 adapters).
- Fork of Ink at block ~61,545,336, real PoolManager 0x360E...FB32: 2 of 2.
  - Treasury opens the YUZU/WETH pool at the script's price (tick 157,134), adds liquidity three times, collects fees, runs a buyback. After every step its WETH and YUZU balances equal its ledgers to the wei and the pool's stored liquidity equals `lockedLiquidity`.
  - Open: 149,999.9964 YUZU and all but 3 wei of the 0.0225 WETH went in; the rest stays in the LP reserve.
  - Hook mined to 0x2880 is accepted: an outside initialize reverts, an outside buy reverts, SocketBay buyAndSeat works (0.00909 WETH for 50,000 YUZU), selling works.
  - Adapter on the real Quotrons USDG/wSPYx pool through the real hook: 500 USDG -> 0.6121 wSPYx (about 816.9 USDG per wSPYx), back to 497.00 USDG. Adapter keeps nothing.
- Sizes: Treasury 19,368 bytes (was 19,539), hook 6,225, socket bay 9,095, adapter 5,687.

**Found, NOT fixed (for argon):**
1. (FIXED 2026-11-19, see 0d.) Hook records the opening tick as 0. `beforeInitialize` calls `_tickFromSqrtPrice`, which reads the pool's slot0 before the PoolManager has written it. On the fork: pool tick 157,134, `referenceTick` 0, `lastRecordedTick` 0, and the PoolInitialized event reports 0. During the gate the band check ignores referenceTick, and `liftGate` replaces it with the TWAP (lift + buyback passed on the fork), so nothing failed. It is still wrong state. Fix: use the tick `initialize` returns, or compute it from sqrtPrice.
2. QuotronStockHook (verified source on the Ink explorer, read in part: beforeSwap, afterSwap, fee skim, owner functions): its owner can pause a pool (`setPoolPaused`), which reverts every swap in it, and can step the fee within fixed bounds. A paused wSPYx pool would revert every wSPYx swap, including a NON_US_XSTOCK seed. The fee is taken in USDG.

**Not covered:**
- The fork test uses MockYuzuUnits and plain addresses for seeder / distributor. The full 17-contract deploy script has not been run on the fork; no oracle, registry, seeder or vault ran against Ink.
- Ink's V3 router address is still not supplied; no V3 hop ran on the fork (WETH/USDG, WETH/kBTC at fee 3000 unchecked).
- The two fork revert checks (outside initialize, outside buy) accept any revert, because real v4 wraps a hook's error.
- USDG for the fork swap was created with forge's `deal`.

Run the fork test: `INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-path test/YuzuInkFork.t.sol -vv`

## 0b. (2026-11-18 20:39Z) Script deploys the router adapter; Ink values read on-chain; real v4 ABI gap confirmed

Founder message 20:18Z. This closes item 2 of the "open for argon" list in 0a and changes items 1 and 5.

### Router deployment (done, tested)
- `DeployParams` has two new fields, `swapRouter` and `v3SwapRouter`; `DeployedContracts` has `swapRouterAdapter`.
- If `swapRouter == address(0)`, `deployAndWireAll17` deploys `new YuzuSwapRouterAdapter(p.poolManager, p.v3SwapRouter)` before the registry and points every route whose router is `address(0)` at it. Routes that already name a router are left alone. With neither address it reverts `NoSwapRouterConfigured`.
- `run()`: `SWAP_ROUTER` is now optional (`vm.envOr`). Unset means deploy the adapter, and `V3_SWAP_ROUTER` is then required. If `SWAP_ROUTER` is set it is used as is.
- Tests run this pass: `YuzuFull17Integration.t.sol` 7 of 7 and `YuzuAdapters.t.sol` 2 of 2. The six phase suites (24) and `YuzuIntegration.t.sol` (10) were NOT re-run; `src/` and those files are unchanged since they passed at 20:10Z. Repo total is now 43.
- New `test_AutoDeploysSwapRouterAdapter_AndSeedsUnitsThroughIt`: the script deploys the real adapter, all 8 routes point at it, #0000 and #0001 (US_BASKET) are seeded through it on the V3 single hop, and #0002 (NON_US_XSTOCK) is seeded through the registered WETH -> USDG -> wSPYx two-hop with the exact output the mock pool's math predicts. New `test_RevertsWhenNoSwapRouterAndNoV3Router`. `test_Run_FromEnvironment_WithBroadcastKey` now leaves `SWAP_ROUTER` unset, so `run()` deploys the adapter from the broadcasting key.
- Still mocks: `MockV4PoolManager`, a mock V3 router that ignores the fee tier, and a pass-through hook at the Quotrons hook address. Still not executed anywhere: the sell-side two-hop (wSPYx -> WETH) and the 32-byte V3 path.

### Ink (57073) values, read through the public RPC https://rpc-gel.inkonchain.com at 20:24Z to 20:29Z
- PoolManager `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32`: has code. Its bytecode hash equals the PoolManager at the same address on Arbitrum (`0xe4b2759e...e794a4`), whose verified ABI was read (see below).
- QuotronStockHook `0x8bb4516059F9149Bc3b89018Fc7537f1F14a30cc`: has code. Its code and behaviour were NOT read.
- USDG `0xe343167631d89B6Ffc58B88d6B7fB0228795491D`: symbol USDG, 6 decimals.
- wSPYx `0xE7E553CD128f0011777323A0b44a7b96EA1CB540`: symbol wSPYx, 18 decimals, `convertToAssets(1e18)` = 1.007474126658766e18, `asset()` = `0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48`. So it is a wrapper with a multiplier above 1, and `isWrapper: true` is right.
- Pool (USDG, wSPYx, fee 0x800000, tickSpacing 60, that hook): pool id `0x84b421dc355c6c003fcf4f8100691eddaa0319deb894acb7e9bbf633621694a7`. Read with `extsload` at the pools mapping (slot 6): slot0 is non-zero and liquidity is non-zero, so the pool exists with those exact key values.
- NOT checked: the Uniswap V3 router address on Ink (the founder has not supplied it), whether WETH/USDG and WETH/kBTC V3 pools exist at fee 3000 (every crypto route and both two-hops assume it), WETH, kBTC, Pyth and the Chainlink feed addresses.

### Real v4 PoolManager ABI vs this repo (confirmed from the verified ABI, not yet changed)
Real: `sync(address)`, `settle()` with no arguments, `settleFor(address)`, `swap` returns one `int256`, `modifyLiquidity` returns `(int256 callerDelta, int256 feesAccrued)`, `extsload`, and no `getSlot0` or `getPositionBalances`. `initialize`, `unlock` and `take` match the repo.
As written, every pool call from the repo fails on Ink: `settle(address)` and `getSlot0` do not exist there. That includes #0000's mint, which opens the pool, so the deployment itself would revert.
Changes needed:
1. `IYuzuV4Interfaces.sol`: `sync` + `settle()`, packed return values (amount0 in the upper 128 bits, amount1 in the lower), remove `getSlot0` / `getPositionBalances`, add `extsload`.
2. `YuzuPoolHook`: five `getSlot0` tick reads (lines 244, 260, 266, 291, 298) become `extsload` reads of the pool's slot0.
3. `YuzuSocketBay` (lines 309 to 321) and `YuzuSwapRouterAdapter` (lines 152 to 167): unpack the swap result, call `sync` before the transfer, then `settle()`.
4. `YuzuSocketBay` line 306 and `YuzuTreasury` line 657 pass `sqrtPriceLimitX96: 0`. From memory real v4 rejects that; use the MIN+1 / MAX-1 bounds the adapter already has.
5. `YuzuTreasury`, the large one: `ADD_LIQUIDITY` passes the token amounts in `hookData` with `liquidityDelta = amt0 + amt1`, which only the mock understands. Real v4 needs liquidity computed from the amounts and the current price, and what the pool actually takes can differ from the amounts sent, so leftovers need handling. The three `getPositionBalances` reads (lines 250, 383, 558) must be computed from the position's liquidity and the price. That brings tick and liquidity math into a contract already at 19,539 of 24,576 bytes; size is the risk.
6. `MockV4PoolManager`: same ABI changes, and it must track what each caller owes and revert if it is not paid. Today `settle` does nothing, so no test shows the contracts pay the pool what they owe.
7. Tests that read `poolManager.pools(...)` or use the mock: `YuzuPhase1.t.sol`, `YuzuAdapters.t.sol`, `YuzuFull17Integration.t.sol`.
Suggested check: a fork test against Ink's real PoolManager (the RPC is reachable from the sandbox) in place of a more elaborate mock.
Unverified, from memory only: that the three `IHooks` selectors match v4-core (argon's claim), and the 0x2880 flag bits.

## 0a. COMPILED AND TESTED (2026-11-18 20:14Z): Quotron LP adapter removed, wSPYx route paths, router adapter test

Result: 41 of 41 tests pass (forge 1.7.1, solc 0.8.24, via_ir): 24 in the six phase suites, 10 in `YuzuIntegration.t.sol`, 5 in `YuzuFull17Integration.t.sol`, 2 in the new `test/YuzuAdapters.t.sol`. Run as four separate `forge test --match-path` calls. Local only: `MockV4PoolManager` and a mock V3 router, not real Uniswap v4 or V3, not Ink. Nothing was deployed.

`test/YuzuAdapters.t.sol` is argon's router-only test, pasted 20:01Z. It was not run as pasted. Changes made when saving, from reading it against the mocks (marked `FIX (bankr 2026-11-18)`):
- It called `poolManager.modifyLiquidity` directly; the mock rejects that with `NotUnlocked`. Liquidity is now added inside `unlock()` through a callback on the test contract.
- The pool uses the Quotrons hook address, which has no code locally, and the mock calls the hook on initialize, add-liquidity and swap. A pass-through `MockPassThroughHook` is placed at that address with `vm.etch`. It is NOT the real QuotronStockHook.
- `weth.mint` does not exist on `MockWETH`; the test wraps ETH with `deposit()`.
- The bare `vm.expectRevert()` now expects `InvalidHopEndpoints` with its four arguments.
Added (marked `ADDED`): exact output checks against the mock pool's math, delivery to the recipient, no tokens or V3 approval left on the adapter, path lengths 160 / 384, and a second test for the sell direction (wSPYx -> USDG), `SlippageExceeded` and `OnlyPoolManager`.

`test/YuzuFull17Integration.t.sol` now also checks the script's registered wSPYx paths are byte-for-byte what the adapter's own encoders produce (USDG -> wSPYx, wSPYx -> USDG, WETH -> wSPYx) and decodes the sell-side two-hop (wSPYx -> WETH) field by field.

Not covered by any test:
- The sell-side two-hop (wSPYx -> USDG on v4, then USDG -> WETH on V3) is decoded but never executed; the mock V3 router only prices WETH -> USDG.
- The 32-byte V3 fee path.
- The deployment still seeds units through `MockSwapRouter`, which ignores the path. No test deploys the suite with `YuzuSwapRouterAdapter` as the registered router and commissions a unit through it.
- The real Quotrons hook, a real v4 PoolManager, a real V3 router, Ink.

Written 2026-11-18 18:00Z, before the compile:

Founder said yes at 17:48Z.

Removed (founder decision: 17 core contracts fixed for v1, external LP vaults only after launch through the 48h registry timelock, after their live bytecode is audited):
- `src/adapters/QuotronLpVenueAdapter.sol`, `test/QuotronLpVenueAdapter.t.sol`, `test/mocks/QuotronMocks.sol` deleted.
- `test/YuzuIntegration.t.sol`: the two Quotron imports and `test_QuotronAdapter_CashLeg_NeedsPricedReceipt_GainSkimmed_LossPassedThrough` removed. That file is back to 10 tests. Expected repo total: 39 (24 phase + 10 integration + 5 full-17), before `YuzuAdapters.t.sol`.

Route paths in `script/DeployYuzu98V50.s.sol` `buildDefaultRegistryInputs` (marked `CHANGE (founder 2026-11-18 17:48Z)`):
- `routes[3]` USDG -> wSPYx and `routes[4]` wSPYx -> USDG: one 160-byte `V4Hop` (fee 0x800000, tickSpacing 60, hooks 0x8bb4516059F9149Bc3b89018Fc7537f1F14a30cc).
- `routes[2]` WETH -> wSPYx: two-hop `V4Hop[]`, WETH -> USDG on V3 at fee 3000, then USDG -> wSPYx on Quotrons v4. `routes[5]` wSPYx -> WETH is the reverse order.
- The four wSPYx routes use `routerType: 2`. No contract in `src` reads `routerType`; the adapter decides by path length.
- The script imports `YuzuSwapRouterAdapter` for its `V4Hop` struct and repeats its three Quotrons constants. They must stay equal to the adapter's.
- `test/YuzuFull17Integration.t.sol` now asserts the path lengths (160, 160, 384, 384, and 0 for WETH -> USDG).

Router adapter v2 (`src/adapters/YuzuSwapRouterAdapter.sol`, saved 15:31Z as pasted). Closed, by reading only:
- v4 hops pass `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1` instead of 0. The two constants match the Uniswap v4 TickMath values from memory; not checked against Ink.
- Mixed V3 + v4 multi-hop is implemented (a hop with `hooks == 0` and `tickSpacing == 0` goes to the V3 router).
- The first hop's `tokenIn` and the last hop's `tokenOut` are checked against the call arguments.

Still open for argon:
1. The adapter still uses the repo's simplified `IPoolManager` (`settle(address)`, `swap` returning two ints). From memory the real v4 PoolManager uses `sync(currency)` then `settle()` and returns one packed BalanceDelta. If so every v4 hop reverts on a real PoolManager, and the treasury, socket bay and hook use the same interface. Needs checking against Ink's deployed PoolManager, which cannot be read from here. `MockV4PoolManager` cannot catch this.
2. The deploy script does not deploy `YuzuSwapRouterAdapter`. `SWAP_ROUTER` must be the address of one already deployed with Ink's PoolManager and V3 router. If `SWAP_ROUTER` is anything else, the four wSPYx paths mean nothing to it.
3. The local tests use a mock router that takes the price from its own table, so in the deployment suite the new paths are stored and compared but never executed. `YuzuAdapters.t.sol` executes the single hop both ways and the buy-side two-hop against the adapter directly (see the result above).
4. Hops are not checked for continuity (hop i `tokenOut` == hop i+1 `tokenIn`). Low risk, since routes are timelocked registry entries.
5. `QUOTRON_STOCK_HOOK` and the pool's fee flag and tick spacing cannot be verified on Ink from here. They are now in the registered routes, not only in the adapter's encode helpers, so a wrong value means every wSPYx swap reverts, including the wSPYx leg of a US_BASKET seed.
6. Intermediate hops pass a minimum of 0; only the final amount is checked against `minAmountOut`. That is the usual pattern and the callers pass an oracle-based minimum.

## 0. APPLIED AND TESTED (2026-11-18 13:57Z)

Result: the patch below is applied to `foundry.toml`, `src/YuzuSeeder.sol`, `script/DeployYuzu98V50.s.sol`, `test/YuzuFull17Integration.t.sol` and `test/YuzuPhase3.t.sol`, and both adapters are in `src/adapters/`. Everything compiles (forge 1.7.1, solc 0.8.24, via_ir). 39 of 39 tests pass: 24 in the six phase suites, 10 in `YuzuIntegration.t.sol`, 5 in `YuzuFull17Integration.t.sol`. Run as three separate `forge test --match-path` calls, because a single full build killed the sandbox again. Local only, against `MockV4PoolManager`, not real Uniswap v4 and not Ink. Nothing was deployed.

Runtime sizes: YuzuAccount 23,332, YuzuTreasury 19,539, YuzuSeeder 15,466 (was 15,320), YuzuCartridge 14,254, YuzuAccountCompanion 10,616, YuzuSwapRouterAdapter 4,529, QuotronLpVenueAdapter 3,700. All under 24,576.

The five tests in `YuzuFull17Integration.t.sol` are now: 5 full standalone vaults + #0000 + public mint #0001; registry defaults (8 routes, wrapper pricing at 1.00x and 1.05x, 24h / 1h windows, #0000 refused for a non-deployer); gas per standalone vault; `run()` from the environment with a broadcast key, `PYTH_UPDATE_HEX` set and 40 vaults (NOT 1,000; set `YUZU_TEST_RUN_BATCH=1000` for the full fleet, not run here); revert when the sender cannot pay for #0000. The 1,000-clone test is gone with the clone path.

Measured: one full standalone vault costs 4,804,066 execution gas (code storage included, transaction calldata and the L1 data fee not included). 1,000 vaults is about 4.8 billion gas, which is about 0.0048 ETH per 0.001 gwei of gas price. Argon's ~$30 needs an Ink gas price of about 0.0035 gwei or lower at ETH $1,795, before the L1 data fee for about 24 KB of initcode per vault. Ink's gas price was not checked.

Not covered by any test: YuzuSwapRouterAdapter (it compiles, nothing calls it), a real v4 PoolManager, Ink, a real broadcast, the full 1,000-vault run. QuotronLpVenueAdapter is now tested, see the 14:59Z update further down.

Founder decisions of 2026-11-18 12:46Z: full standalone vaults only (no EIP-1167 clones, zero `delegatecall`), 8th route kBTC -> WETH, wSPYx `isWrapper` true, `maxAge` 86,400 for WETH / kBTC / USDG and 3,600 for wSPYx, optional `PYTH_UPDATE_HEX` on `run()`, and a deployer-only check on `YuzuSeeder.commissionFounderUnitZero`.

These are written as `wip-fixes/patch.txt` (apply with `wip-fixes/apply.mjs` from the repo root). The patch applies cleanly (32 edits, 5 files: `foundry.toml`, `src/YuzuSeeder.sol`, `script/DeployYuzu98V50.s.sol`, `test/YuzuFull17Integration.t.sol`, `test/YuzuPhase3.t.sol`). It is applied (see the result above). Sections 1, 4 and 5 below describe the third script BEFORE this patch and are kept for history.

Differences from the founder's instructions, inside the patch:
- wSPYx in the test becomes the existing `MockXStockWrapper` (adjustable multiplier, checked at 1.00x and 1.05x). `convertToAssets` is not added to `MockERC20Asset`.
- `YuzuSeeder` charges 0.15 ETH plus the Pyth update fee, so step 15 adds `pyth.getUpdateFee` to #0000's payment when `PYTH_UPDATE_HEX` is set.
- The clone path, the `Clones` import, `useEip1167Clones` and `masterVaultImplementation` are removed outright.
- `foundry.toml` gets `gas_limit = 30000000000`; the `run()` test deploys 40 vaults by default (`YUZU_TEST_RUN_BATCH=1000` for the full fleet).
- New tests: registry defaults + wrapper pricing + #0000 caller check, and gas per standalone vault (gas now measured, see the result above).

To flag: `YuzuNavLens.requireFresh` applies `maxAge` to both the Chainlink and the Pyth timestamp, so 86,400 lets the crypto legs trade on a Pyth price up to 24h old as well.

Received 2026-11-18 13:18Z: `src/adapters/YuzuSwapRouterAdapter.sol`, saved as pasted (only `‹ ›` restored to `< >`). Read against `IYuzuSwapRouter` and `IYuzuV4Interfaces.sol`: the imports and the `swapExactIn` signature match. It compiles (4,529 bytes). No test exists for it. Findings, by reading:
- v4 swaps pass `sqrtPriceLimitX96: 0`. Real v4 rejects that (it needs MIN_SQRT_PRICE + 1 for zeroForOne, MAX_SQRT_PRICE - 1 otherwise). `MockV4PoolManager` never reads the limit, so no local test would catch it. From memory of v4-core, not checked on Ink.
- The adapter uses the repo's simplified `IPoolManager` (`settle(address)`, `swap` returning two int256). From memory, the deployed v4 PoolManager has `settle()` with a `sync(currency)` call before the transfer, and `swap` returns one packed BalanceDelta. If so, this also affects YuzuTreasury, YuzuSocketBay and YuzuPoolHook. Check against the Ink PoolManager ABI.
- The header says multi-hop V3 paths are supported, but any path that is not 0, 32 or 160 bytes is decoded as `V4Hop[]`, so a packed V3 path reverts. `exactInput` and `UnsupportedRouterType` are unused and `routerType` is never read.
- The V3 params struct has no `deadline` (SwapRouter02 layout). Slipstream takes a tickSpacing and a deadline, so the "Velodrome Slipstream" claim needs a different struct. Which router is on Ink is unverified.
- `buildDefaultRegistryInputs` registers every route with an empty path, which this adapter treats as a V3 single hop at fee 3000. If wSPYx trades against USDG in a Quotrons v4 pool, its routes need a v4 hop path, and WETH <-> wSPYx needs two hops, which the adapter only supports when both pools are v4.
- No check that the first hop's tokenIn and the last hop's tokenOut equal the `tokenIn` / `tokenOut` arguments.
- `QUOTRON_STOCK_HOOK` is not verified (Ink cannot be read from here).

Received 2026-11-18 13:38Z: `src/adapters/QuotronLpVenueAdapter.sol`, saved as pasted. It compiles (3,700 bytes) and its two functions match `ILendingMarketAdapter`. No test exists for it. Findings, by reading, none changed in the file:
- **Withdrawals revert as wired.** `YuzuCartridge.withdrawFromCashLeg` pulls the receipt token out of the vault with `pullSlot2Asset(receiptToken, ...)`, and `YuzuAccount.pullSlot2Asset` reverts unless `registry.isPricedAsset(asset)`. Nothing registers the receipt (this adapter contract) as a priced asset, and a priced asset needs a Chainlink or Pyth feed. So a vault can supply and then cannot withdraw until the receipt is registered with a working price (multisig + 48h timelock).
- **Registering it as a wrapper does not work yet.** With `isWrapper` true the lens calls `convertToAssets(1 share)` on the receipt token. The adapter has no `convertToAssets`, the lens catches the failure and prices the receipt at 0. Fix for argon: add `convertToAssets(shares)` forwarding to the Quotrons vault, and register the receipt as a wrapper on the underlying's feed. Receipt decimals are 18 by default; they must match what the Quotrons vault's shares use.
- Until that is done the header's claim that the lens prices the position is not true: supplied cash leaves the vault's NAV.
- `IQuotronMarketLpVault` assumes ERC-4626 style `deposit(assets, receiver)` and `redeem(shares, receiver, owner)`. Whether a Quotrons LP vault with that interface exists on Ink is unverified.
- It is plugged into the cash-leg LENDING slot (Rule 8), but an xStock/USDG LP position carries stock price exposure and impermanent loss. The cartridge skims 10% only when more comes back than went in, so a loss is passed through unskimmed. FOUNDER DECISION: does an LP vault belong in the lending slot.
- The cartridge's `forceApprove(venue, shares)` on the receipt is unused, since the adapter burns from the cartridge directly. Harmless.

**UPDATE 2026-11-18 14:59Z: argon's second QuotronLpVenueAdapter.sol replaces the first** (saved as pasted). It adds `convertToAssets(shares)` forwarding to the Quotrons vault and makes the receipt report the underlying's `decimals()`. It compiles (3,939 bytes).

Tests added, all passing. Only these two suites were run in this pass (13 tests); the six phase suites and `YuzuFull17Integration.t.sol` (29 tests) import none of the changed files and were not re-run, they last passed at 13:57Z.
- `test/QuotronLpVenueAdapter.t.sol` (2 tests): real adapter + real YuzuRegistry + real YuzuNavLens, mock Quotrons vault (`test/mocks/QuotronMocks.sol`), the test contract standing in for the cartridge.
- `test/YuzuIntegration.t.sol` gained `test_QuotronAdapter_CashLeg_NeedsPricedReceipt_GainSkimmed_LossPassedThrough` (11 tests now): real vault + real cartridge + real Treasury + real adapter, mock Quotrons vault, mock lens and registry.

What the tests show:
- Fixed: once the receipt is registered as a wrapper on the underlying's feed, the real lens prices it (500 USDG supplied = $500 NAV, $525 at a 1.05 share price, $450 at 0.90) and the withdrawal goes through the real vault and cartridge.
- Still true: with the venue listed and the receipt NOT registered, supply succeeds and withdrawal reverts (`UnpricedOrSeedAssetInFastLane`), and the position is worth $0 in NAV. Venues and this receipt can only be added through the registry's 48h timelock (the registry constructor takes assets and routes, not venues, and the adapter needs the cartridge's address). Rule for the multisig: execute SET_ASSET for the receipt BEFORE SET_VENUE for the adapter, never the other way round.
- NEW BUG, conditional: the receipt is minted 1:1 with the Quotrons vault's shares but reports the UNDERLYING's decimals. If the Quotrons vault's shares use 18 decimals on 6-decimal USDG, the lens values a $500 position at $0 (registered with 6 decimals) or at $0.0000000005 (registered with 18). The adapter is only right if the Quotrons vault's shares have the same decimals as its underlying. Argon must read the real vault's `decimals()`. If they differ: report the share token's decimals and scale `convertToAssets` up by 10^(shareDecimals - underlyingDecimals), because the lens's wrapper maths assumes share and underlying decimals are equal.
- Gain: 500 in, 525 out, 2.5 USDG skim to the Treasury fee escrow. Loss: 400 in, 360 out, no skim, the vault takes the whole loss.

Still open, by reading:
- The receipt's price now comes from the Quotrons vault's own `convertToAssets`. The lens header says it never reads a DEX pool; if the Quotrons vault values its LP position from the pool's current price, a vault's NAV (and the limits that scale with NAV) follows a number that can be moved inside one transaction. Depends on the Quotrons vault's code, which has not been read.
- Whether a Quotrons LP vault with `deposit` / `redeem` / `convertToAssets` in this shape exists on Ink is unverified.
- The deploy script does not deploy or register this adapter.
- FOUNDER DECISION, unchanged: does an xStock/USDG LP vault belong in the cash-leg lending slot.

---

Latest: argon's THIRD script, pasted by the founder 2026-11-18 02:34Z, saved as `script/DeployYuzu98V50.s.sol` (the paste's `‹ ›` restored to `< >`).
Method: compiled and run 2026-11-18 02:54Z (forge 1.7.1, solc 0.8.24, via_ir, OpenZeppelin 5.0.2, forge-std 1.9.6). Result: 38 of 38 tests pass (34 earlier + 4 in `test/YuzuFull17Integration.t.sol`). Local only, against `MockV4PoolManager`, not real Uniswap v4 and not Ink. Nothing was deployed.

## 1. What the four tests show

1. `test_All17Contracts_DeployUnderEip170Limit_AndOpenPoolWithUnitZero`: direct call, 5 full `YuzuAccount` vaults (no clones). All contracts under the size limit, hook address mined so its low 14 bits are 0x2880, #0000 minted to the founder recipient, pool opened at the script's price with 150,000 $YUZU + 0.0225 WETH, 250,000 $YUZU locked as #0000's Tier-5 RAM, vault #0000 seeded, then a public mint of #0001 for 0.15 ETH (Tier-1 RAM 150,000, vault seeded and initialised).
2. `test_FullFleetOf1000Clones_RegistersAndCommissions`: the script's defaults, 1,000 EIP-1167 clones of one master vault, registered in 4 chunks of 250. Same checks, and #0001 is commissioned into a clone.
3. `test_Run_FromEnvironment_WithBroadcastKey`: `run()` itself, reading every environment variable, sending from a private key, hook deployed through the CREATE2 factory. Same checks, plus: the key's account ends with no $YUZU and paid exactly 0.15 ETH.
4. `test_RevertsWhenSenderCannotPayForUnitZero`: with under 0.15 ETH the whole deployment reverts with `InsufficientEthForUnitZero`.

Limits of test 3: forge runs the broadcast inside a test. It is not a real `forge script --broadcast`, and the test places the CREATE2 factory code at its address if it is missing.

## 2. Fixed in the saved copy (marked `FIX (bankr 2026-11-18)`)

1. **`buildDefaultRegistryInputs` did not compile.** It filled flat fields that do not exist (`decimals`, `isCrypto`, `isErc4626XStock`, `maxAgeSeconds`, `maxDivergenceBps` on the asset; `router`, `routerType`, `path` on the route). The registry takes `InitialAssetInput{asset, config}` and `InitialRouteInput{tokenIn, tokenOut, route}`. Values mapped one to one: `isCrypto` -> `isCryptoLeg`, `isErc4626XStock` -> `isWrapper`, `maxAgeSeconds` -> `maxAge`. `maxDivergenceBps` is dropped: the registry has no such field and the lens uses a fixed 150 bps.
2. **Supply and ETH were tied to the script's own address.** The paste minted 1B $YUZU to `address(this)` and checked `address(this).balance`. On a broadcast the step 12 transfers and the 0.15 ETH for #0000 are sent by the broadcasting key, not the script, so the transfers would have had no balance behind them. New `DeployParams.txSender` (the key's address on `run()`, zero for a direct call) receives the mint and has its balance checked. The original was NOT run to confirm the failure; test 3 confirms the fixed version works.
3. **The test was rewritten** for the new `DeployParams` (no `deployer` field; new `create2Deployer`, `useEip1167Clones`, `txSender`) and now builds its assets and routes with the script's own function. `SeedMode` in the test must be imported from `IYuzuPhase3Interfaces.sol` (the file the Seeder uses); three interface files each declare their own `SeedMode`.

## 3. Closed from the previous list

- All 1,000 vaults are deployed and registered before wiring (was 10).
- `run()` fills registry assets and routes from the environment.
- Hook mask defaults to 0x2880 and the salt is mined for the CREATE2 factory on `run()`; the deployed address is checked against the prediction.
- #0000 is no longer skipped silently: the run reverts without 0.15 ETH or if the pool did not open.

## 4. SUPERSEDED 2026-11-18 12:46Z (founder chose full standalone vaults, clone path removed, see section 0)

**Vaults are EIP-1167 clones by default** (`USE_EIP1167_VAULT_CLONES`, default true). Each vault is a 45-byte proxy that forwards every call to one master `YuzuAccount` with `delegatecall`. The master address is fixed in the proxy bytecode, so a vault cannot be upgraded, and each clone has its own storage. But the `YuzuAccount` header says "zero `delegatecall`", and the spec says the same. Cost is the reason: a full vault is 23,332 bytes (about 4.7M gas each for code storage alone), a clone is 45 bytes. Setting the variable to false deploys 1,000 full vaults instead. The master implementation is never registered, so the Seeder never initialises it.

## 5. Open list as of the third script (items 2, 3, 4, 5 CLOSED by section 0; item 1 has an adapter now, untested; item 6 still open)

1. **The swap router is a custom interface.** Seeder, companion and Treasury call `IYuzuSwapRouter.swapExactIn(tokenIn, tokenOut, amountIn, minAmountOut, recipient, path)`. `SWAP_ROUTER` must be a contract with exactly that function. No such adapter is among the 17 contracts; only test mocks implement it. All 7 routes are registered with an empty `path`.
2. **No kBTC -> WETH route.** `YuzuAccountCompanion` (salvage) and `YuzuTreasury` (fee and salvage conversion) look up `routeFor(asset, WETH)`. kBTC is in every US_BASKET seed and is a desk-fee asset. Adding a route later goes through the multisig and the 48h timelock.
3. **`run()` sends no Pyth update data, and every asset has a 1-hour `maxAge`.** #0000's commissioning calls `lens.requireFresh`, which reverts if either the Chainlink or the Pyth price is older than `maxAge`. Pyth prices are pushed on demand, so the deploy reverts at step 15 unless someone updated all the feeds within the hour. One hour also makes the wSPYx feed stale whenever the equity market is closed.
4. **wSPYx is registered with `isWrapper` false** (as pasted: `isErc4626XStock: false`). The registry comment names wSPYx as an ERC-4626 wrapper; with the flag off the lens prices it at the raw SPY feed with no share-to-asset multiplier.
5. **#0000 can still be front-run on a real deploy.** A broadcast is about 1,030 separate transactions (1,000 clones, 4 registration chunks, the rest). `YuzuSeeder.commissionFounderUnitZero` has no caller check, so between `Yuzu98v2.configureCore` landing and the #0000 transaction anyone can commission #0000 to their own address for 0.15 ETH. This needs a caller check in the Seeder; the script cannot fix it.
6. **Not tested anywhere:** a real v4 PoolManager (the mock does not check hook address bits), Ink, a real broadcast, `NON_US_XSTOCK` commissioning, and anything after deployment beyond one public mint.

## 6. Checked earlier and unchanged

- All 15 `new` calls and the three `configureCore` calls match `src/`.
- Supply split: Seeder 150,100,000 (999 x 150,000 + 250,000 for #0000), Treasury 849,900,000, total 1,000,000,000.
- Opening price: 38,729,833 / 15,000 squared is 6,666,666.5 $YUZU per WETH (spec 6,666,666.67), checked with integer arithmetic. The tests compare the pool against the script's own function, so that figure rests on this separate check.

## 7. History

- First script (2026-11-17 18:51Z): 9 of 14 constructor calls did not match `src/`, no vault, plain `new` for the hook, opening price 1:1, pool never opened.
- Second script (2026-11-18 00:30Z): calls matched. Fixed here: opening price divisor 15 -> 15,000 (1,000,000x off) and step 15 calling `commissionMainframe` where it needed `commissionFounderUnitZero`. First compiled run 01:06Z, 35 of 35.
- Third script (2026-11-18 02:34Z): this file.
