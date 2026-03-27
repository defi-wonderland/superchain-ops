// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {RevShareUpgradeAndSetup} from "src/template/RevShareUpgradeAndSetup.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PermissionedBetanetRevShareIntegrationTest is IntegrationBase {
    RevShareUpgradeAndSetup public revShareTask;

    // Betanet fork ID
    uint256 internal _betanetForkId;

    // OP Sepolia fork ID
    uint256 internal _opSepoliaForkId;

    // Betanet L1 addresses (on Sepolia)
    address internal constant BETANET_PORTAL = 0xa68B3c6C2147Caf13a760a4eC79855B0d859D9e5;
    address internal constant BETANET_L1_MESSENGER = 0xF116B86545360fcF0f8F931ec4543AF6D082A6e7;

    // OP Sepolia addresses
    address internal constant OP_SEPOLIA_PORTAL = 0x16Fc5058F25648194471939df75CF27A2fdC48BC;
    address internal constant OP_SEPOLIA_L1_MESSENGER = 0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef;
    address internal constant OP_SEPOLIA_FEES_DEPOSITOR_TARGET = 0x7ca800c55ad9C745AC84FdeEfaf4522F4Df07577;

    // L2 ProxyAdmin predeploy
    address internal constant L2_PROXY_ADMIN = 0x4200000000000000000000000000000000000018;

    // Aliased L1 PAO (correct owner for L2 ProxyAdmin)
    address internal constant ALIASED_L1_PAO = 0x2FC3ffc903729a0f03966b917003800B145F67F3;

    function setUp() public {
        // Create forks for Sepolia L1, Betanet L2, and OP Sepolia L2
        _mainnetForkId = vm.createFork("https://ethereum-sepolia-rpc.publicnode.com");
        _betanetForkId = vm.createFork("https://revshare-beta-1.optimism.io");
        _opSepoliaForkId = vm.createFork("https://sepolia.optimism.io");

        // Configure betanet chain with production config values
        // Values from src/tasks/sep/060-betanet-rev-share/config.toml
        l2Chains.push(
            L2ChainConfig({
                forkId: _betanetForkId,
                portal: BETANET_PORTAL,
                l1Messenger: BETANET_L1_MESSENGER,
                minWithdrawalAmount: 2 ether,
                l1WithdrawalRecipient: 0xed9B99a703BaD32AC96FDdc313c0652e379251Fd,
                withdrawalGasLimit: 800000,
                chainFeesRecipient: 0xEE7D049e5f573a08bB5A358FCEFB3d4af992fdcB,
                name: "revshare-beta-1"
            })
        );

        revShareTask = new RevShareUpgradeAndSetup();

        // Switch to Sepolia fork for task execution
        vm.selectFork(_mainnetForkId);
    }

    /// @notice Test the integration of setupRevShare for betanet
    function test_setupRevShare_betanet_integration() public {
        // Switch back to L1 for task execution
        vm.selectFork(_mainnetForkId);

        // Step 1: Record logs for L1→L2 message relay
        vm.recordLogs();

        // Step 2: Execute task simulation
        revShareTask.simulate("src/tasks/sep/064-permissioned-betanet-rev-share/config.toml");

        // Step 3: Relay deposit transactions from L1 to betanet L2
        uint256[] memory forkIds = new uint256[](1);
        address[] memory portals = new address[](1);

        forkIds[0] = _betanetForkId;
        portals[0] = BETANET_PORTAL;

        _relayAllMessages(forkIds, IS_SIMULATE, portals);

        // Step 4: Assert L2 state for betanet
        L2ChainConfig memory chain = l2Chains[0];

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

        // Step 5: Fund vaults
        _fundVaults(5 ether, _betanetForkId);

        // Step 6: Disburse fees and assert withdrawals
        // Expected L1Withdrawer share = 15 ether * 15% = 2.25 ether
        // It is 15 ether instead of 20 because net revenue doesn't count L1FeeVault's balance
        // For details on the rev share calculation, check the SuperchainRevSharesCalculator contract.
        uint256 expectedWithdrawalAmount = 2.25 ether;

        _executeDisburseAndAssertWithdrawal(
            ChainConfig({
                l1ForkId: _mainnetForkId,
                l2ForkId: _betanetForkId,
                l1Withdrawer: l1Withdrawer,
                l1WithdrawalRecipient: chain.l1WithdrawalRecipient,
                expectedWithdrawalAmount: expectedWithdrawalAmount,
                portal: chain.portal,
                l1Messenger: chain.l1Messenger,
                withdrawalGasLimit: chain.withdrawalGasLimit
            }),
            OPConfig({
                opL2ForkId: _opSepoliaForkId,
                opL1Messenger: OP_SEPOLIA_L1_MESSENGER,
                opPortal: OP_SEPOLIA_PORTAL,
                feesDepositorTarget: OP_SEPOLIA_FEES_DEPOSITOR_TARGET
            })
        );
    }
}
