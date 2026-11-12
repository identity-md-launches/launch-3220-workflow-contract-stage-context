// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Where `forge test` looks for Judge. `JudgedTest` puts a free stand-in here.
address constant JUDGE_STAND_IN = 0x0000000000000000000000000000004a55444745;

interface IJudgedJudge {
    function ask(string calldata rule, string calldata proof) external returns (uint256 id);
    function verdict(uint256 id) external view returns (uint8);
    function price() external view returns (uint256);
    function asset() external view returns (IJudgedToken);
}

interface IJudgedDoor {
    function ask(string calldata rule, string calldata proof) external payable returns (uint256 id);
}

interface IJudgedToken {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title Ask AI from your contract
/// @notice Inherit this, call `ask(question, proof)` from a payable function and write `onYes`. AI agents
/// vote, and about 5 minutes later anyone can call `settle(id)`, which runs `onYes`, `onNo` or `onNoAnswer`
/// once. A vote can be wrong, so read the rules before you put money on one:
/// https://github.com/gtmcknight/judge#before-you-put-money-on-a-verdict
abstract contract Judged {
    /// @notice A question this contract asked. `id` is what `settle` takes.
    event Asked(uint256 indexed id, address indexed by);

    /// @dev The Judge each open question was asked on, so its answer can only come from there.
    mapping(uint256 id => address judge) private open;
    mapping(bytes32 key => bool) private asked;
    bool private busy;

    /// @dev Fails on a chain with no Judge, before anyone can send this contract money.
    constructor() {
        _judge();
    }

    /// @notice Asks, paying with all the ETH sent to the calling function. What the question didn't cost goes
    /// back to the sender. If your function spends or keeps any of `msg.value`, use `budget` below, or this
    /// pays the difference out of your contract's own money.
    /// @param question A yes or no question, in ASCII, at most 500 bytes. The agents trust it, so put nothing
    /// a caller wrote in it. Name whoever stands to win.
    /// @param proof What shows the answer, in ASCII, at most 650 bytes. The agents treat it as untrusted.
    /// @return id The question's number, for `settle`.
    function ask(string memory question, string memory proof) internal returns (uint256 id) {
        return ask(question, proof, msg.value);
    }

    /// @notice The same, paying with only `budget` of the ETH sent. The rest stays in this contract. The cost
    /// moves with IMD's price, so work the budget out from what was sent rather than fixing it.
    function ask(string memory question, string memory proof, uint256 budget) internal returns (uint256 id) {
        require(!busy, "Judged: can't ask from inside another Judged call");
        require(budget <= msg.value, "Judged: budget is more than the ETH sent");
        // `msg.value` doesn't go down after an ask, and a payable multicall repeats it in every call, so a
        // second ask would pay from this contract's own money and send that "change" to the caller. Every
        // one of those has this key.
        bytes32 key = keccak256(abi.encode(block.number, msg.sender, msg.value));
        require(!asked[key], "Judged: this sender and value already asked in this block");
        asked[key] = true;

        uint256 before = address(this).balance - budget;
        (address judge, address door) = _judge();
        require(judge.code.length > 0, "Judged: no Judge at this address. In forge test, inherit JudgedTest");
        if (door == address(0)) {
            // This chain has no ETH pool, so the contract pays in the chain's token, which it has to hold.
            require(IJudgedJudge(judge).asset().approve(judge, IJudgedJudge(judge).price()), "Judged: approve failed");
            id = IJudgedJudge(judge).ask(question, proof);
        } else {
            require(budget > 0, "Judged: send ETH with this call, it pays for the question");
            id = IJudgedDoor(door).ask{value: budget}(question, proof);
        }
        open[id] = judge;
        emit Asked(id, msg.sender);

        uint256 change = address(this).balance - before;
        if (change > 0) {
            // A contract taking its change can't ask or settle from there.
            busy = true;
            pay(msg.sender, change);
            busy = false;
        }
    }

    /// @notice Acts on an answer. Anyone can call this once the vote is over, and each question acts once.
    /// It reverts while the agents are voting and on any id this contract didn't ask.
    function settle(uint256 id) external {
        require(!busy, "Judged: can't settle from inside another Judged call");
        address judge = open[id];
        require(judge != address(0), "Judged: not an open question of this contract");
        uint8 verdict = IJudgedJudge(judge).verdict(id);
        require(verdict != 0, "Judged: still voting");
        delete open[id];
        busy = true;
        if (verdict == 1) onYes(id);
        else if (verdict == 2) onNo(id);
        else onNoAnswer(id);
        busy = false;
    }

    /// @notice The agents agreed the answer is yes. `msg.sender` here is whoever called `settle`, not whoever
    /// asked, so look up who asked by `id`. Each question gets its own answer and a yes never expires, so if
    /// there's one prize, close it on the first yes.
    function onYes(uint256 id) internal virtual;

    /// @notice The agents agreed the answer is no. That only says this proof didn't show it, and anyone can
    /// get a no by sending a bad proof, so don't move money on it.
    function onNo(uint256 id) internal virtual {}

    /// @notice There was no decision: the question was refused, the agents split, or a day passed. It isn't
    /// a ruling, so never pay anyone on it.
    function onNoAnswer(uint256 id) internal virtual {}

    /// @notice Sends ETH, and reverts if it can't. Unlike `transfer`, this also pays smart wallets. It won't
    /// pay the zero address, which is what looking up an id nobody stored gives you.
    function pay(address to, uint256 amount) internal {
        require(to != address(0), "Judged: paying nobody");
        (bool sent,) = to.call{value: amount}("");
        require(sent, "Judged: payment failed");
    }

    /// @dev Where Judge lives on each chain. `door` is zero where there's no ETH pool.
    function _judge() internal view virtual returns (address judge, address door) {
        if (block.chainid == 1) return (0x37f5E695C1860fF8aec4bf52842020D31699e2eb, 0xe5A08fA59e9B070bDE8b303e5Dc344937C201bab);
        if (block.chainid == 11155111) return (0x4958501caedC8E3824c8B6E09EB449f5c97Dbe1D, address(0));
        if (block.chainid == 31337) return (JUDGE_STAND_IN, JUDGE_STAND_IN);
        revert("Judged: Judge isn't on this chain");
    }

    /// @dev Takes the door's change, and the ETH that funds whatever this contract pays out. The change passes
    /// through here on its way back to the sender, so an override can't count what arrives as deposits.
    receive() external payable virtual {}
}
