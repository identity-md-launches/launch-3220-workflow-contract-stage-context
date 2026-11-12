// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Judged} from "judge/Judged.sol";

/// @title GTA 6 release prediction market
/// @notice A parimutuel market in ETH on one question: is Grand Theft Auto VI released on or before
/// 2026-12-31 UTC? Anyone bets YES or NO while betting is open. The winning side splits the whole pot in
/// proportion to what each winner staked.
///
/// Resolution comes from Judge (https://taylor.fyi/judge), a panel of AI agents that answers a yes or no
/// question with proof. Once the game is out, anyone calls `resolve(proof)` with a little ETH to pay for the
/// question, and about five minutes later anyone calls `settle(id)`. The first YES verdict settled on or
/// before `RESOLUTION_DEADLINE` (2027-01-07 23:59:59 UTC) makes the YES side win. If no YES verdict has
/// landed by then, the NO side wins, with no further action from anyone. A NO or no-answer verdict decides
/// nothing: anyone can get one with a bad proof, so only a YES ever moves the market.
///
/// Betting is suspended while a question is pending (asked and not yet settled): the panel's verdict is
/// readable on the Judge before anyone settles it, so a bet placed then would carry no risk. A NO or
/// no-answer verdict reopens betting when settled; a counted YES closes it for good.
///
/// There is no owner, no fee, no pause and no upgrade. The only parties with any power are the bettors, the
/// Judge panel and whoever pays to ask.
contract GtaSixMarket is Judged {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Last second at which a bet is accepted: 2026-12-31 23:59:59 UTC, the end of the release window.
    uint256 public constant BETTING_CLOSES_AT = 1798761599;

    /// @notice Last second at which a YES verdict counts: 2027-01-07 23:59:59 UTC. After it, if no YES has
    /// landed, the NO side has won.
    uint256 public constant RESOLUTION_DEADLINE = 1799366399;

    /// @notice Last second at which `resolve` may ask: 2027-01-06 23:59:59 UTC, one day before the
    /// resolution deadline. A Judge question can take up to a day to end, so a question asked later than
    /// this could never be settled in time and its fee would be wasted.
    uint256 public constant LAST_ASK_AT = RESOLUTION_DEADLINE - 1 days;

    /// @notice The question put to the Judge panel. ASCII, under 500 bytes, and fixed so that nothing a caller
    /// writes can reach the part the panel trusts. The caller's evidence goes in the proof.
    string public constant QUESTION =
        "Was Grand Theft Auto VI (GTA 6), the video game by Rockstar Games, publicly released for sale and playable by the general public on or before 2026-12-31 (UTC)? Only the full general release counts: a trailer, a pre-order, a beta, an early-access program, a demo or a leak does not. Answer yes only if the proof links to an official Rockstar Games or Take-Two Interactive announcement, or a major news report, showing the game was released on or before that date.";

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    /// @notice Where the market stands right now.
    enum Phase {
        Betting, // bets are accepted
        AwaitingResolution, // betting closed or suspended, a YES verdict can still land
        YesWon, // a YES verdict landed in time: YES bettors claim
        NoWon // the resolution deadline passed with no YES: NO bettors claim
    }

    /// @notice ETH staked on YES by each bettor, until claimed.
    mapping(address bettor => uint256) public yesStake;
    /// @notice ETH staked on NO by each bettor, until claimed.
    mapping(address bettor => uint256) public noStake;
    /// @notice All ETH ever staked on YES. Never decreases, so payouts stay pro rata after claims.
    uint256 public yesTotal;
    /// @notice All ETH ever staked on NO. Never decreases.
    uint256 public noTotal;

    /// @notice True once a YES verdict has been settled on or before `RESOLUTION_DEADLINE`.
    bool public resolvedYes;
    /// @notice When the winning YES verdict was settled, or zero.
    uint256 public resolvedAt;
    /// @notice The Judge question id whose YES verdict resolved the market, or zero.
    uint256 public winningQuestionId;

    /// @notice Every Judge question this contract has asked, in order.
    uint256[] private _questionIds;
    /// @notice How many asked questions have not been settled yet. Betting is suspended while this is
    /// non-zero, because a verdict is readable on the Judge before it is settled here.
    uint256 public pendingQuestions;
    /// @notice Who asked each question.
    mapping(uint256 id => address) public askedBy;
    /// @notice When each question was asked.
    mapping(uint256 id => uint256) public askedAt;
    /// @notice The verdict `settle` delivered for each question: 0 pending, 1 yes, 2 no, 3 no answer.
    mapping(uint256 id => uint8) public verdictOf;

    /// @notice Total ETH paid out to winners so far.
    uint256 public totalClaimed;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event BetPlaced(address indexed bettor, bool indexed yes, uint256 amount);
    event ResolutionAsked(uint256 indexed id, address indexed by, string proof);
    event QuestionSettled(uint256 indexed id, uint8 verdict, bool counted);
    event ResolvedYes(uint256 indexed id, uint256 yesTotal, uint256 noTotal);
    event Claimed(address indexed bettor, uint256 payout);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroBet();
    error BettingClosed();
    error AlreadyResolved();
    error ResolutionWindowOver();
    error NotOverYet();
    error NothingToClaim();
    error DirectDepositRefused();

    // ---------------------------------------------------------------------------------------------
    // Betting
    // ---------------------------------------------------------------------------------------------

    /// @notice Stake `msg.value` on the game being released on or before 2026-12-31 UTC.
    function betYes() external payable {
        _bet(true);
    }

    /// @notice Stake `msg.value` on the game not being released by then.
    function betNo() external payable {
        _bet(false);
    }

    function _bet(bool yes) private {
        if (msg.value == 0) revert ZeroBet();
        if (!bettingOpen()) revert BettingClosed();
        if (yes) {
            yesStake[msg.sender] += msg.value;
            yesTotal += msg.value;
        } else {
            noStake[msg.sender] += msg.value;
            noTotal += msg.value;
        }
        emit BetPlaced(msg.sender, yes, msg.value);
    }

    // ---------------------------------------------------------------------------------------------
    // Resolution
    // ---------------------------------------------------------------------------------------------

    /// @notice Ask the Judge panel whether the game is out, attaching `proof` (ASCII, at most 650 bytes:
    /// a link to the announcement or news report). Send about 0.002 ETH to pay for the question; what it
    /// did not cost comes straight back. Anyone may ask, any number of times, until the market resolves
    /// YES or `LAST_ASK_AT` passes. The id is in the `Asked` and `ResolutionAsked` events. Betting is
    /// suspended from this call until the question is settled.
    /// @dev A caller that is a contract takes its change inside this call and must have a `receive`.
    function resolve(string calldata proof) external payable returns (uint256 id) {
        if (resolvedYes) revert AlreadyResolved();
        if (block.timestamp > LAST_ASK_AT) revert ResolutionWindowOver();
        id = ask(QUESTION, proof);
        _questionIds.push(id);
        pendingQuestions += 1;
        askedBy[id] = msg.sender;
        askedAt[id] = block.timestamp;
        emit ResolutionAsked(id, msg.sender, proof);
    }

    /// @dev The panel said yes. It counts only once, and only on or before the resolution deadline.
    function onYes(uint256 id) internal override {
        _settled(id, 1);
        bool counted = !resolvedYes && block.timestamp <= RESOLUTION_DEADLINE;
        emit QuestionSettled(id, 1, counted);
        if (counted) {
            resolvedYes = true;
            resolvedAt = block.timestamp;
            winningQuestionId = id;
            emit ResolvedYes(id, yesTotal, noTotal);
        }
    }

    /// @dev The panel said this proof did not show a release. Nothing changes but betting reopens: ask
    /// again with better proof.
    function onNo(uint256 id) internal override {
        _settled(id, 2);
        emit QuestionSettled(id, 2, false);
    }

    /// @dev No decision: refused, split, or a day passed. Nothing changes but betting reopens: ask again.
    function onNoAnswer(uint256 id) internal override {
        _settled(id, 3);
        emit QuestionSettled(id, 3, false);
    }

    /// @dev Records a verdict and takes the question out of the pending count. `Judged.settle` runs each
    /// question's hook exactly once, so the count never goes below zero.
    function _settled(uint256 id, uint8 verdict) private {
        verdictOf[id] = verdict;
        pendingQuestions -= 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------

    /// @notice Collect your share of the pot once the market has a winner. A winner receives its stake
    /// times the pot over the winning side's total. If nobody bet on the winning side, every bettor
    /// takes back exactly what they staked instead. Each bettor claims once.
    function claim() external {
        uint256 payout = _claimable(msg.sender, true);
        if (payout == 0) revert NothingToClaim();
        yesStake[msg.sender] = 0;
        noStake[msg.sender] = 0;
        totalClaimed += payout;
        emit Claimed(msg.sender, payout);
        pay(msg.sender, payout);
    }

    /// @notice What `claim` would pay `bettor` right now. Zero before the market has a winner.
    function claimable(address bettor) external view returns (uint256) {
        return _claimable(bettor, false);
    }

    function _claimable(address bettor, bool revertIfNotOver) private view returns (uint256) {
        bool yesWins;
        if (resolvedYes) {
            yesWins = true;
        } else if (block.timestamp > RESOLUTION_DEADLINE) {
            yesWins = false;
        } else {
            if (revertIfNotOver) revert NotOverYet();
            return 0;
        }
        uint256 winningTotal = yesWins ? yesTotal : noTotal;
        if (winningTotal == 0) {
            // Nobody took the winning side: there is nobody to pay the losers' money to, so it goes back.
            return yesStake[bettor] + noStake[bettor];
        }
        uint256 stake = yesWins ? yesStake[bettor] : noStake[bettor];
        return stake * (yesTotal + noTotal) / winningTotal;
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the site
    // ---------------------------------------------------------------------------------------------

    /// @notice Whether a bet would be accepted right now: no counted YES, no question pending, and the
    /// betting window still open.
    function bettingOpen() public view returns (bool) {
        return !resolvedYes && pendingQuestions == 0 && block.timestamp <= BETTING_CLOSES_AT;
    }

    /// @notice Where the market stands right now.
    function phase() public view returns (Phase) {
        if (resolvedYes) return Phase.YesWon;
        if (block.timestamp > RESOLUTION_DEADLINE) return Phase.NoWon;
        if (bettingOpen()) return Phase.Betting;
        return Phase.AwaitingResolution;
    }

    /// @notice The whole pot: everything ever staked, including what has already been claimed.
    function pot() external view returns (uint256) {
        return yesTotal + noTotal;
    }

    /// @notice How many Judge questions this market has asked.
    function questionCount() external view returns (uint256) {
        return _questionIds.length;
    }

    /// @notice Every Judge question id this market has asked, oldest first.
    function questionIds() external view returns (uint256[] memory) {
        return _questionIds;
    }

    /// @notice Everything the site needs in one read.
    struct MarketState {
        Phase phase;
        bool bettingOpen;
        uint256 yesTotal;
        uint256 noTotal;
        uint256 totalClaimed;
        uint256 questionCount;
        uint256 pendingQuestions;
        bool resolvedYes;
        uint256 resolvedAt;
        uint256 winningQuestionId;
        uint256 bettingClosesAt;
        uint256 lastAskAt;
        uint256 resolutionDeadline;
    }

    function marketState() external view returns (MarketState memory s) {
        s.phase = phase();
        s.bettingOpen = bettingOpen();
        s.yesTotal = yesTotal;
        s.noTotal = noTotal;
        s.totalClaimed = totalClaimed;
        s.questionCount = _questionIds.length;
        s.pendingQuestions = pendingQuestions;
        s.resolvedYes = resolvedYes;
        s.resolvedAt = resolvedAt;
        s.winningQuestionId = winningQuestionId;
        s.bettingClosesAt = BETTING_CLOSES_AT;
        s.lastAskAt = LAST_ASK_AT;
        s.resolutionDeadline = RESOLUTION_DEADLINE;
    }

    // ---------------------------------------------------------------------------------------------
    // ETH in
    // ---------------------------------------------------------------------------------------------

    /// @dev The only ETH this contract takes outside `betYes`, `betNo` and `resolve` is a question's change
    /// on its way back to whoever asked, which the Judge door sends. Anything else is refused, so money
    /// cannot be stranded here by a plain transfer.
    receive() external payable override {
        (, address door) = _judge();
        if (msg.sender != door) revert DirectDepositRefused();
    }
}
