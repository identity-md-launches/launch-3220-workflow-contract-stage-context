// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JudgedTest, JudgeStandIn} from "judge/JudgedTest.sol";
import {JUDGE_STAND_IN} from "judge/Judged.sol";
import {GtaSixMarket} from "src/GtaSixMarket.sol";

/// @dev Metamorphic properties compare equivalent economic actions, rather than duplicating
/// the implementation's payout expression. uint96 stakes stress arithmetic well above real
/// ETH balances while keeping all products representable in uint256.
/// forge-config: default.fuzz.runs = 1000
contract GtaSixMarketPropertiesTest is Test, JudgedTest {
    GtaSixMarket internal market;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal asker;
    uint256 internal constant MAX_STAKE = type(uint96).max;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1_794_000_000);
        vm.roll(100);
        market = new GtaSixMarket();
        alice = makeAddr("property alice");
        bob = makeAddr("property bob");
        carol = makeAddr("property carol");
        asker = makeAddr("property asker");
        vm.deal(asker, 1 ether);
    }

    function _bet(GtaSixMarket target, address actor, bool yes, uint256 amount) internal {
        if (amount == 0) return;
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        if (yes) target.betYes{value: amount}();
        else target.betNo{value: amount}();
    }

    function _yes(GtaSixMarket target) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(asker);
        uint256 id = target.resolve{value: 0.002 ether}("property-test evidence");
        JudgeStandIn(JUDGE_STAND_IN).answer(id, JudgeStandIn.Verdict.Yes);
        target.settle(id);
    }

    function _finish(GtaSixMarket first, GtaSixMarket second, bool yesWins) internal {
        if (yesWins) {
            _yes(first);
            _yes(second);
        } else {
            vm.warp(first.RESOLUTION_DEADLINE() + 1);
        }
    }

    function _claim(GtaSixMarket target, address actor) internal returns (uint256 received) {
        uint256 before = actor.balance;
        vm.prank(actor);
        target.claim();
        received = actor.balance - before;
    }

    function testFuzz_claimOrderDoesNotChangeAnyEntitlement(uint96 aSeed, uint96 bSeed, uint96 losingSeed, bool yesWins)
        public
    {
        uint256 a = bound(aSeed, 1, MAX_STAKE);
        uint256 b = bound(bSeed, 1, MAX_STAKE);
        uint256 losing = bound(losingSeed, 0, MAX_STAKE);
        GtaSixMarket reversed = new GtaSixMarket();
        _bet(market, alice, yesWins, a);
        _bet(market, bob, yesWins, b);
        _bet(market, carol, !yesWins, losing);
        _bet(reversed, alice, yesWins, a);
        _bet(reversed, bob, yesWins, b);
        _bet(reversed, carol, !yesWins, losing);
        _finish(market, reversed, yesWins);

        uint256 beforeA = market.claimable(alice);
        uint256 beforeB = market.claimable(bob);
        uint256 paidA = _claim(market, alice);
        assertEq(market.claimable(bob), beforeB, "an earlier claim cannot shrink another winner's share");
        uint256 paidB = _claim(market, bob);
        assertEq(_claim(reversed, bob), paidB);
        assertEq(reversed.claimable(alice), beforeA);
        assertEq(_claim(reversed, alice), paidA);
        assertEq(paidA, beforeA);
        assertEq(paidB, beforeB);
        assertEq(market.totalClaimed(), reversed.totalClaimed());
        assertEq(address(market).balance, address(reversed).balance);
        assertLt(address(market).balance, 2);
        assertEq(market.pot(), a + b + losing, "claims do not erase the historical pot");
    }

    function testFuzz_splittingOneActorsBetIntoTransactionsDoesNotChangePayout(
        uint96 firstSeed,
        uint96 secondSeed,
        uint96 othersSeed,
        bool yesWins
    ) public {
        uint256 first = bound(firstSeed, 1, MAX_STAKE);
        uint256 second = bound(secondSeed, 1, MAX_STAKE);
        uint256 others = bound(othersSeed, 1, MAX_STAKE);
        GtaSixMarket combined = new GtaSixMarket();
        _bet(market, alice, yesWins, first);
        _bet(market, bob, !yesWins, others);
        _bet(market, alice, yesWins, second);
        _bet(market, carol, yesWins, others);
        _bet(combined, alice, yesWins, first + second);
        _bet(combined, carol, yesWins, others);
        _bet(combined, bob, !yesWins, others);
        _finish(market, combined, yesWins);
        assertEq(_claim(market, alice), _claim(combined, alice));
        assertEq(_claim(market, carol), _claim(combined, carol));
        assertEq(address(market).balance, address(combined).balance);
    }

    function testFuzz_splittingAcrossAddressesCannotIncreaseTotalPayout(
        uint96 firstSeed,
        uint96 secondSeed,
        uint96 losingSeed,
        bool yesWins
    ) public {
        uint256 first = bound(firstSeed, 1, MAX_STAKE);
        uint256 second = bound(secondSeed, 1, MAX_STAKE);
        uint256 losing = bound(losingSeed, 0, MAX_STAKE);
        GtaSixMarket combined = new GtaSixMarket();
        _bet(market, alice, yesWins, first);
        _bet(market, bob, yesWins, second);
        _bet(market, carol, !yesWins, losing);
        _bet(combined, alice, yesWins, first + second);
        _bet(combined, carol, !yesWins, losing);
        _finish(market, combined, yesWins);
        uint256 splitPayout = _claim(market, alice) + _claim(market, bob);
        uint256 combinedPayout = _claim(combined, alice);
        assertLe(splitPayout, combinedPayout, "splitting cannot extract rounding dust");
        assertLe(combinedPayout - splitPayout, 1, "two winners lose at most one wei to rounding");
        assertEq(combinedPayout, first + second + losing);
    }

    function testFuzz_missingWinningSideRefundsExactlyWhatEachActorDeposited(uint96 aSeed, uint96 bSeed, bool yesWins)
        public
    {
        uint256 a = bound(aSeed, 1, MAX_STAKE);
        uint256 b = bound(bSeed, 1, MAX_STAKE);
        _bet(market, alice, !yesWins, a);
        _bet(market, bob, !yesWins, b);
        if (yesWins) _yes(market);
        else vm.warp(market.RESOLUTION_DEADLINE() + 1);
        assertEq(_claim(market, bob), b);
        assertEq(market.claimable(alice), a);
        assertEq(_claim(market, alice), a);
        assertEq(market.totalClaimed(), a + b);
        assertEq(address(market).balance, 0);
        vm.prank(alice);
        vm.expectRevert(GtaSixMarket.NothingToClaim.selector);
        market.claim();
    }

    function testFuzz_singleHedgedActorRecoversWholePot(bool yesWins, uint96 yesSeed, uint96 noSeed) public {
        uint256 yes = bound(yesSeed, 1, MAX_STAKE);
        uint256 no = bound(noSeed, 1, MAX_STAKE);
        _bet(market, alice, true, yes);
        _bet(market, alice, false, no);
        if (yesWins) _yes(market);
        else vm.warp(market.RESOLUTION_DEADLINE() + 1);
        assertEq(_claim(market, alice), yes + no);
        assertEq(market.yesStake(alice), 0);
        assertEq(market.noStake(alice), 0);
        assertEq(market.yesTotal(), yes);
        assertEq(market.noTotal(), no);
        assertEq(address(market).balance, 0);
    }

    function test_oneWeiWinnersCanAllClaimDespiteRounding() public {
        _bet(market, alice, true, 1);
        _bet(market, bob, true, 1);
        _bet(market, carol, false, 1);
        _yes(market);
        assertEq(_claim(market, alice), 1);
        assertEq(_claim(market, bob), 1);
        assertEq(market.totalClaimed(), 2);
        assertEq(address(market).balance, 1);
        assertEq(market.claimable(carol), 0);
    }

    function test_maximumUint96StakesStillDistributeWholePot() public {
        _bet(market, alice, false, MAX_STAKE);
        _bet(market, bob, false, MAX_STAKE);
        _bet(market, carol, true, MAX_STAKE * 2);
        vm.warp(market.RESOLUTION_DEADLINE() + 1);
        assertEq(_claim(market, alice), MAX_STAKE * 2);
        assertEq(_claim(market, bob), MAX_STAKE * 2);
        assertEq(address(market).balance, 0);
        assertEq(market.totalClaimed(), MAX_STAKE * 4);
    }
}
