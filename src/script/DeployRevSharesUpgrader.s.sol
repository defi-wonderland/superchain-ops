// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";

/// @notice Deploys the RevShareContractsUpgrader contract.
/// @dev Deployed at https://sepolia.etherscan.io/address/0x65d1b057EeFE204cAb3AC1607ba4b577eeA1515e
/// @dev Usage:
///      forge script src/script/DeployRevSharesUpgrader.s.sol:DeployRevSharesUpgrader \
///          --rpc-url https://ethereum-sepolia.rpc.subquery.network/public \
///          --broadcast \
///          --verify --private-key $PRIVATE_KEY --verifier custom \
///          --verifier-url 'https://api.etherscan.io/v2/api?chainid=11155111&apikey={$API_KEY}'
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
