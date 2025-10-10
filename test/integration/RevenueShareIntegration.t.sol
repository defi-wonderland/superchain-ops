// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {console2} from "forge-std/console2.sol";
import {RevenueShareV100UpgradePath} from "src/template/RevenueShareUpgradePath.sol";
import {Action} from "src/libraries/MultisigTypes.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";

contract RevenueShareIntegrationTest is IntegrationBase {
    RevenueShareV100UpgradePath public template;

    // Constants
    address public constant PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address public constant CREATE2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;

    // L2 predeploys
    address internal constant FEE_SPLITTER = 0x420000000000000000000000000000000000002B;
    address internal constant SEQUENCER_FEE_VAULT = 0x4200000000000000000000000000000000000011;
    address internal constant OPERATOR_FEE_VAULT = 0x420000000000000000000000000000000000001b;
    address internal constant BASE_FEE_VAULT = 0x4200000000000000000000000000000000000019;
    address internal constant L1_FEE_VAULT = 0x420000000000000000000000000000000000001A;

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
        string memory configPath = "test/tasks/example/eth/015-revenue-share-upgrade/config.toml";

        // Step 1: Execute L1 transaction recording logs
        vm.recordLogs();
        template.simulate(configPath, new address[](0));

        // Step 2: Relay messages from L1 to L2
        _relayAllMessages(_optimismForkId);
    }

    function test_optOutRevenueShare_integration() public {
        string memory configPath = "test/tasks/example/eth/019-revenueshare-upgrade-opt-out/config.toml";

        // Step 1: Execute L1 transaction recording logs
        vm.recordLogs();
        template.simulate(configPath, new address[](0));

        // Step 2: Relay messages from L1 to L2
        _relayAllMessages(_optimismForkId);
    }

}