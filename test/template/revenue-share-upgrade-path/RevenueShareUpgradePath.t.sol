// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {RevenueShareV100UpgradePath} from "src/template/RevenueShareUpgradePath.sol";

/// @notice Test contract for the RevenueShareUpgradePath that expect reverts on misconfiguration of required fields.
contract RevenueShareUpgradePathRequiredFieldsTest is Test {
    RevenueShareV100UpgradePath public template;

    function setUp() public {
        vm.createSelectFork("mainnet", 23197819);
        template = new RevenueShareV100UpgradePath();
    }

    /// @notice Tests that the template reverts when the portal is a zero address.
    function test_revenueShareUpgradePath_portal_zero_address_reverts() public {
        string memory configPath = "test/template/revenue-share-upgrade-path/config/portal-zero-address-config.toml";
        vm.expectRevert("portal must be set in config");
        template.simulate(configPath);
    }

    /// @notice Tests that the template reverts when the salt seed is an empty string.
    function test_revenueShareUpgradePath_saltSeed_empty_string_reverts() public {
        string memory configPath = "test/template/revenue-share-upgrade-path/config/saltSeed-empty-string-config.toml";
        vm.expectRevert("saltSeed must be set in the config");
        template.simulate(configPath);
    }

    /// @notice Tests that the template reverts when the l1 withdrawer recipient is a zero address.
    function test_revenueShareUpgradePath_l1WithdrawerRecipient_zero_address_reverts() public {
        string memory configPath =
            "test/template/revenue-share-upgrade-path/config/l1WithdrawerRecipient-zero-address-config.toml";
        vm.expectRevert("l1WithdrawerRecipient must be set in config");
        template.simulate(configPath);
    }

    /// @notice Tests that the template reverts when the l1 withdrawer gas limit is zero.
    function test_revenueShareUpgradePath_l1WithdrawerGasLimit_zero_reverts() public {
        string memory configPath =
            "test/template/revenue-share-upgrade-path/config/l1WithdrawerGasLimit-zero-config.toml";
        vm.expectRevert("l1WithdrawerGasLimit must be greater than 0");
        template.simulate(configPath);
    }

    /// @notice Tests that the template reverts when the l1 withdrawer gas limit is too high.
    function test_revenueShareUpgradePath_l1WithdrawerGasLimit_too_high_reverts() public {
        string memory configPath =
            "test/template/revenue-share-upgrade-path/config/l1WithdrawerGasLimit-too-high-config.toml";
        vm.expectRevert("l1WithdrawerGasLimit must be less than uint32.max");
        template.simulate(configPath);
    }

    /// @notice Tests that the template reverts when the chain fees recipient is a zero address.
    function test_revenueShareUpgradePath_scRevShareCalcChainFeesRecipient_zero_address_reverts() public {
        string memory configPath =
            "test/template/revenue-share-upgrade-path/config/scRevShareCalcChainFeesRecipient-zero-address-config.toml";
        vm.expectRevert("scRevShareCalcChainFeesRecipient must be set in config");
        template.simulate(configPath);
    }
}
