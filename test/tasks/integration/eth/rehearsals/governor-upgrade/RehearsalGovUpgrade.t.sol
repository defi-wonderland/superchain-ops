// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {L1PortalExecuteL2Call} from "src/template/L1PortalExecuteL2Call.sol";
import {IntegrationBase} from "test/tasks/integration/IntegrationBase.t.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IProxy {
    function implementation() external view returns (address);
}

/// @notice Mock implementation contract for testing upgrades
contract MockGovernorImplementation {
// Empty implementation - just needs to exist as a contract
}

/// @title RehearsalGovUpgradeIntegrationTest
/// @notice Integration test for Rehearsal Governor Upgrade
/// @dev This test verifies that the L1->L2 portal call executes successfully
///      and that the target contract on L2 receives the upgrade call
contract RehearsalGovUpgradeIntegrationTest is IntegrationBase {
    event Upgraded(address indexed implementation);

    L1PortalExecuteL2Call public portalTemplate;

    // Fork IDs
    uint256 internal _mainnetForkId;
    uint256 internal _opMainnetForkId;

    // Configuration path
    string internal constant CONFIG_PATH = "src/tasks/eth/rehearsals/2025-08-22-R4-governor-upgrade/config.toml";

    function setUp() public {
        // Create forks for L1 (Ethereum Mainnet) and L2 (OP Mainnet)
        _mainnetForkId = vm.createFork(vm.envString("ETH_RPC_URL"));
        _opMainnetForkId = vm.createFork(vm.envString("OP_MAINNET_RPC_URL"));

        vm.selectFork(_mainnetForkId);
        portalTemplate = new L1PortalExecuteL2Call();
    }

    /// @notice Test the integration of the rehearsal 4 - no-op governor upgrade
    /// @dev This test:
    ///      1. Simulates the L1 transaction that calls OptimismPortal.depositTransaction
    ///      2. Replays the deposit on L2
    ///      3. Verifies the transaction executed successfully
    function test_rehearsalGovUpgrade_integration() public {
        // Read config to get expected parameters
        string memory _config = vm.readFile(CONFIG_PATH);
        address _l2Target = vm.parseTomlAddress(_config, ".l2Target");
        uint256 _gasLimit = vm.parseTomlUint(_config, ".gasLimit");
        bytes memory _l2Data = vm.parseTomlBytes(_config, ".l2Data");

        console2.log("\n=== Rehearsal 4 - No-op Governor Upgrade Integration Test ===");
        console2.log("L2 Target:", _l2Target);
        console2.log("Gas Limit:", _gasLimit);
        console2.log("L2 Data:");
        console2.logBytes(_l2Data);

        // Step 1: Execute L1 transaction recording logs
        vm.selectFork(_mainnetForkId);
        console2.log("\n=== Step 1: Executing L1 Transaction ===");
        vm.recordLogs();

        // Simulate the task (this will emit TransactionDeposited events)
        portalTemplate.simulate(CONFIG_PATH);

        // Step 2: Etch mock implementation contract for the placeholder implementation address
        vm.selectFork(_opMainnetForkId);
        // Deploy a minimal contract and etch it to the placeholder address
        bytes memory _mockImplementation = type(MockGovernorImplementation).runtimeCode;
        vm.etch(0x0000000000000000000000000000000000001234, _mockImplementation);

        // Step 3: Relay messages from L1 to L2
        console2.log("\n=== Step 2: Relaying Messages to L2 ===");
        // Pass true for _isSimulate since simulate() emits events twice
        vm.expectEmit(_l2Target);
        emit Upgraded(0x0000000000000000000000000000000000001234);
        vm.startPrank(0x2501c477D0A35545a387Aa4A3EEe4292A9a8B3F0);
        _relayAllMessages(_opMainnetForkId, true);
        vm.stopPrank();

        // Step 3: Verify the L2 state
        console2.log("\n=== Step 3: Verifying L2 State ===");
        vm.selectFork(_opMainnetForkId);

        // Verify the target contract code size
        uint256 _codeSize;
        assembly {
            _codeSize := extcodesize(_l2Target)
        }

        if (_codeSize > 0) {
            console2.log("Target contract has code (", _codeSize, "bytes)");

            // Read implementation from ERC1967 implementation slot
            bytes32 _implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
            address _impl = address(uint160(uint256(vm.load(_l2Target, _implSlot))));

            console2.log("Target is a proxy");
            console2.log("Current implementation:", _impl);

            // Verify the implementation was upgraded to the expected address
            address _expectedImpl = address(0x0000000000000000000000000000000000001234);
            assertEq(_impl, _expectedImpl, "Implementation should match expected address");
        } else {
            console2.log("Target address is a placeholder with no code");
            console2.log("This is expected for a rehearsal with a placeholder address");
            console2.log("In a real execution, this would be replaced with the actual Governor proxy address");
        }

        console2.log("\n=== Test Completed Successfully ===");
        console2.log("The L1->L2 deposit transaction was successfully relayed and executed");
    }

    /// @notice Test that verifies the correct calldata structure
    /// @dev This test decodes and validates the upgrade calldata
    function test_verifyUpgradeCalldata() public view {
        string memory _config = vm.readFile(CONFIG_PATH);
        bytes memory _l2Data = vm.parseTomlBytes(_config, ".l2Data");

        // The l2Data should be upgradeTo(address) selector + address parameter
        // upgradeTo selector: 0x3659cfe6
        require(_l2Data.length >= 36, "Calldata too short");

        bytes4 _selector;
        address _newImplementation;

        assembly {
            _selector := mload(add(_l2Data, 32))
            _newImplementation := mload(add(_l2Data, 36))
        }

        // Verify selector is upgradeTo(address)
        assertEq(_selector, bytes4(0x3659cfe6), "Selector should be upgradeTo(address)");

        console2.log("\n=== Calldata Verification ===");
        console2.log("Function selector:", vm.toString(uint32(_selector)));
        console2.log("New implementation address:", _newImplementation);

        // In this rehearsal, we're upgrading to a placeholder address
        // The actual implementation address should match config
        assertTrue(_newImplementation != address(0), "Implementation address should not be zero");
    }

    /// @notice Test configuration validation
    /// @dev Verifies all required config parameters are present and valid
    function test_validateConfiguration() public view {
        string memory _config = vm.readFile(CONFIG_PATH);

        // Validate all required fields
        string memory _templateName = vm.parseTomlString(_config, ".templateName");
        assertEq(_templateName, "L1PortalExecuteL2Call", "Template name should be L1PortalExecuteL2Call");

        address _portal = vm.parseTomlAddress(_config, ".portal");
        address _l2Target = vm.parseTomlAddress(_config, ".l2Target");
        uint256 _gasLimit = vm.parseTomlUint(_config, ".gasLimit");
        uint256 _value = vm.parseTomlUint(_config, ".value");
        bool _isCreation = vm.parseTomlBool(_config, ".isCreation");

        // Validate addresses are not zero
        assertTrue(_portal != address(0), "Portal address should not be zero");
        assertTrue(_l2Target != address(0), "L2 target address should not be zero");

        // Validate gas limit is reasonable
        assertGt(_gasLimit, 0, "Gas limit should be greater than zero");
        assertLe(_gasLimit, 10_000_000, "Gas limit should be reasonable");

        // Validate value and isCreation for this rehearsal
        assertEq(_value, 0, "Value should be zero for upgrade call");
        assertFalse(_isCreation, "isCreation should be false for upgrade call");

        console2.log("\n=== Configuration Validation ===");
        console2.log("Template:", _templateName);
        console2.log("Portal:", _portal);
        console2.log("L2 Target:", _l2Target);
        console2.log("Gas Limit:", _gasLimit);
        console2.log("Value:", _value);
        console2.log("Is Creation:", _isCreation);
        console2.log("All configuration parameters are valid");
    }
}
