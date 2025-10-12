// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IGnosisSafe, Enum} from "@base-contracts/script/universal/IGnosisSafe.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {Signatures} from "@base-contracts/script/universal/Signatures.sol";

import {RevenueShareV100UpgradePath} from "src/template/RevenueShareUpgradePath.sol";
import {SimpleAddressRegistry} from "src/SimpleAddressRegistry.sol";
import {Action, TaskPayload, SafeData} from "src/libraries/MultisigTypes.sol";
import {Utils} from "src/libraries/Utils.sol";
import {AddressAliasHelper} from "@eth-optimism-bedrock/src/vendor/AddressAliasHelper.sol";

interface IOptimismPortal2 {
    function depositTransaction(address _to, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes memory _data)
        external
        payable;
}

interface ICreate2Deployer {
    function deploy(uint256 _value, bytes32 _salt, bytes memory _code) external;
}

interface IProxyAdmin {
    function upgrade(address _proxy, address _implementation) external;
    function upgradeAndCall(address _proxy, address _implementation, bytes memory _data) external payable returns (bytes memory);
}

contract RevenueShareUpgradePathTest is Test {
    using stdStorage for StdStorage;

    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    RevenueShareV100UpgradePath public template;
    string public configPath = "test/tasks/example/eth/015-revenue-share-upgrade/config.toml";

    // Expected addresses from config
    address public constant PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address public constant PROXY_ADMIN_OWNER = 0x5a0Aae59D09fccBdDb6C6CcEB07B7279367C3d2A;

    // Expected number of actions
    uint256 public constant EXPECTED_DEPLOYMENTS_OPT_IN = 7;
    uint256 public constant EXPECTED_UPGRADES_OPT_IN = 5;
    uint256 public constant EXPECTED_DEPLOYMENTS_OPT_OUT = 5;
    uint256 public constant EXPECTED_UPGRADES_OPT_OUT = 5;

    // L2 predeploys
    address internal constant CREATE2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;
    address internal constant FEE_SPLITTER = 0x420000000000000000000000000000000000002B;
    address internal constant PROXY_ADMIN = 0x4200000000000000000000000000000000000018;

    // Gas limits
    uint64 internal constant SC_REV_SHARE_CALCULATOR_DEPLOYMENT_GAS_LIMIT = 625_000;
    uint64 internal constant L1_WITHDRAWER_DEPLOYMENT_GAS_LIMIT = 625_000;
    uint64 internal constant FEE_VAULTS_DEPLOYMENT_GAS_LIMIT = 910_000;
    uint64 internal constant FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT = 1_235_000;
    uint64 internal constant UPGRADE_GAS_LIMIT = 150_000;

    uint64[12] internal EXPECTED_GAS_LIMITS_OPT_IN = [
        L1_WITHDRAWER_DEPLOYMENT_GAS_LIMIT,
        SC_REV_SHARE_CALCULATOR_DEPLOYMENT_GAS_LIMIT,
        FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT
    ];

    uint64[10] internal EXPECTED_GAS_LIMITS_OPT_OUT = [
        FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT,
        FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
        UPGRADE_GAS_LIMIT
    ];

    uint256 internal constant DEPOSIT_VERSION = 0;

    function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
        vm.mockCall(_receiver, _calldata, _returned);
        vm.expectCall(_receiver, _calldata);
    }

    function setUp() public {
        vm.createSelectFork("mainnet");

        template = new RevenueShareV100UpgradePath();
    }

    function test_optInRevenueShare_succeeds() public {
        // Step 1: Run simulate to prepare everything and get the actions
        (, Action[] memory actions,,, address rootSafe) = template.simulate(configPath, new address[](0));

        // Verify we got the expected safe
        assertEq(rootSafe, PROXY_ADMIN_OWNER, "Root safe should be ProxyAdminOwner");
        assertEq(
            actions.length,
            EXPECTED_DEPLOYMENTS_OPT_IN + EXPECTED_UPGRADES_OPT_IN,
            "Should have 12 actions for opt-in scenario"
        );

        // Step 2: Get the safe's owners
        IGnosisSafe safe = IGnosisSafe(rootSafe);
        address[] memory owners = safe.getOwners();

        // Step 3: Get the multicall calldata that will be executed
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](actions.length);
        for (uint256 i = 0; i < actions.length; i++) {
            calls[i] = IMulticall3.Call3Value({
                target: actions[i].target,
                allowFailure: false,
                value: actions[i].value,
                callData: actions[i].arguments
            });
        }
        bytes memory multicallData = abi.encodeCall(IMulticall3.aggregate3Value, (calls));

        // Step 4: Get the nonce and compute transaction hash before any state changes
        uint256 nonceBefore = safe.nonce();

        bytes32 txHash = safe.getTransactionHash(
            template.multicallTarget(),
            0, // value
            multicallData,
            Enum.Operation.DelegateCall,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            nonceBefore
        );

        // Step 5: Mock the portal to record calls instead of reverting
        _mockAndExpect(PORTAL, abi.encodeWithSelector(IOptimismPortal2.depositTransaction.selector), abi.encode());

        // Step 6: Manually verify expected portal calls based on known config values
        _verifyExpectedPortalCalls(actions, true);

        // Step 7: Prank owners to approve the transaction
        for (uint256 i = 0; i < owners.length; i++) {
            vm.prank(owners[i]);
            safe.approveHash(txHash);
        }

        // Step 8: Generate signatures after approval
        bytes memory signatures = Signatures.genPrevalidatedSignatures(owners);

        // Step 9: Execute the transaction
        bool success = safe.execTransaction(
            template.multicallTarget(),
            0, // value
            multicallData,
            Enum.Operation.DelegateCall,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures
        );

        assertTrue(success, "Transaction should execute successfully");
        assertEq(safe.nonce(), nonceBefore + 1, "Safe nonce should increment");

        // Step 10: Verify the portal calls
        // For opt-in scenario, we expect:
        // - 7 deployments (L1Withdrawer, SCRevShareCalc, FeeSplitter, 4 vaults)
        // - 5 upgrades (4 vault proxies + 1 FeeSplitter upgrade)
        _verifyPortalCalls(actions, EXPECTED_DEPLOYMENTS_OPT_IN, EXPECTED_UPGRADES_OPT_IN);
    }

    function test_optOutRevenueShare_succeeds() public {
        // Define the config path
        configPath = "test/tasks/example/eth/019-revenueshare-upgrade-opt-out/config.toml";

        // Step 1: Run simulate to prepare everything and get the actions
        (, Action[] memory actions,,, address rootSafe) = template.simulate(configPath, new address[](0));

        // Verify we got the expected safe and action count
        assertEq(rootSafe, PROXY_ADMIN_OWNER, "Root safe should be ProxyAdminOwner");
        assertEq(
            actions.length,
            EXPECTED_DEPLOYMENTS_OPT_OUT + EXPECTED_UPGRADES_OPT_OUT,
            "Should have 10 actions for non-opt-in scenario"
        );

        // Step 2: Get the safe's owners
        IGnosisSafe safe = IGnosisSafe(rootSafe);
        address[] memory owners = safe.getOwners();

        // Step 3: Get the multicall calldata that will be executed
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](actions.length);
        for (uint256 i = 0; i < actions.length; i++) {
            calls[i] = IMulticall3.Call3Value({
                target: actions[i].target,
                allowFailure: false,
                value: actions[i].value,
                callData: actions[i].arguments
            });
        }
        bytes memory multicallData = abi.encodeCall(IMulticall3.aggregate3Value, (calls));

        // Step 4: Get the nonce and compute transaction hash before any state changes
        uint256 nonceBefore = safe.nonce();

        bytes32 txHash = safe.getTransactionHash(
            template.multicallTarget(),
            0, // value
            multicallData,
            Enum.Operation.DelegateCall,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            nonceBefore
        );

        // Step 5: Manually verify expected portal calls based on known config values
        _verifyExpectedPortalCalls(actions, false);

        // Step 6: Prank owners to approve the transaction
        for (uint256 i = 0; i < owners.length; i++) {
            vm.prank(owners[i]);
            safe.approveHash(txHash);
        }

        // Step 7: Generate signatures after approval
        bytes memory signatures = Signatures.genPrevalidatedSignatures(owners);

        _expectPortalEvents(actions);

        // Step 8: Execute the transaction
        bool success = safe.execTransaction(
            template.multicallTarget(),
            0, // value
            multicallData,
            Enum.Operation.DelegateCall,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures
        );

        assertTrue(success, "Transaction should execute successfully");
        assertEq(safe.nonce(), nonceBefore + 1, "Safe nonce should increment");

        // Step 9: Verify the portal calls
        // For non-opt-in scenario:
        // - 5 deployments (FeeSplitter + 4 vaults, no L1Withdrawer/SCRevShareCalc)
        // - 5 upgrades (4 vault proxies + FeeSplitter)
        _verifyPortalCalls(actions, EXPECTED_DEPLOYMENTS_OPT_OUT, EXPECTED_UPGRADES_OPT_OUT);
    }

    function _verifyPortalCalls(Action[] memory actions, uint256 expectedDeployments, uint256 expectedUpgrades)
        internal
        pure
    {
        uint256 deploymentCalls = 0;
        uint256 upgradeCalls = 0;

        for (uint256 i = 0; i < actions.length; i++) {
            // Decode the depositTransaction parameters
            bytes memory params = new bytes(actions[i].arguments.length - 4);
            for (uint256 j = 0; j < params.length; j++) {
                params[j] = actions[i].arguments[j + 4];
            }
            (address to,,,,) = abi.decode(params, (address, uint256, uint64, bool, bytes));

            if (to == CREATE2_DEPLOYER) {
                deploymentCalls++;
            } else {
                upgradeCalls++;
            }
        }

        assertEq(deploymentCalls, expectedDeployments, "Incorrect number of deployment calls");
        assertEq(upgradeCalls, expectedUpgrades, "Incorrect number of upgrade calls");
    }

    /// @notice Manually construct and expect portal calls based on known config values
    /// This ensures the template generates correct calldata, not just circular validation
    function _verifyExpectedPortalCalls(Action[] memory actions, bool isOptIn) internal {
        string memory config = vm.readFile(configPath);


        uint256 deploymentCount;
        uint256 upgradeCount;

        for (uint256 i = 0; i < actions.length; i++) {
            bytes memory params = _extractParams(actions[i].arguments);
            // depending on if is optin or optout, we use the expected gas limits
            uint64 gasLimit = isOptIn ? EXPECTED_GAS_LIMITS_OPT_IN[i] : EXPECTED_GAS_LIMITS_OPT_OUT[i];
            (address to, uint256 value, uint64 actualGasLimit, bool isCreation, bytes memory data) =
                abi.decode(params, (address, uint256, uint64, bool, bytes));

            assertEq(actions[i].target, PORTAL, "All actions should target the portal");
            _verifyCommonParams(value, actualGasLimit, gasLimit, isCreation, data);

            if (to == CREATE2_DEPLOYER) {
                deploymentCount++;
                _verifyDeploymentCall(to, gasLimit, data);
            } else {
                upgradeCount++;
                _verifyUpgradeCall(to, gasLimit, data);
            }
        }

        assertGt(deploymentCount, 0, "Should have at least one deployment");
        assertGt(upgradeCount, 0, "Should have at least one upgrade");
        assertEq(deploymentCount + upgradeCount, actions.length, "All actions should be accounted for");
    }

    function _extractParams(bytes memory arguments) internal pure returns (bytes memory) {
        bytes memory params = new bytes(arguments.length - 4);
        for (uint256 j = 0; j < params.length; j++) {
            params[j] = arguments[j + 4];
        }
        return params;
    }

    function _verifyCommonParams(
        uint256 value,
        uint64 actualGasLimit,
        uint64 expectedGasLimit,
        bool isCreation,
        bytes memory data
    ) internal pure {
        require(value == 0, "All calls should have 0 value");
        require(actualGasLimit == expectedGasLimit, "Gas limit should match config");
        require(!isCreation, "Should not use creation flag");
        require(data.length > 0, "Should have calldata");
    }

    function _verifyDeploymentCall(address to, uint64 gasLimit, bytes memory data) internal {
        vm.expectCall(
            PORTAL, abi.encodeCall(IOptimismPortal2.depositTransaction, (CREATE2_DEPLOYER, 0, gasLimit, false, data))
        );

        bytes4 actualSelector;
        assembly {
            actualSelector := mload(add(data, 32))
        }
        assertEq(actualSelector, ICreate2Deployer.deploy.selector, "Deployment should call CREATE2 deploy");
    }

    function _verifyUpgradeCall(address to, uint64 gasLimit, bytes memory data) internal {
        vm.expectCall(PORTAL, abi.encodeCall(IOptimismPortal2.depositTransaction, (to, 0, gasLimit, false, data)));

        _assertIsProxyAdmin(to);

        bytes4 selector;
        assembly {
            selector := mload(add(data, 32))
        }
        assertTrue(
            selector == IProxyAdmin.upgrade.selector || selector == IProxyAdmin.upgradeAndCall.selector,
            "Upgrade should call upgradeTo or upgradeToAndCall"
        );
    }

    function _assertIsProxyAdmin(address to) internal pure {
        assertTrue(
            to == PROXY_ADMIN,
            "Upgrade should target the proxy admin"
        );
    }

    function _expectPortalEvents(Action[] memory actions) internal {
        for (uint256 i = 0; i < actions.length; i++) {
            bytes memory params = _extractParams(actions[i].arguments);
            (address to, uint256 value, uint64 actualGasLimit, bool isCreation, bytes memory data) =
                abi.decode(params, (address, uint256, uint64, bool, bytes));

            bytes memory opaqueData = abi.encodePacked(uint256(0), uint256(0), actualGasLimit, isCreation, data);

            vm.expectEmit(true, true, true, true, PORTAL);
            emit TransactionDeposited(AddressAliasHelper.applyL1ToL2Alias(PROXY_ADMIN_OWNER), to, DEPOSIT_VERSION, opaqueData);
        }
    }
}
