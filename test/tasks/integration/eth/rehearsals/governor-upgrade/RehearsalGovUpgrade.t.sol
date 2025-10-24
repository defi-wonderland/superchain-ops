// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {L1PortalExecuteL2Call} from "src/template/L1PortalExecuteL2Call.sol";
import {IntegrationBase} from "test/tasks/integration/IntegrationBase.t.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IProxyAdmin} from "@eth-optimism-bedrock/interfaces/universal/IProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Mock implementation contract for testing upgrades
contract MockGovernorImplementation {
// Empty implementation - just needs to exist as a contract
}

/// @title RehearsalGovUpgradeIntegrationTest
/// @notice Integration test for Rehearsal Governor Upgrade
/// @dev This test verifies that the L1->L2 portal call executes successfully
///      and that the target contract on L2 receives the upgrade call
contract RehearsalGovUpgradeIntegrationTest is IntegrationBase {
    L1PortalExecuteL2Call public portalTemplate;

    // Fork IDs
    uint256 internal _mainnetForkId;
    uint256 internal _opMainnetForkId;

    // State tracking
    address internal _implBeforeUpgrade;

    // Configuration path
    string internal constant CONFIG_PATH = "src/tasks/eth/rehearsals/2025-08-22-R4-governor-upgrade/config.toml";

    // Addresses
    address internal constant GOVERNOR_PROXY = 0xcDF27F107725988f2261Ce2256bDfCdE8B382B10;
    address internal constant CURRENT_OWNER = 0x2501c477D0A35545a387Aa4A3EEe4292A9a8B3F0;
    address internal constant L2_PROXY_ADMIN = 0x4200000000000000000000000000000000000018;
    address internal constant NEW_IMPLEMENTATION = 0x637DA4Eeac836188D8C46F63Cb2655f4d3C9F893;

    // ERC1967 Storage slots
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

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
        console2.log("\n=== Rehearsal 4 - Governor Upgrade Integration Test ===");
        console2.log("Governor Proxy:", GOVERNOR_PROXY);
        console2.log("Current Owner:", CURRENT_OWNER);
        console2.log("L2 ProxyAdmin:", L2_PROXY_ADMIN);
        console2.log("New Implementation:", NEW_IMPLEMENTATION);

        // Step 1: Transfer ownership on L2
        _transferOwnershipToProxyAdmin();

        // Step 2: Execute L1 transaction and record logs
        vm.selectFork(_mainnetForkId);
        console2.log("\n=== Step 2: Executing L1 Transaction ===");
        vm.recordLogs();
        portalTemplate.simulate(CONFIG_PATH);

        // Step 4: Relay messages from L1 to L2
        console2.log("\n=== Step 3: Relaying Messages to L2 ===");
        _relayAllMessages(_opMainnetForkId, true);

        // Step 5: Verify the upgrade was successful
        _verifyUpgrade();

        console2.log("\n=== Test Completed Successfully ===");
        console2.log("Governor ownership transferred and upgrade executed successfully");
    }

    /// @notice Transfer ownership of the governor proxy to L2ProxyAdmin
    function _transferOwnershipToProxyAdmin() internal {
        console2.log("\n=== Step 1: Transfer Governor Ownership to L2ProxyAdmin ===");
        vm.selectFork(_opMainnetForkId);

        address _adminBefore = _getProxyAdmin(GOVERNOR_PROXY);
        console2.log("Admin before:", _adminBefore);
        assertEq(_adminBefore, CURRENT_OWNER, "Current owner should match expected");

        // Store implementation before upgrade
        _implBeforeUpgrade = _getProxyImplementation(GOVERNOR_PROXY);
        console2.log("Implementation before upgrade:", _implBeforeUpgrade);

        vm.prank(CURRENT_OWNER);
        ITransparentUpgradeableProxy(payable(GOVERNOR_PROXY)).changeAdmin(L2_PROXY_ADMIN);

        address _adminAfter = _getProxyAdmin(GOVERNOR_PROXY);
        console2.log("Admin after:", _adminAfter);
        assertEq(_adminAfter, L2_PROXY_ADMIN, "Admin should be L2ProxyAdmin");
    }

    /// @notice Verify the upgrade was successful
    function _verifyUpgrade() internal {
        console2.log("\n=== Step 4: Verifying Upgrade ===");
        vm.selectFork(_opMainnetForkId);

        address _implAfter = _getProxyImplementation(GOVERNOR_PROXY);
        console2.log("Implementation after upgrade:", _implAfter);

        assertEq(_implAfter, NEW_IMPLEMENTATION, "Implementation should match new implementation");
        assertNotEq(_implAfter, _implBeforeUpgrade, "Implementation should have changed");
    }

    /// @notice Helper to get proxy admin from storage
    function _getProxyAdmin(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, ADMIN_SLOT))));
    }

    /// @notice Helper to get proxy implementation from storage
    function _getProxyImplementation(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, IMPLEMENTATION_SLOT))));
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
        assertEq(_selector, IProxyAdmin.upgrade.selector, "Selector should be upgrade(address,address)");

        console2.log("\n=== Calldata Verification ===");
        console2.log("Function selector:", vm.toString(uint32(_selector)));
        console2.log("Proxy address:", _proxy);
        console2.log("New implementation address:", _newImplementation);

        // Verify addresses match expected constants
        assertEq(_proxy, GOVERNOR_PROXY, "Proxy should be OptimismGovernorProxy");
        assertEq(_newImplementation, NEW_IMPLEMENTATION, "Implementation should match expected");
    }

    /// @notice Test configuration validation
    /// @dev Verifies all required config parameters are present and valid
    function test_validateConfiguration() public view {
        string memory _config = vm.readFile(CONFIG_PATH);

        // Validate template name
        assertEq(
            vm.parseTomlString(_config, ".templateName"),
            "L1PortalExecuteL2Call",
            "Template name should be L1PortalExecuteL2Call"
        );

        // Validate L2 target is ProxyAdmin
        assertEq(vm.parseTomlAddress(_config, ".l2Target"), L2_PROXY_ADMIN, "L2 target should be ProxyAdmin");

        // Validate gas limit is reasonable
        uint256 _gasLimit = vm.parseTomlUint(_config, ".gasLimit");
        assertGt(_gasLimit, 0, "Gas limit should be greater than zero");
        assertLe(_gasLimit, 10_000_000, "Gas limit should be reasonable");

        // Validate value and isCreation for upgrade call
        assertEq(vm.parseTomlUint(_config, ".value"), 0, "Value should be zero for upgrade call");
        assertFalse(vm.parseTomlBool(_config, ".isCreation"), "isCreation should be false for upgrade call");

        console2.log("\n=== Configuration Validation ===");
        console2.log("All configuration parameters are valid");
    }
}
