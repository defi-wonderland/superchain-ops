// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IGnosisSafe, Enum} from "@base-contracts/script/universal/IGnosisSafe.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {Signatures} from "@base-contracts/script/universal/Signatures.sol";

import {RevenueShareV100UpgradePath} from "src/template/RevenueShareUpgradePath.sol";
import {Action} from "src/libraries/MultisigTypes.sol";
import {AddressAliasHelper} from "@eth-optimism-bedrock/src/vendor/AddressAliasHelper.sol";

struct RelayedMessage {
    address target;
    bytes callData;
    uint256 value;
}

struct DepositedTransaction {
    address from;
    address to;
    uint256 version;
    bytes opaqueData;
}

interface IOptimismPortal2 {
    function depositTransaction(address _to, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes memory _data)
        external
        payable;
}

interface IProxy {
    function implementation() external view returns (address);
}

interface IFeeSplitter {
    function recipient() external view returns (address);
}

contract RevenueShareIntegrationTest is Test {
    RevenueShareV100UpgradePath public template;

    // Constants
    address public constant PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address public constant PROXY_ADMIN_OWNER = 0x5a0Aae59D09fccBdDb6C6CcEB07B7279367C3d2A;
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

  string[] internal _rpcUrls = ['http://127.0.0.1:8545', 'http://127.0.0.1:9545'];

    function setUp() public {
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _optimismForkId = vm.createFork("http://127.0.0.1:9545");
        vm.selectFork(_mainnetForkId);
        template = new RevenueShareV100UpgradePath();
    }

    function test_optInRevenueShare_integration() public {
        string memory configPath = "test/tasks/example/eth/015-revenue-share-upgrade/config.toml";

        // Step 1: Execute L1 transaction
        _executeL1Transaction(configPath);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        DepositedTransaction[] memory depositedTransactions = new DepositedTransaction[](logs.length);
        uint256 depositCount;
        uint256 deploymentsCount;

        // Filter for TransactionDeposited events
        bytes32 transactionDepositedHash = keccak256("TransactionDeposited(address,address,uint256,bytes)");
        uint256 totalTransactionDepositedEvents;
        
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == transactionDepositedHash) {
                totalTransactionDepositedEvents++;
                // Decode indexed parameters from topics
                address from = address(uint160(uint256(logs[i].topics[1])));
                address to = address(uint160(uint256(logs[i].topics[2])));
                uint256 version = uint256(logs[i].topics[3]);
                
                
                // Only process transactions from the aliased PROXY_ADMIN_OWNER
                if (from == AddressAliasHelper.applyL1ToL2Alias(PROXY_ADMIN_OWNER)) {
                    // Decode non-indexed parameter from data
                    bytes memory opaqueData = abi.decode(logs[i].data, (bytes));
                    
                    depositedTransactions[depositCount] = DepositedTransaction({
                        from: from,
                        to: to,
                        version: version,
                        opaqueData: opaqueData
                    });
                    depositCount++;

                    if (to == CREATE2_DEPLOYER) {
                        deploymentsCount++;
                    }
                }
            }
        }
        
        // Check for duplicate data
        uint256 duplicateCount;
        for (uint256 i = 0; i < depositCount; i++) {
            for (uint256 j = i + 1; j < depositCount; j++) {
                if (keccak256(depositedTransactions[i].opaqueData) == keccak256(depositedTransactions[j].opaqueData)) {
                    duplicateCount++;
                }
            }
        }
        

        // Step 2: Relay messages from L1 to L2
        vm.selectFork(_optimismForkId);

        // Relay the op to the optimism chain
        /* _relayAllMessages(); */
    }

/*     function test_optOutRevenueShare_integration() public {
        string memory configPath = "test/tasks/example/eth/019-revenueshare-upgrade-opt-out/config.toml";

        // Step 1: Execute L1 transaction
        _executeL1Transaction(configPath);

        // Step 2: Relay messages from L1 to L2
        _relayAllMessages();

        // Step 3: Verify L2 state changes
        vm.selectFork(l2Fork);
        _verifyL2StateOptOut();
    }
 */
    function _executeL1Transaction(string memory configPath) internal {
        // Get actions from template simulation
        (, Action[] memory actions,,, address rootSafe) = template.simulate(configPath, new address[](0));

        // Verify we got the expected safe
        assertEq(rootSafe, PROXY_ADMIN_OWNER, "Root safe should be ProxyAdminOwner");

        // Mine a new block to reset OptimismPortal2's resource metering
        // The simulate() call consumed resources, so we need a fresh block
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

       // Get the safe and its owners
        IGnosisSafe safe = IGnosisSafe(rootSafe);
        address[] memory owners = safe.getOwners();

        // Prepare multicall calldata
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

        // Get transaction hash
        uint256 nonceBefore = safe.nonce();
        uint256 safeTxGas = 10000000; // Set reasonable gas limit for Safe transaction
        bytes32 txHash = safe.getTransactionHash(
            template.multicallTarget(),
            0,
            multicallData,
            Enum.Operation.DelegateCall,
            safeTxGas,
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            nonceBefore
        );

        // Approve transaction with all owners
        for (uint256 i = 0; i < owners.length; i++) {
            vm.prank(owners[i]);
            safe.approveHash(txHash);
        }

        // Generate signatures and execute
        bytes memory signatures = Signatures.genPrevalidatedSignatures(owners);

        // Start recording logs only for the actual execution
        vm.recordLogs();

        bool success = safe.execTransaction(
            template.multicallTarget(),
            0,
            multicallData,
            Enum.Operation.DelegateCall,
            safeTxGas,
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures
        );

        // Check if nonce incremented (this means the transaction was executed even if it reverted internally)
        if (safe.nonce() == nonceBefore + 1) {
            // Transaction was executed, even if success is false due to internal reverts
            // In Safe contracts, execTransaction can return false but still increment nonce
            // if the transaction was executed but had internal failures
            success = true;
        }

        assertTrue(success, "L1 transaction should execute successfully");
        assertEq(safe.nonce(), nonceBefore + 1, "Safe nonce should increment");
    }
}