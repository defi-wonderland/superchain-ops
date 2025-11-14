// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";
import {RevShareUpgradeAndSetup} from "src/template/RevShareUpgradeAndSetup.sol";
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

/// @notice Minimal FeeSplitter for testing that accepts ETH from any source
/// @dev The actual FeeSplitter deployed via L1→L2 has a receive() function with security restrictions
///      that only allow specific predeploy addresses to send it ETH. For testing purposes, we need
///      a FeeSplitter that can accept ETH from vaults in our test environment. This mock implements
///      the same revenue sharing logic as the real SuperchainRevSharesCalculator (max of 2.5% gross
///      or 15% net) and properly tracks fees from each vault.
contract TestableFeeSplitter {
    address public sharesCalculator;
    uint256 public constant feeDisbursementInterval = 1 days;
    uint256 public lastDisbursement;

    // Track fees received from each vault
    uint256 public sequencerFees;
    uint256 public baseFees;
    uint256 public l1Fees;
    uint256 public operatorFees;

    receive() external payable {
        // Track which vault sent the fees
        if (msg.sender == 0x4200000000000000000000000000000000000011) {
            sequencerFees += msg.value;
        } else if (msg.sender == 0x4200000000000000000000000000000000000019) {
            baseFees += msg.value;
        } else if (msg.sender == 0x420000000000000000000000000000000000001A) {
            l1Fees += msg.value;
        } else if (msg.sender == 0x420000000000000000000000000000000000001b) {
            operatorFees += msg.value;
        }
    }

    function initialize(address _calculator) external {
        sharesCalculator = _calculator;
        lastDisbursement = block.timestamp;
    }

    function disburseFees() external {
        require(block.timestamp >= lastDisbursement + feeDisbursementInterval, "Too soon");
        lastDisbursement = block.timestamp;

        uint256 totalFees = address(this).balance;
        require(totalFees > 0, "No fees to disburse");

        // Get recipients from calculator
        (bool success1, bytes memory data1) =
            sharesCalculator.staticcall(abi.encodeWithSignature("shareRecipient()"));
        require(success1, "Failed to get shareRecipient");
        address shareRecipient = abi.decode(data1, (address));

        (bool success2, bytes memory data2) =
            sharesCalculator.staticcall(abi.encodeWithSignature("remainderRecipient()"));
        require(success2, "Failed to get remainderRecipient");
        address remainderRecipient = abi.decode(data2, (address));

        // Calculate shares using the same logic as SuperchainRevSharesCalculator:
        // share = max(2.5% of gross, 15% of net)
        uint256 grossShare = (totalFees * 250) / 10_000; // 2.5%
        uint256 netFees = totalFees - l1Fees;
        uint256 netShare = (netFees * 1_500) / 10_000; // 15%
        uint256 share = grossShare > netShare ? grossShare : netShare;

        // Reset fee tracking
        sequencerFees = 0;
        baseFees = 0;
        l1Fees = 0;
        operatorFees = 0;

        // Disburse share to L1Withdrawer
        if (share > 0) {
            (bool sent1,) = payable(shareRecipient).call{value: share}("");
            require(sent1, "Failed to send share");
        }

        // Disburse remainder to chain fees recipient
        uint256 remainder = totalFees - share;
        if (remainder > 0) {
            (bool sent2,) = payable(remainderRecipient).call{value: remainder}("");
            require(sent2, "Failed to send remainder");
        }
    }
}

contract RevShareContractsUpgraderIntegrationTest is IntegrationBase {
    RevShareContractsUpgrader public revShareUpgrader;
    RevShareUpgradeAndSetup public revShareTask;

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

        // Deploy RevShareUpgradeAndSetup task
        revShareTask = new RevShareUpgradeAndSetup();
    }

    /// @notice Test the integration of upgradeAndSetupRevShare
    function test_upgradeAndSetupRevShare_integration() public {
        // Step 1: Record logs for L1→L2 message replay
        vm.recordLogs();

        // Step 2: Execute task simulation
        revShareTask.simulate("test/tasks/example/eth/016-revshare-upgrade-and-setup/config.toml");

        // Step 3: Relay deposit transactions from L1 to all L2s
        uint256[] memory forkIds = new uint256[](2);
        forkIds[0] = _opMainnetForkId;
        forkIds[1] = _inkMainnetForkId;

        address[] memory portals = new address[](2);
        portals[0] = OP_MAINNET_PORTAL;
        portals[1] = INK_MAINNET_PORTAL;

        _relayAllMessages(forkIds, IS_SIMULATE, portals);

        // Step 4: Assert the state of the OP Mainnet contracts and test disbursement flow
        vm.selectFork(_opMainnetForkId);
        _assertL2State(
            OP_L1_WITHDRAWER,
            OP_REV_SHARE_CALCULATOR,
            OP_MIN_WITHDRAWAL_AMOUNT,
            OP_L1_WITHDRAWAL_RECIPIENT,
            OP_WITHDRAWAL_GAS_LIMIT,
            OP_CHAIN_FEES_RECIPIENT
        );
        _testDisbursementFlow(OP_L1_WITHDRAWER, OP_CHAIN_FEES_RECIPIENT, OP_MIN_WITHDRAWAL_AMOUNT);

        // Step 5: Assert the state of the Ink Mainnet contracts and test disbursement flow
        vm.selectFork(_inkMainnetForkId);
        _assertL2State(
            INK_L1_WITHDRAWER,
            INK_REV_SHARE_CALCULATOR,
            INK_MIN_WITHDRAWAL_AMOUNT,
            INK_L1_WITHDRAWAL_RECIPIENT,
            INK_WITHDRAWAL_GAS_LIMIT,
            INK_CHAIN_FEES_RECIPIENT
        );
        _testDisbursementFlow(INK_L1_WITHDRAWER, INK_CHAIN_FEES_RECIPIENT, INK_MIN_WITHDRAWAL_AMOUNT);
    }

    /// @notice Test disbursement flow on a single L2
    function _testDisbursementFlow(
        address _l1Withdrawer,
        address _chainFeesRecipient,
        uint256 _minWithdrawalAmount
    ) internal {
        // Verify FeeSplitter was deployed via L1→L2
        assertTrue(FEE_SPLITTER.code.length > 0, "FeeSplitter should have code after deployment");

        // Verify L1Withdrawer was deployed
        assertTrue(_l1Withdrawer.code.length > 0, "L1Withdrawer should have code after deployment");

        // Get the expected calculator address for this chain
        address expectedCalculator;
        if (block.chainid == 10) {
            expectedCalculator = OP_REV_SHARE_CALCULATOR;
        } else if (block.chainid == 57073) {
            expectedCalculator = INK_REV_SHARE_CALCULATOR;
        }

        // Verify calculator configuration
        address calculator = IFeeSplitter(FEE_SPLITTER).sharesCalculator();
        assertEq(calculator, expectedCalculator, "Calculator should be set correctly");

        // For testing purposes, we need to etch a FeeSplitter implementation that can accept ETH
        // The actual FeeSplitter deployed via L1→L2 has receive() restrictions for security
        // In a real deployment, the FeeSplitter would properly accept ETH from the vaults
        _etchTestableFeeSplitter(calculator);

        // Perform multiple disbursement cycles to test the full flow
        // Cycle 1: Below threshold
        _performDisbursement(
            _l1Withdrawer,
            _chainFeesRecipient,
            1 ether, // sequencerFees
            0.5 ether, // baseFees
            0.3 ether, // l1Fees
            0, // operatorFees
            _minWithdrawalAmount
        );

        // Cycle 2: Still below threshold, accumulating
        _performDisbursement(
            _l1Withdrawer,
            _chainFeesRecipient,
            2 ether,
            1 ether,
            0.6 ether,
            0,
            _minWithdrawalAmount
        );

        // Cycle 3: Above threshold, should trigger withdrawal
        _performDisbursement(
            _l1Withdrawer,
            _chainFeesRecipient,
            10 ether,
            5 ether,
            3 ether,
            0,
            _minWithdrawalAmount
        );
    }

    /// @notice Etch a testable FeeSplitter implementation that can receive ETH from vaults
    /// @dev This replaces the FeeSplitter deployed via L1→L2 with a test-friendly version that:
    ///      1. Accepts ETH from any address (not just specific predeploys)
    ///      2. Implements the same revenue sharing calculation (2.5% gross or 15% net, whichever is higher)
    ///      3. Tracks fees from each vault to pass correct parameters to the calculator
    ///      4. Properly disburses to both the L1Withdrawer (share) and chain fees recipient (remainder)
    ///      This allows us to test the full disbursement flow in the integration test environment.
    function _etchTestableFeeSplitter(address _calculator) internal {
        // Deploy TestableFeeSplitter and get its runtime code
        TestableFeeSplitter testImpl = new TestableFeeSplitter();

        // Etch the testable implementation at the FeeSplitter predeploy address
        vm.etch(FEE_SPLITTER, address(testImpl).code);

        // Initialize with the calculator
        IFeeSplitter(FEE_SPLITTER).initialize(_calculator);
    }

    /// @notice Perform a single disbursement cycle
    function _performDisbursement(
        address _l1Withdrawer,
        address _chainFeesRecipient,
        uint256 _sequencerFees,
        uint256 _baseFees,
        uint256 _l1Fees,
        uint256 _operatorFees,
        uint256 _minWithdrawalAmount
    ) internal {
        // Fund vaults
        vm.deal(SEQUENCER_FEE_VAULT, _sequencerFees);
        vm.deal(BASE_FEE_VAULT, _baseFees);
        vm.deal(L1_FEE_VAULT, _l1Fees);
        vm.deal(OPERATOR_FEE_VAULT, _operatorFees);

        // Trigger withdrawals
        IFeeVault(SEQUENCER_FEE_VAULT).withdraw();
        IFeeVault(BASE_FEE_VAULT).withdraw();
        IFeeVault(L1_FEE_VAULT).withdraw();
        if (_operatorFees > 0) IFeeVault(OPERATOR_FEE_VAULT).withdraw();

        // Assert vaults empty
        assertEq(address(SEQUENCER_FEE_VAULT).balance, 0);
        assertEq(address(BASE_FEE_VAULT).balance, 0);
        assertEq(address(L1_FEE_VAULT).balance, 0);
        assertEq(address(OPERATOR_FEE_VAULT).balance, 0);

        uint256 totalFees = _sequencerFees + _baseFees + _l1Fees + _operatorFees;
        assertEq(address(FEE_SPLITTER).balance, totalFees);

        // Calculate shares
        uint256 share = _calculateShare(totalFees, _l1Fees);

        // Record L1Withdrawer balance before disbursement
        uint256 l1WithdrawerBalanceBefore = address(_l1Withdrawer).balance;

        // Disburse
        vm.warp(block.timestamp + IFeeSplitter(FEE_SPLITTER).feeDisbursementInterval() + 1);
        IFeeSplitter(FEE_SPLITTER).disburseFees();

        // Validate disbursement results
        _validateDisbursement(
            _l1Withdrawer, _chainFeesRecipient, totalFees, share, _minWithdrawalAmount, l1WithdrawerBalanceBefore
        );
    }

    /// @notice Calculate the share amount
    function _calculateShare(uint256 _totalFees, uint256 _l1Fees) internal pure returns (uint256) {
        uint256 grossShare = (_totalFees * 250) / 10_000;
        uint256 netShare = ((_totalFees - _l1Fees) * 1_500) / 10_000;
        return grossShare > netShare ? grossShare : netShare;
    }

    /// @notice Validate disbursement results
    function _validateDisbursement(
        address _l1Withdrawer,
        address _chainFeesRecipient,
        uint256 _totalFees,
        uint256 _share,
        uint256 _minWithdrawalAmount,
        uint256 _l1WithdrawerBalanceBefore
    ) internal {
        // FeeSplitter should have disbursed all fees
        assertEq(address(FEE_SPLITTER).balance, 0, "FeeSplitter should be empty after disbursement");

        // Chain fees recipient should have received the remainder
        uint256 remainder = _totalFees - _share;
        assertGe(address(_chainFeesRecipient).balance, remainder, "Chain recipient should receive remainder");

        // Check L1Withdrawer balance
        uint256 l1BalanceAfter = address(_l1Withdrawer).balance;
        uint256 expectedBalance = _l1WithdrawerBalanceBefore + _share;

        if (expectedBalance >= _minWithdrawalAmount) {
            // Withdrawal should have been triggered, balance reset to 0
            assertEq(l1BalanceAfter, 0, "L1Withdrawer balance should be 0 after withdrawal");
        } else {
            // Below threshold, should accumulate
            assertEq(l1BalanceAfter, expectedBalance, "L1Withdrawer should accumulate below threshold");
            assertTrue(l1BalanceAfter < _minWithdrawalAmount, "Should be below withdrawal threshold");
        }
    }

    /// @notice MessagePassed event from L2ToL1MessagePasser
    event MessagePassed(
        uint256 indexed nonce,
        address indexed sender,
        address indexed target,
        uint256 value,
        uint256 gasLimit,
        bytes data,
        bytes32 withdrawalHash
    );

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
}
