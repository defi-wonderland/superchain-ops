// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IntegrationBase} from "./IntegrationBase.t.sol";

/// @title RevSharePostTaskAssertionsTest
/// @notice Integration test for asserting Rev Share contract state after task execution.
///         This test does NOT execute the task simulation or relay L1->L2 messages.
///         It directly asserts the expected state on L2 chains after a real task execution.
///         Set POST_REVSHARE_TASK_ASSERTIONS=true to run these tests.
contract RevSharePostTaskAssertionsTest is IntegrationBase {
    /// @notice Modifier to skip tests if POST_REVSHARE_TASK_ASSERTIONS env var is not set to "true"
    modifier onlyIfEnabled() {
        bool enabled = vm.envOr("POST_REVSHARE_TASK_ASSERTIONS", false);
        if (!enabled) vm.skip(true);
        _;
    }
    // Fork IDs

    uint256 internal _opMainnetForkId;
    uint256 internal _inkMainnetForkId;
    uint256 internal _soneiumMainnetForkId;

    // L1 Portal addresses (needed for L2ChainConfig)
    address internal constant OP_MAINNET_PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address internal constant INK_MAINNET_PORTAL = 0x5d66C1782664115999C47c9fA5cd031f495D3e4F;
    address internal constant SONEIUM_MAINNET_PORTAL = 0x88e529A6ccd302c948689Cd5156C83D4614FAE92;

    // Array to store all L2 chain configurations
    L2ChainConfig[] internal l2Chains;

    function setUp() public {
        // Create L2 forks only (no L1 fork needed for assertions)
        _opMainnetForkId = vm.createFork("http://127.0.0.1:9545");
        _inkMainnetForkId = vm.createFork("http://127.0.0.1:9546");
        _soneiumMainnetForkId = vm.createFork("http://127.0.0.1:9547");

        // Configure all L2 chains
        l2Chains.push(
            L2ChainConfig({
                forkId: _opMainnetForkId,
                portal: OP_MAINNET_PORTAL,
                minWithdrawalAmount: 350000,
                l1WithdrawalRecipient: address(0x1),
                withdrawalGasLimit: 800000,
                chainFeesRecipient: address(0x1),
                name: "OP Mainnet"
            })
        );

        l2Chains.push(
            L2ChainConfig({
                forkId: _inkMainnetForkId,
                portal: INK_MAINNET_PORTAL,
                minWithdrawalAmount: 500000,
                l1WithdrawalRecipient: address(0x2),
                withdrawalGasLimit: 800000,
                chainFeesRecipient: address(0x2),
                name: "Ink Mainnet"
            })
        );

        l2Chains.push(
            L2ChainConfig({
                forkId: _soneiumMainnetForkId,
                portal: SONEIUM_MAINNET_PORTAL,
                minWithdrawalAmount: 500000,
                l1WithdrawalRecipient: address(0x3),
                withdrawalGasLimit: 800000,
                chainFeesRecipient: address(0x3),
                name: "Soneium Mainnet"
            })
        );
    }

    /// @notice Assert the Rev Share contract state on all L2 chains
    function test_assertRevShareState() public onlyIfEnabled {
        for (uint256 i = 0; i < l2Chains.length; i++) {
            L2ChainConfig memory chain = l2Chains[i];

            vm.selectFork(chain.forkId);

            address l1Withdrawer = _computeL1WithdrawerAddress(
                chain.minWithdrawalAmount, chain.l1WithdrawalRecipient, chain.withdrawalGasLimit
            );
            address revShareCalculator = _computeRevShareCalculatorAddress(l1Withdrawer, chain.chainFeesRecipient);

            _assertL2State(
                l1Withdrawer,
                revShareCalculator,
                chain.minWithdrawalAmount,
                chain.l1WithdrawalRecipient,
                chain.withdrawalGasLimit,
                chain.chainFeesRecipient
            );
        }
    }

    /// @notice Test the withdrawal flow on all L2 chains
    function test_withdrawalFlow() public onlyIfEnabled {
        // Fund vaults for all chains
        for (uint256 i = 0; i < l2Chains.length; i++) {
            _fundVaults(1 ether, l2Chains[i].forkId);
        }

        // Disburse fees in all chains and assert withdrawals
        // Expected L1Withdrawer share = 3 ether * 15% = 0.45 ether
        // It is 3 ether instead of 4 because net revenue doesn't count L1FeeVault's balance
        // For details on the rev share calculation, check the SuperchainRevSharesCalculator contract.
        // https://github.com/ethereum-optimism/optimism/blob/f392d4b7e8bc5d1c8d38fcf19c8848764f8bee3b/packages/contracts-bedrock/src/L2/SuperchainRevSharesCalculator.sol#L67-L101
        uint256 expectedWithdrawalAmount = 0.45 ether;

        for (uint256 i = 0; i < l2Chains.length; i++) {
            _executeDisburseAndAssertWithdrawal(
                l2Chains[i].forkId, l2Chains[i].l1WithdrawalRecipient, expectedWithdrawalAmount
            );
        }
    }
}
