// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {JUDGE_STAND_IN} from "./Judged.sol";

/// @dev Foundry's cheat codes, named here so this file works beside whichever forge-std a project has.
interface IJudgedCheats {
    function etch(address target, bytes calldata code) external;
    function warp(uint256 time) external;
    function roll(uint256 height) external;
}

IJudgedCheats constant JUDGED_CHEATS = IJudgedCheats(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title Judge without the panel, for `forge test`
/// @notice Free and instant. It costs about what a question costs, refuses the text the real one refuses,
/// ends a question after a day, and answers when told to. It uses far less gas than the real one.
contract JudgeStandIn {
    error EthShort(uint256 needed, uint256 sent);
    error RefundFailed();
    error EmptyText();
    error TextTooLong(uint256 length, uint256 limit);
    error NotAscii(uint256 index);

    enum Verdict {
        Pending,
        Yes,
        No,
        NoAnswer
    }

    uint256 public constant COST = 0.0007 ether;

    /// @notice The latest question's id. Real ids count every question anyone asks, so they won't match a
    /// counter of your own, and these start at 1001 so a test shows that.
    uint256 public latest;
    mapping(uint256 id => uint256) private askedAt;
    mapping(uint256 id => Verdict) private answers;

    function ask(string calldata rule, string calldata proof) external payable returns (uint256 id) {
        _check(rule, 500);
        _check(proof, 650);
        // The real price moves, so a real ask always has change to send back. So does this one.
        if (msg.value <= COST) revert EthShort(COST + 1, msg.value);
        id = latest == 0 ? 1001 : latest + 1;
        latest = id;
        askedAt[id] = block.timestamp;
        (bool ok,) = msg.sender.call{value: msg.value - COST}("");
        if (!ok) revert RefundFailed();
    }

    function verdict(uint256 id) public view returns (Verdict) {
        if (answers[id] == Verdict.Pending && askedAt[id] != 0 && block.timestamp > askedAt[id] + 1 days) return Verdict.NoAnswer;
        return answers[id];
    }

    function answer(uint256 id, Verdict v) external {
        require(askedAt[id] != 0, "JudgeStandIn: nobody asked that");
        require(verdict(id) == Verdict.Pending, "JudgeStandIn: that question is over");
        answers[id] = v;
    }

    function _check(string calldata text, uint256 limit) private pure {
        uint256 length = bytes(text).length;
        if (length == 0) revert EmptyText();
        if (length > limit) revert TextTooLong(length, limit);
        for (uint256 i; i < length; ++i) {
            if (uint8(bytes(text)[i]) >= 0x80) revert NotAscii(i);
        }
    }
}

/// @title Test a contract that inherits `Judged`, for free
/// @notice Inherit this beside forge-std's `Test`. Each answer goes to the latest question, moves the clock
/// to when it would land, and returns the id for `settle`.
abstract contract JudgedTest {
    constructor() {
        JUDGED_CHEATS.etch(JUDGE_STAND_IN, type(JudgeStandIn).runtimeCode);
    }

    function answerYes() internal returns (uint256) {
        return _answer(JudgeStandIn.Verdict.Yes);
    }

    function answerNo() internal returns (uint256) {
        return _answer(JudgeStandIn.Verdict.No);
    }

    /// @dev The question was refused or the agents split. A question nobody answers ends the same way a day after it was asked.
    function answerNone() internal returns (uint256) {
        return _answer(JudgeStandIn.Verdict.NoAnswer);
    }

    /// @notice The latest question's id, for a test that settles before there's an answer.
    function latestQuestion() internal view returns (uint256) {
        return JudgeStandIn(JUDGE_STAND_IN).latest();
    }

    function _answer(JudgeStandIn.Verdict verdict) private returns (uint256 id) {
        id = latestQuestion();
        JudgeStandIn(JUDGE_STAND_IN).answer(id, verdict);
        JUDGED_CHEATS.warp(block.timestamp + 5 minutes);
        JUDGED_CHEATS.roll(block.number + 25);
    }

    /// @dev Takes the change when the test itself asks.
    receive() external payable virtual {}
}
