// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevSharePredeploys} from "src/libraries/RevSharePredeploys.sol";
import {RevShareCodeRepo} from "src/libraries/RevShareCodeRepo.sol";
import {RevShareGasLimits} from "src/libraries/RevShareGasLimits.sol";
import {Utils} from "src/libraries/Utils.sol";

// Interfaces
import {IOptimismPortal2} from "@eth-optimism-bedrock/interfaces/L1/IOptimismPortal2.sol";
import {IProxyAdmin} from "@eth-optimism-bedrock/interfaces/universal/IProxyAdmin.sol";
import {ICreate2Deployer} from "src/interfaces/ICreate2Deployer.sol";
import {IFeeSplitter} from "src/interfaces/IFeeSplitter.sol";
import {IFeeVault} from "src/interfaces/IFeeVault.sol";

/// @title RevShareContractsUpgrader
/// @notice Upgrader contract that manages RevShare deployments and configuration via delegatecall.
/// @dev    Supports two operations:
///         1. setupRevShare() - Setup revenue sharing on already-upgraded contracts
///         2. upgradeAndSetupRevShare() - Combined upgrade + setup (most efficient)
///         All operations use the default calculator (L1Withdrawer + SuperchainRevenueShareCalculator).
contract RevShareContractsUpgrader is RevSharePredeploys {
    /// @notice Base salt seed for CREATE2 deployments
    string private constant SALT_SEED = "RevShare";

    /// @notice Thrown when portal address is zero
    error PortalCannotBeZeroAddress();

    /// @notice Thrown when L1Withdrawer recipient is zero address
    error L1WithdrawerRecipientCannotBeZeroAddress();

    /// @notice Thrown when chain fees recipient is zero address
    error ChainFeesRecipientCannotBeZeroAddress();

    /// @notice Thrown when array lengths don't match
    error ArrayLengthMismatch();

    /// @notice Thrown when array is empty
    error EmptyArray();

    /// @notice Struct for L1Withdrawer configuration.
    /// @param minWithdrawalAmount Minimum withdrawal amount
    /// @param recipient Recipient address for withdrawals
    /// @param gasLimit Gas limit for L1 withdrawals
    struct L1WithdrawerConfig {
        uint256 minWithdrawalAmount;
        address recipient;
        uint32 gasLimit;
    }

    /// @notice Upgrades vault and splitter contracts and sets up revenue sharing in one transaction for multiple chains.
    ///         This is the most efficient path as vaults are initialized with RevShare config from the start.
    /// @param _portals Array of OptimismPortal2 addresses for the target L2s.
    /// @param _l1WithdrawerConfigs Array of L1Withdrawer configurations.
    /// @param _chainFeesRecipients Array of chain fees recipients for the calculators.
    function upgradeAndSetupRevShare(
        address[] calldata _portals,
        L1WithdrawerConfig[] calldata _l1WithdrawerConfigs,
        address[] calldata _chainFeesRecipients
    ) external {
        if (_portals.length == 0) revert EmptyArray();
        if (_portals.length != _l1WithdrawerConfigs.length || _portals.length != _chainFeesRecipients.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i; i < _portals.length; i++) {
            if (_portals[i] == address(0)) revert PortalCannotBeZeroAddress();
            if (_l1WithdrawerConfigs[i].recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
            if (_chainFeesRecipients[i] == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

            // Deploy L1Withdrawer and SuperchainRevenueShareCalculator
            address calculator = _deployRevSharePeriphery(_portals[i], _l1WithdrawerConfigs[i], _chainFeesRecipients[i]);

            // Upgrade fee splitter and initialize with calculator FIRST
            // This prevents the edge case where fees could be sent to an uninitialized FeeSplitter
            bytes32 feeSplitterSalt = _getSalt("FeeSplitter");
            address feeSplitterImpl =
                Utils.getCreate2Address(feeSplitterSalt, RevShareCodeRepo.feeSplitterCreationCode, CREATE2_DEPLOYER);
            _depositCreate2(
                _portals[i],
                RevShareGasLimits.FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
                feeSplitterSalt,
                RevShareCodeRepo.feeSplitterCreationCode
            );
            _depositCall(
                _portals[i],
                address(PROXY_ADMIN),
                RevShareGasLimits.UPGRADE_GAS_LIMIT,
                abi.encodeCall(
                    IProxyAdmin.upgradeAndCall,
                    (payable(FEE_SPLITTER), feeSplitterImpl, abi.encodeCall(IFeeSplitter.initialize, (calculator)))
                )
            );

            // Upgrade all 4 vaults with RevShare configuration (recipient=FeeSplitter, minWithdrawal=0, network=L2)
            _upgradeVaultsWithRevShareConfig(_portals[i]);
        }
    }

    /// @notice Enables revenue sharing after vaults have been upgraded and `FeeSplitter` initialized.
    ///         Deploys L1Withdrawer and calculator, then configures vaults and splitter for multiple chains.
    /// @param _portals Array of OptimismPortal2 addresses for the target L2s.
    /// @param _l1WithdrawerConfigs Array of L1Withdrawer configurations.
    /// @param _chainFeesRecipients Array of chain fees recipients for the calculators.
    function setupRevShare(
        address[] calldata _portals,
        L1WithdrawerConfig[] calldata _l1WithdrawerConfigs,
        address[] calldata _chainFeesRecipients
    ) external {
        if (_portals.length == 0) revert EmptyArray();
        if (_portals.length != _l1WithdrawerConfigs.length || _portals.length != _chainFeesRecipients.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i; i < _portals.length; i++) {
            if (_portals[i] == address(0)) revert PortalCannotBeZeroAddress();
            if (_l1WithdrawerConfigs[i].recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
            if (_chainFeesRecipients[i] == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

            // Deploy L1Withdrawer and SuperchainRevenueShareCalculator
            address calculator = _deployRevSharePeriphery(_portals[i], _l1WithdrawerConfigs[i], _chainFeesRecipients[i]);

            // Set calculator on fee splitter
            _depositCall(
                _portals[i],
                FEE_SPLITTER,
                RevShareGasLimits.SETTERS_GAS_LIMIT,
                abi.encodeCall(IFeeSplitter.setSharesCalculator, (calculator))
            );

            // Configure all 4 vaults for revenue sharing
            _configureVaultsForRevShare(_portals[i]);
        }
    }

    /// @notice Deploys L1Withdrawer and SuperchainRevenueShareCalculator to L2.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _l1WithdrawerConfig L1Withdrawer configuration
    /// @param _chainFeesRecipient Chain fees recipient address
    /// @return calculator The deployed calculator address
    function _deployRevSharePeriphery(
        address _portal,
        L1WithdrawerConfig calldata _l1WithdrawerConfig,
        address _chainFeesRecipient
    ) private returns (address calculator) {
        // Deploy L1Withdrawer
        bytes memory l1WithdrawerInitCode = bytes.concat(
            RevShareCodeRepo.l1WithdrawerCreationCode,
            abi.encode(_l1WithdrawerConfig.minWithdrawalAmount, _l1WithdrawerConfig.recipient, _l1WithdrawerConfig.gasLimit)
        );
        bytes32 l1WithdrawerSalt = _getSalt("L1Withdrawer");
        address l1Withdrawer = Utils.getCreate2Address(l1WithdrawerSalt, l1WithdrawerInitCode, CREATE2_DEPLOYER);
        _depositCreate2(
            _portal, RevShareGasLimits.L1_WITHDRAWER_DEPLOYMENT_GAS_LIMIT, l1WithdrawerSalt, l1WithdrawerInitCode
        );

        // Deploy SuperchainRevenueShareCalculator
        bytes memory calculatorInitCode =
            bytes.concat(RevShareCodeRepo.scRevShareCalculatorCreationCode, abi.encode(l1Withdrawer, _chainFeesRecipient));
        bytes32 calculatorSalt = _getSalt("SCRevShareCalculator");
        calculator = Utils.getCreate2Address(calculatorSalt, calculatorInitCode, CREATE2_DEPLOYER);
        _depositCreate2(
            _portal, RevShareGasLimits.SC_REV_SHARE_CALCULATOR_DEPLOYMENT_GAS_LIMIT, calculatorSalt, calculatorInitCode
        );
    }

    /// @notice Configures all 4 vaults for revenue sharing (recipient=FeeSplitter, minWithdrawal=0, network=L2).
    /// @param _portal The OptimismPortal2 address for the target L2
    function _configureVaultsForRevShare(address _portal) private {
        address[4] memory vaults = [OPERATOR_FEE_VAULT, SEQUENCER_FEE_WALLET, BASE_FEE_VAULT, L1_FEE_VAULT];

        for (uint256 i; i < vaults.length; i++) {
            _depositCall(
                _portal, vaults[i], RevShareGasLimits.SETTERS_GAS_LIMIT, abi.encodeCall(IFeeVault.setRecipient, (FEE_SPLITTER))
            );
            _depositCall(
                _portal, vaults[i], RevShareGasLimits.SETTERS_GAS_LIMIT, abi.encodeCall(IFeeVault.setMinWithdrawalAmount, (0))
            );
            _depositCall(
                _portal, vaults[i], RevShareGasLimits.SETTERS_GAS_LIMIT, abi.encodeCall(IFeeVault.setWithdrawalNetwork, (IFeeVault.WithdrawalNetwork.L2))
            );
        }
    }

    /// @notice Upgrades all 4 vaults with RevShare configuration (recipient=FeeSplitter, minWithdrawal=0, network=L2).
    /// @param _portal The OptimismPortal2 address for the target L2
    function _upgradeVaultsWithRevShareConfig(address _portal) private {
        address[4] memory vaultProxies = [OPERATOR_FEE_VAULT, SEQUENCER_FEE_WALLET, BASE_FEE_VAULT, L1_FEE_VAULT];
        bytes[4] memory creationCodes = [
            RevShareCodeRepo.operatorFeeVaultCreationCode,
            RevShareCodeRepo.sequencerFeeVaultCreationCode,
            RevShareCodeRepo.baseFeeVaultCreationCode,
            RevShareCodeRepo.l1FeeVaultCreationCode
        ];
        string[4] memory vaultNames = ["OperatorFeeVault", "SequencerFeeVault", "BaseFeeVault", "L1FeeVault"];

        for (uint256 i; i < vaultProxies.length; i++) {
            bytes32 salt = _getSalt(vaultNames[i]);
            address impl = Utils.getCreate2Address(salt, creationCodes[i], CREATE2_DEPLOYER);

            _depositCreate2(_portal, RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT, salt, creationCodes[i]);
            _depositCall(
                _portal,
                address(PROXY_ADMIN),
                RevShareGasLimits.UPGRADE_GAS_LIMIT,
                abi.encodeCall(
                    IProxyAdmin.upgradeAndCall,
                    (
                        payable(vaultProxies[i]),
                        impl,
                        abi.encodeCall(
                            IFeeVault.initialize,
                            (FEE_SPLITTER, 0, IFeeVault.WithdrawalNetwork.L2) // recipient=FeeSplitter, minWithdrawal=0, network=L2
                        )
                    )
                )
            );
        }
    }

    /// @notice Helper for CREATE2 contract deployments via depositTransaction.
    /// @param _portal The OptimismPortal2 address
    /// @param _gasLimit Gas limit for the transaction
    /// @param _salt CREATE2 salt
    /// @param _initCode Contract creation code with constructor args
    function _depositCreate2(address _portal, uint64 _gasLimit, bytes32 _salt, bytes memory _initCode) private {
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            _gasLimit,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, _salt, _initCode))
        );
    }

    /// @notice Helper for regular function calls via depositTransaction.
    /// @param _portal The OptimismPortal2 address
    /// @param _target Target contract address
    /// @param _gasLimit Gas limit for the transaction
    /// @param _data Encoded function call data
    function _depositCall(address _portal, address _target, uint64 _gasLimit, bytes memory _data) private {
        IOptimismPortal2(payable(_portal)).depositTransaction(_target, 0, _gasLimit, false, _data);
    }

    /// @notice Generates a unique salt for CREATE2 deployments based on the contract suffix.
    /// @param _suffix The suffix to append to the base salt seed
    /// @return The generated salt as bytes32
    function _getSalt(string memory _suffix) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_SEED, ":", _suffix));
    }
}
