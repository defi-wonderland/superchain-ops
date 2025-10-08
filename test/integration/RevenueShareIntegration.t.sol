// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IGnosisSafe, Enum} from "@base-contracts/script/universal/IGnosisSafe.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {Signatures} from "@base-contracts/script/universal/Signatures.sol";
import {console2} from "forge-std/console2.sol";
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

        // Step 2: Relay messages from L1 to L2
        _relayAllMessages();
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
        vm.recordLogs();
        // Get actions from template simulation
        (, Action[] memory actions,,, address rootSafe) = template.simulate(configPath, new address[](0));
    }

    function _relayAllMessages() internal {
        vm.selectFork(_optimismForkId);

        // Get logs from L1 execution
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Filter for TransactionDeposited events
        bytes32 transactionDepositedHash = keccak256("TransactionDeposited(address,address,uint256,bytes)");
        
        console2.log("\n=== Deduplicating and Replaying Deposit Transactions on L2 ===");
        
        // First pass: collect unique opaqueData hashes
        bytes32[] memory seenHashes = new bytes32[](logs.length);
        uint256 uniqueCount;
        
        uint256 successCount;
        uint256 failureCount;
        
        for (uint256 i = 0; i < logs.length; i++) {
            // Check if this is a TransactionDeposited event
            if (logs[i].topics[0] == transactionDepositedHash) {
                // Decode indexed parameters
                address from = address(uint160(uint256(logs[i].topics[1])));
                address to = address(uint160(uint256(logs[i].topics[2])));
                
                // Only process transactions from the aliased PROXY_ADMIN_OWNER
                if (from == AddressAliasHelper.applyL1ToL2Alias(PROXY_ADMIN_OWNER)) {
                    // Decode the opaqueData to check for duplicates
                    bytes memory opaqueData = abi.decode(logs[i].data, (bytes));
                    bytes32 dataHash = keccak256(opaqueData);
                    
                    // Check if we've seen this exact transaction before
                    bool isDuplicate = false;
                    for (uint256 j = 0; j < uniqueCount; j++) {
                        if (seenHashes[j] == dataHash) {
                            isDuplicate = true;
                            console2.log("\nSkipping duplicate transaction with hash:");
                            console2.logBytes32(dataHash);
                            break;
                        }
                    }
                    
                    // Skip if duplicate
                    if (isDuplicate) {
                        continue;
                    }
                    
                    // Mark as seen
                    seenHashes[uniqueCount] = dataHash;
                    uniqueCount++;
                    
                    // The opaqueData is: abi.encodePacked(mint, value, gasLimit, isCreation, data)
                    // Layout:
                    //   value: uint256 (32 bytes) - ETH to send with the call
                    //   mint: uint256 (32 bytes) - ETH to mint on L2
                    //   gasLimit: uint64 (8 bytes) - gas limit for L2 tx
                    //   isCreation: bool (1 byte) - is contract creation
                    //   data: bytes (remaining) - the actual calldata
                    
                    // Extract value (bytes 0-31)
                    uint256 value = uint256(bytes32(_slice(opaqueData, 0, 32)));
                    
                    // Extract mint (bytes 32-63)
                    uint256 mint = uint256(bytes32(_slice(opaqueData, 32, 32)));
                    
                    // Extract gasLimit (bytes 64-71)
                    uint64 gasLimit = uint64(bytes8(_slice(opaqueData, 64, 8)));
                    
                    // Extract isCreation (byte 72)
                    bool isCreation = uint8(opaqueData[72]) != 0;
                    
                    // Extract data (bytes 73 onwards)
                    bytes memory data = _slice(opaqueData, 73, opaqueData.length - 73);
                    
                    // Execute the transaction on L2 as if it came from the aliased address
                    vm.prank(from);
                    (bool success, bytes memory returnData) = to.call{value: value}(data);
                    
                    if (!success) {
                        console2.log("  Result: FAILED");
                        failureCount++;
                        if (returnData.length > 0) {
                            console2.log("  Error data:");
                            console2.logBytes(returnData);
                        }
                    } else {
                        console2.log("  Result: SUCCESS");
                        successCount++;
                        if (returnData.length > 0) {
                            console2.log("  Return data length:", returnData.length);
                        }
                    }
                }
            }
        }
        
        console2.log("\n=== Summary ===");
        console2.log("Unique transactions:", uniqueCount);
        console2.log("Successful transactions:", successCount);
        console2.log("Failed transactions:", failureCount);
        
        // Assert all transactions succeeded
        assertEq(failureCount, 0, "All deposit transactions should succeed");
        assertEq(successCount, uniqueCount, "All unique transactions should succeed");
    }

    /// @notice Helper function to slice bytes
    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory) {
        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[start + i];
        }
        return result;
    }
}