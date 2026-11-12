// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JudgeStandIn} from "judge/JudgedTest.sol";
import {JUDGE_STAND_IN} from "judge/Judged.sol";
import {GtaSixMarket} from "src/GtaSixMarket.sol";

/// @dev The runner targets only the action selectors, never the oracle or the market directly.
/// Expected failures are checked explicitly. Unexpected results latch firstFailure instead of
/// reverting the handler (which a runner with fail_on_revert=false could otherwise discard).
contract GtaSixMarketHandler is Test {
    uint256 public constant ACTORS = 6;
    uint256 public constant INITIAL_BALANCE = 1_000 ether;
    uint256 public constant FEE = 0.002 ether;
    uint256 public constant COST = 0.0007 ether;
    string internal constant PROOF = "https://example.org/independent-market-test";

    GtaSixMarket public immutable market;
    address[6] public actors;
    uint256[6] public depositedYes;
    uint256[6] public depositedNo;
    uint256[6] public paid;
    uint256[6] public fees;
    bool[6] public claimed;

    uint256 public yesDeposited;
    uint256 public noDeposited;
    uint256 public paidOut;
    uint256 public donated;
    uint256 public betCalls;
    uint256 public askCalls;
    uint256 public settlementCalls;
    uint256 public claimCalls;
    bytes32 public firstFailure;

    bool public yesWon;
    uint256 public winningId;
    uint256 public winningTime;
    uint256 public highestPhase;

    struct Question {
        uint256 id;
        address asker;
        uint256 time;
        uint8 answer;
        uint8 delivered;
        bool settled;
    }

    Question[] internal questions;

    constructor(GtaSixMarket market_) {
        market = market_;
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = makeAddr(string.concat("sequence bettor ", vm.toString(i)));
            vm.deal(actors[i], INITIAL_BALANCE);
        }
    }

    function bet(uint256 actorSeed, uint256 amountSeed, bool yes) external {
        uint256 index = actorSeed % ACTORS;
        address actor = actors[index];
        uint256 amount = bound(amountSeed, 0, actor.balance);
        // Exercise tiny amounts as well as spending an actor's entire available balance.
        if (amountSeed % 4 == 0) amount = 0;
        else if (amountSeed % 4 == 1 && actor.balance != 0) amount = 1;
        else if (amountSeed % 4 == 2) amount = actor.balance;

        bool open = !yesWon && vm.getBlockTimestamp() <= market.BETTING_CLOSES_AT();
        vm.prank(actor);
        (bool ok, bytes memory data) = address(market).call{value: amount}(
            yes ? abi.encodeCall(market.betYes, ()) : abi.encodeCall(market.betNo, ())
        );
        _check(ok == (open && amount != 0), "bet result");
        if (ok) {
            if (yes) {
                depositedYes[index] += amount;
                yesDeposited += amount;
            } else {
                depositedNo[index] += amount;
                noDeposited += amount;
            }
            ++betCalls;
        } else {
            _check(
                keccak256(data)
                    == keccak256(
                        abi.encodeWithSelector(
                            amount == 0 ? GtaSixMarket.ZeroBet.selector : GtaSixMarket.BettingClosed.selector
                        )
                    ),
                "bet revert"
            );
        }
        _checkPhase();
    }

    function ask(uint256 actorSeed) external {
        uint256 index = actorSeed % ACTORS;
        address actor = actors[index];
        if (actor.balance < FEE) return;
        // A new transaction in a new block avoids the library's same-sender/value block guard.
        vm.roll(vm.getBlockNumber() + 1);
        bool allowed = !yesWon && vm.getBlockTimestamp() <= market.RESOLUTION_DEADLINE();
        uint256 balanceBefore = address(market).balance;
        vm.prank(actor);
        (bool ok, bytes memory data) = address(market).call{value: FEE}(abi.encodeCall(market.resolve, (PROOF)));
        _check(ok == allowed, "ask result");
        if (ok) {
            uint256 id = abi.decode(data, (uint256));
            questions.push(Question(id, actor, vm.getBlockTimestamp(), 0, 0, false));
            fees[index] += COST;
            ++askCalls;
        } else {
            _check(
                keccak256(data)
                    == keccak256(
                        abi.encodeWithSelector(
                            yesWon ? GtaSixMarket.AlreadyResolved.selector : GtaSixMarket.ResolutionWindowOver.selector
                        )
                    ),
                "ask revert"
            );
        }
        _check(address(market).balance == balanceBefore, "question spent pot");
        _checkPhase();
    }

    function answer(uint256 questionSeed, uint256 answerSeed) external {
        if (questions.length == 0) return;
        Question storage q = questions[questionSeed % questions.length];
        if (q.answer != 0 || vm.getBlockTimestamp() > q.time + 1 days) return;
        uint8 verdict = uint8(bound(answerSeed, 1, 3));
        JudgeStandIn(JUDGE_STAND_IN).answer(q.id, JudgeStandIn.Verdict(verdict));
        q.answer = verdict;
    }

    function settle(uint256 questionSeed, uint256 callerSeed) external {
        if (questions.length == 0) return;
        Question storage q = questions[questionSeed % questions.length];
        uint8 verdict = q.answer;
        if (verdict == 0 && vm.getBlockTimestamp() > q.time + 1 days) verdict = 3;
        bool wasSettled = q.settled;
        bool allowed = !wasSettled && verdict != 0;
        vm.prank(actors[callerSeed % ACTORS]);
        (bool ok, bytes memory data) = address(market).call(abi.encodeCall(market.settle, (q.id)));
        _check(ok == allowed, "settle result");
        if (ok) {
            q.settled = true;
            q.delivered = verdict;
            ++settlementCalls;
            if (verdict == 1 && !yesWon && vm.getBlockTimestamp() <= market.RESOLUTION_DEADLINE()) {
                yesWon = true;
                winningId = q.id;
                winningTime = vm.getBlockTimestamp();
            }
        } else {
            string memory reason = wasSettled ? "Judged: not an open question of this contract" : "Judged: still voting";
            _check(keccak256(data) == keccak256(abi.encodeWithSignature("Error(string)", reason)), "settle revert");
        }
        _checkPhase();
    }

    function claim(uint256 actorSeed) public {
        uint256 index = actorSeed % ACTORS;
        address actor = actors[index];
        bool over = yesWon || vm.getBlockTimestamp() > market.RESOLUTION_DEADLINE();
        uint256 winningTotal = yesWon ? yesDeposited : noDeposited;
        uint256 stake = yesWon ? depositedYes[index] : depositedNo[index];
        bool eligible =
            !claimed[index] && (winningTotal == 0 ? depositedYes[index] + depositedNo[index] != 0 : stake != 0);
        uint256 balanceBefore = actor.balance;
        uint256 preview = market.claimable(actor);
        vm.prank(actor);
        (bool ok, bytes memory data) = address(market).call(abi.encodeCall(market.claim, ()));
        _check(ok == (over && eligible), "claim result");
        if (ok) {
            uint256 received = actor.balance - balanceBefore;
            _check(received == preview, "claim preview");
            // Check the pro-rata entitlement as inequalities, without copying its division.
            if (winningTotal != 0) {
                uint256 numerator = stake * (yesDeposited + noDeposited);
                _check(received * winningTotal <= numerator, "overpaid share");
                _check((received + 1) * winningTotal > numerator, "underpaid share");
                _check(received >= stake, "principal lost");
            } else {
                _check(received == depositedYes[index] + depositedNo[index], "refund differs");
            }
            paid[index] += received;
            paidOut += received;
            claimed[index] = true;
            ++claimCalls;
        } else {
            _check(
                keccak256(data)
                    == keccak256(
                        abi.encodeWithSelector(
                            over ? GtaSixMarket.NothingToClaim.selector : GtaSixMarket.NotOverYet.selector
                        )
                    ),
                "claim revert"
            );
            _check(actor.balance == balanceBefore, "failed claim paid");
        }
        _checkPhase();
    }

    function advanceTime(uint256 secondsSeed, uint256 boundarySeed) external {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 choice = boundarySeed % 5;
        uint256 next;
        if (choice == 0) next = market.BETTING_CLOSES_AT();
        else if (choice == 1) next = market.BETTING_CLOSES_AT() + 1;
        else if (choice == 2) next = market.RESOLUTION_DEADLINE();
        else if (choice == 3) next = market.RESOLUTION_DEADLINE() + 1;
        else next = now_ + bound(secondsSeed, 0, 12 hours);
        if (next > now_) vm.warp(next);
        vm.roll(vm.getBlockNumber() + 1);
        _checkPhase();
    }

    function directDeposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % ACTORS];
        uint256 amount = bound(amountSeed, 0, actor.balance);
        vm.prank(actor);
        (bool ok, bytes memory data) = address(market).call{value: amount}("");
        _check(!ok, "direct deposit accepted");
        _check(
            keccak256(data) == keccak256(abi.encodeWithSelector(GtaSixMarket.DirectDepositRefused.selector)),
            "deposit revert"
        );
    }

    function forceDonation(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 10 ether);
        // Model an unsolicited ETH credit (e.g. a fee-recipient payment). It creates no stake.
        vm.deal(address(market), address(market).balance + amount);
        donated += amount;
    }

    function questionLength() external view returns (uint256) {
        return questions.length;
    }

    function question(uint256 index) external view returns (Question memory) {
        return questions[index];
    }

    function _check(bool condition, bytes32 reason) internal {
        if (!condition && firstFailure == bytes32(0)) firstFailure = reason;
    }

    function _checkPhase() internal {
        uint256 current = uint256(market.phase());
        _check(current >= highestPhase, "phase regressed");
        highestPhase = current;
    }
}
