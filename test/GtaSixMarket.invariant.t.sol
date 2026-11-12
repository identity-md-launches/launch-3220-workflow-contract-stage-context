// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JudgedTest} from "judge/JudgedTest.sol";
import {GtaSixMarket} from "src/GtaSixMarket.sol";
import {GtaSixMarketHandler} from "./handlers/GtaSixMarketHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract GtaSixMarketInvariantTest is Test, JudgedTest {
    GtaSixMarket internal market;
    GtaSixMarketHandler internal handler;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1_794_000_000);
        vm.roll(100);
        market = new GtaSixMarket();
        handler = new GtaSixMarketHandler(market);

        // Seed real deposits through the same handler, so solvency is never vacuous even
        // when the first random action advances past the deadline or resolves YES.
        handler.bet(0, 5, true);
        handler.bet(1, 3 ether + 3, true);
        handler.bet(2, 9, false);
        handler.bet(3, 7 ether + 3, false);
        handler.ask(4);
        handler.ask(5);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.bet.selector;
        selectors[1] = handler.ask.selector;
        selectors[2] = handler.answer.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.directDeposit.selector;
        selectors[7] = handler.forceDonation.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_actionsMeetTheirPreconditionsAndPostconditions() public view {
        assertEq(handler.firstFailure(), bytes32(0), "handler detected an unexpected result");
    }

    function invariant_ethAndHistoricalTotalsAreConserved() public view {
        uint256 yes;
        uint256 no;
        uint256 payouts;
        for (uint256 i; i < handler.ACTORS(); ++i) {
            yes += handler.depositedYes(i);
            no += handler.depositedNo(i);
            payouts += handler.paid(i);
        }
        assertEq(market.yesTotal(), yes);
        assertEq(market.noTotal(), no);
        assertEq(market.pot(), yes + no);
        assertEq(market.totalClaimed(), payouts);
        assertEq(payouts, handler.paidOut());
        assertLe(payouts, yes + no, "unsolicited ETH must not enlarge entitlements");
        assertEq(address(market).balance + payouts, yes + no + handler.donated());
    }

    function invariant_individualStakesAndWalletsMatchTheLedger() public view {
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address actor = handler.actors(i);
            uint256 yes = handler.depositedYes(i);
            uint256 no = handler.depositedNo(i);
            assertEq(market.yesStake(actor), handler.claimed(i) ? 0 : yes);
            assertEq(market.noStake(actor), handler.claimed(i) ? 0 : no);
            assertEq(actor.balance + yes + no + handler.fees(i), handler.INITIAL_BALANCE() + handler.paid(i));
            if (handler.claimed(i)) assertEq(market.claimable(actor), 0, "a paid actor cannot claim twice");
        }
    }

    function invariant_allLiabilitiesRemainFundedWithBoundedRounding() public view {
        bool over = handler.yesWon() || vm.getBlockTimestamp() > market.RESOLUTION_DEADLINE();
        uint256 liabilities;
        uint256 winners;
        uint256 winningTotal = handler.yesWon() ? handler.yesDeposited() : handler.noDeposited();
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address actor = handler.actors(i);
            uint256 claimable = market.claimable(actor);
            liabilities += claimable;
            uint256 stake = handler.yesWon() ? handler.depositedYes(i) : handler.depositedNo(i);
            if (stake != 0) ++winners;
            if (!over) {
                assertEq(claimable, 0);
            } else if (!handler.claimed(i) && winningTotal != 0) {
                uint256 numerator = stake * (handler.yesDeposited() + handler.noDeposited());
                assertLe(claimable * winningTotal, numerator);
                assertGt((claimable + 1) * winningTotal, numerator);
            }
        }
        assertLe(liabilities, address(market).balance);
        if (over) {
            uint256 dust = address(market).balance - handler.donated() - liabilities;
            if (winningTotal == 0) assertEq(dust, 0);
            else assertLt(dust, winners, "less than one wei rounding per winner");
        }
    }

    function invariant_resolutionAndQuestionHistoryMatchIndependentModel() public view {
        assertEq(market.resolvedYes(), handler.yesWon());
        assertEq(market.winningQuestionId(), handler.winningId());
        assertEq(market.resolvedAt(), handler.winningTime());
        uint256 count = handler.questionLength();
        uint256[] memory ids = market.questionIds();
        assertEq(market.questionCount(), count);
        assertEq(ids.length, count);
        for (uint256 i; i < count; ++i) {
            GtaSixMarketHandler.Question memory q = handler.question(i);
            assertEq(ids[i], q.id);
            if (i != 0) assertGt(ids[i], ids[i - 1]);
            assertEq(market.askedBy(q.id), q.asker);
            assertEq(market.askedAt(q.id), q.time);
            assertEq(market.verdictOf(q.id), q.delivered);
        }
        GtaSixMarket.Phase expected;
        if (handler.yesWon()) expected = GtaSixMarket.Phase.YesWon;
        else if (vm.getBlockTimestamp() > market.RESOLUTION_DEADLINE()) expected = GtaSixMarket.Phase.NoWon;
        else if (vm.getBlockTimestamp() > market.BETTING_CLOSES_AT()) expected = GtaSixMarket.Phase.AwaitingResolution;
        else expected = GtaSixMarket.Phase.Betting;
        assertEq(uint256(market.phase()), uint256(expected));
        GtaSixMarket.MarketState memory s = market.marketState();
        assertEq(uint256(s.phase), uint256(expected));
        assertEq(s.bettingOpen, expected == GtaSixMarket.Phase.Betting);
        assertEq(market.bettingOpen(), s.bettingOpen);
        assertEq(s.yesTotal, handler.yesDeposited());
        assertEq(s.noTotal, handler.noDeposited());
        assertEq(s.totalClaimed, handler.paidOut());
        assertEq(s.questionCount, count);
        assertEq(s.resolvedYes, handler.yesWon());
        assertEq(s.resolvedAt, handler.winningTime());
        assertEq(s.winningQuestionId, handler.winningId());
        assertEq(s.bettingClosesAt, market.BETTING_CLOSES_AT());
        assertEq(s.resolutionDeadline, market.RESOLUTION_DEADLINE());
    }

    /// @dev Exercise withdrawal liveness after every generated sequence, including runs that
    /// finish while betting is still open. Every eligible EOA must actually receive its money.
    function afterInvariant() public {
        if (vm.getBlockTimestamp() <= market.RESOLUTION_DEADLINE()) {
            vm.warp(market.RESOLUTION_DEADLINE() + 1);
        }
        for (uint256 i; i < handler.ACTORS(); ++i) {
            handler.claim(i);
        }
        invariant_actionsMeetTheirPreconditionsAndPostconditions();
        invariant_ethAndHistoricalTotalsAreConserved();
        invariant_individualStakesAndWalletsMatchTheLedger();
        invariant_allLiabilitiesRemainFundedWithBoundedRounding();
        invariant_resolutionAndQuestionHistoryMatchIndependentModel();
        for (uint256 i; i < handler.ACTORS(); ++i) {
            assertEq(market.claimable(handler.actors(i)), 0);
        }
    }

    function test_handlerCanReachYesAndPayEveryWinner() public {
        handler.answer(0, 1);
        handler.settle(0, 5);
        handler.claim(0);
        handler.claim(1);
        assertTrue(handler.yesWon());
        assertEq(handler.claimCalls(), 2);
        assertEq(handler.settlementCalls(), 1);
        invariant_actionsMeetTheirPreconditionsAndPostconditions();
        invariant_ethAndHistoricalTotalsAreConserved();
    }

    function test_handlerCanReachTimeoutAndRejectLateYes() public {
        handler.answer(0, 1);
        handler.advanceTime(0, 3);
        handler.claim(2);
        handler.settle(0, 4);
        handler.claim(3);
        assertFalse(handler.yesWon());
        assertEq(handler.claimCalls(), 2);
        assertEq(handler.settlementCalls(), 1);
        invariant_actionsMeetTheirPreconditionsAndPostconditions();
        invariant_ethAndHistoricalTotalsAreConserved();
    }
}
