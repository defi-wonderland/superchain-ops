// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";
import {RevShareSetup} from "src/template/RevShareSetup.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {Test} from "forge-std/Test.sol";
import {FeeVaultUpgrader} from "src/libraries/FeeVaultUpgrader.sol";
import {FeeSplitterSetup} from "src/libraries/FeeSplitterSetup.sol";
import {RevShareCommon} from "src/libraries/RevShareCommon.sol";
import {Proxy} from "@eth-optimism-bedrock/src/universal/Proxy.sol";
import {Predeploys} from "@eth-optimism-bedrock/src/libraries/Predeploys.sol";

// Interfaces
import {IOptimismPortal2} from "@eth-optimism-bedrock/interfaces/L1/IOptimismPortal2.sol";
import {IProxyAdmin} from "@eth-optimism-bedrock/interfaces/universal/IProxyAdmin.sol";
import {ICreate2Deployer} from "src/interfaces/ICreate2Deployer.sol";
import {IFeeSplitter} from "src/interfaces/IFeeSplitter.sol";
import {IFeeVault} from "src/interfaces/IFeeVault.sol";
import {IL1Withdrawer} from "src/interfaces/IL1Withdrawer.sol";
import {ISuperchainRevSharesCalculator} from "src/interfaces/ISuperchainRevSharesCalculator.sol";

contract RevShareContractsUpgraderIntegrationTest is IntegrationBase {
    RevShareContractsUpgrader public revShareUpgrader;
    RevShareSetup public revShareTask;

    // Events for testing
    event WithdrawalInitiated(address indexed recipient, uint256 amount);

    // Fork IDs
    uint256 internal _mainnetForkId;
    uint256 internal _opMainnetForkId;
    uint256 internal _inkMainnetForkId;

    // L1 addresses
    address internal constant PROXY_ADMIN_OWNER = 0x5a0Aae59D09fccBdDb6C6CcEB07B7279367C3d2A;
    address internal constant OP_MAINNET_PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address internal constant INK_MAINNET_PORTAL = 0x5d66C1782664115999C47c9fA5cd031f495D3e4F;
    address internal constant REV_SHARE_UPGRADER_ADDRESS = 0x0000000000000000000000000000000000001337;

    // L2 predeploys (same across all OP Stack chains)
    address internal constant SEQUENCER_FEE_VAULT = 0x4200000000000000000000000000000000000011;
    address internal constant OPERATOR_FEE_VAULT = 0x420000000000000000000000000000000000001b;
    address internal constant BASE_FEE_VAULT = 0x4200000000000000000000000000000000000019;
    address internal constant L1_FEE_VAULT = 0x420000000000000000000000000000000000001A;
    address internal constant FEE_SPLITTER = 0x420000000000000000000000000000000000002B;

    // EIP-1967 storage slots for proxy
    bytes32 internal constant PROXY_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant PROXY_OWNER_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Expected deployed contracts (deterministic CREATE2 addresses)
    address internal constant OP_L1_WITHDRAWER = 0xB3AeB34b88D73Fb4832f65BEa5Bd865017fB5daC;
    address internal constant OP_REV_SHARE_CALCULATOR = 0x3E806Fd8592366E850197FEC8D80608b5526Bba2;

    address internal constant INK_L1_WITHDRAWER = 0x70e26B12a578176BccCD3b7e7f58f605871c5eF7;
    address internal constant INK_REV_SHARE_CALCULATOR = 0xd7a5307B4Ce92B0269903191007b95dF42552Dfa;

    // Test configuration - OP Mainnet
    uint256 internal constant OP_MIN_WITHDRAWAL_AMOUNT = 350000;
    address internal constant OP_L1_WITHDRAWAL_RECIPIENT = 0x0000000000000000000000000000000000000001;
    uint32 internal constant OP_WITHDRAWAL_GAS_LIMIT = 800000;
    address internal constant OP_CHAIN_FEES_RECIPIENT = 0x0000000000000000000000000000000000000001;

    // Test configuration - Ink Mainnet
    uint256 internal constant INK_MIN_WITHDRAWAL_AMOUNT = 500000;
    address internal constant INK_L1_WITHDRAWAL_RECIPIENT = 0x0000000000000000000000000000000000000002;
    uint32 internal constant INK_WITHDRAWAL_GAS_LIMIT = 1000000;
    address internal constant INK_CHAIN_FEES_RECIPIENT = 0x0000000000000000000000000000000000000002;

    bool internal constant IS_SIMULATE = true;

    // Creation codes from libraries (cannot be constant as they reference library constants)
    bytes internal OPERATOR_FEE_VAULT_CREATION_CODE = FeeVaultUpgrader.operatorFeeVaultCreationCode;
    bytes internal SEQUENCER_FEE_VAULT_CREATION_CODE = FeeVaultUpgrader.sequencerFeeVaultCreationCode;
    bytes internal DEFAULT_FEE_VAULT_CREATION_CODE = FeeVaultUpgrader.defaultFeeVaultCreationCode;
    bytes internal FEE_SPLITTER_CREATION_CODE = FeeSplitterSetup.feeSplitterCreationCode;

    function setUp() public {
        // Create forks for L1 (mainnet) and L2 (OP Mainnet)
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _opMainnetForkId = vm.createFork("http://127.0.0.1:9545");
        _inkMainnetForkId = vm.createFork("http://127.0.0.1:9546");

        // Deploy contracts on L1
        vm.selectFork(_mainnetForkId);

        // Deploy RevShareContractsUpgrader and etch at predetermined address
        revShareUpgrader = new RevShareContractsUpgrader();
        vm.etch(REV_SHARE_UPGRADER_ADDRESS, address(revShareUpgrader).code);
        revShareUpgrader = RevShareContractsUpgrader(REV_SHARE_UPGRADER_ADDRESS);

        // Deploy RevShareSetup task
        revShareTask = new RevShareSetup();

        // Deploy implementations once to get their addresses and bytecode
        address operatorFeeVaultImpl = _deployFromCreationCode(OPERATOR_FEE_VAULT_CREATION_CODE);
        address sequencerFeeVaultImpl = _deployFromCreationCode(SEQUENCER_FEE_VAULT_CREATION_CODE);
        address defaultFeeVaultImpl = _deployFromCreationCode(DEFAULT_FEE_VAULT_CREATION_CODE);
        address feeSplitterImpl = _deployFromCreationCode(FEE_SPLITTER_CREATION_CODE);

        // Get implementation bytecodes
        bytes memory operatorFeeVaultImplCode = operatorFeeVaultImpl.code;
        bytes memory sequencerFeeVaultImplCode = sequencerFeeVaultImpl.code;
        bytes memory defaultFeeVaultImplCode = defaultFeeVaultImpl.code;
        bytes memory feeSplitterImplCode = feeSplitterImpl.code;

        // Deploy a proxy to get its bytecode
        Proxy proxyTemplate = new Proxy(address(this));
        bytes memory proxyCode = address(proxyTemplate).code;

        // Etch predeploys on OP Mainnet fork
        vm.selectFork(_opMainnetForkId);
        _etchImplementations(
            operatorFeeVaultImpl,
            sequencerFeeVaultImpl,
            defaultFeeVaultImpl,
            feeSplitterImpl,
            operatorFeeVaultImplCode,
            sequencerFeeVaultImplCode,
            defaultFeeVaultImplCode,
            feeSplitterImplCode
        );
        _setupProxyPredeploys(
            proxyCode, operatorFeeVaultImpl, sequencerFeeVaultImpl, defaultFeeVaultImpl, feeSplitterImpl
        );

        // Etch predeploys on Ink Mainnet fork
        vm.selectFork(_inkMainnetForkId);
        _etchImplementations(
            operatorFeeVaultImpl,
            sequencerFeeVaultImpl,
            defaultFeeVaultImpl,
            feeSplitterImpl,
            operatorFeeVaultImplCode,
            sequencerFeeVaultImplCode,
            defaultFeeVaultImplCode,
            feeSplitterImplCode
        );
        _setupProxyPredeploys(
            proxyCode, operatorFeeVaultImpl, sequencerFeeVaultImpl, defaultFeeVaultImpl, feeSplitterImpl
        );

        // Switch back to mainnet fork after setup
        vm.selectFork(_mainnetForkId);
    }

    /// @notice Test the integration of setupRevShare
    function test_setupRevShare_integration() public {
        // Step 1: Record logs for L1→L2 message replay
        vm.recordLogs();

        // Step 2: Execute task simulation
        revShareTask.simulate("test/tasks/example/eth/017-revshare-setup/config.toml");

        // Step 3: Relay deposit transactions from L1 to all L2s
        uint256[] memory forkIds = new uint256[](2);
        forkIds[0] = _opMainnetForkId;
        forkIds[1] = _inkMainnetForkId;

        address[] memory portals = new address[](2);
        portals[0] = OP_MAINNET_PORTAL;
        portals[1] = INK_MAINNET_PORTAL;

        _relayAllMessages(forkIds, IS_SIMULATE, portals);

        // Step 4: Assert the state of the OP Mainnet contracts
        vm.selectFork(_opMainnetForkId);
        _assertL2State(
            OP_L1_WITHDRAWER,
            OP_REV_SHARE_CALCULATOR,
            OP_MIN_WITHDRAWAL_AMOUNT,
            OP_L1_WITHDRAWAL_RECIPIENT,
            OP_WITHDRAWAL_GAS_LIMIT,
            OP_CHAIN_FEES_RECIPIENT
        );

        // Step 5: Assert the state of the Ink Mainnet contracts
        vm.selectFork(_inkMainnetForkId);
        _assertL2State(
            INK_L1_WITHDRAWER,
            INK_REV_SHARE_CALCULATOR,
            INK_MIN_WITHDRAWAL_AMOUNT,
            INK_L1_WITHDRAWAL_RECIPIENT,
            INK_WITHDRAWAL_GAS_LIMIT,
            INK_CHAIN_FEES_RECIPIENT
        );

        // Step 6: Do a withdrawal flow

        // Fund vaults with amount > minWithdrawalAmount
        _fundVaults(1 ether, _opMainnetForkId);
        _fundVaults(1 ether, _inkMainnetForkId);

        // Disburse fees in both chains and expect the L1Withdrawer to trigger the withdrawal
        // Expected L1Withdrawer share = 3 ether * 15% = 0.45 ether
        // It is 3 ether instead of 4 because net revenue doesn't count L1FeeVault's balance
        // For details on the rev share calculation, check the SuperchainRevSharesCalculator contract.
        // https://github.com/ethereum-optimism/optimism/blob/f392d4b7e8bc5d1c8d38fcf19c8848764f8bee3b/packages/contracts-bedrock/src/L2/SuperchainRevSharesCalculator.sol#L67-L101
        uint256 expectedWithdrawalAmount = 0.45 ether;

        _executeDisburseAndAssertWithdrawal(_opMainnetForkId, OP_L1_WITHDRAWAL_RECIPIENT, expectedWithdrawalAmount);
        _executeDisburseAndAssertWithdrawal(_inkMainnetForkId, INK_L1_WITHDRAWAL_RECIPIENT, expectedWithdrawalAmount);
    }

    function _fundVaults(uint256 _amount, uint256 _forkId) internal {
        vm.selectFork(_forkId);
        vm.deal(SEQUENCER_FEE_VAULT, _amount);
        vm.deal(OPERATOR_FEE_VAULT, _amount);
        vm.deal(BASE_FEE_VAULT, _amount);
        vm.deal(L1_FEE_VAULT, _amount);
    }

    /// @notice Assert the state of all L2 contracts after upgrade
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

    /// @notice Setup proxy predeploys pointing to implementations
    /// @param _proxyCode Proxy runtime bytecode
    /// @param _operatorFeeVaultImpl OperatorFeeVault implementation address
    /// @param _sequencerFeeVaultImpl SequencerFeeVault implementation address
    /// @param _defaultFeeVaultImpl Default FeeVault implementation address (for Base and L1)
    /// @param _feeSplitterImpl FeeSplitter implementation address
    function _setupProxyPredeploys(
        bytes memory _proxyCode,
        address _operatorFeeVaultImpl,
        address _sequencerFeeVaultImpl,
        address _defaultFeeVaultImpl,
        address _feeSplitterImpl
    ) internal {
        // Setup OperatorFeeVault proxy
        vm.etch(OPERATOR_FEE_VAULT, _proxyCode);
        vm.store(OPERATOR_FEE_VAULT, PROXY_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(_operatorFeeVaultImpl))));
        vm.store(OPERATOR_FEE_VAULT, PROXY_OWNER_SLOT, bytes32(uint256(uint160(RevShareCommon.PROXY_ADMIN))));

        // Setup SequencerFeeVault proxy
        vm.etch(SEQUENCER_FEE_VAULT, _proxyCode);
        vm.store(SEQUENCER_FEE_VAULT, PROXY_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(_sequencerFeeVaultImpl))));
        vm.store(SEQUENCER_FEE_VAULT, PROXY_OWNER_SLOT, bytes32(uint256(uint160(RevShareCommon.PROXY_ADMIN))));

        // Setup BaseFeeVault proxy
        vm.etch(BASE_FEE_VAULT, _proxyCode);
        vm.store(BASE_FEE_VAULT, PROXY_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(_defaultFeeVaultImpl))));
        vm.store(BASE_FEE_VAULT, PROXY_OWNER_SLOT, bytes32(uint256(uint160(RevShareCommon.PROXY_ADMIN))));

        // Setup L1FeeVault proxy
        vm.etch(L1_FEE_VAULT, _proxyCode);
        vm.store(L1_FEE_VAULT, PROXY_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(_defaultFeeVaultImpl))));
        vm.store(L1_FEE_VAULT, PROXY_OWNER_SLOT, bytes32(uint256(uint160(RevShareCommon.PROXY_ADMIN))));

        // Setup FeeSplitter proxy
        vm.etch(FEE_SPLITTER, _proxyCode);
        vm.store(FEE_SPLITTER, PROXY_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(_feeSplitterImpl))));
        vm.store(FEE_SPLITTER, PROXY_OWNER_SLOT, bytes32(uint256(uint160(RevShareCommon.PROXY_ADMIN))));
    }

    /// @notice Deploy a contract from creation code
    /// @param _creationCode The creation code of the contract to deploy
    /// @return deployed The address of the deployed contract
    function _deployFromCreationCode(bytes memory _creationCode) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(_creationCode, 0x20), mload(_creationCode))
        }
        require(deployed != address(0), "Deployment failed");
    }

    /// @notice Etch implementation bytecode at addresses on the current fork
    /// @param _operatorFeeVaultImpl OperatorFeeVault implementation address
    /// @param _sequencerFeeVaultImpl SequencerFeeVault implementation address
    /// @param _defaultFeeVaultImpl Default FeeVault implementation address
    /// @param _feeSplitterImpl FeeSplitter implementation address
    /// @param _operatorFeeVaultImplCode OperatorFeeVault implementation bytecode
    /// @param _sequencerFeeVaultImplCode SequencerFeeVault implementation bytecode
    /// @param _defaultFeeVaultImplCode Default FeeVault implementation bytecode
    /// @param _feeSplitterImplCode FeeSplitter implementation bytecode
    function _etchImplementations(
        address _operatorFeeVaultImpl,
        address _sequencerFeeVaultImpl,
        address _defaultFeeVaultImpl,
        address _feeSplitterImpl,
        bytes memory _operatorFeeVaultImplCode,
        bytes memory _sequencerFeeVaultImplCode,
        bytes memory _defaultFeeVaultImplCode,
        bytes memory _feeSplitterImplCode
    ) internal {
        vm.etch(_operatorFeeVaultImpl, _operatorFeeVaultImplCode);
        vm.etch(_sequencerFeeVaultImpl, _sequencerFeeVaultImplCode);
        vm.etch(_defaultFeeVaultImpl, _defaultFeeVaultImplCode);
        vm.etch(_feeSplitterImpl, _feeSplitterImplCode);
    }

    /// @notice Execute disburseFees and assert that it triggers a withdrawal with the expected amount
    /// @param _forkId The fork ID of the chain to test
    /// @param _l1WithdrawalRecipient The expected recipient of the withdrawal
    /// @param _expectedWithdrawalAmount The expected withdrawal amount
    function _executeDisburseAndAssertWithdrawal(
        uint256 _forkId,
        address _l1WithdrawalRecipient,
        uint256 _expectedWithdrawalAmount
    ) internal {
        vm.selectFork(_forkId);
        vm.warp(block.timestamp + IFeeSplitter(FEE_SPLITTER).feeDisbursementInterval() + 1);

        uint256 balanceBefore = Predeploys.L2_TO_L1_MESSAGE_PASSER.balance;

        vm.expectEmit(true, true, true, true);
        emit WithdrawalInitiated(_l1WithdrawalRecipient, _expectedWithdrawalAmount);
        IFeeSplitter(FEE_SPLITTER).disburseFees();

        uint256 balanceAfter = Predeploys.L2_TO_L1_MESSAGE_PASSER.balance;

        assertEq(balanceAfter - balanceBefore, _expectedWithdrawalAmount);
    }
}
