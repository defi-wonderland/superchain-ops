// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {L1PortalExecuteL2Call} from "src/template/L1PortalExecuteL2Call.sol";
import {IntegrationBase} from "test/tasks/integration/IntegrationBase.t.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IProxy {
    function implementation() external view returns (address);
    function admin() external view returns (address);
}

interface IProxyAdmin {
    function changeProxyAdmin(address proxy, address newAdmin) external;
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

    /// @notice Test the integration of the rehearsal 4 - governor upgrade
    /// @dev This test:
    ///      1. Transfers ownership of OptimismGovernorProxy to L2ProxyAdmin on L2
    ///      2. Simulates the L1 transaction that calls OptimismPortal.depositTransaction
    ///      3. Replays the deposit on L2
    ///      4. Verifies the upgrade executed successfully
    function test_rehearsalGovUpgrade_integration() public {
        // Read config to get expected parameters
        string memory _config = vm.readFile(CONFIG_PATH);
        address _l2ProxyAdmin = vm.parseTomlAddress(_config, ".l2Target");
        uint256 _gasLimit = vm.parseTomlUint(_config, ".gasLimit");
        bytes memory _l2Data = vm.parseTomlBytes(_config, ".l2Data");

        // Governor proxy and addresses
        address _governorProxy = 0xcDF27F107725988f2261Ce2256bDfCdE8B382B10;
        address _currentOwner = 0x2501c477D0A35545a387Aa4A3EEe4292A9a8B3F0;
        address _newImplementation = 0x637DA4Eeac836188D8C46F63Cb2655f4d3C9F893;

        console2.log("\n=== Rehearsal 4 - Governor Upgrade Integration Test ===");
        console2.log("Governor Proxy:", _governorProxy);
        console2.log("Current Owner:", _currentOwner);
        console2.log("L2 ProxyAdmin:", _l2ProxyAdmin);
        console2.log("New Implementation:", _newImplementation);

        // Step 1: Transfer ownership on L2
        console2.log("\n=== Step 1: Transfer Governor Ownership to L2ProxyAdmin ===");
        vm.selectFork(_opMainnetForkId);

        // Read current admin before transfer
        bytes32 _adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        address _adminBefore = address(uint160(uint256(vm.load(_governorProxy, _adminSlot))));
        console2.log("Admin before:", _adminBefore);
        assertEq(_adminBefore, _currentOwner, "Current owner should match expected");

        // Transfer ownership by calling changeAdmin on the proxy from current owner
        vm.prank(_currentOwner);
        (bool _success,) = _governorProxy.call(abi.encodeWithSignature("changeAdmin(address)", _l2ProxyAdmin));
        require(_success, "changeAdmin failed");

        address _adminAfter = address(uint160(uint256(vm.load(_governorProxy, _adminSlot))));
        console2.log("Admin after:", _adminAfter);
        assertEq(_adminAfter, _l2ProxyAdmin, "Admin should be L2ProxyAdmin");

        // Read current implementation before upgrade
        bytes32 _implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address _implBefore = address(uint160(uint256(vm.load(_governorProxy, _implSlot))));
        console2.log("Implementation before upgrade:", _implBefore);

        // Step 2: Execute L1 transaction recording logs
        vm.selectFork(_mainnetForkId);
        console2.log("\n=== Step 2: Executing L1 Transaction ===");
        console2.log("L2 Data:");
        console2.logBytes(_l2Data);
        vm.recordLogs();

        // Simulate the task (this will emit TransactionDeposited events)
        portalTemplate.simulate(CONFIG_PATH);

        // Step 3: Deploy mock implementation contract
        vm.selectFork(_opMainnetForkId);
        console2.log("\n=== Step 3: Deploying Mock Implementation ===");
        bytes memory _mockImplementation = type(MockGovernorImplementation).runtimeCode;
        vm.etch(_newImplementation, _mockImplementation);
        console2.log("Mock implementation deployed at:", _newImplementation);

        // Step 4: Relay messages from L1 to L2
        console2.log("\n=== Step 4: Relaying Messages to L2 ===");
        // Pass true for _isSimulate since simulate() emits events twice
        _relayAllMessages(_opMainnetForkId, true);

        // Step 5: Verify the upgrade was successful
        console2.log("\n=== Step 5: Verifying Upgrade ===");
        vm.selectFork(_opMainnetForkId);

        address _implAfter = address(uint160(uint256(vm.load(_governorProxy, _implSlot))));
        console2.log("Implementation after upgrade:", _implAfter);

        // Verify the implementation was upgraded to the expected address
        assertEq(_implAfter, _newImplementation, "Implementation should match new implementation");
        assertTrue(_implAfter != _implBefore, "Implementation should have changed");

        console2.log("\n=== Test Completed Successfully ===");
        console2.log("Governor ownership transferred and upgrade executed successfully");
    }

    /// @notice Test that verifies the correct calldata structure
    /// @dev This test decodes and validates the upgrade calldata for L2ProxyAdmin.upgrade()
    function test_verifyUpgradeCalldata() public view {
        string memory _config = vm.readFile(CONFIG_PATH);
        bytes memory _l2Data = vm.parseTomlBytes(_config, ".l2Data");

        // The l2Data should be upgrade(address,address) selector + proxy + implementation
        // upgrade selector: 0x99a88ec4
        require(_l2Data.length >= 68, "Calldata too short");

        bytes4 _selector;
        address _proxy;
        address _newImplementation;

        assembly {
            _selector := mload(add(_l2Data, 32))
            _proxy := mload(add(_l2Data, 36))
            _newImplementation := mload(add(_l2Data, 68))
        }

        // Verify selector is upgrade(address,address)
        assertEq(_selector, bytes4(0x99a88ec4), "Selector should be upgrade(address,address)");

        console2.log("\n=== Calldata Verification ===");
        console2.log("Function selector:", vm.toString(uint32(_selector)));
        console2.log("Proxy address:", _proxy);
        console2.log("New implementation address:", _newImplementation);

        // Verify addresses match expected values
        assertEq(_proxy, 0xcDF27F107725988f2261Ce2256bDfCdE8B382B10, "Proxy should be OptimismGovernorProxy");
        assertEq(
            _newImplementation, 0x637DA4Eeac836188D8C46F63Cb2655f4d3C9F893, "Implementation should match expected"
        );
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
