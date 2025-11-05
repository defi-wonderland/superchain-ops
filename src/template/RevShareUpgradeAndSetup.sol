// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {VmSafe} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {L2TaskBase} from "src/tasks/types/L2TaskBase.sol";
import {SuperchainAddressRegistry} from "src/SuperchainAddressRegistry.sol";
import {Action} from "src/libraries/MultisigTypes.sol";
import {RevSharePredeploys} from "src/libraries/RevSharePredeploys.sol";

/// @notice Interface for the RevShareContractsManager.
interface IRevShareContractsManager {
    struct L1WithdrawerConfig {
        uint256 minWithdrawalAmount;
        address recipient;
        uint32 gasLimit;
    }

    function upgradeAndSetupRevShare(
        address _portal,
        string memory _saltSeed,
        L1WithdrawerConfig memory _l1Config,
        address _chainFeesRecipient
    ) external;
}

/// @notice Template for upgrading vault and fee splitter contracts AND enabling revenue sharing.
/// @dev This template performs the complete upgrade and setup with default calculator. Supports multiple L2 chains.
contract RevShareUpgradeAndSetup is L2TaskBase, RevSharePredeploys {
    using stdToml for string;

    /// @notice Struct representing configuration for a single chain.
    struct ChainConfig {
        uint256 chainId;
        string saltSeed;
        uint256 l1WithdrawerMinWithdrawalAmount;
        address l1WithdrawerRecipient;
        uint32 l1WithdrawerGasLimit;
        address chainFeesRecipient;
    }

    /// @notice The RevShareContractsManager contract to delegatecall.
    address public REVSHARE_MANAGER;

    /// @notice Mapping of chain ID to configuration.
    mapping(uint256 => ChainConfig) public cfg;

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
    function _templateSetup(string memory _taskConfigFilePath, address _rootSafe) internal override {
        super._templateSetup(_taskConfigFilePath, _rootSafe);

        string memory _toml = vm.readFile(_taskConfigFilePath);
        SuperchainAddressRegistry.ChainInfo[] memory _chains = superchainAddrRegistry.getChains();

        // Load RevShareContractsManager address
        REVSHARE_MANAGER = _toml.readAddress(".addresses.RevShareContractsManager");
        require(REVSHARE_MANAGER != address(0), "RevShareContractsManager must be set");
        vm.label(REVSHARE_MANAGER, "RevShareContractsManager");

        // Load per-chain configurations
        // Expected TOML structure:
        // [[revShareSetups]]
        // chainId = 10
        // saltSeed = "..."
        // l1WithdrawerMinWithdrawalAmount = 350000
        // l1WithdrawerRecipient = "0x..."
        // l1WithdrawerGasLimit = 800000
        // chainFeesRecipient = "0x..."
        ChainConfig[] memory _configs = abi.decode(_toml.parseRaw(".revShareSetups"), (ChainConfig[]));

        for (uint256 i = 0; i < _configs.length; i++) {
            ChainConfig memory _config = _configs[i];
            require(bytes(_config.saltSeed).length != 0, "saltSeed must be set for each chain");
            require(_config.l1WithdrawerRecipient != address(0), "l1WithdrawerRecipient must be set");
            require(_config.chainFeesRecipient != address(0), "chainFeesRecipient must be set");
            require(_config.l1WithdrawerGasLimit > 0, "l1WithdrawerGasLimit must be greater than 0");

            // Verify chainId is in the l2chains list
            bool chainFound = false;
            for (uint256 j = 0; j < _chains.length; j++) {
                if (_chains[j].chainId == _config.chainId) {
                    chainFound = true;
                    break;
                }
            }
            require(chainFound, "Chain ID not found in l2chains list");

            // Store configuration
            cfg[_config.chainId] = _config;
        }
    }

    /// @notice Executes the vault/splitter upgrade and revenue sharing setup via delegatecall for each chain.
    function _build(address) internal override {
        SuperchainAddressRegistry.ChainInfo[] memory chains = superchainAddrRegistry.getChains();

        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i].chainId;
            ChainConfig memory chainCfg = cfg[chainId];

            // Get portal address for this chain
            address portal = superchainAddrRegistry.getAddress("OptimismPortal", chainId);
            require(portal != address(0), "OptimismPortal not found for chain");

            // Prepare L1Withdrawer config
            IRevShareContractsManager.L1WithdrawerConfig memory l1Config = IRevShareContractsManager
                .L1WithdrawerConfig({
                minWithdrawalAmount: chainCfg.l1WithdrawerMinWithdrawalAmount,
                recipient: chainCfg.l1WithdrawerRecipient,
                gasLimit: chainCfg.l1WithdrawerGasLimit
            });

            // Delegatecall to RevShareContractsManager for this chain
            (bool success,) = REVSHARE_MANAGER.delegatecall(
                abi.encodeCall(
                    IRevShareContractsManager.upgradeAndSetupRevShare,
                    (portal, chainCfg.saltSeed, l1Config, chainCfg.chainFeesRecipient)
                )
            );
            require(success, "RevShareUpgradeAndSetup: Delegatecall to upgradeAndSetupRevShare failed");
        }
    }

    /// @notice Validates the operations executed as expected.
    function _validate(VmSafe.AccountAccess[] memory, Action[] memory, address) internal view override {
        // Basic validation - state changes are validated by the framework
        SuperchainAddressRegistry.ChainInfo[] memory chains = superchainAddrRegistry.getChains();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i].chainId;
            ChainConfig memory chainCfg = cfg[chainId];

            // Verify configuration was loaded
            require(bytes(chainCfg.saltSeed).length != 0, "Configuration not loaded for chain");
        }
    }

    /// @notice Returns list of addresses that should not be checked for code length.
    function _getCodeExceptions() internal view virtual override returns (address[] memory) {}
}
