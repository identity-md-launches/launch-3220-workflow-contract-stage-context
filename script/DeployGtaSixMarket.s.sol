// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {GtaSixMarket} from "../src/GtaSixMarket.sol";

/// @notice Local and rehearsal deployment only. The launch itself deploys `GtaSixMarket` through the IMD
/// project factory from the built bytecode, with no constructor arguments, so this script is never part of
/// it. `deploy()` is what the tests call; `run()` only wraps it in a broadcast for a manual local deploy.
contract DeployGtaSixMarket is Script {
    function deploy() public returns (GtaSixMarket market) {
        market = new GtaSixMarket();
    }

    function run() external returns (GtaSixMarket market) {
        vm.startBroadcast();
        market = deploy();
        vm.stopBroadcast();
    }
}
