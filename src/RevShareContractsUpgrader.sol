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
import {IFeeSplitterSetter} from "src/interfaces/IFeeSplitterSetter.sol";
import {IFeeVault} from "src/interfaces/IFeeVault.sol";

/// @title RevShareContractsManager
/// @notice Upgrader contract that manages RevShare deployments and configuration via delegatecall.
/// @dev    Supports two operations:
///         1. setupRevShare() - Setup revenue sharing on already-upgraded contracts
///         2. upgradeAndSetupRevShare() - Combined upgrade + setup (most efficient)
///         All operations use the default calculator (L1Withdrawer + SuperchainRevenueShareCalculator).
contract RevShareContractsManager is RevSharePredeploys {
    /// @notice Salt used for all CREATE2 deployments
    bytes32 private constant SALT = keccak256("RevShare");

    /// @notice Thrown when portal address is zero
    error PortalCannotBeZeroAddress();

    /// @notice Thrown when L1Withdrawer recipient is zero address
    error L1WithdrawerRecipientCannotBeZeroAddress();

    /// @notice Thrown when chain fees recipient is zero address
    error ChainFeesRecipientCannotBeZeroAddress();

    /// @notice Thrown when array lengths don't match
    error ArrayLengthMismatch();

    /// @notice Struct for L1Withdrawer configuration.
    /// @param minWithdrawalAmount Minimum withdrawal amount
    /// @param recipient Recipient address for withdrawals
    /// @param gasLimit Gas limit for L1 withdrawals
    struct L1WithdrawerConfig {
        uint256 minWithdrawalAmount;
        address recipient;
        uint32 gasLimit;
    }

    /// @notice Enables revenue sharing after vaults have been upgraded and `FeeSplitter` initialized.
    ///         Deploys L1Withdrawer and calculator, then configures vaults and splitter for multiple chains.
    /// @param _portals Array of OptimismPortal2 addresses for the target L2s.
    /// @param _l1Configs Array of L1Withdrawer configurations.
    /// @param _chainFeesRecipients Array of chain fees recipients for the calculators.
    function setupRevShare(
        address[] calldata _portals,
        L1WithdrawerConfig[] calldata _l1Configs,
        address[] calldata _chainFeesRecipients
    ) external {
        if (_portals.length != _l1Configs.length || _portals.length != _chainFeesRecipients.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < _portals.length; i++) {
            if (_portals[i] == address(0)) revert PortalCannotBeZeroAddress();
            if (_l1Configs[i].recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
            if (_chainFeesRecipients[i] == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

            // Deploy L1Withdrawer
            address l1Withdrawer = _deployL1Withdrawer(_portals[i], _l1Configs[i]);

            // Deploy SuperchainRevenueShareCalculator
            address calculator = _deployCalculator(_portals[i], l1Withdrawer, _chainFeesRecipients[i]);

            // Configure all 4 vaults for revenue sharing
            _configureVaultsForRevShare(_portals[i]);

            // Set calculator on fee splitter
            _setFeeSplitterCalculator(_portals[i], calculator);
        }
    }

    /// @notice Upgrades vault and splitter contracts and sets up revenue sharing in one transaction for multiple chains.
    ///         This is the most efficient path as vaults are initialized with RevShare config from the start.
    /// @param _portals Array of OptimismPortal2 addresses for the target L2s.
    /// @param _l1Configs Array of L1Withdrawer configurations.
    /// @param _chainFeesRecipients Array of chain fees recipients for the calculators.
    function upgradeAndSetupRevShare(
        address[] calldata _portals,
        L1WithdrawerConfig[] calldata _l1Configs,
        address[] calldata _chainFeesRecipients
    ) external {
        if (_portals.length != _l1Configs.length || _portals.length != _chainFeesRecipients.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < _portals.length; i++) {
            if (_portals[i] == address(0)) revert PortalCannotBeZeroAddress();
            if (_l1Configs[i].recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
            if (_chainFeesRecipients[i] == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

            // Deploy L1Withdrawer
            address l1Withdrawer = _deployL1Withdrawer(_portals[i], _l1Configs[i]);

            // Deploy SuperchainRevenueShareCalculator
            address calculator = _deployCalculator(_portals[i], l1Withdrawer, _chainFeesRecipients[i]);

            // Upgrade fee splitter and initialize with calculator FIRST
            // This prevents the edge case where fees could be sent to an uninitialized FeeSplitter
            _deployAndUpgradeFeeSplitterWithCalculator(_portals[i], calculator);

            // Upgrade all 4 vaults with RevShare configuration (recipient=FeeSplitter, minWithdrawal=0, network=L2)
            _upgradeVaultsWithRevShareConfig(_portals[i]);
        }
    }

    /// @notice Deploys L1Withdrawer to L2.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _config L1Withdrawer configuration
    /// @return The deployed L1Withdrawer address
    function _deployL1Withdrawer(address _portal, L1WithdrawerConfig memory _config) private returns (address) {
        bytes memory initCode = bytes.concat(
            RevShareCodeRepo.l1WithdrawerCreationCode,
            abi.encode(_config.minWithdrawalAmount, _config.recipient, _config.gasLimit)
        );
        address l1Withdrawer = Utils.getCreate2Address(SALT, initCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.L1_WITHDRAWER_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, SALT, initCode))
        );

        return l1Withdrawer;
    }

    /// @notice Deploys SuperchainRevenueShareCalculator to L2.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _l1Withdrawer The L1Withdrawer address
    /// @param _chainFeesRecipient The chain fees recipient address
    /// @return The deployed calculator address
    function _deployCalculator(address _portal, address _l1Withdrawer, address _chainFeesRecipient)
        private
        returns (address)
    {
        bytes memory initCode = bytes.concat(
            RevShareCodeRepo.scRevShareCalculatorCreationCode, abi.encode(_l1Withdrawer, _chainFeesRecipient)
        );
        address calculator = Utils.getCreate2Address(SALT, initCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.SC_REV_SHARE_CALCULATOR_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, SALT, initCode))
        );

        return calculator;
    }

    /// @notice Configures all 4 vaults for revenue sharing (recipient=FeeSplitter, minWithdrawal=0, network=L2).
    /// @param _portal The OptimismPortal2 address for the target L2
    function _configureVaultsForRevShare(address _portal) private {
        address[4] memory vaults = [OPERATOR_FEE_VAULT, SEQUENCER_FEE_WALLET, BASE_FEE_VAULT, L1_FEE_VAULT];

        for (uint256 i = 0; i < vaults.length; i++) {
            // Set recipient to FeeSplitter
            IOptimismPortal2(payable(_portal)).depositTransaction(
                vaults[i], 0, RevShareGasLimits.SETTERS_GAS_LIMIT, false, abi.encodeCall(IFeeVault.setRecipient, (FEE_SPLITTER))
            );

            // Set minWithdrawalAmount to 0
            IOptimismPortal2(payable(_portal)).depositTransaction(
                vaults[i], 0, RevShareGasLimits.SETTERS_GAS_LIMIT, false, abi.encodeCall(IFeeVault.setMinWithdrawalAmount, (0))
            );

            // Set withdrawalNetwork to L2 (1)
            IOptimismPortal2(payable(_portal)).depositTransaction(
                vaults[i], 0, RevShareGasLimits.SETTERS_GAS_LIMIT, false, abi.encodeCall(IFeeVault.setWithdrawalNetwork, (1))
            );
        }
    }

    /// @notice Sets the calculator on the fee splitter.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _calculator The calculator address to set
    function _setFeeSplitterCalculator(address _portal, address _calculator) private {
        IOptimismPortal2(payable(_portal)).depositTransaction(
            FEE_SPLITTER,
            0,
            RevShareGasLimits.SETTERS_GAS_LIMIT,
            false,
            abi.encodeCall(IFeeSplitterSetter.setSharesCalculator, (_calculator))
        );
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

        for (uint256 i = 0; i < 4; i++) {
            address impl = Utils.getCreate2Address(SALT, creationCodes[i], CREATE2_DEPLOYER);

            // Deploy implementation
            IOptimismPortal2(payable(_portal)).depositTransaction(
                address(CREATE2_DEPLOYER),
                0,
                RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
                false,
                abi.encodeCall(ICreate2Deployer.deploy, (0, SALT, creationCodes[i]))
            );

            // Upgrade proxy and initialize with RevShare config
            IOptimismPortal2(payable(_portal)).depositTransaction(
                address(PROXY_ADMIN),
                0,
                RevShareGasLimits.UPGRADE_GAS_LIMIT,
                false,
                abi.encodeCall(
                    IProxyAdmin.upgradeAndCall,
                    (
                        payable(vaultProxies[i]),
                        impl,
                        abi.encodeCall(
                            IFeeVault.initialize,
                            (FEE_SPLITTER, 0, 1) // recipient=FeeSplitter, minWithdrawal=0, network=L2
                        )
                    )
                )
            );
        }
    }

    /// @notice Deploys and upgrades the fee splitter with a calculator.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _calculator The calculator address to initialize with
    function _deployAndUpgradeFeeSplitterWithCalculator(address _portal, address _calculator) private {
        bytes memory creationCode = RevShareCodeRepo.feeSplitterCreationCode;
        address impl = Utils.getCreate2Address(SALT, creationCode, CREATE2_DEPLOYER);

        // Deploy implementation
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, SALT, creationCode))
        );

        // Upgrade proxy and initialize with calculator
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (payable(FEE_SPLITTER), impl, abi.encodeCall(IFeeSplitter.initialize, (_calculator)))
            )
        );
    }
}
