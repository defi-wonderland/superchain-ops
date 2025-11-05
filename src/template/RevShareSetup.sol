// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {VmSafe} from "forge-std/Vm.sol";
import {LibString} from "solady/utils/LibString.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {SimpleTaskBase} from "src/tasks/types/SimpleTaskBase.sol";
import {Action} from "src/libraries/MultisigTypes.sol";
import {RevSharePredeploys} from "src/libraries/RevSharePredeploys.sol";

/// @notice Interface for the RevShareContractsManager.
interface IRevShareContractsManager {
    struct L1WithdrawerConfig {
        uint256 minWithdrawalAmount;
        address recipient;
        uint32 gasLimit;
    }

    function setupRevShare(
        address _portal,
        string memory _saltSeed,
        bool _useDefaultCalculator,
        address _customCalculator,
        L1WithdrawerConfig memory _l1Config,
        address _chainFeesRecipient
    ) external;

    function upgradeAndSetupRevShare(
        address _portal,
        string memory _saltSeed,
        bool _useDefaultCalculator,
        address _customCalculator,
        L1WithdrawerConfig memory _l1Config,
        address _chainFeesRecipient
    ) external;
}

/// @notice Template for setting up revenue sharing via RevShareContractsManager.
/// @dev This template can either:
///      1. Setup revenue sharing on already-upgraded contracts (setupRevShare)
///      2. Upgrade contracts and setup revenue sharing in one transaction (upgradeAndSetupRevShare)
contract RevShareSetup is SimpleTaskBase, RevSharePredeploys {
    using LibString for string;
    using stdToml for string;

    /// @notice The RevShareContractsManager contract to delegatecall.
    address public REVSHARE_MANAGER;

    /// @notice The OptimismPortal2 address for the target L2.
    address public portal;

    /// @notice The salt seed for CREATE2 deployments.
    string public saltSeed;

    /// @notice Whether to upgrade contracts before setting up revenue sharing.
    bool public shouldUpgradeContracts;

    /// @notice Whether to deploy the default calculator (L1Withdrawer + SC Rev Share Calculator).
    bool public useDefaultCalculator;

    /// @notice L1Withdrawer configuration (only used if useDefaultCalculator=true).
    IRevShareContractsManager.L1WithdrawerConfig public l1Config;

    /// @notice Chain fees recipient for the calculator (only used if useDefaultCalculator=true).
    address public chainFeesRecipient;

    /// @notice Custom calculator address (only used if useDefaultCalculator=false).
    address public customCalculator;

    /// @notice Returns the safe address string identifier.
    function safeAddressString() public pure override returns (string memory) {
        return "ProxyAdminOwner";
    }

    /// @notice Returns the storage write permissions required for this task.
    function _taskStorageWrites() internal pure virtual override returns (string[] memory) {
        string[] memory _storageWrites = new string[](1);
        _storageWrites[0] = "OptimismPortal";
        return _storageWrites;
    }

    /// @notice Returns an array of contract names expected to have balance changes.
    function _taskBalanceChanges() internal view virtual override returns (string[] memory) {
        string[] memory _balanceChanges = new string[](1);
        _balanceChanges[0] = "OptimismPortal";
        return _balanceChanges;
    }

    /// @notice Sets up the template with configurations from a TOML file.
    function _templateSetup(string memory _taskConfigFilePath, address) internal override {
        string memory _toml = vm.readFile(_taskConfigFilePath);

        // Load RevShareContractsManager address
        REVSHARE_MANAGER = _toml.readAddress(".addresses.RevShareContractsManager");
        require(REVSHARE_MANAGER != address(0), "RevShareContractsManager must be set");
        vm.label(REVSHARE_MANAGER, "RevShareContractsManager");

        // Load portal and salt seed
        portal = _toml.readAddress(".portal");
        require(portal != address(0), "portal must be set");
        vm.label(portal, "OptimismPortal");

        saltSeed = _toml.readString(".saltSeed");
        require(bytes(saltSeed).length != 0, "saltSeed must be set");

        // Load mode flags
        shouldUpgradeContracts = _toml.readBool(".shouldUpgradeContracts");
        useDefaultCalculator = _toml.readBool(".useDefaultCalculator");

        // Load calculator configuration based on mode
        if (useDefaultCalculator) {
            // Load L1Withdrawer configuration
            uint256 l1MinWithdrawal = _toml.readUint(".l1WithdrawerMinWithdrawalAmount");
            address l1Recipient = _toml.readAddress(".l1WithdrawerRecipient");
            require(l1Recipient != address(0), "l1WithdrawerRecipient must be set");

            uint256 l1GasLimitRaw = _toml.readUint(".l1WithdrawerGasLimit");
            require(l1GasLimitRaw > 0, "l1WithdrawerGasLimit must be greater than 0");
            require(l1GasLimitRaw <= type(uint32).max, "l1WithdrawerGasLimit must fit in uint32");
            uint32 l1GasLimit = uint32(l1GasLimitRaw);

            l1Config = IRevShareContractsManager.L1WithdrawerConfig({
                minWithdrawalAmount: l1MinWithdrawal,
                recipient: l1Recipient,
                gasLimit: l1GasLimit
            });

            // Load chain fees recipient
            chainFeesRecipient = _toml.readAddress(".scRevShareCalcChainFeesRecipient");
            require(chainFeesRecipient != address(0), "scRevShareCalcChainFeesRecipient must be set");
        } else {
            // Load custom calculator address
            customCalculator = _toml.readAddress(".customCalculator");
            require(customCalculator != address(0), "customCalculator must be set when useDefaultCalculator is false");

            // Set dummy values for l1Config (not used)
            l1Config = IRevShareContractsManager.L1WithdrawerConfig({
                minWithdrawalAmount: 0,
                recipient: address(0),
                gasLimit: 0
            });
            chainFeesRecipient = address(0);
        }
    }

    /// @notice Executes revenue sharing setup via delegatecall.
    function _build(address) internal override {
        // Prepare parameters for delegatecall
        address calcAddress = useDefaultCalculator ? address(0) : customCalculator;

        if (shouldUpgradeContracts) {
            // Call upgradeAndSetupRevShare
            (bool success,) = REVSHARE_MANAGER.delegatecall(
                abi.encodeCall(
                    IRevShareContractsManager.upgradeAndSetupRevShare,
                    (portal, saltSeed, useDefaultCalculator, calcAddress, l1Config, chainFeesRecipient)
                )
            );
            require(success, "RevShareSetup: Delegatecall to upgradeAndSetupRevShare failed");
        } else {
            // Call setupRevShare
            (bool success,) = REVSHARE_MANAGER.delegatecall(
                abi.encodeCall(
                    IRevShareContractsManager.setupRevShare,
                    (portal, saltSeed, useDefaultCalculator, calcAddress, l1Config, chainFeesRecipient)
                )
            );
            require(success, "RevShareSetup: Delegatecall to setupRevShare failed");
        }
    }

    /// @notice Validates the operations executed as expected.
    function _validate(VmSafe.AccountAccess[] memory, Action[] memory, address) internal view override {
        // Basic validation - can be extended with specific checks
        // The actual state changes validation is handled by the framework
    }

    /// @notice Returns list of addresses that should not be checked for code length.
    function _getCodeExceptions() internal view virtual override returns (address[] memory) {}
}
