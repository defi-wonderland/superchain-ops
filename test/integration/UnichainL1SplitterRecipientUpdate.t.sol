// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {L1PortalExecuteL2Call} from "src/template/L1PortalExecuteL2Call.sol";
import {Action} from "src/libraries/MultisigTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {AddressAliasHelper} from "@eth-optimism-bedrock/src/vendor/AddressAliasHelper.sol";

contract UnichainL1SplitterRecipientUpdateTest is IntegrationBase {
    L1PortalExecuteL2Call internal _template;

    uint256 internal _mainnetForkId;
    uint256 internal _optimismForkId;

    function setUp() public {
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _optimismForkId = vm.createFork("http://127.0.0.1:9545");

        vm.selectFork(_mainnetForkId);
        _template = new L1PortalExecuteL2Call();
    }

    function test_unichainL1SplitterRecipientUpdate() public {
        string memory configPath = "test/tasks/example/eth/020-unichain-l1splitter-update-recipient/config.toml";

        // Step 1: Execute L1 transaction recording logs
        vm.recordLogs();
        (, Action[] memory actions,,, address rootSafe) = _template.simulate(configPath, new address[](0));

        // Verify simulation returned expected results
        assertTrue(actions.length > 0, "Should have generated actions");
        assertTrue(rootSafe != address(0), "Should have a valid root safe");

        // Step 2: Relay messages from L1 to L2
        _relayAllMessages(_optimismForkId);

        // Step 3: Verify the L2 state was updated correctly
        // TODO: Add specific assertions to verify the L1Splitter recipient was updated
        // This would involve checking the actual L2 contract state after the relay
    }
}
