# Market test coverage

These tests exercise the accepted `src/GtaSixMarket.sol` implementation. All added
dependencies are already vendored in `lib/`; the tests need no network, fork, keys,
environment mutation, or changes to Foundry configuration.

Run from the repository root:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xcd91d0dc1f5eefbf77a60dec2ab7d69ce4b2735e9d6b8a31d5e6873ae24693b9 forge test --out test/scratch/out --cache-path test/scratch/cache
```

The output and cache flags keep generated files inside the disposable scratch
directory. Ordinary `forge build` and `forge test` use the same tests. No delivered
source imports anything from scratch.

## Independent property discovery

The five discovery passes in the supplied Pashov reference and the Trail of Bits
property review guide informed these original tests:

| Pass | Property and source basis | Coverage |
| --- | --- | --- |
| Conservation | Historical deposits equal `yesTotal + noTotal`; market ETH plus withdrawals equals deposits plus unsolicited ETH. Questions pay their own costs. (`src/GtaSixMarket.sol:113`, `:135`, `:177`) | Six-actor ghost ledger, wallet balance checks, fee separation, forced donations, and successful/failed claims after random sequences. |
| State transitions | Betting closes, only the first timely settled YES wins, settled questions cannot act twice, final phases never reopen. (`:135`, `:146`, `:159`, `:165`, `:216`, `:221`) | Random asks, answers, settlements, monotonic time advancement, rejected calls, independent question records and market-state checks. |
| Round trips and rounding | A payout is the floor of its proportional entitlement; claim order and transaction splitting cannot alter it, and splitting across addresses cannot increase it. (`:174`, `:192`) | Cross-multiplication inequalities, two-market comparisons, aggregate dust bounds, one-wei and maximum uint96 stakes. |
| Adversarial sequences | Reentry cannot duplicate a payout; rejected ETH must roll back accounting; foreign question IDs cannot authorize settlement. (`:177`, `lib/judge/src/Judged.sol:54`, `:89`, `:118`) | Real callback wallets, retries, question isolation, oracle outages, refund reentry, and forced ETH. |
| Prediction-market specifics | Non-YES answers leave the outcome undecided; winners get at least their winning stake; if the winning side is empty, bettors recover their deposits. (`src/GtaSixMarket.sol:145`, `:158`, `:174`) | Existing boundary/verdict tests, independent sequence model, both-outcome refund properties, hedged and empty markets. |

The accounting and rounding properties follow exact identities or documented
contract behavior. Adversarial hypotheses are checked using concrete call trees;
they are not treated as defects merely because a callback is possible. In
particular, an outstanding question **can** be settled from a claim callback, but
it cannot replace the winning question or change payouts. The old unit test that
only exercised an ordinary claim was renamed to describe what it actually checks.

## Stateful harness

`GtaSixMarket.invariant.t.sol` uses 256 runs with depth 96, configured inline. Only
the eight action selectors on `handlers/GtaSixMarketHandler.sol` are targeted.
The market and Judge are never arbitrary fuzz targets. Six funded actors make
bets, ask questions, provide simulated oracle answers, settle, claim, attempt
direct deposits, advance time, and introduce unsolicited ETH.

Deposits and two pending questions are seeded through the handler so an early
deadline jump cannot leave a meaningless empty-pot campaign. Zero, one wei, full
actor balances, both exact deadlines and their following seconds are reachable.
Time only moves forward. Stakes, fees, payouts, question provenance and delivered
verdicts are tracked separately from the implementation's getters.

Expected reverts are caught and compared with their exact errors. Unexpected
results persist in `firstFailure`, checked by an invariant; they cannot disappear
as discarded handler reverts. An `afterInvariant` hook advances unfinished markets
to the deadline and actually withdraws every eligible actor's claim, testing
liveness as well as solvency. Two deterministic handler tests prove that the same
model can reach and pay both outcomes.

The handler models unsolicited ETH with an additive `vm.deal` credit, records it
separately, and never overwrites market storage. A separate unit test exercises a
real forced transfer using a constructor-only `selfdestruct` helper; this helper
is test code, not an application contract.

## Boundaries of the evidence

- The supplied Judge stand-in simulates verdicts and a fixed fee. These tests do
  not validate a real panel's evidence, signatures, mainnet pricing or availability.
- There is no specified fork block or RPC variable in this assignment, so the
  suite is fully local and deterministic.
- Large arithmetic cases use uint96 stakes. uint256-sized ETH balances that cannot
  exist on the target chain are not treated as realistic exploit capital.
- The accepted implementation interprets the release window as through the end
  of December 31 UTC and a timely YES as one **settled** by the end of January 7.
  The tests exercise those implemented boundaries; they cannot establish whether
  those date interpretations or the economics of betting after a release is known
  match a requester's unstated intent.
- Passing tests establish the properties exercised, not an absence of all defects.
