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
    ///         Deploys L1Withdrawer and calculator, then configures vaults and splitter.
    /// @param _portal The OptimismPortal2 address for the target L2.
    /// @param _l1Config L1Withdrawer configuration.
    /// @param _chainFeesRecipient The chain fees recipient for the calculator.
    function setupRevShare(address _portal, L1WithdrawerConfig memory _l1Config, address _chainFeesRecipient)
        external
    {
        if (_portal == address(0)) revert PortalCannotBeZeroAddress();
        if (_l1Config.recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
        if (_chainFeesRecipient == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

        // Deploy L1Withdrawer
        address l1Withdrawer = _deployL1Withdrawer(_portal, _l1Config);

        // Deploy SuperchainRevenueShareCalculator
        address calculator = _deployCalculator(_portal, l1Withdrawer, _chainFeesRecipient);

        // Configure all 4 vaults for revenue sharing
        _configureVaultsForRevShare(_portal);

        // Set calculator on fee splitter
        _setFeeSplitterCalculator(_portal, calculator);
    }

    /// @notice Upgrades vault and splitter contracts and sets up revenue sharing in one transaction.
    ///         This is the most efficient path as vaults are initialized with RevShare config from the start.
    /// @param _portal The OptimismPortal2 address for the target L2.
    /// @param _l1Config L1Withdrawer configuration.
    /// @param _chainFeesRecipient The chain fees recipient for the calculator.
    function upgradeAndSetupRevShare(address _portal, L1WithdrawerConfig memory _l1Config, address _chainFeesRecipient)
        external
    {
        if (_portal == address(0)) revert PortalCannotBeZeroAddress();
        if (_l1Config.recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
        if (_chainFeesRecipient == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

        // Deploy L1Withdrawer
        address l1Withdrawer = _deployL1Withdrawer(_portal, _l1Config);

        // Deploy SuperchainRevenueShareCalculator
        address calculator = _deployCalculator(_portal, l1Withdrawer, _chainFeesRecipient);

        // Upgrade fee splitter and initialize with calculator FIRST
        // This prevents the edge case where fees could be sent to an uninitialized FeeSplitter
        _deployAndUpgradeFeeSplitterWithCalculator(_portal, calculator);

        // Upgrade all 4 vaults with RevShare configuration (recipient=FeeSplitter, minWithdrawal=0, network=L2)
        _upgradeVaultsWithRevShareConfig(_portal);
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
