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

interface IOptimismPortal2 {
    function depositTransaction(address _to, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes memory _data)
        external
        payable;
}

contract RevenueShareUpgradePathTest is Test {
    using stdStorage for StdStorage;

    RevenueShareV100UpgradePath public template;
    string public configPath = "test/tasks/example/eth/015-revenue-share-upgrade/config.toml";

    // Expected addresses from config
    address public constant PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address public constant PROXY_ADMIN_OWNER = 0x5a0Aae59D09fccBdDb6C6CcEB07B7279367C3d2A;

    // L2 predeploys
    address internal constant CREATE2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;
    address internal constant FEE_SPLITTER = 0x420000000000000000000000000000000000002B;

    // Track portal calls for verification
    struct PortalCall {
        address to;
        uint256 value;
        uint64 gasLimit;
        bool isCreation;
        bytes data;
    }
    PortalCall[] public recordedPortalCalls;

    function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
        vm.mockCall(_receiver, _calldata, _returned);
        vm.expectCall(_receiver, _calldata);
    }

    function setUp() public {
        vm.createSelectFork("mainnet");

        template = new RevenueShareV100UpgradePath();
    }

    function testOptInRevenueShare() public {
        // Step 1: Run simulate to prepare everything and get the actions
        (
            ,
            Action[] memory actions,
            ,
            ,
            address rootSafe
        ) = template.simulate(configPath, new address[](0));

        // Verify we got the expected safe
        assertEq(rootSafe, PROXY_ADMIN_OWNER, "Root safe should be ProxyAdminOwner");
        assertEq(actions.length, 12, "Should have 12 actions for opt-in scenario");

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
        _mockAndExpect(
            PORTAL,
            abi.encodeWithSelector(IOptimismPortal2.depositTransaction.selector),
            abi.encode()
        );

        // Expect all portal calls
        for (uint i = 0; i < actions.length; i++) {
            vm.expectCall(PORTAL, actions[i].arguments);
        }

        // Step 6: Prank owners to approve the transaction
        for (uint256 i = 0; i < owners.length; i++) {
            vm.prank(owners[i]);
            safe.approveHash(txHash);
        }

        // Step 7: Generate signatures after approval
        bytes memory signatures = Signatures.genPrevalidatedSignatures(owners);


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


        // Step 8: Verify the portal calls
        _verifyPortalCalls(actions);
    }

    function _verifyPortalCalls(Action[] memory actions) internal pure {

        uint256 deploymentCalls = 0;
        uint256 upgradeCalls = 0;

        for (uint i = 0; i < actions.length; i++) {
            // Decode the depositTransaction parameters
            bytes memory params = new bytes(actions[i].arguments.length - 4);
            for (uint j = 0; j < params.length; j++) {
                params[j] = actions[i].arguments[j + 4];
            }
            (address to, , , , ) =
                abi.decode(params, (address, uint256, uint64, bool, bytes));

            if (to == CREATE2_DEPLOYER) {
                deploymentCalls++;
            } else {
                upgradeCalls++;
            }
        }


        // For opt-in scenario, we expect:
        // - 7 deployments (L1Withdrawer, SCRevShareCalc, FeeSplitter, 4 vaults)
        // - 5 upgrades (4 vault proxies + 1 FeeSplitter upgrade)
        assertEq(deploymentCalls, 7, "Should have 7 deployment calls");
        assertEq(upgradeCalls, 5, "Should have 5 upgrade calls");
    }

    function testOptOutRevenueShare() public {
        // Create a non-opt-in config
        string memory configPath = "test/tasks/example/eth/017-revenue-share-upgrade-opt-out/config.toml";

        // Step 1: Run simulate to prepare everything and get the actions
        (
            ,
            Action[] memory actions,
            ,
            ,
            address rootSafe
        ) = template.simulate(configPath, new address[](0));

        // Verify we got the expected safe and action count
        assertEq(rootSafe, PROXY_ADMIN_OWNER, "Root safe should be ProxyAdminOwner");
        assertEq(actions.length, 10, "Should have 10 actions for non-opt-in scenario");

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
        _mockAndExpect(
            PORTAL,
            abi.encodeWithSelector(IOptimismPortal2.depositTransaction.selector),
            abi.encode()
        );

        // Expect all portal calls
        for (uint i = 0; i < actions.length; i++) {
            vm.expectCall(PORTAL, actions[i].arguments);
        }

        // Step 6: Prank owners to approve the transaction
        for (uint256 i = 0; i < owners.length; i++) {
            vm.prank(owners[i]);
            safe.approveHash(txHash);
        }

        // Step 7: Generate signatures after approval
        bytes memory signatures = Signatures.genPrevalidatedSignatures(owners);

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
        _verifyNonOptInPortalCalls(actions);
    }

    function _verifyNonOptInPortalCalls(Action[] memory actions) internal pure {
        uint256 deploymentCalls = 0;
        uint256 upgradeCalls = 0;

        for (uint i = 0; i < actions.length; i++) {
            // Decode the depositTransaction parameters
            bytes memory params = new bytes(actions[i].arguments.length - 4);
            for (uint j = 0; j < params.length; j++) {
                params[j] = actions[i].arguments[j + 4];
            }
            (address to,,,,) = abi.decode(params, (address, uint256, uint64, bool, bytes));

            if (to == CREATE2_DEPLOYER) {
                deploymentCalls++;
            } else {
                upgradeCalls++;
            }
        }

        // For non-opt-in scenario:
        // - 5 deployments (FeeSplitter + 4 vaults, no L1Withdrawer/SCRevShareCalc)
        // - 5 upgrades (4 vault proxies + FeeSplitter)
        assertEq(deploymentCalls, 5, "Should have 5 deployment calls for non-opt-in");
        assertEq(upgradeCalls, 5, "Should have 5 upgrade calls for non-opt-in");
    }
}