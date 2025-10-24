// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {AddressAliasHelper} from "@eth-optimism-bedrock/src/vendor/AddressAliasHelper.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";

/// @notice Storage slot override for Tenderly simulation
struct StorageOverride {
    bytes32 key;
    bytes32 value;
}

/// @notice State override for a contract in Tenderly simulation
struct StateOverride {
    address contractAddress;
    StorageOverride[] storage_;
}

/// @title IntegrationBase
/// @notice Base contract for integration tests with L1->L2 deposit transaction replay functionality
abstract contract IntegrationBase is Test {
    // State overrides for Tenderly simulation
    StateOverride[] internal _stateOverrides;
    /// @notice Replay all deposit transactions from L1 to L2
    /// @param _forkId The fork ID to switch to for L2 execution
    /// @param _isSimulate If true, only process the second half of logs to avoid duplicates.
    ///                    Task simulations emit events twice: once during the initial dry-run
    ///                    and once during the actual simulation. Taking the second half ensures
    ///                    we only process the final simulation results.

    function _relayAllMessages(uint256 _forkId, bool _isSimulate) internal {
        vm.selectFork(_forkId);

        console2.log("\n");
        console2.log("================================================================================");
        console2.log("=== Replaying Deposit Transactions on L2                                    ===");
        console2.log("=== Each transaction includes Tenderly simulation link                      ===");
        console2.log("=== Network is set to 10 (OP Mainnet) - adjust if testing on different L2  ===");
        console2.log("================================================================================");

        // Get logs from L1 execution
        Vm.Log[] memory _allLogs = vm.getRecordedLogs();

        // If this is a simulation, only take the second half of logs to avoid processing duplicates
        // Simulations emit events twice, so we skip the first half
        uint256 _startIndex = _isSimulate ? _allLogs.length / 2 : 0;
        uint256 _logsCount = _isSimulate ? _allLogs.length - _startIndex : _allLogs.length;

        Vm.Log[] memory _logs = new Vm.Log[](_logsCount);
        for (uint256 _i = 0; _i < _logsCount; _i++) {
            _logs[_i] = _allLogs[_startIndex + _i];
        }

        // Filter for TransactionDeposited events
        bytes32 _transactionDepositedHash = keccak256("TransactionDeposited(address,address,uint256,bytes)");

        uint256 _transactionCount;
        uint256 _successCount;
        uint256 _failureCount;

        for (uint256 _i = 0; _i < _logs.length; _i++) {
            // Check if this is a TransactionDeposited event
            if (_logs[_i].topics[0] == _transactionDepositedHash) {
                // Decode indexed parameters
                address _from = address(uint160(uint256(_logs[_i].topics[1])));
                address _to = address(uint160(uint256(_logs[_i].topics[2])));

                // Decode the opaqueData
                bytes memory _opaqueData = abi.decode(_logs[_i].data, (bytes));

                _transactionCount++;

                // Process and execute the transaction
                bool _success = _processDepositTransaction(_from, _to, _opaqueData, _transactionCount);

                if (_success) {
                    _successCount++;
                } else {
                    _failureCount++;
                }
            }
        }

        console2.log("\n=== Summary ===");
        console2.log("Total transactions:", _transactionCount);
        console2.log("Successful transactions:", _successCount);
        console2.log("Failed transactions:", _failureCount);

        // Assert all transactions succeeded
        assertEq(_failureCount, 0, "All deposit transactions should succeed");
        assertEq(_successCount, _transactionCount, "All transactions should succeed");
    }

    /// @notice Process and execute a deposit transaction
    function _processDepositTransaction(address _from, address _to, bytes memory _opaqueData, uint256 _txNumber)
        internal
        returns (bool)
    {
        // Extract value (bytes 0-31)
        uint256 _value = uint256(bytes32(LibBytes.slice(_opaqueData, 0, 32)));

        // Extract gasLimit (bytes 64-71)
        uint64 _gasLimit = uint64(bytes8(LibBytes.slice(_opaqueData, 64, 72)));

        // Extract data (bytes 73 onwards)
        bytes memory _data = LibBytes.slice(_opaqueData, 73);

        // Print Tenderly simulation parameters
        string memory _tenderlyLink = _generateTenderlyLink(_to, _from, uint256(_gasLimit), _value, _data);
        console2.log("\nTenderly Simulation Link for transaction #", _txNumber);
        console2.log(_tenderlyLink);

        // Execute the transaction on L2 as if it came from the aliased address
        vm.prank(_from);
        (bool _success,) = _to.call{value: _value, gas: _gasLimit}(_data);

        return _success;
    }

    /// @notice Generate Tenderly simulation link for L2 transaction
    function _generateTenderlyLink(
        address _contractAddress,
        address _from,
        uint256 _gas,
        uint256 _value,
        bytes memory _rawFunctionInput
    ) internal view returns (string memory) {
        // Build the base Tenderly URL with standard parameters
        string memory _baseUrl = string.concat(
            "https://dashboard.tenderly.co/TENDERLY_USERNAME/TENDERLY_PROJECT/simulator/new",
            "?network=10",
            "&contractAddress=",
            LibString.toHexString(_contractAddress),
            "&from=",
            LibString.toHexString(_from),
            "&gas=",
            LibString.toString(_gas),
            "&value=",
            LibString.toString(_value),
            "&rawFunctionInput=",
            LibString.toHexString(_rawFunctionInput)
        );

        // If no state overrides, return base URL
        if (_stateOverrides.length == 0) {
            return _baseUrl;
        }

        // Build state overrides JSON and URL encode it
        string memory _stateOverridesJson = _buildStateOverridesJson();
        string memory _encodedOverrides = _urlEncode(_stateOverridesJson);

        return string.concat(_baseUrl, "&stateOverrides=", _encodedOverrides);
    }

    /// @notice Build JSON string for state overrides
    function _buildStateOverridesJson() internal view returns (string memory) {
        string memory _json = "[";

        for (uint256 i = 0; i < _stateOverrides.length; i++) {
            if (i > 0) {
                _json = string.concat(_json, ",");
            }

            _json = string.concat(
                _json,
                "{",
                '"contractAddress":"',
                LibString.toHexString(_stateOverrides[i].contractAddress),
                '","storage":['
            );

            for (uint256 j = 0; j < _stateOverrides[i].storage_.length; j++) {
                if (j > 0) {
                    _json = string.concat(_json, ",");
                }

                _json = string.concat(
                    _json,
                    '{"key":"0x',
                    LibString.toHexStringNoPrefix(uint256(_stateOverrides[i].storage_[j].key), 32),
                    '","value":"0x',
                    LibString.toHexStringNoPrefix(uint256(_stateOverrides[i].storage_[j].value), 32),
                    '"}'
                );
            }

            _json = string.concat(_json, "]}");
        }

        _json = string.concat(_json, "]");
        return _json;
    }

    /// @notice URL encode a string (basic implementation for JSON)
    function _urlEncode(string memory _str) internal pure returns (string memory) {
        bytes memory _strBytes = bytes(_str);
        string memory _encoded = "";

        for (uint256 i = 0; i < _strBytes.length; i++) {
            bytes1 _char = _strBytes[i];

            // Encode special characters
            if (_char == '"') {
                _encoded = string.concat(_encoded, "%22");
            } else if (_char == "[") {
                _encoded = string.concat(_encoded, "%5B");
            } else if (_char == "]") {
                _encoded = string.concat(_encoded, "%5D");
            } else if (_char == "{") {
                _encoded = string.concat(_encoded, "%7B");
            } else if (_char == "}") {
                _encoded = string.concat(_encoded, "%7D");
            } else if (_char == ":") {
                _encoded = string.concat(_encoded, "%3A");
            } else if (_char == ",") {
                _encoded = string.concat(_encoded, "%2C");
            } else {
                _encoded = string.concat(_encoded, string(abi.encodePacked(_char)));
            }
        }

        return _encoded;
    }
}
