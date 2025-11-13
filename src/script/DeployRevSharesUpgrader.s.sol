// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";

/// @notice Deploys the RevShareContractsUpgrader contract.
/// @dev Usage:
///      forge script src/script/DeployRevSharesUpgrader.s.sol:DeployRevSharesUpgrader \
///        --rpc-url $RPC_URL \
///        --broadcast \
///        --verify
contract DeployRevSharesUpgrader is Script {
    /// @notice Deploys the RevShareContractsUpgrader contract
    /// @return upgrader The deployed RevShareContractsUpgrader contract
    function run() public returns (RevShareContractsUpgrader upgrader) {
        vm.startBroadcast();

        // Deploy the RevShareContractsUpgrader
        upgrader = new RevShareContractsUpgrader();

        vm.stopBroadcast();

        // Log the deployed address
        console.log("---");
        console.log("RevShareContractsUpgrader deployed at:", address(upgrader));
        console.log("---");
    }
}
