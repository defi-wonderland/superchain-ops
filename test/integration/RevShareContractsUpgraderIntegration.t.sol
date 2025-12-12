// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";
import {RevShareUpgradeAndSetup} from "src/template/RevShareUpgradeAndSetup.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";

contract RevShareContractsUpgraderIntegrationTest is IntegrationBase {
    RevShareUpgradeAndSetup public revShareTask;

    function setUp() public {
        _setupDefaultL2Chains();
        _deployRevShareUpgrader();
        revShareTask = new RevShareUpgradeAndSetup();
    }

    /// @notice Test the integration of upgradeAndSetupRevShare (Ink and Soneium only - need proxy upgrade)
    function test_upgradeAndSetupRevShare_integration() public {
        // Step 1: Record logs for L1→L2 message relay
        vm.recordLogs();

        // Step 2: Execute task simulation
        revShareTask.simulate("test/tasks/example/eth/017-revshare-upgrade-and-setup-sony-ink/config.toml");

        // Step 3: Relay deposit transactions from L1 to all L2s
        uint256[] memory forkIds = new uint256[](l2Chains.length);
        address[] memory portals = new address[](l2Chains.length);

        for (uint256 i = 0; i < l2Chains.length; i++) {
            forkIds[i] = l2Chains[i].forkId;
            portals[i] = l2Chains[i].portal;
        }

        _relayAllMessages(forkIds, IS_SIMULATE, portals);

        // Step 4: Assert L2 state for all chains
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

        // Step 5: Fund vaults for all chains
        for (uint256 i = 0; i < l2Chains.length; i++) {
            _fundVaults(1 ether, l2Chains[i].forkId);
        }

        // Step 6: Disburse fees in all chains and assert withdrawals
        // Expected L1Withdrawer share = 3 ether * 15% = 0.45 ether
        // It is 3 ether instead of 4 because net revenue doesn't count L1FeeVault's balance
        // For details on the rev share calculation, check the SuperchainRevSharesCalculator contract.
        // https://github.com/ethereum-optimism/optimism/blob/f392d4b7e8bc5d1c8d38fcf19c8848764f8bee3b/packages/contracts-bedrock/src/L2/SuperchainRevSharesCalculator.sol#L67-L101
        uint256 expectedWithdrawalAmount = 2.25 ether;

        for (uint256 i = 0; i < l2Chains.length; i++) {
            L2ChainConfig memory chain = l2Chains[i];
            address l1Withdrawer = _computeL1WithdrawerAddress(
                chain.minWithdrawalAmount, chain.l1WithdrawalRecipient, chain.withdrawalGasLimit
            );
            _executeDisburseAndAssertWithdrawal(
                _mainnetForkId,
                chain.forkId,
                l1Withdrawer,
                chain.l1WithdrawalRecipient,
                expectedWithdrawalAmount,
                chain.portal,
                chain.l1Messenger,
                chain.withdrawalGasLimit
            );
        }
    }
}
