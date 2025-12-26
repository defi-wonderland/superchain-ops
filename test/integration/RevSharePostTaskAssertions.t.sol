// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {IFeeSplitter} from "src/interfaces/IFeeSplitter.sol";
import {ISuperchainRevSharesCalculator} from "src/interfaces/ISuperchainRevSharesCalculator.sol";

/// @title RevSharePostTaskAssertionsTest
/// @notice Integration test for asserting Rev Share contract state after task execution.
///         This test does NOT execute the task simulation or relay L1->L2 messages.
///         It directly asserts the expected state on L2 chains after a real task execution.
///         The L1Withdrawer and calculator addresses are queried directly from the FeeSplitter
///         on-chain, making this test compatible with any deployment mechanism (CREATE2 or genesis).
/// @dev Required environment variables:
///      - RPC_URL: L2 RPC URL to create fork
///      - L1_RPC_URL: L1 RPC URL to create fork (for withdrawal relay tests)
///      - OP_RPC_URL: OP L2 RPC URL for L1→L2 relay tests (defaults to RPC_URL)
///      - OPTIMISM_PORTAL: Portal address for the chain
///      - L1_MESSENGER: L1CrossDomainMessenger address for the chain
///      - OP_L1_MESSENGER: OP L1CrossDomainMessenger address (defaults to mainnet)
///      - MIN_WITHDRAWAL_AMOUNT: Expected min withdrawal amount for L1Withdrawer (wei)
///      - L1_WITHDRAWAL_RECIPIENT: Expected L1 withdrawal recipient address
///      - WITHDRAWAL_GAS_LIMIT: Expected gas limit for withdrawals
///      - CHAIN_FEES_RECIPIENT: Expected chain fees recipient address
/// @dev Example command:
/// ```sh
/// RPC_URL="https://revshare-alpha-0.optimism.io" \
/// L1_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com" \
/// OP_RPC_URL="https://sepolia.optimism.io" \
/// OPTIMISM_PORTAL="0x5b03d83e3355cdb33fa89bafc598128c2992e0ac" \
/// L1_MESSENGER="0x5bb384968c190f6452b8db4f6ba8a282005947b3" \
/// OP_L1_MESSENGER="0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef" \
/// MIN_WITHDRAWAL_AMOUNT="10000000000000000000" \
/// L1_WITHDRAWAL_RECIPIENT="0x81c01427DFA9A2512b4EBf1462868856BA4aA91a" \
/// WITHDRAWAL_GAS_LIMIT="1000000" \
/// CHAIN_FEES_RECIPIENT="0x455A1115C97cb0E2b24B064C00a9E13872cC37ca" \
/// forge test --match-contract RevSharePostTaskAssertionsTest
/// ```
contract RevSharePostTaskAssertionsTest is IntegrationBase {
    // Fork ID
    uint256 internal _l2ForkId;

    // Chain configuration from env vars
    address internal _portal;
    address internal _l1Messenger;
    address internal _opL1Messenger;

    // Expected values from env vars
    uint256 internal _expectedMinWithdrawalAmount;
    address internal _expectedL1WithdrawalRecipient;
    uint32 internal _expectedWithdrawalGasLimit;
    address internal _expectedChainFeesRecipient;

    // RevShare addresses discovered from on-chain state
    address internal _calculator;
    address internal _l1Withdrawer;

    // Flag to track if env vars are set
    bool internal _isEnabled;

    /// @notice Modifier to skip tests if required env vars are not set
    modifier onlyIfEnabled() {
        if (!_isEnabled) {
            vm.skip(true);
        }
        _;
    }

    function setUp() public {
        // Read env vars with defaults to detect if they're set
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        string memory l1RpcUrl = vm.envOr("L1_RPC_URL", string(""));
        string memory opRpcUrl = vm.envOr("OP_RPC_URL", rpcUrl); // Defaults to RPC_URL
        _portal = vm.envOr("OPTIMISM_PORTAL", address(0));
        _l1Messenger = vm.envOr("L1_MESSENGER", address(0));
        _opL1Messenger = vm.envOr("OP_L1_MESSENGER", OP_MAINNET_L1_MESSENGER); // Defaults to mainnet

        // Expected values to verify against on-chain state
        _expectedMinWithdrawalAmount = vm.envOr("MIN_WITHDRAWAL_AMOUNT", uint256(0));
        _expectedL1WithdrawalRecipient = vm.envOr("L1_WITHDRAWAL_RECIPIENT", address(0));
        _expectedWithdrawalGasLimit = uint32(vm.envOr("WITHDRAWAL_GAS_LIMIT", uint256(0)));
        _expectedChainFeesRecipient = vm.envOr("CHAIN_FEES_RECIPIENT", address(0));

        // Check if all required env vars are set
        bool hasRpcUrl = bytes(rpcUrl).length > 0;
        bool hasL1RpcUrl = bytes(l1RpcUrl).length > 0;
        bool hasPortal = _portal != address(0);
        bool hasL1Messenger = _l1Messenger != address(0);
        bool hasExpectedL1WithdrawalRecipient = _expectedL1WithdrawalRecipient != address(0);
        bool hasExpectedWithdrawalGasLimit = _expectedWithdrawalGasLimit != 0;
        bool hasExpectedChainFeesRecipient = _expectedChainFeesRecipient != address(0);

        _isEnabled = hasRpcUrl && hasL1RpcUrl && hasPortal && hasL1Messenger && hasExpectedL1WithdrawalRecipient
            && hasExpectedWithdrawalGasLimit && hasExpectedChainFeesRecipient;

        if (_isEnabled) {
            _mainnetForkId = vm.createFork(l1RpcUrl);
            _opMainnetForkId = vm.createFork(opRpcUrl);
            _l2ForkId = vm.createFork(rpcUrl);

            // Query RevShare addresses from on-chain state
            vm.selectFork(_l2ForkId);
            _calculator = IFeeSplitter(FEE_SPLITTER).sharesCalculator();
            require(_calculator != address(0), "FeeSplitter calculator not set - RevShare not configured");

            _l1Withdrawer = address(ISuperchainRevSharesCalculator(_calculator).shareRecipient());
            require(_l1Withdrawer != address(0), "Calculator shareRecipient not set");
        }
    }

    /// @notice Assert the Rev Share contract state on the L2 chain
    function test_assertRevShareState() public onlyIfEnabled {
        vm.selectFork(_l2ForkId);

        _assertL2State(
            _l1Withdrawer,
            _calculator,
            _expectedMinWithdrawalAmount,
            _expectedL1WithdrawalRecipient,
            _expectedWithdrawalGasLimit,
            _expectedChainFeesRecipient
        );
    }

    /// @notice Test the withdrawal flow on the L2 chain - tests both below and above threshold paths
    // Fund vaults with half the minWithdrawalAmount so that:
    // - First disburse: share = minWithdrawalAmount / 2 (below threshold, no withdrawal)
    // - Second disburse: total = minWithdrawalAmount (at threshold, triggers withdrawal)
    function test_withdrawalFlow() public onlyIfEnabled {
        // L1Withdrawer share = netRevenue * 15% = vaultFunding * 3 * 15 / 100 = vaultFunding * 45 / 100
        // To get share = minWithdrawalAmount / 2, we need vaultFunding = minWithdrawalAmount / 2 * 100 / 45
        uint256 sharePerDisburse = _expectedMinWithdrawalAmount / 2;
        uint256 vaultFunding = (sharePerDisburse * 100) / 45;

        // ==================== PART 1: Below threshold - no withdrawal ====================
        vm.selectFork(_l2ForkId);

        // Fund vaults for first disburse
        _fundVaults(vaultFunding, _l2ForkId);

        // Warp time to allow disbursement
        vm.warp(block.timestamp + IFeeSplitter(FEE_SPLITTER).feeDisbursementInterval() + 1);

        // Record L1Withdrawer balance before
        uint256 l1WithdrawerBalanceBefore = _l1Withdrawer.balance;

        // Disburse fees - should NOT trigger withdrawal (below threshold)
        IFeeSplitter(FEE_SPLITTER).disburseFees();

        // Verify funds accumulated in L1Withdrawer (no withdrawal triggered)
        uint256 l1WithdrawerBalanceAfter = _l1Withdrawer.balance;
        assertEq(
            l1WithdrawerBalanceAfter - l1WithdrawerBalanceBefore,
            sharePerDisburse,
            "L1Withdrawer should have half of threshold"
        );

        // ==================== PART 2: At threshold - withdrawal triggers ====================

        // Fund vaults again for second disburse
        _fundVaults(vaultFunding, _l2ForkId);

        // Warp time again
        vm.warp(block.timestamp + IFeeSplitter(FEE_SPLITTER).feeDisbursementInterval() + 1);

        // Now the total in L1Withdrawer will be: previous balance + new share = minWithdrawalAmount
        uint256 expectedWithdrawalAmount = sharePerDisburse * 2;
        assertEq(expectedWithdrawalAmount, _expectedMinWithdrawalAmount, "Total should equal threshold");

        _executeDisburseAndAssertWithdrawal(
            _mainnetForkId,
            _l2ForkId,
            _opMainnetForkId,
            _l1Withdrawer,
            _expectedL1WithdrawalRecipient,
            expectedWithdrawalAmount,
            _portal,
            _l1Messenger,
            _expectedWithdrawalGasLimit,
            _opL1Messenger
        );
    }
}
