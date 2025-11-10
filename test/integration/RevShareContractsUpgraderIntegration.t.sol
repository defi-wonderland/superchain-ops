// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevShareContractsManager} from "src/RevShareContractsUpgrader.sol";
import {RevShareUpgradeAndSetup} from "src/template/RevShareUpgradeAndSetup.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {Test} from "forge-std/Test.sol";

enum WithdrawalNetwork {
    L1,
    L2
}

interface IFeeVault {
    function MIN_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function RECIPIENT() external view returns (address);
    function WITHDRAWAL_NETWORK() external view returns (WithdrawalNetwork);
    function minWithdrawalAmount() external view returns (uint256);
    function recipient() external view returns (address);
    function withdrawalNetwork() external view returns (WithdrawalNetwork);
}

interface IFeeSplitter {
    function sharesCalculator() external view returns (address);
}

interface IL1Withdrawer {
    function minWithdrawalAmount() external view returns (uint256);
    function recipient() external view returns (address);
    function withdrawalGasLimit() external view returns (uint32);
}

interface ISuperchainRevSharesCalculator {
    function shareRecipient() external view returns (address payable);
    function remainderRecipient() external view returns (address payable);
}

contract RevShareContractsUpgraderIntegrationTest is IntegrationBase {
    RevShareContractsManager public revShareManager;
    RevShareUpgradeAndSetup public revShareTask;

    // Fork IDs
    uint256 internal _mainnetForkId;
    uint256 internal _opMainnetForkId;
    uint256 internal _inkMainnetForkId;

    // L1 addresses
    address internal constant PROXY_ADMIN_OWNER = 0x5a0Aae59D09fccBdDb6C6CcEB07B7279367C3d2A;
    address internal constant OP_MAINNET_PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address internal constant INK_MAINNET_PORTAL = 0x5d66C1782664115999C47c9fA5cd031f495D3e4F;
    address internal constant REV_SHARE_MANAGER_ADDRESS = 0x0000000000000000000000000000000000001337;

    // L2 predeploys (same across all OP Stack chains)
    address internal constant SEQUENCER_FEE_VAULT = 0x4200000000000000000000000000000000000011;
    address internal constant OPERATOR_FEE_VAULT = 0x420000000000000000000000000000000000001b;
    address internal constant BASE_FEE_VAULT = 0x4200000000000000000000000000000000000019;
    address internal constant L1_FEE_VAULT = 0x420000000000000000000000000000000000001A;
    address internal constant FEE_SPLITTER = 0x420000000000000000000000000000000000002B;

    // Expected deployed contracts (deterministic CREATE2 addresses)
    address internal constant L1_WITHDRAWER = 0xB3AeB34b88D73Fb4832f65BEa5Bd865017fB5daC;
    address internal constant REV_SHARE_CALCULATOR = 0x3E806Fd8592366E850197FEC8D80608b5526Bba2;

    // Test configuration
    uint256 internal constant MIN_WITHDRAWAL_AMOUNT = 350000;
    address internal constant L1_WITHDRAWAL_RECIPIENT = address(1); // Placeholder
    uint32 internal constant WITHDRAWAL_GAS_LIMIT = 800000;
    address internal constant CHAIN_FEES_RECIPIENT = address(1); // Placeholder

    function setUp() public {
        // Create forks for L1 (mainnet) and L2 (OP Mainnet)
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _opMainnetForkId = vm.createFork("http://127.0.0.1:9545");
        _inkMainnetForkId = vm.createFork("http://127.0.0.1:9546");

        // Deploy contracts on L1
        vm.selectFork(_mainnetForkId);

        // Deploy RevShareContractsManager and etch at predetermined address
        revShareManager = new RevShareContractsManager();
        vm.etch(REV_SHARE_MANAGER_ADDRESS, address(revShareManager).code);
        revShareManager = RevShareContractsManager(REV_SHARE_MANAGER_ADDRESS);

        // Deploy RevShareUpgradeAndSetup task
        revShareTask = new RevShareUpgradeAndSetup();
    }

    /// @notice Test the integration of upgradeAndSetupRevShare
    function test_upgradeAndSetupRevShare_integration() public {
        // Step 1: Record logs for L1→L2 message replay
        vm.recordLogs();

        // Step 2: Execute task simulation
        revShareTask.simulate("test/tasks/example/eth/018-revshare-upgrade-and-setup/config.toml");

        // Step 3: Relay deposit transactions from L1 to all L2s
        uint256[] memory forkIds = new uint256[](2);
        forkIds[0] = _opMainnetForkId;
        forkIds[1] = _inkMainnetForkId;

        address[] memory portals = new address[](2);
        portals[0] = OP_MAINNET_PORTAL;
        portals[1] = INK_MAINNET_PORTAL;

        _relayAllMessages(forkIds, true, portals);

        // Step 4: Assert the state of the OP Mainnet contracts
        vm.selectFork(_opMainnetForkId);
        _assertL2State();

        // Step 5: Assert the state of the Ink Mainnet contracts
        vm.selectFork(_inkMainnetForkId);
        _assertL2State();
    }

    /// @notice Assert the state of all L2 contracts after upgrade
    function _assertL2State() internal view {
        // L1Withdrawer: check configuration
        assertEq(IL1Withdrawer(L1_WITHDRAWER).minWithdrawalAmount(), MIN_WITHDRAWAL_AMOUNT, "L1Withdrawer minWithdrawalAmount mismatch");
        assertEq(IL1Withdrawer(L1_WITHDRAWER).recipient(), L1_WITHDRAWAL_RECIPIENT, "L1Withdrawer recipient mismatch");
        assertEq(IL1Withdrawer(L1_WITHDRAWER).withdrawalGasLimit(), WITHDRAWAL_GAS_LIMIT, "L1Withdrawer gasLimit mismatch");

        // Rev Share Calculator: check it's linked correctly
        assertEq(
            ISuperchainRevSharesCalculator(REV_SHARE_CALCULATOR).shareRecipient(),
            L1_WITHDRAWER,
            "Calculator shareRecipient should be L1Withdrawer"
        );
        assertEq(
            ISuperchainRevSharesCalculator(REV_SHARE_CALCULATOR).remainderRecipient(),
            CHAIN_FEES_RECIPIENT,
            "Calculator remainderRecipient mismatch"
        );

        // Fee Splitter: check calculator is set
        assertEq(
            IFeeSplitter(FEE_SPLITTER).sharesCalculator(),
            REV_SHARE_CALCULATOR,
            "FeeSplitter calculator should be set to RevShareCalculator"
        );

        // Vaults: recipient should be fee splitter, withdrawal network should be L2, min withdrawal amount 0
        _assertFeeVaultsState();
    }

    /// @notice Assert the configuration of all fee vaults
    function _assertFeeVaultsState() internal view {
        _assertVaultGetters(SEQUENCER_FEE_VAULT, FEE_SPLITTER, WithdrawalNetwork.L2, 0);
        _assertVaultGetters(OPERATOR_FEE_VAULT, FEE_SPLITTER, WithdrawalNetwork.L2, 0);
        _assertVaultGetters(BASE_FEE_VAULT, FEE_SPLITTER, WithdrawalNetwork.L2, 0);
        _assertVaultGetters(L1_FEE_VAULT, FEE_SPLITTER, WithdrawalNetwork.L2, 0);
    }

    /// @notice Assert the configuration of a single fee vault
    /// @param _vault The address of the fee vault
    /// @param _recipient The expected recipient of the fee vault
    /// @param _withdrawalNetwork The expected withdrawal network
    /// @param _minWithdrawalAmount The expected minimum withdrawal amount
    /// @dev Ensures both the legacy and the new getters return the same value
    function _assertVaultGetters(
        address _vault,
        address _recipient,
        WithdrawalNetwork _withdrawalNetwork,
        uint256 _minWithdrawalAmount
    ) internal view {
        // Check new getters
        assertEq(IFeeVault(_vault).recipient(), _recipient, "Vault recipient mismatch");
        assertEq(
            uint256(IFeeVault(_vault).withdrawalNetwork()),
            uint256(_withdrawalNetwork),
            "Vault withdrawalNetwork mismatch"
        );
        assertEq(IFeeVault(_vault).minWithdrawalAmount(), _minWithdrawalAmount, "Vault minWithdrawalAmount mismatch");

        // Check legacy getters (should return same values)
        assertEq(IFeeVault(_vault).RECIPIENT(), _recipient, "Vault RECIPIENT (legacy) mismatch");
        assertEq(
            uint256(IFeeVault(_vault).WITHDRAWAL_NETWORK()),
            uint256(_withdrawalNetwork),
            "Vault WITHDRAWAL_NETWORK (legacy) mismatch"
        );
        assertEq(
            IFeeVault(_vault).MIN_WITHDRAWAL_AMOUNT(),
            _minWithdrawalAmount,
            "Vault MIN_WITHDRAWAL_AMOUNT (legacy) mismatch"
        );
    }
}
