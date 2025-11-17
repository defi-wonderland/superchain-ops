// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";
import {RevShareSetup} from "src/template/RevShareSetup.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {Test} from "forge-std/Test.sol";

// Interfaces
import {IOptimismPortal2} from "@eth-optimism-bedrock/interfaces/L1/IOptimismPortal2.sol";
import {IProxyAdmin} from "@eth-optimism-bedrock/interfaces/universal/IProxyAdmin.sol";
import {ICreate2Deployer} from "src/interfaces/ICreate2Deployer.sol";
import {IFeeSplitter} from "src/interfaces/IFeeSplitter.sol";
import {IFeeVault} from "src/interfaces/IFeeVault.sol";
import {IL1Withdrawer} from "src/interfaces/IL1Withdrawer.sol";
import {ISuperchainRevSharesCalculator} from "src/interfaces/ISuperchainRevSharesCalculator.sol";

// Import libraries for manual vault upgrade
import {FeeVaultUpgrader} from "src/libraries/FeeVaultUpgrader.sol";
import {FeeSplitterSetup} from "src/libraries/FeeSplitterSetup.sol";

contract RevShareSetupIntegrationTest is IntegrationBase {
    RevShareContractsUpgrader public revShareUpgrader;
    RevShareSetup public revShareTask;

    // Fork IDs
    uint256 internal _mainnetForkId;
    uint256 internal _opSepoliaForkId;

    // L1 addresses
    address internal constant PROXY_ADMIN_OWNER = 0x1Eb2fFc903729a0F03966B917003800b145F56E2;
    address internal constant OP_SEPOLIA_PORTAL = 0x16Fc5058F25648194471939df75CF27A2fdC48BC;
    address internal constant REV_SHARE_UPGRADER_ADDRESS = 0x890C61C7F3f40B851EbCAacFA879C6075426419D;

    // L2 predeploys (same across all OP Stack chains)
    address internal constant SEQUENCER_FEE_VAULT = 0x4200000000000000000000000000000000000011;
    address internal constant OPERATOR_FEE_VAULT = 0x420000000000000000000000000000000000001b;
    address internal constant BASE_FEE_VAULT = 0x4200000000000000000000000000000000000019;
    address internal constant L1_FEE_VAULT = 0x420000000000000000000000000000000000001A;
    address internal constant FEE_SPLITTER = 0x420000000000000000000000000000000000002B;
    address internal constant PROXY_ADMIN = 0x4200000000000000000000000000000000000018;

    // Expected deployed contracts (deterministic CREATE2 addresses)
    address internal constant OP_L1_WITHDRAWER = 0xB3AeB34b88D73Fb4832f65BEa5Bd865017fB5daC;
    address internal constant OP_REV_SHARE_CALCULATOR = 0x3E806Fd8592366E850197FEC8D80608b5526Bba2;

    // Test configuration - OP Sepolia
    uint256 internal constant OP_MIN_WITHDRAWAL_AMOUNT = 350000;
    address internal constant OP_L1_WITHDRAWAL_RECIPIENT = 0x0000000000000000000000000000000000000001;
    uint32 internal constant OP_WITHDRAWAL_GAS_LIMIT = 800000;
    address internal constant OP_CHAIN_FEES_RECIPIENT = 0x0000000000000000000000000000000000000001;

    bool internal constant IS_SIMULATE = true;

    function setUp() public {
        // Create forks for L1 (mainnet) and L2 (OP Sepolia)
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _opSepoliaForkId = vm.createFork("http://127.0.0.1:9545");

        // Deploy contracts on L1
        vm.selectFork(_mainnetForkId);

        // Deploy RevShareContractsUpgrader and etch at predetermined address
        revShareUpgrader = new RevShareContractsUpgrader();
        vm.etch(REV_SHARE_UPGRADER_ADDRESS, address(revShareUpgrader).code);
        revShareUpgrader = RevShareContractsUpgrader(REV_SHARE_UPGRADER_ADDRESS);

        // Deploy RevShareSetup task
        revShareTask = new RevShareSetup();

        // Manually upgrade vaults on L2 using vm.etch
        vm.selectFork(_opSepoliaForkId);
        _manuallyUpgradeVaults();
        _manuallyInitializeFeeSplitter();
    }

    /// @notice Manually upgrade all 4 fee vaults using vm.etch to simulate pre-upgraded state
    function _manuallyUpgradeVaults() internal {
        // Deploy vault implementations using creation codes from FeeVaultUpgrader
        address operatorVaultImpl;
        address sequencerVaultImpl;
        address baseFeeVaultImpl;
        address l1FeeVaultImpl;

        // Deploy OperatorFeeVault
        bytes memory operatorCode = FeeVaultUpgrader.operatorFeeVaultCreationCode;
        assembly {
            operatorVaultImpl := create(0, add(operatorCode, 0x20), mload(operatorCode))
        }
        require(operatorVaultImpl != address(0), "OperatorFeeVault deployment failed");

        // Deploy SequencerFeeVault
        bytes memory sequencerCode = FeeVaultUpgrader.sequencerFeeVaultCreationCode;
        assembly {
            sequencerVaultImpl := create(0, add(sequencerCode, 0x20), mload(sequencerCode))
        }
        require(sequencerVaultImpl != address(0), "SequencerFeeVault deployment failed");

        // Deploy BaseFeeVault (using default)
        bytes memory defaultCode = FeeVaultUpgrader.defaultFeeVaultCreationCode;
        assembly {
            baseFeeVaultImpl := create(0, add(defaultCode, 0x20), mload(defaultCode))
        }
        require(baseFeeVaultImpl != address(0), "BaseFeeVault deployment failed");

        // L1FeeVault uses the same implementation as BaseFeeVault
        l1FeeVaultImpl = baseFeeVaultImpl;

        // Get the implementation slot (EIP-1967: bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1))
        bytes32 IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

        // Set implementations in proxy storage
        vm.store(OPERATOR_FEE_VAULT, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(operatorVaultImpl))));
        vm.store(SEQUENCER_FEE_VAULT, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(sequencerVaultImpl))));
        vm.store(BASE_FEE_VAULT, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(baseFeeVaultImpl))));
        vm.store(L1_FEE_VAULT, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(l1FeeVaultImpl))));
    }

    /// @notice Manually initialize FeeSplitter using vm.etch to simulate pre-initialized state
    function _manuallyInitializeFeeSplitter() internal {
        // Deploy FeeSplitter implementation using creation code from FeeSplitterSetup
        address feeSplitterImpl;
        bytes memory feeSplitterCode = FeeSplitterSetup.feeSplitterCreationCode;
        assembly {
            feeSplitterImpl := create(0, add(feeSplitterCode, 0x20), mload(feeSplitterCode))
        }
        require(feeSplitterImpl != address(0), "FeeSplitter deployment failed");

        // Get the implementation slot (EIP-1967: bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1))
        bytes32 IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

        // Set implementation in proxy storage
        vm.store(FEE_SPLITTER, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(feeSplitterImpl))));

        // Initialize the FeeSplitter with a dummy calculator (will be replaced by setupRevShare)
        // We need to initialize it so setupRevShare can call setSharesCalculator
        address dummyCalculator = address(0x1234567890123456789012345678901234567890);

        // Prank as ProxyAdmin owner to initialize
        vm.prank(PROXY_ADMIN);
        IFeeSplitter(FEE_SPLITTER).initialize(dummyCalculator);
    }

    /// @notice Test the integration of setupRevShare
    function test_setupRevShare_integration() public {
        // Switch back to L1 for task execution
        vm.selectFork(_mainnetForkId);

        // Step 1: Record logs for L1→L2 message replay
        vm.recordLogs();

        // Step 2: Execute task simulation
        revShareTask.simulate("test/tasks/example/sep/031-revshare-setup/config.toml");

        // Step 3: Relay deposit transactions from L1 to L2
        uint256[] memory forkIds = new uint256[](1);
        forkIds[0] = _opSepoliaForkId;

        address[] memory portals = new address[](1);
        portals[0] = OP_SEPOLIA_PORTAL;

        _relayAllMessages(forkIds, IS_SIMULATE, portals);

        // Step 4: Assert the state of the OP Sepolia contracts
        vm.selectFork(_opSepoliaForkId);
        _assertL2State(
            OP_L1_WITHDRAWER,
            OP_REV_SHARE_CALCULATOR,
            OP_MIN_WITHDRAWAL_AMOUNT,
            OP_L1_WITHDRAWAL_RECIPIENT,
            OP_WITHDRAWAL_GAS_LIMIT,
            OP_CHAIN_FEES_RECIPIENT
        );
    }

    /// @notice Assert the state of all L2 contracts after setup
    /// @param _l1Withdrawer Expected L1Withdrawer address
    /// @param _revShareCalculator Expected RevShareCalculator address
    /// @param _minWithdrawalAmount Expected minimum withdrawal amount for L1Withdrawer
    /// @param _l1Recipient Expected recipient address for L1Withdrawer
    /// @param _gasLimit Expected gas limit for L1Withdrawer
    /// @param _chainFeesRecipient Expected chain fees recipient (remainder recipient)
    function _assertL2State(
        address _l1Withdrawer,
        address _revShareCalculator,
        uint256 _minWithdrawalAmount,
        address _l1Recipient,
        uint32 _gasLimit,
        address _chainFeesRecipient
    ) internal view {
        // L1Withdrawer: check configuration
        assertEq(
            IL1Withdrawer(_l1Withdrawer).minWithdrawalAmount(),
            _minWithdrawalAmount,
            "L1Withdrawer minWithdrawalAmount mismatch"
        );
        assertEq(IL1Withdrawer(_l1Withdrawer).recipient(), _l1Recipient, "L1Withdrawer recipient mismatch");
        assertEq(IL1Withdrawer(_l1Withdrawer).withdrawalGasLimit(), _gasLimit, "L1Withdrawer gasLimit mismatch");

        // Rev Share Calculator: check it's linked correctly
        assertEq(
            ISuperchainRevSharesCalculator(_revShareCalculator).shareRecipient(),
            _l1Withdrawer,
            "Calculator shareRecipient should be L1Withdrawer"
        );
        assertEq(
            ISuperchainRevSharesCalculator(_revShareCalculator).remainderRecipient(),
            _chainFeesRecipient,
            "Calculator remainderRecipient mismatch"
        );

        // Fee Splitter: check calculator is set
        assertEq(
            IFeeSplitter(FEE_SPLITTER).sharesCalculator(),
            _revShareCalculator,
            "FeeSplitter calculator should be set to RevShareCalculator"
        );

        // Vaults: recipient should be fee splitter, withdrawal network should be L2, min withdrawal amount 0
        _assertFeeVaultsState();
    }

    /// @notice Assert the configuration of all fee vaults
    function _assertFeeVaultsState() internal view {
        _assertVaultGetters(SEQUENCER_FEE_VAULT, FEE_SPLITTER, IFeeVault.WithdrawalNetwork.L2, 0);
        _assertVaultGetters(OPERATOR_FEE_VAULT, FEE_SPLITTER, IFeeVault.WithdrawalNetwork.L2, 0);
        _assertVaultGetters(BASE_FEE_VAULT, FEE_SPLITTER, IFeeVault.WithdrawalNetwork.L2, 0);
        _assertVaultGetters(L1_FEE_VAULT, FEE_SPLITTER, IFeeVault.WithdrawalNetwork.L2, 0);
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
        IFeeVault.WithdrawalNetwork _withdrawalNetwork,
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
