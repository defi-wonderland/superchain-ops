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
/// @dev    Supports three operations:
///         1. upgradeContracts() - Upgrade vault and splitter implementations only
///         2. setupRevShare() - Setup revenue sharing on already-upgraded contracts
///         3. upgradeAndSetupRevShare() - Combined upgrade + setup (most efficient)
///         All operations use the default calculator (L1Withdrawer + SuperchainRevenueShareCalculator).
contract RevShareContractsManager is RevSharePredeploys {
    /// @notice Thrown when portal address is zero
    error PortalCannotBeZeroAddress();

    /// @notice Thrown when salt seed is empty
    error SaltSeedCannotBeEmpty();

    /// @notice Thrown when vaults array length is not 4
    error VaultsMustBeArrayOf4();

    /// @notice Thrown when L1Withdrawer recipient is zero address
    error L1WithdrawerRecipientCannotBeZeroAddress();

    /// @notice Thrown when chain fees recipient is zero address
    error ChainFeesRecipientCannotBeZeroAddress();

    /// @notice Thrown when vault proxy address is zero
    error VaultProxyCannotBeZeroAddress();

    /// @notice Thrown when vault proxy address is unknown
    error UnknownVaultProxyAddress();

    /// @notice Struct for vault configuration.
    /// @param proxy Vault proxy address
    /// @param recipient Withdrawal recipient
    /// @param minWithdrawal Minimum withdrawal amount
    /// @param withdrawalNetwork Network for withdrawals (0=L1, 1=L2)
    struct VaultConfig {
        address proxy;
        address recipient;
        uint256 minWithdrawal;
        uint8 withdrawalNetwork;
    }

    /// @notice Struct for L1Withdrawer configuration.
    /// @param minWithdrawalAmount Minimum withdrawal amount
    /// @param recipient Recipient address for withdrawals
    /// @param gasLimit Gas limit for L1 withdrawals
    struct L1WithdrawerConfig {
        uint256 minWithdrawalAmount;
        address recipient;
        uint32 gasLimit;
    }

    /// @notice Upgrades vault initializing them with custom configuration and deploys fee splitter initializing it with 0 address as shares calculator since revenue sharing is disabled.
    ///         Vaults are NOT configured for revenue sharing - use setupRevShare() afterwards.
    /// @param _portal The OptimismPortal2 address for the target L2.
    /// @param _saltSeed The salt seed for CREATE2 deployments.
    /// @param _vaults Array of 4 vault configurations.
    function upgradeContracts(address _portal, string memory _saltSeed, VaultConfig[] memory _vaults) external {
        if (_portal == address(0)) revert PortalCannotBeZeroAddress();
        if (bytes(_saltSeed).length == 0) revert SaltSeedCannotBeEmpty();
        if (_vaults.length != 4) revert VaultsMustBeArrayOf4();

        // Deploy and upgrade each vault with custom config
        for (uint256 i = 0; i < _vaults.length; i++) {
            _upgradeVaultWithCustomConfig(_portal, _saltSeed, _vaults[i]);
        }

        // Deploy and upgrade fee splitter with address(0) calculator (disabled)
        _deployAndUpgradeFeeSplitterDisabled(_portal, _saltSeed);
    }

    /// @notice Enables revenue sharing after vaults have been upgraded and `FeeSplitter` initialized.
    ///         Deploys L1Withdrawer and calculator, then configures vaults and splitter.
    /// @param _portal The OptimismPortal2 address for the target L2.
    /// @param _saltSeed The salt seed for CREATE2 deployments.
    /// @param _l1Config L1Withdrawer configuration.
    /// @param _chainFeesRecipient The chain fees recipient for the calculator.
    function setupRevShare(
        address _portal,
        string memory _saltSeed,
        L1WithdrawerConfig memory _l1Config,
        address _chainFeesRecipient
    ) external {
        if (_portal == address(0)) revert PortalCannotBeZeroAddress();
        if (bytes(_saltSeed).length == 0) revert SaltSeedCannotBeEmpty();
        if (_l1Config.recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
        if (_chainFeesRecipient == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

        // Deploy L1Withdrawer
        address l1Withdrawer = _deployL1Withdrawer(_portal, _saltSeed, _l1Config);

        // Deploy SuperchainRevenueShareCalculator
        address calculator = _deployCalculator(_portal, _saltSeed, l1Withdrawer, _chainFeesRecipient);

        // Configure all 4 vaults for revenue sharing
        _configureVaultsForRevShare(_portal);

        // Set calculator on fee splitter
        _setFeeSplitterCalculator(_portal, calculator);
    }

    /// @notice Upgrades vault and splitter contracts and sets up revenue sharing in one transaction.
    ///         This is the most efficient path as vaults are initialized with RevShare config from the start.
    /// @param _portal The OptimismPortal2 address for the target L2.
    /// @param _saltSeed The salt seed for CREATE2 deployments.
    /// @param _l1Config L1Withdrawer configuration.
    /// @param _chainFeesRecipient The chain fees recipient for the calculator.
    function upgradeAndSetupRevShare(
        address _portal,
        string memory _saltSeed,
        L1WithdrawerConfig memory _l1Config,
        address _chainFeesRecipient
    ) external {
        if (_portal == address(0)) revert PortalCannotBeZeroAddress();
        if (bytes(_saltSeed).length == 0) revert SaltSeedCannotBeEmpty();
        if (_l1Config.recipient == address(0)) revert L1WithdrawerRecipientCannotBeZeroAddress();
        if (_chainFeesRecipient == address(0)) revert ChainFeesRecipientCannotBeZeroAddress();

        // Deploy L1Withdrawer
        address l1Withdrawer = _deployL1Withdrawer(_portal, _saltSeed, _l1Config);

        // Deploy SuperchainRevenueShareCalculator
        address calculator = _deployCalculator(_portal, _saltSeed, l1Withdrawer, _chainFeesRecipient);

        // Upgrade fee splitter and initialize with calculator FIRST
        // This prevents the edge case where fees could be sent to an uninitialized FeeSplitter
        _deployAndUpgradeFeeSplitterWithCalculator(_portal, _saltSeed, calculator);

        // Upgrade all 4 vaults with RevShare configuration (recipient=FeeSplitter, minWithdrawal=0, network=L2)
        _upgradeVaultsWithRevShareConfig(_portal, _saltSeed);
    }

    /// @notice Deploys and upgrades a single vault with custom configuration.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _saltSeed The salt seed for CREATE2 deployments
    /// @param _config Vault configuration containing proxy address and initialization parameters
    function _upgradeVaultWithCustomConfig(address _portal, string memory _saltSeed, VaultConfig memory _config) private {
        if (_config.proxy == address(0)) revert VaultProxyCannotBeZeroAddress();

        // Determine which vault type and get the appropriate creation code
        bytes memory creationCode;
        string memory vaultName;

        if (_config.proxy == OPERATOR_FEE_VAULT) {
            creationCode = RevShareCodeRepo.operatorFeeVaultCreationCode;
            vaultName = "OperatorFeeVault";
        } else if (_config.proxy == SEQUENCER_FEE_WALLET) {
            creationCode = RevShareCodeRepo.sequencerFeeVaultCreationCode;
            vaultName = "SequencerFeeVault";
        } else if (_config.proxy == BASE_FEE_VAULT) {
            creationCode = RevShareCodeRepo.baseFeeVaultCreationCode;
            vaultName = "BaseFeeVault";
        } else if (_config.proxy == L1_FEE_VAULT) {
            creationCode = RevShareCodeRepo.l1FeeVaultCreationCode;
            vaultName = "L1FeeVault";
        } else {
            revert UnknownVaultProxyAddress();
        }

        bytes32 salt = _getSalt(_saltSeed, vaultName);
        address impl = Utils.getCreate2Address(salt, creationCode, CREATE2_DEPLOYER);

        // Deploy implementation
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, salt, creationCode))
        );

        // Upgrade proxy and initialize with custom config
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (
                    payable(_config.proxy),
                    impl,
                    abi.encodeCall(
                        IFeeVault.initialize, (_config.recipient, _config.minWithdrawal, _config.withdrawalNetwork)
                    )
                )
            )
        );
    }

    /// @notice Deploys and upgrades the fee splitter with address(0) calculator (revenue sharing disabled).
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _saltSeed The salt seed for CREATE2 deployments
    function _deployAndUpgradeFeeSplitterDisabled(address _portal, string memory _saltSeed) private {
        bytes32 salt = _getSalt(_saltSeed, "FeeSplitter");
        bytes memory creationCode = RevShareCodeRepo.feeSplitterCreationCode;
        address impl = Utils.getCreate2Address(salt, creationCode, CREATE2_DEPLOYER);

        // Deploy implementation
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, salt, creationCode))
        );

        // Upgrade proxy and initialize with address(0) calculator (disabled)
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (payable(FEE_SPLITTER), impl, abi.encodeCall(IFeeSplitter.initialize, (address(0))))
            )
        );
    }

    /// @notice Deploys L1Withdrawer to L2.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _saltSeed The salt seed for CREATE2 deployments
    /// @param _config L1Withdrawer configuration
    /// @return The deployed L1Withdrawer address
    function _deployL1Withdrawer(address _portal, string memory _saltSeed, L1WithdrawerConfig memory _config)
        private
        returns (address)
    {
        bytes memory initCode = bytes.concat(
            RevShareCodeRepo.l1WithdrawerCreationCode,
            abi.encode(_config.minWithdrawalAmount, _config.recipient, _config.gasLimit)
        );
        bytes32 salt = _getSalt(_saltSeed, "L1Withdrawer");
        address l1Withdrawer = Utils.getCreate2Address(salt, initCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.L1_WITHDRAWER_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, salt, initCode))
        );

        return l1Withdrawer;
    }

    /// @notice Deploys SuperchainRevenueShareCalculator to L2.
    /// @param _portal The OptimismPortal2 address for the target L2
    /// @param _saltSeed The salt seed for CREATE2 deployments
    /// @param _l1Withdrawer The L1Withdrawer address
    /// @param _chainFeesRecipient The chain fees recipient address
    /// @return The deployed calculator address
    function _deployCalculator(
        address _portal,
        string memory _saltSeed,
        address _l1Withdrawer,
        address _chainFeesRecipient
    ) private returns (address) {
        bytes memory initCode = bytes.concat(
            RevShareCodeRepo.scRevShareCalculatorCreationCode, abi.encode(_l1Withdrawer, _chainFeesRecipient)
        );
        bytes32 salt = _getSalt(_saltSeed, "SCRevShareCalculator");
        address calculator = Utils.getCreate2Address(salt, initCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.SC_REV_SHARE_CALCULATOR_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, salt, initCode))
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
    /// @param _saltSeed The salt seed for CREATE2 deployments
    function _upgradeVaultsWithRevShareConfig(address _portal, string memory _saltSeed) private {
        address[4] memory vaultProxies = [OPERATOR_FEE_VAULT, SEQUENCER_FEE_WALLET, BASE_FEE_VAULT, L1_FEE_VAULT];
        bytes[4] memory creationCodes = [
            RevShareCodeRepo.operatorFeeVaultCreationCode,
            RevShareCodeRepo.sequencerFeeVaultCreationCode,
            RevShareCodeRepo.baseFeeVaultCreationCode,
            RevShareCodeRepo.l1FeeVaultCreationCode
        ];
        string[4] memory vaultNames = ["OperatorFeeVault", "SequencerFeeVault", "BaseFeeVault", "L1FeeVault"];

        for (uint256 i = 0; i < 4; i++) {
            bytes32 salt = _getSalt(_saltSeed, vaultNames[i]);
            address impl = Utils.getCreate2Address(salt, creationCodes[i], CREATE2_DEPLOYER);

            // Deploy implementation
            IOptimismPortal2(payable(_portal)).depositTransaction(
                address(CREATE2_DEPLOYER),
                0,
                RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
                false,
                abi.encodeCall(ICreate2Deployer.deploy, (0, salt, creationCodes[i]))
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
    /// @param _saltSeed The salt seed for CREATE2 deployments
    /// @param _calculator The calculator address to initialize with
    function _deployAndUpgradeFeeSplitterWithCalculator(address _portal, string memory _saltSeed, address _calculator)
        private
    {
        bytes32 salt = _getSalt(_saltSeed, "FeeSplitter");
        bytes memory creationCode = RevShareCodeRepo.feeSplitterCreationCode;
        address impl = Utils.getCreate2Address(salt, creationCode, CREATE2_DEPLOYER);

        // Deploy implementation
        IOptimismPortal2(payable(_portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, salt, creationCode))
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

    /// @notice Generates a salt from a prefix and suffix.
    /// @param _prefix The prefix string
    /// @param _suffix The suffix string
    /// @return The generated salt as bytes32
    function _getSalt(string memory _prefix, string memory _suffix) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes(_prefix), bytes(":"), bytes(_suffix)));
    }
}
