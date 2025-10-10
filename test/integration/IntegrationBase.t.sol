// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {AddressAliasHelper} from "@eth-optimism-bedrock/src/vendor/AddressAliasHelper.sol";

/// @title IntegrationBase
/// @notice Base contract for integration tests with L1->L2 deposit transaction replay functionality
abstract contract IntegrationBase is Test {
    /// @notice Replay all deposit transactions from L1 to L2
    function _relayAllMessages(uint256 _forkId) internal {
        vm.selectFork(_forkId);

        console2.log("\n");
        console2.log("================================================================================");
        console2.log("=== Replaying Deposit Transactions on L2                                    ===");
        console2.log("=== Each transaction includes Tenderly simulation link                      ===");
        console2.log("=== Network is set to 10 (OP Mainnet) - adjust if testing on different L2  ===");
        console2.log("================================================================================");

        // Get logs from L1 execution
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Filter for TransactionDeposited events
        bytes32 transactionDepositedHash = keccak256("TransactionDeposited(address,address,uint256,bytes)");
        
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
                
                // Decode the opaqueData to check for duplicates
                bytes memory opaqueData = abi.decode(logs[i].data, (bytes));
                bytes32 dataHash = keccak256(opaqueData);
                
                // Check if we've seen this exact transaction before
                bool isDuplicate = _isDuplicate(seenHashes, uniqueCount, dataHash);
                if (isDuplicate) continue;
                
                // Mark as seen
                seenHashes[uniqueCount] = dataHash;
                uniqueCount++;
                
                // Process and execute the transaction
                bool success = _processDepositTransaction(from, to, opaqueData, uniqueCount);
                
                if (success) {
                    successCount++;
                } else {
                    failureCount++;
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

    /// @notice Check if transaction is a duplicate
    function _isDuplicate(bytes32[] memory seenHashes, uint256 count, bytes32 hash) internal pure returns (bool) {
        for (uint256 j = 0; j < count; j++) {
            if (seenHashes[j] == hash) {
                return true;
            }
        }
        return false;
    }

    /// @notice Process and execute a deposit transaction
    function _processDepositTransaction(
        address from,
        address to,
        bytes memory opaqueData,
        uint256 txNumber
    ) internal returns (bool) {
        // Extract value (bytes 0-31)
        uint256 value = uint256(bytes32(_slice(opaqueData, 0, 32)));
        
        // Extract gasLimit (bytes 64-71)
        uint64 gasLimit = uint64(bytes8(_slice(opaqueData, 64, 8)));
        
        // Extract data (bytes 73 onwards)
        bytes memory data = _slice(opaqueData, 73, opaqueData.length - 73);
        
        // Print Tenderly simulation parameters
        _logTransactionDetails(from, to, value, gasLimit, data, txNumber);
        
        // Execute the transaction on L2 as if it came from the aliased address
        vm.prank(from);
        (bool success, ) = to.call{value: value}(data);
        
        return success;
    }

    /// @notice Log transaction details and Tenderly link
    function _logTransactionDetails(
        address from,
        address to,
        uint256 value,
        uint64 gasLimit,
        bytes memory data,
        uint256 txNumber
    ) internal view {
        if (data.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(data, 32))
            }
        }
        
        // Generate Tenderly simulation link
        string memory tenderlyLink = _generateTenderlyLink(to, from, uint256(gasLimit), value, data);
        console2.log("\nTenderly Simulation Link for transaction #", txNumber);
        console2.log(tenderlyLink);
    }

    /// @notice Helper function to slice bytes
    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory) {
        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[start + i];
        }
        return result;
    }

    /// @notice Generate Tenderly simulation link for L2 transaction
    function _generateTenderlyLink(
        address contractAddress,
        address from,
        uint256 gas,
        uint256 value,
        bytes memory rawFunctionInput
    ) internal pure returns (string memory) {
        // Convert bytes to hex string
        string memory calldataHex = _bytesToHexString(rawFunctionInput);
        
        // Build the Tenderly URL
        // network=10 for OP Mainnet (change if testing on different L2)
        return string.concat(
            "https://dashboard.tenderly.co/TENDERLY_USERNAME/TENDERLY_PROJECT/simulator/new",
            "?network=10",
            "&contractAddress=0x", _toAsciiString(contractAddress),
            "&from=0x", _toAsciiString(from),
            "&gas=", vm.toString(gas),
            "&value=", vm.toString(value),
            "&rawFunctionInput=0x", calldataHex
        );
    }

    /// @notice Convert address to lowercase hex string without 0x prefix
    function _toAsciiString(address addr) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(addr)) / (2**(8*(19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2*i] = _char(hi);
            s[2*i+1] = _char(lo);
        }
        return string(s);
    }

    /// @notice Convert bytes to hex string without 0x prefix
    function _bytesToHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            result[i * 2] = hexChars[uint8(data[i] >> 4)];
            result[i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }

    /// @notice Convert nibble to hex character
    function _char(bytes1 b) internal pure returns (bytes1) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }
}

