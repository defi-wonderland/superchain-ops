// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";
import {RevShareUpgradeAndSetup} from "src/template/RevShareUpgradeAndSetup.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";

contract RevShareContractsUpgraderIntegrationTest is IntegrationBase {
    RevShareUpgradeAndSetup public revShareTask;

    // L1 addresses
    address internal constant OP_MAINNET_PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    address internal constant INK_MAINNET_PORTAL = 0x5d66C1782664115999C47c9fA5cd031f495D3e4F;
    address internal constant SONEIUM_MAINNET_PORTAL = 0x88e529A6ccd302c948689Cd5156C83D4614FAE92;

    bool internal constant IS_SIMULATE = true;

    // Array to store all L2 chain configurations
    L2ChainConfig[] internal l2Chains;

    function setUp() public {
        // Create forks for L1 (mainnet) and L2s
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _opMainnetForkId = vm.createFork("http://127.0.0.1:9545");
        _inkMainnetForkId = vm.createFork("http://127.0.0.1:9546");
        _soneiumMainnetForkId = vm.createFork("http://127.0.0.1:9547");

        // Configure all L2 chains (values match config.toml)
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
        // Step 1: Record logs for L1→L2 message relay
        vm.recordLogs();

        // Step 2: Execute task simulation
        revShareTask.simulate("test/tasks/example/eth/016-revshare-upgrade-and-setup/config.toml");

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
        uint256 expectedWithdrawalAmount = 0.45 ether;

        for (uint256 i = 0; i < l2Chains.length; i++) {
            L2ChainConfig memory chain = l2Chains[i];
            address l1Withdrawer = _computeL1WithdrawerAddress(
                chain.minWithdrawalAmount, chain.l1WithdrawalRecipient, chain.withdrawalGasLimit
            );
            _executeDisburseAndAssertWithdrawal(
                chain.forkId, l1Withdrawer, chain.l1WithdrawalRecipient, expectedWithdrawalAmount
            );
        }
    }
}
