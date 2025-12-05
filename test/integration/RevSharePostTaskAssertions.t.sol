// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IntegrationBase} from "./IntegrationBase.t.sol";

/// @title RevSharePostTaskAssertionsTest
/// @notice Integration test for asserting Rev Share contract state after task execution.
///         This test does NOT execute the task simulation or relay L1->L2 messages.
///         It directly asserts the expected state on L2 chains after a real task execution.
/// @dev Required environment variables:
///      - RPC_URL: L2 RPC URL to create fork
///      - OPTIMISM_PORTAL: Portal address for the chain
///      - MIN_WITHDRAWAL_AMOUNT: Min withdrawal amount for L1Withdrawer
///      - CHAIN_FEES_RECIPIENT: Chain fees recipient address
contract RevSharePostTaskAssertionsTest is IntegrationBase {
    // Fork ID
    uint256 internal _l2ForkId;

    // Chain configuration from env vars
    address internal _portal;
    uint256 internal _minWithdrawalAmount;
    address internal _chainFeesRecipient;

    // Hardcoded defaults
    uint32 internal constant WITHDRAWAL_GAS_LIMIT = 800000;
    address internal constant L1_WITHDRAWAL_RECIPIENT = 0x0000000000000000000000000000000000000001;

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
        _portal = vm.envOr("OPTIMISM_PORTAL", address(0));
        _minWithdrawalAmount = vm.envOr("MIN_WITHDRAWAL_AMOUNT", uint256(0));
        _chainFeesRecipient = vm.envOr("CHAIN_FEES_RECIPIENT", address(0));

        // Check if all required env vars are set
        bool hasRpcUrl = bytes(rpcUrl).length > 0;
        bool hasPortal = _portal != address(0);
        bool hasChainFeesRecipient = _chainFeesRecipient != address(0);

        _isEnabled = hasRpcUrl && hasPortal && hasChainFeesRecipient;

        if (_isEnabled) {
            _l2ForkId = vm.createFork(rpcUrl);
        }
    }

    /// @notice Assert the Rev Share contract state on the L2 chain
    function test_assertRevShareState() public onlyIfEnabled {
        vm.selectFork(_l2ForkId);

        address l1Withdrawer =
            _computeL1WithdrawerAddress(_minWithdrawalAmount, L1_WITHDRAWAL_RECIPIENT, WITHDRAWAL_GAS_LIMIT);
        address revShareCalculator = _computeRevShareCalculatorAddress(l1Withdrawer, _chainFeesRecipient);

        _assertL2State(
            l1Withdrawer,
            revShareCalculator,
            _minWithdrawalAmount,
            L1_WITHDRAWAL_RECIPIENT,
            WITHDRAWAL_GAS_LIMIT,
            _chainFeesRecipient
        );
    }

    /// @notice Test the withdrawal flow on the L2 chain
    function test_withdrawalFlow() public onlyIfEnabled {
        // Fund vaults
        _fundVaults(1 ether, _l2ForkId);

        // Disburse fees and assert withdrawal
        // Expected L1Withdrawer share = 3 ether * 15% = 0.45 ether
        // It is 3 ether instead of 4 because net revenue doesn't count L1FeeVault's balance
        // For details on the rev share calculation, check the SuperchainRevSharesCalculator contract.
        // https://github.com/ethereum-optimism/optimism/blob/f392d4b7e8bc5d1c8d38fcf19c8848764f8bee3b/packages/contracts-bedrock/src/L2/SuperchainRevSharesCalculator.sol#L67-L101
        uint256 expectedWithdrawalAmount = 0.45 ether;

        _executeDisburseAndAssertWithdrawal(_l2ForkId, L1_WITHDRAWAL_RECIPIENT, expectedWithdrawalAmount);
    }
}
