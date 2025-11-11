// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {VmSafe} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {OPCMTaskBase} from "src/tasks/types/OPCMTaskBase.sol";
import {Action} from "src/libraries/MultisigTypes.sol";
import {MultisigTaskPrinter} from "src/libraries/MultisigTaskPrinter.sol";
import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";

/// @notice Task for setting up revenue sharing on OP Stack chains.
contract RevShareUpgradeAndSetup is OPCMTaskBase {
    using stdToml for string;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice RevShareContractsUpgrader address
    address public REV_SHARE_UPGRADER;

    /// @notice Portal addresses for L2 chains.
    address[] internal portals;

    /// @notice L1Withdrawer configurations (stored as encoded bytes).
    bytes internal l1WithdrawerConfigsEncoded;

    /// @notice Remainder recipients (chain fees recipients).
    address[] internal remainderRecipients;

    /// @notice Names in the SimpleAddressRegistry that are expected to be written during this task.
    function _taskStorageWrites() internal pure virtual override returns (string[] memory) {
        return new string[](0);
    }

    /// @notice Returns an array of strings that refer to contract names in the address registry.
    function _taskBalanceChanges() internal view virtual override returns (string[] memory) {
        return new string[](0);
    }

    /// @notice Sets the allowed storage accesses - override to add portal addresses
    function _setAllowedStorageAccesses() internal virtual override {
        super._setAllowedStorageAccesses();
        // Add portal addresses as they will have storage writes from depositTransaction calls
        for (uint256 i; i < portals.length; i++) {
            _allowedStorageAccesses.add(portals[i]);
        }
    }

    /// @notice Sets up the template with configurations from a TOML file.
    function _templateSetup(string memory taskConfigFilePath, address) internal override {
        string memory tomlContent = vm.readFile(taskConfigFilePath);

        // Load RevShareContractsUpgrader address from TOML
        REV_SHARE_UPGRADER = tomlContent.readAddress(".revShareUpgrader");
        require(REV_SHARE_UPGRADER.code.length > 0, "RevShareContractsUpgrader has no code");
        vm.label(REV_SHARE_UPGRADER, "RevShareContractsUpgrader");

        // Set RevShareContractsUpgrader as the allowed target for delegatecall
        OPCM_TARGETS.push(REV_SHARE_UPGRADER);

        // Load portal addresses
        portals = abi.decode(tomlContent.parseRaw(".portals"), (address[]));
        require(portals.length > 0, "No portals configured");

        // Load L1Withdrawer configs by reading each field individually
        // Note: We can't use parseRaw + abi.decode directly because TOML inline tables
        // sort keys alphabetically, which doesn't match the struct field order
        // So we need to read each field separately and construct the struct manually
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](portals.length);

        for (uint256 i; i < portals.length; i++) {
            string memory basePath = string.concat(".l1WithdrawerConfigs[", vm.toString(i), "]");
            configs[i] = RevShareContractsUpgrader.L1WithdrawerConfig({
                minWithdrawalAmount: tomlContent.readUint(string.concat(basePath, ".minWithdrawalAmount")),
                recipient: tomlContent.readAddress(string.concat(basePath, ".recipient")),
                gasLimit: uint32(tomlContent.readUint(string.concat(basePath, ".gasLimit")))
            });
        }
        l1WithdrawerConfigsEncoded = abi.encode(configs);

        // Load remainder recipients
        remainderRecipients = abi.decode(tomlContent.parseRaw(".remainderRecipients"), (address[]));
        require(remainderRecipients.length == portals.length, "Remainder recipients length mismatch");
    }

    /// @notice Builds the actions for executing the operations.
    function _build(address) internal override {
        // Decode configs from storage
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory l1WithdrawerConfigs =
            abi.decode(l1WithdrawerConfigsEncoded, (RevShareContractsUpgrader.L1WithdrawerConfig[]));

        // Delegatecall into RevShareContractsUpgrader
        // OPCMTaskBase uses Multicall3Delegatecall, so this delegatecall will be captured as an action
        (bool success,) = REV_SHARE_UPGRADER.delegatecall(
            abi.encodeCall(
                RevShareContractsUpgrader.upgradeAndSetupRevShare, (portals, l1WithdrawerConfigs, remainderRecipients)
            )
        );
        require(success, "RevShareUpgradeAndSetup: Delegatecall failed");
    }

    /// @notice This method performs all validations and assertions that verify the calls executed as expected.
    function _validate(VmSafe.AccountAccess[] memory, Action[] memory _actions, address) internal view override {
        MultisigTaskPrinter.printTitle("Validating delegatecall to RevShareContractsUpgrader");

        // For OPCM tasks using delegatecall, we validate that the delegatecall was made correctly.
        // The actual portal calls happen inside the delegatecall and are validated by integration tests.

        require(_actions.length == 1, "Expected exactly one action");

        bool foundDelegatecall = false;

        for (uint256 i; i < _actions.length; i++) {
            Action memory action = _actions[i];
            // Check if this is a delegatecall to RevShareContractsUpgrader
            if (action.target == REV_SHARE_UPGRADER) {
                foundDelegatecall = true;
                // Verify it's calling upgradeAndSetupRevShare
                bytes4 selector = bytes4(action.arguments);
                require(
                    selector == RevShareContractsUpgrader.upgradeAndSetupRevShare.selector,
                    "Wrong function selector for delegatecall"
                );
            }
        }

        require(foundDelegatecall, "Delegatecall to RevShareContractsUpgrader not found");
    }

    /// @notice Override to return a list of addresses that should not be checked for code length.
    function _getCodeExceptions() internal view virtual override returns (address[] memory) {
        return new address[](0);
    }
}
