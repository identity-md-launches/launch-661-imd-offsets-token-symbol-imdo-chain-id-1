# IMD Offsets (IMDO)

IMDO funds regenerative contributions: the public treasury buys and retires ecological credits on Regen Network. The contracts collect contributions; they do not execute or verify those off-chain purchases and retirements. Holders receive **no payouts, rewards, yield or staking**.

This submission contains a plain token and an immutable Uniswap v4 pool hook in `src/IMDOFeeHook.sol`, plus a Foundry launch script. It has no external Solidity dependencies and builds offline with an installed Solidity 0.8.26 compiler. No configuration files or libraries are required or changed.

## Immutable economics

| Item | Value |
| --- | --- |
| Network | Sepolia, chain ID **11155111** |
| Token | **IMD Offsets**, **IMDO**, **18 decimals** |
| Initial supply | **1,000,000,000 IMDO** = **10^27** base units, minted once to the constructor caller (the launch factory) |
| Quote asset | Native ETH, currency address `0x0000000000000000000000000000000000000000` |
| Treasury | **`0xb1eC9d1C36974d05eb9889eBf8A150b05791E559`** |
| Hook fee denominator | **1,000,000 ppm** |
| Maximum bracket | **20,000 ppm = 2%** |
| Snapshot lag | Previous block's closing pool token inventory; unchanged throughout the current block |

Transfers and `transferFrom` move the exact requested amount. There is no transfer tax, transfer restriction, owner, mint entry point after construction, blacklist, pause, trading gate, proxy or upgrade path. `burn(amount)` burns only the caller's balance and reduces total supply. `approve` and `transferFrom` use ordinary ERC-20 allowances, including unlimited allowance at `uint256.max`. Burning does not enable replacement minting.

| Cumulative settled IMDO input / lagged token reserve | Basis points | Hook rate |
| --- | --- | --- |
| Less than 1% | Less than 100 | **0 ppm / 0%** |
| At least 1%, less than 3% | 100–299 | **5,000 ppm / 0.5%** |
| At least 3%, less than 5% | 300–499 | **10,000 ppm / 1%** |
| At least 5% | 500 or more | **20,000 ppm / 2%** |
| Any positive sell while the lagged reserve is **0** (the launch block, or the block after one that closed with no inventory) | not defined | **20,000 ppm / 2%** (the cap, conservative) |

The integer boundary for a bracket is `ceil(reserve * bps / 10_000)`. No bracket exceeds the hardcoded cap, and **no single swap leg ever pays more than 2% of its own size** (see the per-leg bound below). These numbers and the treasury cannot be changed by any caller, including the deployer. PoolManager and token addresses are immutable constructor arguments. The hook binds exactly once, during `beforeInitialize`, to the **complete pinned launch key**: currency0 native ETH, currency1 IMDO, LP fee **3,000 ppm** (`POOL_FEE`), tick spacing **60** (`TICK_SPACING`), hooks = this contract. Any other key, including another fee tier or tick spacing, is refused with `InvalidPool()`.

## Settled fees and transaction batching

A sell is identified by a **negative settled token component of `BalanceDelta` in `afterSwap`**, including partial fills and exact-output trades. Requested input amounts, router identities and `hookData` do not determine its size. Buys pay **zero hook fee** in both modes. Ordinary pool LP fees still apply to buys and sells.

For one sell in a transaction, with bracket rate `r`:

- **Exact input:** `floor(gross ETH output * r / 1_000_000)` is taken from the unspecified output currency and sent **directly from PoolManager to the treasury**.
- **Exact output:** v4 permits `afterSwap` to change only the unspecified currency, which is IMDO input in this case. `floor(settled IMDO input * r / 1_000_000)` additional IMDO is charged to the swapper and recorded as an **ERC-6909 claim of the hook** (`accruedToken`); it is **burned when anyone calls `harvest()`**. Nothing is ever taken out of PoolManager inside `afterSwap` for the token side: a router that follows the valid `sync -> transfer -> swap -> settle` order would otherwise have its settlement credit reduced and pay the fee twice. The requested ETH output is unchanged; this mode does not send an ETH fee to the treasury.

Transient storage groups **all sells by `tx.origin` in one transaction**, across routers and both swap modes. This is an accounting key, never an authorization check. Buys do not reset the counters. Sells executed for several principals under one origin (an ERC-4337 bundler, a relayer, a batch settler) share that origin's cumulative bracket, so a later principal's leg can pay up to the 2% cap when its own sell alone would be in a lower bracket; the per-leg bound guarantees it never pays more than that. A new transaction starts with empty counters.

Batching uses a cumulative bill, including a catch-up charge when crossing a bracket. Let `S` be cumulative settled token input, `Q` cumulative gross ETH output, and `P` the fee already paid, valued in ETH-wei times 1,000,000. For each sell, `r = feeRate(S, laggedReserve)` and `D = Q*r - P`:

- Exact input collects `min(floor(D / 1_000_000), floor(currentETHOutput * 20_000 / 1_000_000))` ETH and adds that amount times 1,000,000 to `P`.
- Exact output collects `min(floor(D * currentTokenInput / (currentETHOutput * 1_000_000)), floor(currentTokenInput * 20_000 / 1_000_000))` IMDO and credits its settled exchange-value to `P`, rounded down. Full-width multiplication prevents intermediate overflow. Fractional residuals carry to later legs in the transaction.
- **Per-leg hard cap:** a leg is never billed more than **`MAX_FEE_PPM` = 2% of its own size**: the ETH fee never exceeds 2% of the leg's gross ETH output and the IMDO fee never exceeds 2% of the leg's settled IMDO input, whatever earlier legs under the same origin did. The swapper's ETH delta for a sell is therefore never negative, so routers that take only positive output per leg settle every leg. Whatever part of the cumulative bill a leg could not carry stays in `D` and is charged, within the same cap, on the next sell leg of the same transaction.
- A dust swap with token input and zero ETH output still adds its token volume and pays nothing itself; its catch-up charge is collected, within the cap, by the next leg that has output.

For a single sell, the cap never binds: every bracket is at most 2% of the leg. Within one transaction every leg pays at least the cumulative bracket on its own size, up to 2%, so the aggregate fee of a split sell lies between the brackets of its legs taken alone and the bracket of the whole amount sold at once. Mixed modes settle the same quote-valued bill using each fee-paying leg's actual exchange ratio. Different execution prices and integer rounding can affect the token amount charged.

**Trade-off recorded for the requester.** The cap deliberately weakens retroactive catch-up: a sell split across legs of one transaction can pay less than the same amount sold in one leg (for example two legs of 3% each pay about 1.5% in aggregate instead of 2%), which is already what splitting across separate transactions in the same block achieves, since cumulative billing is transaction-local by the brief. In exchange no seller, including a principal whose sell is bundled behind a stranger's under a shared `tx.origin`, can ever lose more than 2% of a leg. Without the cap such a leg could forfeit its entire output to the treasury. There is no sell gate, allowlist or administrator; insufficient balances, gas, v4 numeric limits and router slippage constraints can still revert a trade.

## Reserve integrity and fee claims

`liveReserve` accounts for **this pool's** IMDO inventory: liquidity deposits less withdrawals and collected LP fees, plus swap token inputs less outputs, plus token donations. Token protocol fees accrued during the swap are explicitly subtracted using a read-only `beforeSwap` observation. It includes uncollected LP fees, excludes hook and protocol claims, and covers positions outside the active tick range. It never treats the singleton PoolManager's entire token balance as this pool's reserve. Unrelated pools and unsolicited transfers cannot inflate it.

Before the first inventory update in a new block, the old inventory becomes `laggedReserve`. Every later operation in the block uses that same snapshot. A same-transaction or same-block liquidity addition, donation or buy/sell sequence cannot increase the fee denominator. Across idle blocks the last inventory is still the previous block's closing value. `reserveSnapshot()` exposes the denominator the next swap will use. In the launch block, or after a previous block with zero reserve, a positive sell of any size uses the conservative **2%** bracket (the explicit last row of the bracket table): the snapshot is never seeded from the live inventory, because that would reopen same-block inflation exactly in the launch block; no division by zero or special trading lock occurs.

**Residual exposure, by design of the one-block lag:** manipulation sustained across a block boundary is outside this protection. In particular, the denominator counts token-only positions outside the active range, so a seller who parks a large IMDO-only position below the current price in block N, sells in block N+1 against the inflated snapshot and withdraws the position in the same transaction lowers their bracket at the cost of gas and one block of holding tokens they already own. Closing it would require counting only in-range liquidity or a longer lag, neither of which the brief asks for.

If PoolManager holds less native ETH than an ETH fee, or the treasury rejects ETH, the hook mints an **ERC-6909 claim** for the fee instead of blocking settlement. The optional direct ETH payment is limited to **80,000 gas** so a recipient cannot consume an unbounded gas budget; callers still must supply enough gas to complete the swap and any fallback. Token fees (exact-output sells) are **always** claims. PoolManager claims are backed when the router completes settlement.

Anyone may call `harvest()` outside an existing manager unlock. It redeems **only recorded accrued fees**, with ETH paid directly to the fixed treasury and IMDO burned. It accepts no recipient or asset argument. The two legs are independent: if the treasury rejects ETH, the ETH claim simply stays recorded and redeemable while the token claim is still burned in that same harvest; trading continues through the claim fallback either way. No claim belongs to the harvester. Native and token fee counters cannot be reassigned. The hook authorizes `unlockCallback` only during its own harvest, and every v4 callback requires the immutable PoolManager caller. Transient reentrancy protection covers swaps, observations and harvesting.

Normal token and ETH user balances never remain in the hook after a supported operation: its persistent assets are accrued manager claims. Forced ETH, unsolicited token transfers and donated ERC-6909 claims cannot be prevented and are not sweepable by `harvest`; do not send assets directly to the hook.

## Factory and swarm compatibility

The **pool's own LP fee** remains the manifest's static `pool.fee`: **3,000 ppm (0.3%)**, one of the launch policy's listed tiers, with tick spacing **60**. The factory sets them when it initializes the pool; the hook accepts exactly this key and no other (`POOL_FEE`, `TICK_SPACING`). The hook returns zero from liquidity delta callbacks and zero LP fee override from `beforeSwap`. It never modifies, collects, owns or reroutes the factory's liquidity position. The swap's pool math and LP fee growth run unchanged before the hook adds its fee.

**LP fee destination:** PoolManager credits the LP fees to the liquidity positions, including the factory-owned launch position. The factory collects and distributes its position's fees to **its existing configured payout recipients under its existing distribution logic**. If PoolManager protocol fees are enabled, the protocol portion remains under PoolManager's protocol accounting. **Hook fee destination:** treasury ETH for exact-input sells (paid during the swap, or as a claim redeemed by `harvest()`), and for exact-output sells an IMDO claim that `harvest()` burns; claims are redeemable only to those same destinations. Holding IMDO grants no claim on either fee stream.

The swarm Merkle distributor continues ordinary untaxed token transfers and has no interaction with the hook. Neither its root nor its claims are rewritten. The supplied workspace contains no production factory/distributor source, address, ABI or recipient list, so this submission cannot name those existing recipient addresses or claim a live factory rehearsal. Compatibility was checked locally with real v4 pool accounting, a factory-style position and unchanged payout routine, and a Merkle claim harness; the supplied production factory calldata still needs its own simulation.

## Permissions and calls

The mined low **14** address bits must equal **`0x25d4` (9684)**:

| Enabled callback | Purpose |
| --- | --- |
| `beforeInitialize` | Check the complete pinned key (native ETH/IMDO, fee 3000, tick spacing 60, this hook) and bind one pool |
| `afterAddLiquidity`, `afterRemoveLiquidity` | Observe inventory, including factory fee collection; return zero hook liquidity delta |
| `beforeSwap` | Record protocol fee counter; return zero delta and zero LP fee override |
| `afterSwap`, `afterSwapReturnDelta` | Account settled reserve changes and bill sell fees |
| `afterDonate` | Observe token donations |

All other permission flags are false, including `beforeSwapReturnDelta` and both liquidity-return-delta permissions. The constructor checks **all** 14 address bits; salt mining cannot omit unwanted bits. Initialization is protected even when a prospective hook address has no deployed code: v4 must successfully invoke the required initialization callback.

Anyone can deploy `IMDOToken`, transfer/approve their tokens, burn their own tokens, call read-only getters, or harvest accrued hook claims. Only PoolManager can drive the enabled callbacks and the guarded harvest callback. There are no other privileged or administrative functions. `feeRate`, `reserveSnapshot` and `getHookPermissions` are publicly readable. The launch script's `run`, `mine` and `hookCreationCode` are local tooling, not deployed governance powers.

The self-contained `BaseHookFee` follows [OpenZeppelin's BaseHookFee pattern](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/fee/BaseHookFee.sol): an independent fee on the settled unspecified currency, returned as a positive hook delta, with manager claims available for deferred collection. This is an adaptation, not an import or a claim of inheriting the published library unchanged. It adds fixed economic rules, direct payment/burning, cumulative billing and reserve observation. The local tuples match the [v4 callback ABI](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IHooks.sol).

Configuration record: hook `BaseHookFee`; access **none**; pausable **false**; shares **false**; transient storage **true**; one-block reserve lag **1**; currency settlement through manager `take/mint/burn/unlock`; safe signed bounds and full-width fee conversion implemented locally. Cancun or later is required for transient storage.

## Build and launch script

The default offline source build is `forge build`. Reproducible launch artifacts use:

```sh
forge build --use 0.8.26 --evm-version cancun --optimize --optimizer-runs 200 --via-ir --no-metadata
```

Use these same compiler settings for **every** preparation, simulation and final launch. `--no-metadata` avoids metadata bytes being interpreted as executable opcodes by the pinned floor's whole-bytecode scanner. No build configuration file is created. The source also compiles without optimization.

`script/Deploy.s.sol:Deploy` is the reference deployment. It reads **no keys** and only this configuration; its locally declared Foundry cheatcode interface needs no `forge-std` dependency.

| Variable | Meaning / default |
| --- | --- |
| `EXPECTED_CHAIN_ID` | **0** (default) accepts the chain the script runs on; any other value must equal `block.chainid`. The chain itself must be **31337** (local dry run) or **11155111** (Sepolia); every other chain reverts with `InvalidConfiguration()` |
| `POOL_MANAGER` | The Uniswap v4 PoolManager, passed to the hook's constructor and never hardcoded. **Required on 11155111** and must have code. Optional on 31337: when unset, the script deploys `LocalPoolManagerStandIn`, an empty contract whose only purpose is to satisfy the hook constructor's "manager has code" check in an offline EVM; no pool can be initialized against it |

`run()` performs, between `vm.startBroadcast()` and `vm.stopBroadcast()`:

1. `new IMDOToken()` with CREATE. The whole fixed supply goes to the broadcasting account, exactly as it goes to the launch factory when the factory is the constructor caller.
2. `mine(CREATE2_DEPLOYER, keccak256(hookCreationCode(poolManager, token)), 0)`: a bounded search (at most **1,000,000** salts) for a salt whose CREATE2 address through Foundry's deterministic deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` has low 14 bits exactly **`0x25d4`**.
3. `new IMDOFeeHook{salt: salt}(poolManager, token)`. Foundry routes a salted `new` in broadcast mode through that deployer, so the deployed address equals the mined prediction; the script reverts with `InvalidLaunchResult()` otherwise.

On 31337 without `POOL_MANAGER` the stand-in manager is deployed first, inside the same markers, so an anvil broadcast is self-consistent. Nothing else is deployed: no pool, no liquidity, no factory or distributor call. After the markers, `_attest` re-reads the deployed contracts and reverts with `InvalidLaunchResult()` unless the token name, symbol, 18 decimals and **10^27** fixed supply, the hook's manager and token bindings, treasury, **20,000 ppm** cap, permission bits and not-yet-initialized state all match. It then emits `LaunchAttested` (chain ID, token, hook, manager, salt, flags, treasury, supply, cap, creation-code hashes) in the simulation trace. That event is not an on-chain registry.

The network's standard offline check passes on a bare local EVM:

```sh
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

It deploys the stand-in manager, the token and the hook on chain 31337 and returns `(token, hook, salt)`. `EXPECTED_CHAIN_ID=11155111` on that local EVM, chain 11155111 without `POOL_MANAGER`, or a `POOL_MANAGER` without code each revert with `InvalidConfiguration()` before any deployment.

**Sepolia (operator only).** `POOL_MANAGER=<v4 PoolManager> EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy --rpc-url "$SEPOLIA_RPC_URL" --account <name>` simulates; adding `--broadcast` submits the two deployments. This assignment did **not** broadcast a transaction or provide a signing key. The launch factory then initializes the ETH/IMDO pool with `hooks = <deployed hook>`, fee **3000** and tick spacing **60**; the hook accepts exactly that one initialization in `beforeInitialize` and refuses every other key. **Deploy and initialize in the same transaction.** The production flow is the factory's: it deploys the hook and initializes the pool atomically, so no window exists in which anyone else could initialize the pinned key at a different price. The two-step sequence above (script deploys, factory initializes later) is for the offline dry run and the operator's simulation only; if it were ever used for a live launch, a third party could initialize the pinned key first at an arbitrary price (the hook would then be bound to that pool with no rebind path, and the factory's own initialize would revert with `PoolAlreadyInitialized`). The pinned key means no *other* ETH/IMDO key can capture the hook, but only atomic deploy-and-initialize rules out the price squat. The launch attestation below writes the manager as `$poolManager` and the token as `$token`, the values the network's deployer fills in; a factory that deploys the hook itself must use the same creation code with the same two constructor arguments and a salt mined for the deployer it actually uses. Changing compiler settings, constructor arguments or the deployer changes the salt.

## Launch attestation

The following is the **source-level launch attestation**, embedded here because adding a separate manifest is outside the allowed paths. Address placeholders must be resolved by the actual launch factory/deployer. It records intended launch parameters, not a deployed address, transaction, audit or completed production rehearsal.

```json
{
  "status": "source-ready; offline dry run passes on 31337; Sepolia simulation by the operator pending",
  "chainId": 11155111,
  "deployScript": {
    "artifact": "script/Deploy.s.sol:Deploy",
    "configuration": ["EXPECTED_CHAIN_ID", "POOL_MANAGER"],
    "allowedChainIds": [31337, 11155111],
    "create2Deployer": "0x4e59b44847b379578588920cA78FbF26c0B4956C",
    "deploysBetweenBroadcastMarkers": ["IMDOToken (CREATE)", "IMDOFeeHook (CREATE2, mined salt)"],
    "offlineCheck": "EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline"
  },
  "token": {
    "artifact": "src/IMDOFeeHook.sol:IMDOToken",
    "name": "IMD Offsets",
    "symbol": "IMDO",
    "decimals": 18,
    "initialSupply": "1000000000000000000000000000",
    "constructorArguments": [],
    "initialRecipient": "constructor caller: launch factory"
  },
  "hook": {
    "artifact": "src/IMDOFeeHook.sol:IMDOFeeHook",
    "constructorArguments": ["$poolManager", "$token"],
    "flags": "0x25d4",
    "treasury": "0xb1eC9d1C36974d05eb9889eBf8A150b05791E559",
    "sellThresholdBps": [100, 300, 500],
    "feePpm": [0, 5000, 10000, 20000],
    "maximumFeePpm": 20000,
    "reserveLagBlocks": 1,
    "perLegHardCapPpm": 20000,
    "exactOutputFee": "IMDO claim, burned by permissionless harvest()",
    "exactInputFee": "ETH to treasury during the swap, or ETH claim redeemed to the treasury by harvest()",
    "pinnedPoolKey": {"fee": 3000, "tickSpacing": 60},
    "access": "none",
    "upgradeable": false
  },
  "pool": {
    "currency0": "0x0000000000000000000000000000000000000000",
    "currency1": "$token",
    "fee": 3000,
    "tickSpacing": 60,
    "hooks": "$minedHook",
    "initializer": "$launchFactory",
    "initializeInSameTransactionAsHookDeployment": true
  },
  "compiler": {
    "version": "0.8.26",
    "evmVersion": "cancun",
    "optimizer": true,
    "optimizerRuns": 200,
    "viaIR": true,
    "metadata": false
  },
  "buildCodeHashes": {
    "tokenCreationCodeKeccak256": "0xce0eec3522bd7a5dd9df05e1bcf4b92f1a0e6958cbb29b14fa2bc6052ca8963d",
    "tokenRuntimeCodeKeccak256": "0xafd4a6163de1dbde9aa5a0070480863f6d1def0ac2685defabcf08ebffddd74e",
    "hookCreationCodeWithoutArgumentsKeccak256": "0xfc62facd61905ef2cf79a9bc48328f6462a73bbe11a48bff67f7bce0254926bb",
    "hookRuntimeCodeKeccak256": "0xc5ea8cf2ffc18116654c00266146cefdfd75cddd96d33137735b39f37a3b72d3"
  },
  "holdersReceivePayouts": false,
  "externalAuditPerformed": false,
  "liveDeploymentPerformed": false
}
```

## Local verification and limits

**Results of the first round (accepted code):** the scratch suite passed **27 tests**, including **512 fuzz cases** and **32 invariant runs × 32 calls = 1,024 calls**, with zero invariant reverts, on a real Uniswap v4 PoolManager with actual settlement. It compared equivalent hooked and hookless factory positions for pool fee growth, collection and final recipient balances, and covered both free buy modes, exact-input thresholds and all exact-output fee tiers, exact treasury receipts and burns, batched and mixed-mode cumulative bills, same-transaction reserve inflation, protocol fee accounting, fresh token-only liquidity, rejection-to-claim fallback and harvesting, callback/permission/opcode restrictions, untaxed Merkle claims, ERC-20 allowances, transfers and burning. Stateful checks asserted zero raw hook custody, recorded claims equal to manager claim balances, reconciled pool inventory and non-increasing supply.

**Results of the second revision** (changes: deploy script rewritten; per-leg fee bound in `_bill`): offline build, format check and the dry-run script passed; the two supplied protected floor suites passed all 9 tests; a 10-test scratch suite on a real PoolManager covered free buys, single-sell brackets, split and tiny-leg billing and the deploy script.

**Results of this revision** (changes: per-leg fee bound tightened to the 2% cap; exact-output fee is always a claim burned by `harvest()`; `harvest()` ETH and token legs made independent; pool key pinned to fee 3000 / tick spacing 60; deploy script attests the pinned key): offline `forge build` (default settings and the attested settings above) and `forge fmt --check` pass. `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` succeeds on chain 31337. The optimized attested hook runtime is **7,105 bytes**, and the token runtime is **1,337 bytes**, below the **24,576-byte** limit; an opcode scan of both builds finds no `SELFDESTRUCT`, `DELEGATECALL` or `CALLCODE`. A scratch suite of **13 tests** on a real Uniswap v4 PoolManager passed, including the reviewer's attached proof (a `sync -> transfer -> swap -> settle` router now loses exactly the settled swap delta; on the accepted code it lost the hook fee a second time); two principals' sells under one bundler origin with the second leg (0.2% and 0.05% of the reserve) billed at most 2% of its own gross in exact-input and exact-output modes (on the accepted code the 0.2% leg paid 27.7%); a squatter's `initialize` with fee 500 / tick spacing 1 refused and the launch key then accepted; the launch-block 2% rule followed by a free 1 bps sell in the next block; exact brackets at 0 / 5,000 / 10,000 / 20,000 ppm; free buys; the exact-output claim minted during the swap and burned by `harvest()`; `harvest()` burning the token claim while a treasury that rejects ETH leaves the ETH claim redeemable, then redeeming it once the treasury accepts ETH; two 3% legs in one transaction billed at 1% then 2% of the second leg; same-transaction liquidity inflation not lowering the bracket; and the hook holding nothing but its recorded claims.

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache \
forge test --offline --use 0.8.26 --evm-version cancun --optimize --via-ir \
  --match-path 'test/scratch/**/*.sol' \
  -R forge-std/=<forge-std>/src/ -R v4-core/=<v4-core>/ \
  -R solmate/=<v4-core>/lib/solmate/ -R @openzeppelin/=<v4-core>/lib/openzeppelin-contracts/
```

Scratch fixtures and their test-only dependency sources are excluded from delivery as required by the assignment. No live factory fork, independent external audit, formal verification, Slither/Mythril run or Regen retirement was performed. The production factory's address and launch call were not supplied; its rehearsal against the deployed hook remains a deployment prerequisite.
