// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {console2} from "forge-std/console2.sol";
import {RevenueShareV100UpgradePath} from "src/template/RevenueShareUpgradePath.sol";
import {Action} from "src/libraries/MultisigTypes.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";

contract RevenueShareIntegrationTest is IntegrationBase {
    RevenueShareV100UpgradePath public template;

    // Fork IDs
    uint256 internal _mainnetForkId;
    uint256 internal _optimismForkId;

    function setUp() public {
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _optimismForkId = vm.createFork("http://127.0.0.1:9545");
        vm.selectFork(_mainnetForkId);
        template = new RevenueShareV100UpgradePath();
    }

    function test_optInRevenueShare_integration() public {
        string memory _configPath = "test/tasks/example/eth/015-revenue-share-upgrade/config.toml";

        // Step 1: Execute L1 transaction recording logs
        vm.recordLogs();
        template.simulate(_configPath, new address[](0));

        // Step 2: Relay messages from L1 to L2
        // Pass true for _isSimulate since simulate() emits events twice
        _relayAllMessages(_optimismForkId, true);
    }

    function test_optOutRevenueShare_integration() public {
        string memory _configPath = "test/tasks/example/eth/019-revenueshare-upgrade-opt-out/config.toml";

        // Step 1: Execute L1 transaction recording logs
        vm.recordLogs();
        template.simulate(_configPath, new address[](0));

        // Step 2: Relay messages from L1 to L2
        // Pass true for _isSimulate since simulate() emits events twice
        _relayAllMessages(_optimismForkId, true);
    }

}