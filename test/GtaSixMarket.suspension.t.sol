// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JudgedTest, JudgeStandIn} from "judge/JudgedTest.sol";
import {JUDGE_STAND_IN} from "judge/Judged.sol";
import {GtaSixMarket} from "src/GtaSixMarket.sol";

/// @dev Settles a question and bets in the same transaction, as an informed bettor would.
contract SettleThenBet {
    GtaSixMarket internal immutable market;

    constructor(GtaSixMarket market_) {
        market = market_;
    }

    function settleThenBet(uint256 id, bool yes) external payable {
        market.settle(id);
        if (yes) market.betYes{value: msg.value}();
        else market.betNo{value: msg.value}();
    }

    receive() external payable {}
}

/// @notice Betting suspension while a question is pending, and the LAST_ASK_AT ask window.
/// forge-config: default.fuzz.runs = 1000
contract GtaSixMarketSuspensionTest is Test, JudgedTest {
    GtaSixMarket internal market;
    JudgeStandIn internal judge;
    address internal alice;
    address internal bob;
    address internal asker;
    uint256 internal constant FEE = 0.002 ether;
    uint256 internal constant START = 1_794_000_000;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(START);
        vm.roll(100);
        market = new GtaSixMarket();
        judge = JudgeStandIn(JUDGE_STAND_IN);
        alice = makeAddr("suspension alice");
        bob = makeAddr("suspension bob");
        asker = makeAddr("suspension asker");
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(asker, 10 ether);
    }

    function _bet(address actor, bool yes, uint256 amount) internal {
        vm.prank(actor);
        if (yes) market.betYes{value: amount}();
        else market.betNo{value: amount}();
    }

    function _ask() internal returns (uint256) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        return market.resolve{value: FEE}("https://example.org/suspension-evidence");
    }

    function _expectBetClosed(address actor, bool yes) internal {
        vm.prank(actor);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        if (yes) market.betYes{value: 1 ether}();
        else market.betNo{value: 1 ether}();
    }

    // ---------------------------------------------------------------------------------------------
    // Settling and betting in one transaction
    // ---------------------------------------------------------------------------------------------

    function test_settleNoThenBetInOneTransactionIsAccepted() public {
        _bet(alice, true, 1 ether);
        uint256 id = _ask();
        judge.answer(id, JudgeStandIn.Verdict.No);
        _expectBetClosed(bob, false);
        SettleThenBet helper = new SettleThenBet(market);
        helper.settleThenBet{value: 2 ether}(id, false);
        assertEq(market.verdictOf(id), 2);
        assertEq(market.pendingQuestions(), 0);
        assertEq(market.noStake(address(helper)), 2 ether);
        assertEq(market.noTotal(), 2 ether);
        assertEq(address(market).balance, 3 ether);
    }

    function test_settleYesThenBetInOneTransactionReverts() public {
        _bet(alice, true, 1 ether);
        _bet(bob, false, 4 ether);
        uint256 id = _ask();
        judge.answer(id, JudgeStandIn.Verdict.Yes);
        SettleThenBet helper = new SettleThenBet(market);
        vm.deal(address(this), 100 ether);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        helper.settleThenBet{value: 100 ether}(id, true);
        // The whole transaction rolled back, the settle included.
        assertFalse(market.resolvedYes());
        assertEq(market.pendingQuestions(), 1);
        market.settle(id);
        assertEq(market.claimable(alice), 5 ether);
        assertEq(market.claimable(address(helper)), 0);
    }

    function test_settleNoAnswerThenBetAfterBettingCloseStillReverts() public {
        vm.warp(market.BETTING_CLOSES_AT() - 1 hours);
        uint256 id = _ask();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1); // ended without an answer, after the close
        SettleThenBet helper = new SettleThenBet(market);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        helper.settleThenBet{value: 1 ether}(id, true);
        market.settle(id);
        assertEq(market.verdictOf(id), 3);
        assertFalse(market.bettingOpen());
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.AwaitingResolution));
    }

    // ---------------------------------------------------------------------------------------------
    // A pending question never blocks the outcome or the claims
    // ---------------------------------------------------------------------------------------------

    function test_pendingQuestionAtDeadlineDoesNotBlockNoOutcomeOrClaims() public {
        _bet(alice, true, 1 ether);
        _bet(bob, false, 3 ether);
        vm.warp(market.LAST_ASK_AT());
        uint256 id = _ask();
        judge.answer(id, JudgeStandIn.Verdict.Yes); // answered in time, but nobody settles in time
        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        assertEq(market.pendingQuestions(), 1);
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.NoWon));
        assertEq(market.claimable(bob), 4 ether);

        uint256 before = bob.balance;
        vm.prank(bob);
        market.claim();
        assertEq(bob.balance - before, 4 ether);

        market.settle(id); // late YES: recorded, not counted
        assertEq(market.verdictOf(id), 1);
        assertEq(market.pendingQuestions(), 0);
        assertFalse(market.resolvedYes());
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.NoWon));
        assertEq(market.claimable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
        assertEq(address(market).balance, 0);
    }

    function test_claimBeforeOutcomeRevertsEvenWithReadableYesVerdict() public {
        _bet(alice, true, 1 ether);
        uint256 id = _ask();
        judge.answer(id, JudgeStandIn.Verdict.Yes);
        assertEq(market.claimable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.NotOverYet.selector);
        market.claim();
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.AwaitingResolution));
    }

    function test_unsettledQuestionsDoNotStopLaterYesFromCounting() public {
        _bet(alice, true, 2 ether);
        _bet(bob, false, 2 ether);
        uint256 stale = _ask();
        uint256 good = _ask();
        judge.answer(good, JudgeStandIn.Verdict.Yes);
        market.settle(good);
        assertTrue(market.resolvedYes());
        assertEq(market.pendingQuestions(), 1, "the other question is still open on the Judge");
        assertFalse(market.bettingOpen());
        // The leftover question can still be closed out; it changes nothing.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        market.settle(stale);
        assertEq(market.verdictOf(stale), 3);
        assertEq(market.pendingQuestions(), 0);
        assertFalse(market.bettingOpen(), "a counted YES keeps betting closed");
        assertEq(market.winningQuestionId(), good);
        assertEq(market.claimable(alice), 4 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Boundaries of the question's life
    // ---------------------------------------------------------------------------------------------

    function test_unansweredQuestionStaysPendingForExactlyOneDay() public {
        _bet(alice, true, 1 ether);
        uint256 id = _ask();
        uint256 askedAt = vm.getBlockTimestamp();
        vm.warp(askedAt + 1 days);
        vm.expectRevert(bytes("Judged: still voting"));
        market.settle(id);
        assertFalse(market.bettingOpen());
        _expectBetClosed(bob, false);
        vm.warp(askedAt + 1 days + 1);
        market.settle(id);
        assertEq(market.verdictOf(id), 3);
        assertTrue(market.bettingOpen());
        _bet(bob, false, 1 ether);
        assertEq(market.noTotal(), 1 ether);
    }

    function test_settledQuestionCannotBeSettledAgainOrUnderflowThePendingCount() public {
        uint256 id = _ask();
        judge.answer(id, JudgeStandIn.Verdict.No);
        market.settle(id);
        assertEq(market.pendingQuestions(), 0);
        vm.expectRevert(bytes("Judged: not an open question of this contract"));
        market.settle(id);
        assertEq(market.pendingQuestions(), 0);
        assertTrue(market.bettingOpen());
    }

    /// @dev Any question asked inside the ask window, answered YES at any moment of its life and settled
    /// straight away, counts. This is the property LAST_ASK_AT exists for.
    function testFuzz_questionAskedInWindowAndSettledPromptlyAlwaysCounts(uint256 askSeed, uint256 delaySeed) public {
        _bet(alice, true, 1 ether);
        _bet(bob, false, 2 ether);
        uint256 askAt = bound(askSeed, START, market.LAST_ASK_AT());
        uint256 delay = bound(delaySeed, 0, 1 days);
        if (askSeed % 4 == 0) askAt = market.LAST_ASK_AT();
        if (delaySeed % 4 == 0) delay = 1 days;
        vm.warp(askAt);
        uint256 id = _ask();
        vm.warp(askAt + delay);
        judge.answer(id, JudgeStandIn.Verdict.Yes);
        market.settle(id);
        assertLe(askAt + delay, market.RESOLUTION_DEADLINE());
        assertTrue(market.resolvedYes());
        assertEq(market.resolvedAt(), askAt + delay);
        assertEq(market.claimable(alice), 3 ether);
        assertEq(market.claimable(bob), 0);
    }

    /// @dev Outside the betting window a pending question changes nothing; inside it, betting is open
    /// exactly when no question is pending.
    function testFuzz_bettingOpenMatchesWindowAndPendingCount(uint256 timeSeed, bool leavePending) public {
        uint256 at = bound(timeSeed, START, market.LAST_ASK_AT());
        vm.warp(at);
        uint256 id = _ask();
        if (!leavePending) {
            judge.answer(id, JudgeStandIn.Verdict.NoAnswer);
            market.settle(id);
        }
        bool expected = !leavePending && at <= market.BETTING_CLOSES_AT();
        assertEq(market.bettingOpen(), expected);
        assertEq(market.pendingQuestions(), leavePending ? 1 : 0);
        vm.prank(alice);
        (bool ok, bytes memory data) = address(market).call{value: 1 ether}(abi.encodeCall(market.betNo, ()));
        assertEq(ok, expected);
        if (!ok) assertEq(data, abi.encodeWithSelector(GtaSixMarket.BettingClosed.selector));
        GtaSixMarket.Phase p = market.phase();
        assertEq(uint8(p), uint8(expected ? GtaSixMarket.Phase.Betting : GtaSixMarket.Phase.AwaitingResolution));
    }

    function test_resolveRefusedFromLastAskAtPlusOneThroughAfterDeadlineWithPendingQuestion() public {
        vm.warp(market.LAST_ASK_AT());
        _ask();
        uint256[3] memory times =
            [market.LAST_ASK_AT() + 1, market.RESOLUTION_DEADLINE(), market.RESOLUTION_DEADLINE() + 1 days];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            vm.roll(vm.getBlockNumber() + 1);
            uint256 before = asker.balance;
            vm.prank(asker);
            vm.expectRevert(GtaSixMarket.ResolutionWindowOver.selector);
            market.resolve{value: FEE}("late");
            assertEq(asker.balance, before, "a refused ask keeps the fee");
        }
        assertEq(market.questionCount(), 1);
        assertEq(market.pendingQuestions(), 1);
    }
}
