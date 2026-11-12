// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JudgedTest, JudgeStandIn} from "judge/JudgedTest.sol";
import {JUDGE_STAND_IN} from "judge/Judged.sol";
import {GtaSixMarket} from "../src/GtaSixMarket.sol";
import {DeployGtaSixMarket} from "../script/DeployGtaSixMarket.s.sol";

/// @dev A bettor that tries to re-enter `claim` from its payout.
contract ReentrantClaimer {
    GtaSixMarket private immutable market;
    uint256 public entered;

    constructor(GtaSixMarket market_) {
        market = market_;
    }

    function bet() external payable {
        market.betYes{value: msg.value}();
    }

    function claim() external {
        market.claim();
    }

    receive() external payable {
        entered++;
        if (entered == 1) market.claim();
    }
}

/// @dev Bets YES and settles an already-decided question in one transaction, to take the pot without risk.
contract SettleSniper {
    GtaSixMarket private immutable market;

    constructor(GtaSixMarket market_) {
        market = market_;
    }

    function snipe(uint256 id) external payable {
        market.betYes{value: msg.value}();
        market.settle(id);
    }

    receive() external payable {}
}

/// @dev A contract with no `receive`, so a payout to it fails.
contract NoReceive {
    function bet(GtaSixMarket market) external payable {
        market.betNo{value: msg.value}();
    }

    function claim(GtaSixMarket market) external {
        market.claim();
    }
}

contract GtaSixMarketTest is Test, JudgedTest {
    GtaSixMarket internal market;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal asker = makeAddr("asker");

    uint256 internal constant QUESTION_FEE = 0.002 ether;
    string internal constant PROOF = "https://www.rockstargames.com/newswire/article/gta-vi-out-now";

    uint256 internal constant NOV_2026 = 1_794_000_000; // 2026-11-11, well inside the betting window

    function setUp() public {
        vm.warp(NOV_2026);
        vm.roll(100);
        market = new GtaSixMarket();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(asker, 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _betYes(address who, uint256 amount) internal {
        vm.prank(who);
        market.betYes{value: amount}();
    }

    function _betNo(address who, uint256 amount) internal {
        vm.prank(who);
        market.betNo{value: amount}();
    }

    function _ask() internal returns (uint256 id) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        id = market.resolve{value: QUESTION_FEE}(PROOF);
    }

    function _claim(address who) internal returns (uint256 received) {
        uint256 before = who.balance;
        vm.prank(who);
        market.claim();
        received = who.balance - before;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants and deployment
    // ---------------------------------------------------------------------------------------------

    function test_constants() public view {
        assertEq(market.BETTING_CLOSES_AT(), 1798761599, "2026-12-31T23:59:59Z");
        assertEq(market.RESOLUTION_DEADLINE(), 1799366399, "2027-01-07T23:59:59Z");
        assertLt(market.BETTING_CLOSES_AT(), market.RESOLUTION_DEADLINE());
        assertEq(market.RESOLUTION_DEADLINE() - market.BETTING_CLOSES_AT(), 7 days);
        assertEq(market.LAST_ASK_AT(), 1799279999, "2027-01-06T23:59:59Z");
        assertEq(market.RESOLUTION_DEADLINE() - market.LAST_ASK_AT(), 1 days, "a question lives at most a day");
    }

    function test_questionIsAsciiAndWithinJudgeLimit() public view {
        bytes memory q = bytes(market.QUESTION());
        assertGt(q.length, 0);
        assertLe(q.length, 500, "Judge refuses questions over 500 bytes");
        for (uint256 i; i < q.length; ++i) {
            assertLt(uint8(q[i]), 0x80, "Judge refuses non-ASCII");
        }
    }

    function test_freshMarketState() public view {
        GtaSixMarket.MarketState memory s = market.marketState();
        assertEq(uint8(s.phase), uint8(GtaSixMarket.Phase.Betting));
        assertTrue(s.bettingOpen);
        assertEq(s.yesTotal, 0);
        assertEq(s.noTotal, 0);
        assertEq(s.questionCount, 0);
        assertEq(s.pendingQuestions, 0);
        assertFalse(s.resolvedYes);
        assertEq(s.bettingClosesAt, market.BETTING_CLOSES_AT());
        assertEq(s.lastAskAt, market.LAST_ASK_AT());
        assertEq(s.resolutionDeadline, market.RESOLUTION_DEADLINE());
        assertEq(market.pot(), 0);
        assertEq(market.claimable(alice), 0);
    }

    function test_deployScriptFunction() public {
        DeployGtaSixMarket script = new DeployGtaSixMarket();
        GtaSixMarket deployed = script.deploy();
        assertTrue(address(deployed).code.length > 0);
        assertTrue(deployed.bettingOpen());
    }

    function test_constructorRevertsOnChainWithoutJudge() public {
        vm.chainId(42);
        vm.expectRevert(bytes("Judged: Judge isn't on this chain"));
        new GtaSixMarket();
    }

    function test_constructorDeploysOnMainnetChainIdWithoutCallingAnything() public {
        // The launch rehearses the constructor on an empty chain with chain id 1: nothing may be called.
        vm.chainId(1);
        GtaSixMarket m = new GtaSixMarket();
        assertTrue(m.bettingOpen());
    }

    // ---------------------------------------------------------------------------------------------
    // Betting
    // ---------------------------------------------------------------------------------------------

    function test_betYesAndNoRecordStakes() public {
        vm.expectEmit(true, true, false, true, address(market));
        emit GtaSixMarket.BetPlaced(alice, true, 1 ether);
        _betYes(alice, 1 ether);
        vm.expectEmit(true, true, false, true, address(market));
        emit GtaSixMarket.BetPlaced(bob, false, 2 ether);
        _betNo(bob, 2 ether);
        _betYes(alice, 0.5 ether);

        assertEq(market.yesStake(alice), 1.5 ether);
        assertEq(market.noStake(bob), 2 ether);
        assertEq(market.yesTotal(), 1.5 ether);
        assertEq(market.noTotal(), 2 ether);
        assertEq(market.pot(), 3.5 ether);
        assertEq(address(market).balance, 3.5 ether);
    }

    function test_bettorMayHedgeBothSides() public {
        _betYes(alice, 1 ether);
        _betNo(alice, 1 ether);
        assertEq(market.yesStake(alice), 1 ether);
        assertEq(market.noStake(alice), 1 ether);
    }

    function test_zeroBetReverts() public {
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.ZeroBet.selector);
        market.betYes();
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.ZeroBet.selector);
        market.betNo();
    }

    function test_betAtLastSecondAcceptedAndAfterCloseRejected() public {
        vm.warp(market.BETTING_CLOSES_AT());
        _betYes(alice, 1 ether);
        assertTrue(market.bettingOpen());

        vm.warp(market.BETTING_CLOSES_AT() + 1);
        assertFalse(market.bettingOpen());
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.AwaitingResolution));
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betYes{value: 1 ether}();
        vm.prank(bob);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betNo{value: 1 ether}();
    }

    function test_betAfterYesResolutionRejected() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 1 ether);
        _ask();
        market.settle(answerYes());
        assertFalse(market.bettingOpen());
        vm.prank(carol);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betNo{value: 1 ether}();
        vm.prank(carol);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betYes{value: 1 ether}();
    }

    function test_directEthTransferRefused() public {
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok, "plain transfer must be refused");
        assertEq(address(market).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Asking
    // ---------------------------------------------------------------------------------------------

    function test_resolveAsksJudgeRecordsQuestionAndReturnsChange() public {
        _betYes(alice, 1 ether);
        uint256 before = asker.balance;
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        vm.expectEmit(true, true, false, true, address(market));
        emit GtaSixMarket.ResolutionAsked(1001, asker, PROOF);
        uint256 id = market.resolve{value: QUESTION_FEE}(PROOF);

        assertEq(id, 1001);
        assertEq(id, latestQuestion());
        assertEq(market.questionCount(), 1);
        assertEq(market.questionIds()[0], id);
        assertEq(market.askedBy(id), asker);
        assertEq(market.askedAt(id), block.timestamp);
        assertEq(market.verdictOf(id), 0);
        // Only the stand-in's cost left the asker; the change came back.
        assertEq(before - asker.balance, JudgeStandIn(JUDGE_STAND_IN).COST());
        // The pot is untouched by the question.
        assertEq(address(market).balance, 1 ether);
    }

    function test_resolveWithoutEthReverts() public {
        vm.prank(asker);
        vm.expectRevert(bytes("Judged: send ETH with this call, it pays for the question"));
        market.resolve(PROOF);
    }

    function test_resolveWithTooLittleEthReverts() public {
        vm.prank(asker);
        vm.expectRevert(abi.encodeWithSelector(JudgeStandIn.EthShort.selector, 0.0007 ether + 1, 0.0005 ether));
        market.resolve{value: 0.0005 ether}(PROOF);
    }

    function test_resolveWithEmptyProofReverts() public {
        vm.prank(asker);
        vm.expectRevert(JudgeStandIn.EmptyText.selector);
        market.resolve{value: QUESTION_FEE}("");
    }

    function test_resolveAfterLastAskReverts() public {
        vm.warp(market.LAST_ASK_AT());
        _ask(); // the last second is still allowed
        vm.warp(market.LAST_ASK_AT() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        vm.expectRevert(GtaSixMarket.ResolutionWindowOver.selector);
        market.resolve{value: QUESTION_FEE}(PROOF);
        // Still refused up to and past the resolution deadline: a question asked now could not be settled in time.
        vm.warp(market.RESOLUTION_DEADLINE());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        vm.expectRevert(GtaSixMarket.ResolutionWindowOver.selector);
        market.resolve{value: QUESTION_FEE}(PROOF);
        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        vm.expectRevert(GtaSixMarket.ResolutionWindowOver.selector);
        market.resolve{value: QUESTION_FEE}(PROOF);
    }

    function test_questionAskedAtLastAskCanAlwaysBeSettledInTime() public {
        // Asked at the last allowed second and left for the stand-in's full day: settling at the deadline works.
        _betYes(alice, 1 ether);
        vm.warp(market.LAST_ASK_AT());
        uint256 id = _ask();
        JudgeStandIn(JUDGE_STAND_IN).answer(id, JudgeStandIn.Verdict.Yes);
        vm.warp(market.RESOLUTION_DEADLINE());
        market.settle(id);
        assertTrue(market.resolvedYes());
    }

    function test_resolveAfterYesReverts() public {
        _betYes(alice, 1 ether);
        _ask();
        market.settle(answerYes());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        vm.expectRevert(GtaSixMarket.AlreadyResolved.selector);
        market.resolve{value: QUESTION_FEE}(PROOF);
    }

    function test_sameAskerSameValueSameBlockReverts() public {
        _ask();
        vm.prank(asker);
        vm.expectRevert(bytes("Judged: this sender and value already asked in this block"));
        market.resolve{value: QUESTION_FEE}(PROOF);
    }

    function test_manyQuestionsMayBePending() public {
        uint256 a = _ask();
        uint256 b = _ask();
        assertEq(b, a + 1);
        assertEq(market.questionCount(), 2);
        assertEq(market.pendingQuestions(), 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Betting is suspended while a question is pending
    // ---------------------------------------------------------------------------------------------

    function test_betWhileQuestionPendingReverts() public {
        _betYes(alice, 1 ether);
        _ask();
        assertFalse(market.bettingOpen(), "a pending question suspends betting");
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.AwaitingResolution));
        assertFalse(market.marketState().bettingOpen);
        vm.prank(bob);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betYes{value: 1 ether}();
        vm.prank(bob);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betNo{value: 1 ether}();
        assertEq(market.pot(), 1 ether);
    }

    function test_betAfterVerdictIsReadableButBeforeSettleReverts() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 9 ether);
        _ask();
        uint256 id = answerYes();
        assertEq(uint8(JudgeStandIn(JUDGE_STAND_IN).verdict(id)), 1, "the verdict is public on the Judge");
        assertFalse(market.resolvedYes());
        vm.prank(carol);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betYes{value: 100 ether}();
        market.settle(id);
        assertEq(market.claimable(alice), 10 ether, "the only YES bettor at risk takes the whole pot");
    }

    function test_atomicBetAndSettleAfterVerdictReverts() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 9 ether);
        _ask();
        uint256 id = answerYes();
        SettleSniper sniper = new SettleSniper(market);
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        sniper.snipe{value: 1000 ether}(id);
        assertFalse(market.resolvedYes(), "the failed snipe settled nothing");
        market.settle(id);
        assertTrue(market.resolvedYes());
        assertEq(market.claimable(alice), 10 ether);
        assertEq(market.claimable(address(sniper)), 0);
        assertEq(market.yesTotal(), 1 ether);
    }

    function test_bettingReopensAfterNoVerdictIsSettled() public {
        _betYes(alice, 1 ether);
        _ask();
        uint256 id = answerNo();
        assertFalse(market.bettingOpen());
        market.settle(id);
        assertEq(market.pendingQuestions(), 0);
        assertTrue(market.bettingOpen(), "a NO reopens betting");
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.Betting));
        _betNo(bob, 2 ether);
        assertEq(market.noTotal(), 2 ether);
    }

    function test_bettingReopensAfterNoAnswerIsSettled() public {
        _betYes(alice, 1 ether);
        uint256 id = _ask();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1); // nobody answered: the question ended on its own
        assertFalse(market.bettingOpen(), "still suspended until someone settles");
        market.settle(id);
        assertTrue(market.bettingOpen(), "a no-answer reopens betting");
        _betNo(bob, 2 ether);
        assertEq(market.noTotal(), 2 ether);
    }

    function test_bettingReopensOnlyWhenEveryPendingQuestionIsSettled() public {
        uint256 first = _ask();
        uint256 second = _ask();
        JudgeStandIn(JUDGE_STAND_IN).answer(first, JudgeStandIn.Verdict.No);
        JudgeStandIn(JUDGE_STAND_IN).answer(second, JudgeStandIn.Verdict.No);
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        market.settle(first);
        assertEq(market.pendingQuestions(), 1);
        assertFalse(market.bettingOpen(), "one question is still pending");
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betYes{value: 1 ether}();
        market.settle(second);
        assertEq(market.pendingQuestions(), 0);
        assertTrue(market.bettingOpen());
        _betYes(alice, 1 ether);
    }

    function test_bettingStaysClosedAfterCountedYes() public {
        _betYes(alice, 1 ether);
        _ask();
        market.settle(answerYes());
        assertEq(market.pendingQuestions(), 0);
        assertFalse(market.bettingOpen(), "a counted YES closes betting for good");
        vm.prank(bob);
        vm.expectRevert(GtaSixMarket.BettingClosed.selector);
        market.betNo{value: 1 ether}();
    }

    function testFuzz_betAcceptedOnlyWhenNothingIsPending(uint8 asks, uint8 settles) public {
        asks = uint8(bound(asks, 0, 5));
        settles = uint8(bound(settles, 0, asks));
        uint256[] memory ids = new uint256[](asks);
        for (uint256 i; i < asks; ++i) {
            ids[i] = _ask();
            JudgeStandIn(JUDGE_STAND_IN).answer(ids[i], JudgeStandIn.Verdict.No);
        }
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        for (uint256 i; i < settles; ++i) {
            market.settle(ids[i]);
        }
        assertEq(market.pendingQuestions(), asks - settles);
        if (asks == settles) {
            _betYes(alice, 1 ether);
            assertEq(market.yesTotal(), 1 ether);
        } else {
            assertFalse(market.bettingOpen());
            vm.prank(alice);
            vm.expectRevert(GtaSixMarket.BettingClosed.selector);
            market.betYes{value: 1 ether}();
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Settling
    // ---------------------------------------------------------------------------------------------

    function test_settleWhileVotingReverts() public {
        uint256 id = _ask();
        vm.expectRevert(bytes("Judged: still voting"));
        market.settle(id);
    }

    function test_settleUnknownIdReverts() public {
        vm.expectRevert(bytes("Judged: not an open question of this contract"));
        market.settle(12345);
    }

    function test_settleTwiceReverts() public {
        _ask();
        uint256 id = answerNo();
        market.settle(id);
        vm.expectRevert(bytes("Judged: not an open question of this contract"));
        market.settle(id);
    }

    function test_yesVerdictResolvesMarket() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 3 ether);
        _ask();
        uint256 id = answerYes();
        vm.expectEmit(true, false, false, true, address(market));
        emit GtaSixMarket.QuestionSettled(id, 1, true);
        vm.expectEmit(true, false, false, true, address(market));
        emit GtaSixMarket.ResolvedYes(id, 1 ether, 3 ether);
        vm.prank(carol); // anyone can settle
        market.settle(id);

        assertTrue(market.resolvedYes());
        assertEq(market.resolvedAt(), block.timestamp);
        assertEq(market.winningQuestionId(), id);
        assertEq(market.verdictOf(id), 1);
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.YesWon));
        assertFalse(market.bettingOpen());
    }

    function test_noVerdictChangesNothing() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 1 ether);
        _ask();
        uint256 id = answerNo();
        vm.expectEmit(true, false, false, true, address(market));
        emit GtaSixMarket.QuestionSettled(id, 2, false);
        market.settle(id);

        assertFalse(market.resolvedYes());
        assertEq(market.verdictOf(id), 2);
        assertTrue(market.bettingOpen(), "a NO never closes the market");
        assertEq(address(market).balance, 2 ether);
        vm.expectRevert(GtaSixMarket.NotOverYet.selector);
        vm.prank(bob);
        market.claim();
        // Asking again works.
        _betYes(carol, 1 ether);
        _ask();
        market.settle(answerYes());
        assertTrue(market.resolvedYes());
    }

    function test_noAnswerVerdictChangesNothing() public {
        _betNo(bob, 1 ether);
        _ask();
        uint256 id = answerNone();
        vm.expectEmit(true, false, false, true, address(market));
        emit GtaSixMarket.QuestionSettled(id, 3, false);
        market.settle(id);
        assertFalse(market.resolvedYes());
        assertEq(market.verdictOf(id), 3);
        assertTrue(market.bettingOpen());
    }

    function test_questionNobodyAnswersEndsAsNoAnswerAfterADay() public {
        _betNo(bob, 1 ether);
        uint256 id = _ask();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(bytes("Judged: still voting"));
        market.settle(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        market.settle(id);
        assertEq(market.verdictOf(id), 3);
        assertFalse(market.resolvedYes());
    }

    function test_secondYesIsNotCounted() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 1 ether);
        _ask();
        _ask();
        uint256 second = latestQuestion();
        uint256 first = second - 1;
        JudgeStandIn(JUDGE_STAND_IN).answer(first, JudgeStandIn.Verdict.Yes);
        JudgeStandIn(JUDGE_STAND_IN).answer(second, JudgeStandIn.Verdict.Yes);
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        market.settle(second);
        assertEq(market.winningQuestionId(), second);
        vm.expectEmit(true, false, false, true, address(market));
        emit GtaSixMarket.QuestionSettled(first, 1, false);
        market.settle(first);
        assertEq(market.winningQuestionId(), second, "the first settled YES stays the winner");
        assertEq(market.verdictOf(first), 1);
    }

    function test_yesSettledAfterDeadlineIsIgnoredAndNoWins() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 1 ether);
        vm.warp(market.LAST_ASK_AT());
        _ask();
        uint256 id = latestQuestion();
        JudgeStandIn(JUDGE_STAND_IN).answer(id, JudgeStandIn.Verdict.Yes);
        // Nobody settled for a day: the verdict lands after the deadline.
        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        vm.expectEmit(true, false, false, true, address(market));
        emit GtaSixMarket.QuestionSettled(id, 1, false);
        market.settle(id);

        assertFalse(market.resolvedYes(), "a late YES does not count");
        assertEq(market.verdictOf(id), 1);
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.NoWon));
        assertEq(_claim(bob), 2 ether);
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function test_yesSettledAtExactDeadlineCounts() public {
        _betYes(alice, 1 ether);
        vm.warp(market.LAST_ASK_AT() - 10 minutes);
        _ask();
        uint256 id = latestQuestion();
        JudgeStandIn(JUDGE_STAND_IN).answer(id, JudgeStandIn.Verdict.Yes);
        vm.warp(market.RESOLUTION_DEADLINE());
        market.settle(id);
        assertTrue(market.resolvedYes());
    }

    // ---------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------

    function test_yesWinnersSplitPotProRata() public {
        _betYes(alice, 1 ether);
        _betYes(carol, 3 ether);
        _betNo(bob, 4 ether);
        _ask();
        market.settle(answerYes());

        assertEq(market.claimable(alice), 2 ether);
        assertEq(market.claimable(carol), 6 ether);
        assertEq(market.claimable(bob), 0);

        vm.expectEmit(true, false, false, true, address(market));
        emit GtaSixMarket.Claimed(alice, 2 ether);
        assertEq(_claim(alice), 2 ether);
        assertEq(_claim(carol), 6 ether);
        assertEq(market.totalClaimed(), 8 ether);
        assertEq(address(market).balance, 0);
        assertEq(market.yesStake(alice), 0);
        assertEq(market.claimable(alice), 0);

        vm.prank(bob);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function test_claimTwiceReverts() public {
        _betYes(alice, 1 ether);
        _betNo(bob, 1 ether);
        _ask();
        market.settle(answerYes());
        _claim(alice);
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function test_nonBettorCannotClaim() public {
        _betYes(alice, 1 ether);
        _ask();
        market.settle(answerYes());
        vm.prank(carol);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function test_noSideWinsByTimeAndClaimsAfterDeadline() public {
        _betYes(alice, 2 ether);
        _betNo(bob, 1 ether);
        _betNo(carol, 3 ether);

        vm.warp(market.RESOLUTION_DEADLINE());
        assertEq(market.claimable(bob), 0);
        vm.prank(bob);
        vm.expectRevert(GtaSixMarket.NotOverYet.selector);
        market.claim();

        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        assertEq(uint8(market.phase()), uint8(GtaSixMarket.Phase.NoWon));
        assertEq(market.claimable(bob), 1.5 ether);
        assertEq(market.claimable(carol), 4.5 ether);
        assertEq(_claim(bob), 1.5 ether);
        assertEq(_claim(carol), 4.5 ether);
        assertEq(address(market).balance, 0);
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function test_hedgedBettorIsPaidOnlyForWinningSide() public {
        _betYes(alice, 1 ether);
        _betNo(alice, 1 ether);
        _betNo(bob, 2 ether);
        _ask();
        market.settle(answerYes());
        assertEq(_claim(alice), 4 ether);
        assertEq(market.noStake(alice), 0, "a claim clears both sides");
    }

    function test_yesWinsWithNoYesBettorsRefundsEveryone() public {
        _betNo(bob, 1 ether);
        _betNo(carol, 2 ether);
        _ask();
        market.settle(answerYes());
        assertEq(market.claimable(bob), 1 ether);
        assertEq(_claim(bob), 1 ether);
        assertEq(_claim(carol), 2 ether);
        assertEq(address(market).balance, 0);
    }

    function test_noWinsWithNoNoBettorsRefundsEveryone() public {
        _betYes(alice, 1 ether);
        _betYes(carol, 2 ether);
        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        assertEq(_claim(alice), 1 ether);
        assertEq(_claim(carol), 2 ether);
        assertEq(address(market).balance, 0);
    }

    function test_reentrantClaimCannotDrain() public {
        ReentrantClaimer attacker = new ReentrantClaimer(market);
        vm.deal(address(attacker), 1 ether);
        attacker.bet{value: 1 ether}();
        _betYes(alice, 1 ether);
        _betNo(bob, 2 ether);
        _ask();
        market.settle(answerYes());

        // The nested claim finds nothing left to claim and reverts, which reverts the payout and the claim.
        vm.expectRevert(bytes("Judged: payment failed"));
        attacker.claim();
        assertEq(address(market).balance, 4 ether);
        assertEq(market.yesStake(address(attacker)), 1 ether, "a failed claim leaves the stake intact");
        // Honest claimants are unaffected.
        assertEq(_claim(alice), 2 ether);
    }

    function test_claimToContractWithoutReceiveFailsWithoutLosingStake() public {
        NoReceive bettor = new NoReceive();
        vm.deal(address(bettor), 1 ether);
        bettor.bet{value: 1 ether}(market);
        _betYes(alice, 1 ether);
        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        vm.expectRevert(bytes("Judged: payment failed"));
        bettor.claim(market);
        assertEq(market.noStake(address(bettor)), 1 ether);
        assertEq(address(market).balance, 2 ether);
    }

    function test_honestClaimSucceedsAfterSettlement() public {
        // `claim` runs outside `settle`, so the Judged busy flag never blocks an honest claim.
        _betYes(alice, 1 ether);
        _ask();
        market.settle(answerYes());
        assertEq(_claim(alice), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation of funds
    // ---------------------------------------------------------------------------------------------

    function testFuzz_yesPayoutsNeverExceedPotAndDustIsBounded(uint96 a, uint96 b, uint96 c, uint96 n) public {
        a = uint96(bound(a, 1, 50 ether));
        b = uint96(bound(b, 1, 50 ether));
        c = uint96(bound(c, 1, 50 ether));
        n = uint96(bound(n, 1, 50 ether));
        _betYes(alice, a);
        _betYes(bob, b);
        _betYes(carol, c);
        address dave = makeAddr("dave");
        vm.deal(dave, n);
        _betNo(dave, n);
        uint256 potBefore = address(market).balance;
        assertEq(potBefore, uint256(a) + b + c + n);

        _ask();
        market.settle(answerYes());

        uint256 paid = _claim(alice) + _claim(bob) + _claim(carol);
        assertEq(paid, market.totalClaimed());
        assertLe(paid, potBefore, "payouts never exceed the pot");
        assertLt(potBefore - paid, 3, "rounding dust is below one wei per winner");
        assertEq(market.yesStake(alice) + market.yesStake(bob) + market.yesStake(carol), 0);
        vm.prank(dave);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function testFuzz_noPayoutsNeverExceedPot(uint96 y, uint96 a, uint96 b) public {
        y = uint96(bound(y, 1, 50 ether));
        a = uint96(bound(a, 1, 50 ether));
        b = uint96(bound(b, 1, 50 ether));
        _betYes(carol, y);
        _betNo(alice, a);
        _betNo(bob, b);
        uint256 potBefore = address(market).balance;

        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        uint256 paid = _claim(alice) + _claim(bob);
        assertLe(paid, potBefore);
        assertLt(potBefore - paid, 2);
        vm.prank(carol);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function testFuzz_winnerNeverReceivesLessThanStake(uint96 mine, uint96 others, uint96 losers) public {
        mine = uint96(bound(mine, 1, 50 ether));
        others = uint96(bound(others, 1, 50 ether));
        losers = uint96(bound(losers, 0, 50 ether));
        _betYes(alice, mine);
        _betYes(bob, others);
        if (losers > 0) _betNo(carol, losers);
        _ask();
        market.settle(answerYes());
        assertGe(_claim(alice), mine, "a winner gets at least its stake back");
    }

    function testFuzz_betsBeforeCloseAcceptedAfterRejected(uint256 t) public {
        t = bound(t, NOV_2026, market.BETTING_CLOSES_AT() + 30 days);
        vm.warp(t);
        if (t <= market.BETTING_CLOSES_AT()) {
            _betYes(alice, 1 ether);
            assertEq(market.yesTotal(), 1 ether);
        } else {
            vm.prank(alice);
            vm.expectRevert(GtaSixMarket.BettingClosed.selector);
            market.betYes{value: 1 ether}();
        }
    }
}
