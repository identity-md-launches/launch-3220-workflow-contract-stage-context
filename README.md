# GTA 6 release prediction market

One contract, `GtaSixMarket`, on Ethereum mainnet. People bet ETH on whether Grand Theft Auto VI is
released on or before 2026-12-31 UTC. A YES answer from the [Judge](https://taylor.fyi/judge) panel of
AI agents pays the YES side. If no YES answer has landed by 2027-01-07 23:59:59 UTC, the NO side wins.

The contract has no owner, no fee, no pause and no upgrade path. Nobody can move the pot except the
winners, each claiming their own share.

## How it works

1. **Betting.** Anyone calls `betYes()` or `betNo()` with ETH, any number of times, until
   `BETTING_CLOSES_AT` (2026-12-31 23:59:59 UTC) or until the market resolves YES, whichever is first.
   Stakes are pooled: a parimutuel market, no fixed odds. One address may bet both sides.
2. **Asking.** Once the game is out, anyone calls `resolve(proof)` with about 0.002 ETH attached and a
   link to the official announcement or a major news report as `proof`. The contract puts its fixed
   `QUESTION` to Judge, pays 0.5 IMD for it by buying IMD with the attached ETH in IMD's own pool, and
   returns the change to the caller in the same call. Asking is allowed until `RESOLUTION_DEADLINE`
   (2027-01-07 23:59:59 UTC) and any number of questions may be pending at once.
3. **Settling.** About five minutes after a question is asked, anyone calls `settle(id)`. The id is in
   the `Asked` and `ResolutionAsked` events of the asking transaction, and in `questionIds()`.
   - **YES**, settled on or before `RESOLUTION_DEADLINE`: the market resolves YES, betting closes, and
     `winningQuestionId` records the question. Later YES verdicts change nothing.
   - **YES settled after the deadline**: ignored. The brief says a YES answer must land by Jan 7, 2027.
   - **NO** or **no answer**: nothing changes. A NO only says that proof did not show a release, and
     anyone can get one with a bad link, so it never decides the market. Ask again with better proof.
4. **Claiming.** Once the market has a winner, each winner calls `claim()` once and receives
   `stake * (yesTotal + noTotal) / winningSideTotal`. The NO side has won, with no transaction needed,
   as soon as the clock passes `RESOLUTION_DEADLINE` without a counted YES. If nobody bet on the
   winning side, every bettor takes back exactly what they staked.

Payout rounding leaves at most a few wei of dust in the contract per winner. It is not recoverable
by anyone and is documented as such.

### The question the panel is asked

> Was Grand Theft Auto VI (GTA 6), the video game by Rockstar Games, publicly released for sale and
> playable by the general public on or before 2026-12-31 (UTC)? Only the full general release counts:
> a trailer, a pre-order, a beta, an early-access program, a demo or a leak does not. Answer yes only
> if the proof links to an official Rockstar Games or Take-Two Interactive announcement, or a major
> news report, showing the game was released on or before that date.

The question is a constant. Nothing a caller writes reaches it: the caller's link goes in the proof,
which the panel treats as untrusted.

## Deployment parameters

`GtaSixMarket` takes **no constructor arguments**. Its constructor calls nothing and reads no other
contract. All settings are constants:

| Constant | Value | Meaning |
| --- | --- | --- |
| `BETTING_CLOSES_AT` | `1798761599` (2026-12-31 23:59:59 UTC) | Last second a bet is accepted. Chosen to match the end of the release window, as in Judge's own prediction-market example. |
| `RESOLUTION_DEADLINE` | `1799366399` (2027-01-07 23:59:59 UTC) | Last second a YES verdict counts and the last second `resolve` may ask. From the brief: "If no yes answer lands by Jan 7, 2027, the no side wins." |
| `QUESTION` | text above, 462 ASCII bytes | What Judge is asked, fixed at build time. |

Judge's addresses are fixed inside the vendored `Judged` library, not settable by anyone:

| Chain | Contract | Address | Verified during this build |
| --- | --- | --- | --- |
| Ethereum (1) | `Judge` | `0x37f5E695C1860fF8aec4bf52842020D31699e2eb` | Has code; `price()` reads 0.5 IMD; `asset()` is IMD. Source verified on Sourcify per the Judge README. |
| Ethereum (1) | `JudgeEthDoor` (pays in ETH) | `0xe5A08fA59e9B070bDE8b303e5Dc344937C201bab` | Has code. |

Launch manifest expectations: kind `evm_contracts`, one contract, `GtaSixMarket`, `constructorArgs: []`.
There is no owner argument because there is no owner. The deploy script in `script/` is for local
rehearsal only; the launch deploys the built bytecode through the project factory.

## Assumptions

- "Before Dec 31, 2026" in the brief is read as "on or before 2026-12-31 UTC", the end of the calendar
  year, matching the Judge example the brief follows. The panel is asked exactly that.
- "A yes answer lands" means a YES verdict settled on this contract. The settling transaction, not the
  panel's vote, must be on or before `RESOLUTION_DEADLINE`. Ask early: a question can take up to a day
  to end, and settling is a separate transaction anyone can send.
- A NO verdict is never a ruling. Only time decides for the NO side.
- Betting stays open through the whole release window. In a parimutuel market this means bets placed
  after the outcome is publicly known (the game is scheduled for 2026-11-19) dilute earlier winners'
  profit, though never their principal: a winner always receives at least its stake back (tested).
  The brief fixes no earlier cut-off, and an earlier constant would risk the market launching already
  closed, so the window matches the reference design. The requester may ask for an earlier
  `BETTING_CLOSES_AT` before launch; it is one constant.
- The Judge panel is the sole oracle. Its votes can be wrong. The whole pot rides on one YES, so
  bettors should treat the pot as money they can afford to lose on a wrong verdict.

## Operational responsibilities

Nobody runs this contract, but someone has to act for the market to resolve YES:

| Who | What | When |
| --- | --- | --- |
| Anyone (typically a YES bettor) | Call `resolve(proof)` with ~0.002 ETH and a link to the release announcement | After the game is released, and well before 2027-01-07 |
| Anyone | Call `settle(id)` for each asked question | About five minutes after it was asked; within a day or it ends as no answer |
| Each winner | Call `claim()` | After a counted YES, or after 2027-01-07 23:59:59 UTC for the NO side |
| Website | Read `marketState()`, `claimable(addr)`, `questionIds()`, `verdictOf(id)`; offer `betYes`, `betNo`, `resolve`, `settle`, `claim` | Always |

Costs and limits: a question costs 0.5 IMD, about 0.0006 ETH when Judge was published, plus about
680,000 gas. Attach 0.002 ETH; the change is returned in the same call. A contract calling `resolve`
needs a `receive` function to take its change. The same sender cannot ask twice with the same value
in one block.

## After launch

Nothing needs to be set. There is no owner, no setter and no configuration.

- `$owner` (`0xfe35e15be885750d9b2363cbb6abdd57ac9c4c40`) has no role in this contract.
- The website should be pointed at the deployed `GtaSixMarket` address from the launch handoff and
  use `docs/abi/GtaSixMarket.json`.
- Recommended first step on mainnet, from the Judge guidance: ask one real question with a small pot
  before relying on it. Here that is a `resolve` call with a plausible-but-wrong proof on a market with
  little in it, expecting a NO, which changes nothing.

## Trust and security notes

- **No admin.** No pause, no upgrade, no withdrawal by anyone but a winner. Ownership checks for the
  factory or IMD are moot: the contract has no `owner()`.
- **Oracle trust.** The Judge panel (100 seats, quorum 51) votes and one IMD attester key signs. A wrong
  YES pays the YES side. A refusal, split or outage ends in no answer and the NO side wins by time. If
  IMD stops selling panels, `resolve` reverts before anything is paid.
- **Reentrancy.** `claim` zeroes both stakes before paying; a re-entering claimer finds nothing and the
  whole claim reverts (tested). `Judged` blocks nested `ask` and `settle`.
- **Direct deposits refused.** `receive` accepts ETH only from the Judge door, which returns a
  question's change, so nobody can strand ETH here by a plain transfer.
- **Payout arithmetic** uses the totals ever staked, never the live balance, so a balance that differs
  from the pot can neither inflate nor block payouts.
- **Timestamps** gate betting, resolution and claims. Validator drift of a few seconds is immaterial
  at these horizons.
- **Not an audit.** Tests passing is not a security review. The workflow's independent review step
  covers this contract before launch. Slither was not available on the build machine; the code avoids
  `selfdestruct`, `delegatecall`, `transferFrom`, initializers, Yul shifts and `abi.encodePacked`.
  `forge lint` reports only its informational `block-timestamp` notes and one `reentrancy-events` note
  on `ResolutionAsked`, which is emitted after the Judge call because the id comes from that call.

## Layout

```
foundry.toml                      solc 0.8.26, cancun, optimizer 200 runs, bytecode_hash = "none"
src/GtaSixMarket.sol              the market
script/DeployGtaSixMarket.s.sol   local rehearsal deploy; deploy() is tested
test/GtaSixMarket.t.sol           44 tests: success, failure, timing, verdicts, claims, reentrancy, fuzz
docs/abi/GtaSixMarket.json        ABI for the website
lib/judge/                        Judged.sol and JudgedTest.sol, vendored unchanged (MIT)
lib/forge-std/                    tests only
lib/DEPENDENCIES.md               exact commits of what is vendored
```

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

Tests use Judge's free stand-in (`JudgedTest`), which answers when told, charges a fixed stand-in cost
and ends an unanswered question after a day, as the real one does. The stand-in demonstrates local
behaviour, not the live panel. Tests read no environment variables and pass in any order.
