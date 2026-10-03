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

The integer boundary for a bracket is `ceil(reserve * bps / 10_000)`. No bracket exceeds the hardcoded cap. These numbers and the treasury cannot be changed by any caller, including the deployer. PoolManager and token addresses are immutable constructor arguments. The hook binds exactly once to the ETH/IMDO launch pool during `beforeInitialize`.

## Settled fees and transaction batching

A sell is identified by a **negative settled token component of `BalanceDelta` in `afterSwap`**, including partial fills and exact-output trades. Requested input amounts, router identities and `hookData` do not determine its size. Buys pay **zero hook fee** in both modes. Ordinary pool LP fees still apply to buys and sells.

For one sell in a transaction, with bracket rate `r`:

- **Exact input:** `floor(gross ETH output * r / 1_000_000)` is taken from the unspecified output currency and sent **directly from PoolManager to the treasury**.
- **Exact output:** v4 permits `afterSwap` to change only the unspecified currency, which is IMDO input in this case. `floor(settled IMDO input * r / 1_000_000)` additional IMDO is taken and **burned**. The requested ETH output is unchanged; this mode does not send an ETH fee to the treasury.

Transient storage groups **all sells by `tx.origin` in one transaction**, across routers and both swap modes. This is an accounting key, never an authorization check. Buys do not reset the counters. Transactions from an account-abstraction bundler sharing one origin also share its transaction bracket. A new transaction starts with empty counters.

Batching uses a cumulative bill, including a catch-up charge when crossing a bracket. Let `S` be cumulative settled token input, `Q` cumulative gross ETH output, and `P` the fee already paid, valued in ETH-wei times 1,000,000. For each sell, `r = feeRate(S, laggedReserve)` and `D = Q*r - P`:

- Exact input collects `floor(D / 1_000_000)` ETH and adds that amount times 1,000,000 to `P`.
- Exact output collects `floor(D * currentTokenInput / (currentETHOutput * 1_000_000))` IMDO and credits its settled exchange-value to `P`, rounded down. Full-width multiplication prevents intermediate overflow. Fractional residuals carry to later legs in the transaction.
- A dust swap with token input and zero ETH output still adds its token volume. Exact input can settle an earlier catch-up bill; a zero-output exact-output leg cannot convert a quote bill and leaves it for a later leg.

For batches of exact-input sells, aggregate ETH fees equal the final cumulative gross ETH output times the final bracket, rounded down. Mixed modes settle the same quote-valued bill using each fee-paying leg's actual exchange ratio. Different execution prices and integer rounding can affect the token amount burned.

**Router constraint:** full cumulative billing at discontinuous brackets can charge more than a tiny last leg's ETH output. For example, selling just below 1% and then crossing 1% incurs the 0.5% bill on the earlier proceeds too. That last leg can have a negative ETH delta. Routers must settle the aggregate transaction deltas or provide the additional ETH, and include catch-up charges in slippage limits. A router that requires every individual sell to have positive ETH output is not compatible with that batching edge case. The 2% cap bounds the cumulative bracket, not each catch-up leg independently. There is no sell gate, allowlist or administrator; insufficient balances, gas, v4 numeric limits and router slippage constraints can still revert a trade. Full retroactive billing and unconditional compatibility with output-only routers cannot both be promised with an `afterSwap` unspecified-currency delta.

## Reserve integrity and fee claims

`liveReserve` accounts for **this pool's** IMDO inventory: liquidity deposits less withdrawals and collected LP fees, plus swap token inputs less outputs, plus token donations. Token protocol fees accrued during the swap are explicitly subtracted using a read-only `beforeSwap` observation. It includes uncollected LP fees, excludes hook and protocol claims, and covers positions outside the active tick range. It never treats the singleton PoolManager's entire token balance as this pool's reserve. Unrelated pools and unsolicited transfers cannot inflate it.

Before the first inventory update in a new block, the old inventory becomes `laggedReserve`. Every later operation in the block uses that same snapshot. A same-transaction or same-block liquidity addition, donation or buy/sell sequence cannot increase the fee denominator. Across idle blocks the last inventory is still the previous block's closing value. `reserveSnapshot()` exposes the denominator the next swap will use. In the launch block, or after a previous block with zero reserve, a positive sell uses the conservative **2%** bracket; no division by zero or special trading lock occurs. Manipulation sustained across a block boundary is outside this one-block protection.

If PoolManager lacks immediately transferable fee assets, the hook mints an **ERC-6909 claim** for the fee instead of blocking settlement. Native payment also falls back to claims if the treasury rejects ETH. The optional direct payment is limited to **80,000 gas** so a recipient cannot consume an unbounded gas budget; callers still must supply enough gas to complete the swap and any fallback. PoolManager claims are backed when the router completes settlement.

Anyone may call `harvest()` outside an existing manager unlock. It redeems **only recorded accrued fees**, with ETH paid directly to the fixed treasury and IMDO burned. It accepts no recipient or asset argument. If the treasury still rejects ETH, a harvest attempting that ETH reverts atomically and the claims remain redeemable; trading continues through the claim fallback. No claim belongs to the harvester. Native and token fee counters cannot be reassigned. The hook authorizes `unlockCallback` only during its own harvest, and every v4 callback requires the immutable PoolManager caller. Transient reentrancy protection covers swaps, observations and harvesting.

Normal token and ETH user balances never remain in the hook after a supported operation: its persistent assets are accrued manager claims. An immediately taken token fee is burned in the same callback. Forced ETH, unsolicited token transfers and donated ERC-6909 claims cannot be prevented and are not sweepable by `harvest`; do not send assets directly to the hook.

## Factory and swarm compatibility

The **pool's own LP fee** remains the manifest's static `pool.fee`: **500 ppm (0.05%)**, **3,000 ppm (0.3%)**, or **10,000 ppm (1%)**. The script defaults to **3,000 ppm** and tick spacing **60**. The hook returns zero from liquidity delta callbacks and zero LP fee override from `beforeSwap`. It never modifies, collects, owns or reroutes the factory's liquidity position. The swap's pool math and LP fee growth run unchanged before the hook adds its fee.

**LP fee destination:** PoolManager credits the LP fees to the liquidity positions, including the factory-owned launch position. The factory collects and distributes its position's fees to **its existing configured payout recipients under its existing distribution logic**. If PoolManager protocol fees are enabled, the protocol portion remains under PoolManager's protocol accounting. **Hook fee destination:** treasury ETH for exact-input sells, burned IMDO for exact-output sells, or accrued claims redeemable only to those same destinations. Holding IMDO grants no claim on either fee stream.

The swarm Merkle distributor continues ordinary untaxed token transfers and has no interaction with the hook. Neither its root nor its claims are rewritten. The supplied workspace contains no production factory/distributor source, address, ABI or recipient list, so this submission cannot name those existing recipient addresses or claim a live factory rehearsal. Compatibility was checked locally with real v4 pool accounting, a factory-style position and unchanged payout routine, and a Merkle claim harness; the supplied production factory calldata still needs its own simulation.

## Permissions and calls

The mined low **14** address bits must equal **`0x25d4` (9684)**:

| Enabled callback | Purpose |
| --- | --- |
| `beforeInitialize` | Check native ETH/token, static LP fee tier, and bind one pool |
| `afterAddLiquidity`, `afterRemoveLiquidity` | Observe inventory, including factory fee collection; return zero hook liquidity delta |
| `beforeSwap` | Record protocol fee counter; return zero delta and zero LP fee override |
| `afterSwap`, `afterSwapReturnDelta` | Account settled reserve changes and bill sell fees |
| `afterDonate` | Observe token donations |

All other permission flags are false, including `beforeSwapReturnDelta` and both liquidity-return-delta permissions. The constructor checks **all** 14 address bits; salt mining cannot omit unwanted bits. Initialization is protected even when a prospective hook address has no deployed code: v4 must successfully invoke the required initialization callback.

Anyone can deploy `IMDOToken`, transfer/approve their tokens, burn their own tokens, call read-only getters, or harvest accrued hook claims. Only PoolManager can drive the enabled callbacks and the guarded harvest callback. There are no other privileged or administrative functions. `feeRate`, `reserveSnapshot` and `getHookPermissions` are publicly readable. The launch script's `prepare`, `mine` and `run` are local tooling, not deployed governance powers.

The self-contained `BaseHookFee` follows [OpenZeppelin's BaseHookFee pattern](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/fee/BaseHookFee.sol): an independent fee on the settled unspecified currency, returned as a positive hook delta, with manager claims available for deferred collection. This is an adaptation, not an import or a claim of inheriting the published library unchanged. It adds fixed economic rules, direct payment/burning, cumulative billing and reserve observation. The local tuples match the [v4 callback ABI](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IHooks.sol).

Configuration record: hook `BaseHookFee`; access **none**; pausable **false**; shares **false**; transient storage **true**; one-block reserve lag **1**; currency settlement through manager `take/mint/burn/unlock`; safe signed bounds and full-width fee conversion implemented locally. Cancun or later is required for transient storage.

## Build and launch script

The default offline source build is `forge build`. Reproducible launch artifacts use:

```sh
forge build --use 0.8.26 --evm-version cancun --optimize --optimizer-runs 200 --via-ir --no-metadata
```

Use these same compiler settings for **every** preparation, simulation and final launch. `--no-metadata` avoids metadata bytes being interpreted as executable opcodes by the pinned floor's whole-bytecode scanner. No build configuration file is created. The source also compiles without optimization.

`script/Deploy.s.sol:Deploy` reads the following configuration from the environment. Its locally declared Foundry cheatcode interface needs no `forge-std` dependency.

| Variable | Meaning / default |
| --- | --- |
| `POOL_MANAGER` | Required real PoolManager address; constructor argument, never hardcoded |
| `LAUNCH_FACTORY` | Required existing factory address |
| `TOKEN_ADDRESS` | Required factory-predicted token address, before token deployment |
| `HOOK_CREATE2_DEPLOYER` | Actual CREATE2 deployer; defaults to `LAUNCH_FACTORY` |
| `POOL_FEE` | One of 500, 3000, 10000; default **3000** |
| `TICK_SPACING` | Default **60**; valid positive v4 spacing, at most **32767** |
| `SALT_START` | CREATE2 search start; default **0**, at most **1,000,000 attempts** per search |
| `FACTORY_CALLDATA` | Existing factory's ABI-encoded atomic launch call; required for `run()` |
| `LAUNCH_VALUE` | ETH wei forwarded to that call; default **0** |

1. Configure the factory, manager, predicted token and pool values. Run `forge script script/Deploy.s.sol:Deploy --sig 'prepare()'` with the compiler options above. `prepare()` returns token creation code, hook creation code including constructor arguments, mined salt, predicted hook, pool key and pool ID. No deployment occurs.
2. Use the **existing factory's actual ABI** to encode `FACTORY_CALLDATA` from that returned plan. The factory must create the token itself, CREATE2-deploy the hook through the configured deployer, initialize the pool with the hook attached, and perform its ordinary liquidity allocation and swarm distribution in one transaction. There is no invented replacement factory ABI in this repository.
3. Run `forge script script/Deploy.s.sol:Deploy --rpc-url "$SEPOLIA_RPC_URL"` with the same compiler options and configured Foundry signing account to simulate `run()`. The script checks chain **11155111**, real manager/factory code, unoccupied predicted addresses, the returned token runtime and fixed supply, the hook's immutable bindings and initialized pool ID. Review the single factory call and its existing payout addresses. Do not use `--skip-simulation`.
4. The deployer may submit that same simulated factory call using Foundry's `--broadcast` workflow. This assignment did **not** broadcast a transaction or provide a signing key. Script checks after the factory call are simulation checks; the real factory remains responsible for its atomic on-chain launch assertions.

`LaunchPrepared` and `LaunchAttested` script events expose creation-code hashes, constructor bindings, salt, permission bits, pool ID, fee values and factory calldata hash in the simulation trace. They are not an on-chain attestation registry. Changes to compiler settings, constructor arguments, factory deployer or creation code require a new salt calculation.

## Launch attestation

The following is the **source-level launch attestation**, embedded here because adding a separate manifest is outside the allowed paths. Address placeholders must be resolved by the actual launch factory/deployer. It records intended launch parameters, not a deployed address, transaction, audit or completed production rehearsal.

```json
{
  "status": "source-ready; production factory simulation pending",
  "chainId": 11155111,
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
    "exactOutputFee": "burn IMDO",
    "access": "none",
    "upgradeable": false
  },
  "pool": {
    "currency0": "0x0000000000000000000000000000000000000000",
    "currency1": "$token",
    "fee": 3000,
    "tickSpacing": 60,
    "hooks": "$minedHook",
    "initializer": "$launchFactory"
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
    "hookCreationCodeWithoutArgumentsKeccak256": "0x53b389914fa4835ce68c2ad2c2f8f8f428c96d3f829e2cfdb93e72f5afde4b62"
  },
  "holdersReceivePayouts": false,
  "externalAuditPerformed": false,
  "liveDeploymentPerformed": false
}
```

## Local verification and limits

**Results:** offline unoptimized `forge build --sizes` passed. The scratch suite passed **27 tests**, including **512 fuzz cases** and **32 invariant runs × 32 calls = 1,024 calls**, with zero invariant reverts. The two supplied protected suites, copied into scratch with only import paths adapted and missing test helpers provided locally, passed **all 9 tests**, with zero skips. Total: **36 passing tests**. The optimized attested hook runtime is **7,340 bytes**, and the token runtime is **1,337 bytes**, below the **24,576-byte** runtime limit. Unoptimized token, hook and script also fit that limit.

The integration command used local test-only sources in scratch:

```sh
FOUNDRY_INVARIANT_RUNS=32 FOUNDRY_INVARIANT_DEPTH=32 \
FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
FOUNDRY_TEST=test/scratch/checks FOUNDRY_OUT=test/scratch/out \
FOUNDRY_CACHE_PATH=test/scratch/cache \
forge test --offline --use 0.8.26 --evm-version cancun \
  --optimize --via-ir --no-metadata \
  -R 'forge-std/=test/scratch/deps/forge-std-master/src/' \
  -R 'v4-core/=test/scratch/deps/v4-core-main/' \
  -R 'solmate/=test/scratch/deps/solmate/' -vv
```

Scratch checks use a real Uniswap v4 PoolManager and actual settlement, not mocked swap deltas. They compare equivalent hooked and hookless factory positions for pool fee growth, collection and final recipient balances. Checks cover both free buy modes; exact-input thresholds and all exact-output fee tiers; exact treasury receipts and burns; transaction-batched and mixed-mode cumulative bills; a tiny bracket-crossing leg; same-transaction reserve inflation; protocol fee accounting; fresh token-only liquidity; rejection-to-claim fallback and harvesting; callback/permission/opcode restrictions; untaxed Merkle claims; ERC-20 allowances, transfers and burning; and configuration-driven atomic script execution with a factory harness.

Stateful checks additionally exercise swaps, liquidity changes, block changes and harvesting while asserting zero raw hook custody, recorded claims equal manager claim balances, pool inventory reconciles, and supply never increases. Scratch fixtures and their test-only dependency sources are excluded from delivery as required by the assignment. No live factory fork, independent external audit, formal verification, Slither/Mythril run or Regen retirement was performed. Production factory addresses and calldata were not supplied; their rehearsal remains a deployment prerequisite.
