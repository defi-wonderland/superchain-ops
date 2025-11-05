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
    struct VaultConfig {
        address proxy;
        address recipient;
        uint256 minWithdrawal;
        uint8 withdrawalNetwork;
    }

    function upgradeContracts(address _portal, string memory _saltSeed, VaultConfig[] memory _vaults) external;
}

/// @notice Template for upgrading vault and fee splitter contracts via RevShareContractsManager.
/// @dev This template upgrades contracts without enabling revenue sharing. Supports multiple L2 chains.
contract RevShareContractsUpgrade is L2TaskBase, RevSharePredeploys {
    using stdToml for string;

    /// @notice Temporary struct for parsing TOML (includes vault array).
    struct TempChainConfig {
        uint256 chainId;
        string saltSeed;
        IRevShareContractsManager.VaultConfig[] vaults;
    }

    /// @notice Struct representing configuration for a single chain upgrade.
    struct ChainConfig {
        uint256 chainId;
        string saltSeed;
    }

    /// @notice The RevShareContractsManager contract to delegatecall.
    address public REVSHARE_MANAGER;

    /// @notice Mapping of chain ID to configuration for the upgrade.
    mapping(uint256 => ChainConfig) public cfg;

    /// @notice Mapping of chain ID to vault configurations (stored separately due to Solidity limitations).
    mapping(uint256 => mapping(uint256 => IRevShareContractsManager.VaultConfig)) public vaultCfg;

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
        // [[revShareUpgrades]]
        // chainId = 10
        // saltSeed = "..."
        // [[revShareUpgrades.vaults]]
        // proxy = "0x..."
        // recipient = "0x..."
        // minWithdrawal = 100000
        // withdrawalNetwork = 1

        // Parse the raw TOML array - we need to parse the struct with vaults array separately
        bytes memory rawConfigs = _toml.parseRaw(".revShareUpgrades");

        // Decode into a temporary struct that includes the vaults array
        TempChainConfig[] memory tempConfigs = abi.decode(rawConfigs, (TempChainConfig[]));

        for (uint256 i = 0; i < tempConfigs.length; i++) {
            TempChainConfig memory tempCfg = tempConfigs[i];
            require(bytes(tempCfg.saltSeed).length != 0, "saltSeed must be set for each chain");
            require(tempCfg.vaults.length == 4, "Must provide exactly 4 vault configurations");

            // Verify chainId is in the l2chains list
            bool chainFound = false;
            for (uint256 j = 0; j < _chains.length; j++) {
                if (_chains[j].chainId == tempCfg.chainId) {
                    chainFound = true;
                    break;
                }
            }
            require(chainFound, "Chain ID not found in l2chains list");

            // Store basic configuration
            cfg[tempCfg.chainId] = ChainConfig({chainId: tempCfg.chainId, saltSeed: tempCfg.saltSeed});

            // Store vault configurations separately
            for (uint256 j = 0; j < 4; j++) {
                require(tempCfg.vaults[j].proxy != address(0), "Vault proxy cannot be zero address");
                vaultCfg[tempCfg.chainId][j] = tempCfg.vaults[j];
            }
        }
    }

    /// @notice Executes the vault and splitter upgrade via delegatecall for each chain.
    function _build(address) internal override {
        SuperchainAddressRegistry.ChainInfo[] memory chains = superchainAddrRegistry.getChains();

        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i].chainId;
            ChainConfig memory chainCfg = cfg[chainId];

            // Get portal address for this chain
            address portal = superchainAddrRegistry.getAddress("OptimismPortal", chainId);
            require(portal != address(0), "OptimismPortal not found for chain");

            // Prepare vault configs array from separate mapping
            IRevShareContractsManager.VaultConfig[] memory vaults =
                new IRevShareContractsManager.VaultConfig[](4);
            for (uint256 j = 0; j < 4; j++) {
                vaults[j] = vaultCfg[chainId][j];
            }

            // Delegatecall to RevShareContractsManager for this chain
            (bool success,) = REVSHARE_MANAGER.delegatecall(
                abi.encodeCall(IRevShareContractsManager.upgradeContracts, (portal, chainCfg.saltSeed, vaults))
            );
            require(success, "RevShareContractsUpgrade: Delegatecall to upgradeContracts failed");
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
