// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevSharePredeploys} from "src/libraries/RevSharePredeploys.sol";
import {RevShareCodeRepo} from "src/libraries/RevShareCodeRepo.sol";
import {RevShareGasLimits} from "src/libraries/RevShareGasLimits.sol";
import {Utils} from "src/libraries/Utils.sol";

/// @notice Interface for the OptimismPortal2 in L1.
interface IOptimismPortal2 {
    function depositTransaction(address _to, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes memory _data)
        external
        payable;
}

/// @notice Interface of the Create2 Preinstall in L2.
interface ICreate2Deployer {
    function deploy(uint256 _value, bytes32 _salt, bytes memory _code) external;
}

/// @notice Interface for ProxyAdmin.
interface IProxyAdmin {
    function upgradeAndCall(address payable _proxy, address _implementation, bytes memory _data) external;
}

/// @notice Interface for the FeeSplitter in L2.
interface IFeeSplitter {
    function initialize(address _sharesCalculator) external;
}

/// @notice Interface for the vaults in L2.
interface IFeeVault {
    function initialize(address _recipient, uint256 _minWithdrawalAmount, uint8 _withdrawalNetwork) external;
}

/// @title RevShareContractsManager
/// @notice Upgrader contract that deploys fee vaults and fee splitter via delegatecall.
///         The fee splitter is initialized with address(0) calculator (disabled state).
contract RevShareContractsManager is RevSharePredeploys {
    /// @notice The address of the OptimismPortal2 through which we make deposit transactions.
    address public immutable portal;

    /// @notice The salt seed to be used for the L2 deployments.
    string public saltSeed;

    /// @notice The withdrawal network configuration for the fee vaults.
    uint8 public constant FEE_VAULT_WITHDRAWAL_NETWORK = 1;

    /// @notice The minimum withdrawal amount configuration for the fee vaults.
    uint256 public constant FEE_VAULT_MIN_WITHDRAWAL_AMOUNT = 0;

    /// @notice Constructor sets the portal and saltSeed.
    /// @param _portal The address of the OptimismPortal2.
    /// @param _saltSeed The salt seed for CREATE2 deployments.
    constructor(address _portal, string memory _saltSeed) {
        require(_portal != address(0), "portal must be set");
        require(bytes(_saltSeed).length != 0, "saltSeed must be set");

        portal = _portal;
        saltSeed = _saltSeed;
    }

    /// @notice Deploys fee vaults and fee splitter to L2 via OptimismPortal2.
    ///         The fee splitter is initialized with address(0) calculator (disabled).
    function deployVaultsAndSplitter() external {
        _deployFeeVaults();
        _deployFeeSplitter();
    }

    /// @notice Deploys the fee vaults implementation and upgrades the proxies.
    function _deployFeeVaults() private {
        // Deploy OperatorFeeVault
        bytes32 operatorSalt = _getSalt(saltSeed, "OperatorFeeVault");
        bytes memory operatorInitCode = RevShareCodeRepo.operatorFeeVaultCreationCode;
        address operatorFeeVaultImpl =
            Utils.getCreate2Address(operatorSalt, operatorInitCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, operatorSalt, operatorInitCode))
        );

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (
                    payable(OPERATOR_FEE_VAULT),
                    operatorFeeVaultImpl,
                    abi.encodeCall(
                        IFeeVault.initialize,
                        (FEE_VAULT_RECIPIENT, FEE_VAULT_MIN_WITHDRAWAL_AMOUNT, FEE_VAULT_WITHDRAWAL_NETWORK)
                    )
                )
            )
        );

        // Deploy SequencerFeeVault
        bytes32 sequencerSalt = _getSalt(saltSeed, "SequencerFeeVault");
        bytes memory sequencerInitCode = RevShareCodeRepo.sequencerFeeVaultCreationCode;
        address sequencerFeeVaultImpl =
            Utils.getCreate2Address(sequencerSalt, sequencerInitCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, sequencerSalt, sequencerInitCode))
        );

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (
                    payable(SEQUENCER_FEE_WALLET),
                    sequencerFeeVaultImpl,
                    abi.encodeCall(
                        IFeeVault.initialize,
                        (FEE_VAULT_RECIPIENT, FEE_VAULT_MIN_WITHDRAWAL_AMOUNT, FEE_VAULT_WITHDRAWAL_NETWORK)
                    )
                )
            )
        );

        // Deploy BaseFeeVault
        bytes32 baseSalt = _getSalt(saltSeed, "BaseFeeVault");
        bytes memory baseInitCode = RevShareCodeRepo.baseFeeVaultCreationCode;
        address baseFeeVaultImpl = Utils.getCreate2Address(baseSalt, baseInitCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, baseSalt, baseInitCode))
        );

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (
                    payable(BASE_FEE_VAULT),
                    baseFeeVaultImpl,
                    abi.encodeCall(
                        IFeeVault.initialize,
                        (FEE_VAULT_RECIPIENT, FEE_VAULT_MIN_WITHDRAWAL_AMOUNT, FEE_VAULT_WITHDRAWAL_NETWORK)
                    )
                )
            )
        );

        // Deploy L1FeeVault
        bytes32 l1Salt = _getSalt(saltSeed, "L1FeeVault");
        bytes memory l1InitCode = RevShareCodeRepo.l1FeeVaultCreationCode;
        address l1FeeVaultImpl = Utils.getCreate2Address(l1Salt, l1InitCode, CREATE2_DEPLOYER);

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, l1Salt, l1InitCode))
        );

        IOptimismPortal2(payable(portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (
                    payable(L1_FEE_VAULT),
                    l1FeeVaultImpl,
                    abi.encodeCall(
                        IFeeVault.initialize,
                        (FEE_VAULT_RECIPIENT, FEE_VAULT_MIN_WITHDRAWAL_AMOUNT, FEE_VAULT_WITHDRAWAL_NETWORK)
                    )
                )
            )
        );
    }

    /// @notice Deploys the fee splitter implementation using Create2.
    function _deployFeeSplitter() private {
        bytes32 feeSplitterSalt = _getSalt(saltSeed, "FeeSplitter");
        bytes memory feeSplitterInitCode = RevShareCodeRepo.feeSplitterCreationCode;
        address feeSplitterImpl =
            Utils.getCreate2Address(feeSplitterSalt, feeSplitterInitCode, CREATE2_DEPLOYER);

        // Deploy FeeSplitter implementation
        IOptimismPortal2(payable(portal)).depositTransaction(
            address(CREATE2_DEPLOYER),
            0,
            RevShareGasLimits.FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
            false,
            abi.encodeCall(ICreate2Deployer.deploy, (0, feeSplitterSalt, feeSplitterInitCode))
        );

        // Upgrade FeeSplitter proxy and initialize with address(0) calculator (disabled)
        IOptimismPortal2(payable(portal)).depositTransaction(
            address(PROXY_ADMIN),
            0,
            RevShareGasLimits.UPGRADE_GAS_LIMIT,
            false,
            abi.encodeCall(
                IProxyAdmin.upgradeAndCall,
                (payable(FEE_SPLITTER), feeSplitterImpl, abi.encodeCall(IFeeSplitter.initialize, (address(0))))
            )
        );
    }

    /// @notice Generates a salt from a prefix and suffix.
    /// @param _prefix The prefix for the salt.
    /// @param _suffix The suffix for the salt.
    /// @return The generated salt.
    function _getSalt(string memory _prefix, string memory _suffix) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes(_prefix), bytes(":"), bytes(_suffix)));
    }
}
