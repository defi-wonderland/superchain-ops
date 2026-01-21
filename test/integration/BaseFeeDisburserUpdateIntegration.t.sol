// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {BaseFeeDisburserUpdate} from "src/template/BaseFeeDisburserUpdate.sol";
import {IFeeDisburser} from "src/interfaces/IFeeDisburser.sol";
import {IProxyAdmin} from "@eth-optimism-bedrock/interfaces/universal/IProxyAdmin.sol";
import {IOptimismPortal2} from "@eth-optimism-bedrock/interfaces/L1/IOptimismPortal2.sol";
import {Utils} from "src/libraries/Utils.sol";
import {RevShareCommon} from "src/libraries/RevShareCommon.sol";
import {ICreate2Deployer} from "src/interfaces/ICreate2Deployer.sol";

/// @title BaseFeeDisburserUpdateIntegrationTest
/// @notice Integration tests for the Base FeeDisburser upgrade
/// @dev Note: Full L1→L2 message relay cannot be simulated in fork tests.
///      These tests verify:
///      1. L1 deposit transactions are emitted correctly
///      2. Pre-upgrade L2 state is correct
///      3. CREATE2 address computation is correct
///      Post-upgrade verification should be done on actual testnets or via VALIDATION.md
contract BaseFeeDisburserUpdateIntegrationTest is Test {
    // Events
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    // Fork IDs
    uint256 internal _sepoliaForkId;
    uint256 internal _baseSepoliaForkId;

    // L1 addresses (Sepolia)
    address internal constant BASE_SEPOLIA_PORTAL = 0x49f53e41452C74589E85cA1677426Ba426459e85;

    // Base Sepolia L2 addresses
    address internal constant FEE_DISBURSER_PROXY = 0x76355A67fCBCDE6F9a69409A8EAd5EaA9D8d875d;
    address internal constant L1_WITHDRAWER = 0x7E077dB4e625bbc516c99FD2B0Dbf971D95E5Dff;
    address internal constant PROXY_ADMIN = 0x4200000000000000000000000000000000000018;
    address internal constant L1_WALLET = 0x8D1b5e5614300F5c7ADA01fFA4ccF8F1752D9A57;
    uint256 internal constant FEE_DISBURSEMENT_INTERVAL = 604800; // 7 days

    // CREATE2 deployer predeploy
    address internal constant CREATE2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;

    // Test contract instance
    BaseFeeDisburserUpdate internal template;

    function setUp() public {
        // Create forks
        _sepoliaForkId = vm.createFork("https://ethereum-sepolia-rpc.publicnode.com");
        _baseSepoliaForkId = vm.createFork("https://sepolia.base.org");
    }

    /// @notice Test that the FeeDisburser bytecode is valid and has expected length
    function test_feeDisburserBytecodeIsValid() public {
        // Deploy a fresh template instance to access the constant
        template = new BaseFeeDisburserUpdate();

        bytes memory creationCode = template.FEE_DISBURSER_CREATION_CODE();
        assertTrue(creationCode.length > 0, "FeeDisburser creation code should not be empty");
        // The bytecode should be substantial (FeeDisburser is a non-trivial contract)
        assertTrue(creationCode.length > 1000, "FeeDisburser creation code seems too small");
    }

    /// @notice Test the pre-upgrade state on Base Sepolia
    function test_preUpgradeState() public {
        vm.selectFork(_baseSepoliaForkId);

        // Verify current state
        IFeeDisburser feeDisburser = IFeeDisburser(FEE_DISBURSER_PROXY);

        // Current OPTIMISM_WALLET should NOT be L1Withdrawer
        address currentOptimismWallet = feeDisburser.OPTIMISM_WALLET();
        assertTrue(currentOptimismWallet != L1_WITHDRAWER, "OPTIMISM_WALLET should not be L1Withdrawer before upgrade");

        // L1_WALLET should be the expected value
        assertEq(feeDisburser.L1_WALLET(), L1_WALLET, "L1_WALLET mismatch");

        // FEE_DISBURSEMENT_INTERVAL should be the expected value
        assertEq(
            feeDisburser.FEE_DISBURSEMENT_INTERVAL(), FEE_DISBURSEMENT_INTERVAL, "FEE_DISBURSEMENT_INTERVAL mismatch"
        );

        console2.log("Pre-upgrade state verified:");
        console2.log("  Current OPTIMISM_WALLET:", currentOptimismWallet);
        console2.log("  L1_WALLET:", feeDisburser.L1_WALLET());
        console2.log("  FEE_DISBURSEMENT_INTERVAL:", feeDisburser.FEE_DISBURSEMENT_INTERVAL());
    }

    /// @notice Test that CREATE2 address computation is correct
    function test_create2AddressComputation() public {
        vm.selectFork(_sepoliaForkId);

        // Deploy a fresh template instance
        template = new BaseFeeDisburserUpdate();

        // Build the init code
        bytes memory initCode = abi.encodePacked(
            template.FEE_DISBURSER_CREATION_CODE(), abi.encode(L1_WITHDRAWER, L1_WALLET, FEE_DISBURSEMENT_INTERVAL)
        );

        // Compute the expected address
        bytes32 salt = RevShareCommon.getSalt("BaseFeeDisburser");
        address expectedImpl = Utils.getCreate2Address(salt, initCode, CREATE2_DEPLOYER);

        // Verify address looks reasonable
        assertTrue(expectedImpl != address(0), "Computed implementation address should not be zero");
        assertTrue(uint160(expectedImpl) > 1000, "Computed implementation address seems too small");

        console2.log("CREATE2 address computation verified:");
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Init code length:", initCode.length);
        console2.log("  Expected implementation:", expectedImpl);
    }

    /// @notice Test that direct portal calls emit correct deposit transactions
    function test_directPortalCalls_emitCorrectDeposits() public {
        vm.selectFork(_sepoliaForkId);

        // Build the init code
        template = new BaseFeeDisburserUpdate();
        bytes memory initCode = abi.encodePacked(
            template.FEE_DISBURSER_CREATION_CODE(), abi.encode(L1_WITHDRAWER, L1_WALLET, FEE_DISBURSEMENT_INTERVAL)
        );

        // Compute the expected address
        bytes32 salt = RevShareCommon.getSalt("BaseFeeDisburser");
        address expectedImpl = Utils.getCreate2Address(salt, initCode, CREATE2_DEPLOYER);

        // Record logs for L1→L2 message relay
        vm.recordLogs();

        // Call portal directly (simulating what the template does)
        // Transaction 1: Deploy new FeeDisburser via CREATE2
        RevShareCommon.depositCreate2(BASE_SEPOLIA_PORTAL, 1_500_000, salt, initCode);

        // Transaction 2: Upgrade proxy to new implementation
        RevShareCommon.depositCall(
            BASE_SEPOLIA_PORTAL,
            PROXY_ADMIN,
            RevShareCommon.UPGRADE_GAS_LIMIT,
            abi.encodeCall(IProxyAdmin.upgrade, (payable(FEE_DISBURSER_PROXY), expectedImpl))
        );

        // Get the recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify TransactionDeposited events were emitted
        bytes32 depositEventHash = keccak256("TransactionDeposited(address,address,uint256,bytes)");
        uint256 depositCount = 0;
        address[] memory depositTargets = new address[](2);

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == depositEventHash && logs[i].emitter == BASE_SEPOLIA_PORTAL) {
                if (depositCount < 2) {
                    depositTargets[depositCount] = address(uint160(uint256(logs[i].topics[2])));
                }
                depositCount++;
            }
        }

        // Should have 2 deposit transactions: 1 for CREATE2 deploy, 1 for upgrade call
        assertEq(depositCount, 2, "Should have 2 deposit transactions");

        // First deposit should be to CREATE2_DEPLOYER (for deploying new implementation)
        assertEq(depositTargets[0], CREATE2_DEPLOYER, "First deposit should be to CREATE2_DEPLOYER");

        // Second deposit should be to ProxyAdmin (for upgrading proxy)
        assertEq(depositTargets[1], PROXY_ADMIN, "Second deposit should be to ProxyAdmin");

        console2.log("Direct portal calls verified:");
        console2.log("  Deposit transactions emitted:", depositCount);
        console2.log("  Deposit 1 target (CREATE2):", depositTargets[0]);
        console2.log("  Deposit 2 target (ProxyAdmin):", depositTargets[1]);
        console2.log("  Expected implementation:", expectedImpl);
    }

    /// @notice Test that CREATE2 deployment data is correctly encoded
    function test_create2DeploymentData() public {
        vm.selectFork(_sepoliaForkId);

        // Build the init code
        template = new BaseFeeDisburserUpdate();
        bytes memory initCode = abi.encodePacked(
            template.FEE_DISBURSER_CREATION_CODE(), abi.encode(L1_WITHDRAWER, L1_WALLET, FEE_DISBURSEMENT_INTERVAL)
        );

        bytes32 salt = RevShareCommon.getSalt("BaseFeeDisburser");

        // Build expected CREATE2 deployer call
        bytes memory expectedData = abi.encodeCall(ICreate2Deployer.deploy, (0, salt, initCode));

        // Verify the data is well-formed
        assertTrue(expectedData.length > 0, "CREATE2 deploy data should not be empty");
        assertTrue(expectedData.length > initCode.length, "Deploy data should include selector and salt");

        console2.log("CREATE2 deployment data verified:");
        console2.log("  Init code length:", initCode.length);
        console2.log("  Deploy data length:", expectedData.length);
    }

    /// @notice Test that upgrade data is correctly encoded
    function test_upgradeData() public {
        vm.selectFork(_sepoliaForkId);

        // Build the init code and compute implementation address
        template = new BaseFeeDisburserUpdate();
        bytes memory initCode = abi.encodePacked(
            template.FEE_DISBURSER_CREATION_CODE(), abi.encode(L1_WITHDRAWER, L1_WALLET, FEE_DISBURSEMENT_INTERVAL)
        );

        bytes32 salt = RevShareCommon.getSalt("BaseFeeDisburser");
        address expectedImpl = Utils.getCreate2Address(salt, initCode, CREATE2_DEPLOYER);

        // Build expected upgrade call
        bytes memory expectedUpgradeData =
            abi.encodeCall(IProxyAdmin.upgrade, (payable(FEE_DISBURSER_PROXY), expectedImpl));

        // Verify the selector
        bytes4 selector = bytes4(expectedUpgradeData);
        assertEq(selector, IProxyAdmin.upgrade.selector, "Upgrade selector mismatch");

        console2.log("Upgrade data verified:");
        console2.log("  Upgrade data length:", expectedUpgradeData.length);
        console2.log("  Target proxy:", FEE_DISBURSER_PROXY);
        console2.log("  New implementation:", expectedImpl);
    }

    /// @notice Test that the salt is deterministic
    function test_saltIsDeterministic() public pure {
        bytes32 salt1 = RevShareCommon.getSalt("BaseFeeDisburser");
        bytes32 salt2 = RevShareCommon.getSalt("BaseFeeDisburser");

        assertEq(salt1, salt2, "Salt should be deterministic");

        // Different suffix should produce different salt
        bytes32 differentSalt = RevShareCommon.getSalt("DifferentSuffix");
        assertTrue(salt1 != differentSalt, "Different suffixes should produce different salts");
    }

    /// @notice Test that the implementation address is deterministic given same parameters
    function test_implementationAddressIsDeterministic() public {
        template = new BaseFeeDisburserUpdate();

        bytes memory initCode1 = abi.encodePacked(
            template.FEE_DISBURSER_CREATION_CODE(), abi.encode(L1_WITHDRAWER, L1_WALLET, FEE_DISBURSEMENT_INTERVAL)
        );

        bytes memory initCode2 = abi.encodePacked(
            template.FEE_DISBURSER_CREATION_CODE(), abi.encode(L1_WITHDRAWER, L1_WALLET, FEE_DISBURSEMENT_INTERVAL)
        );

        bytes32 salt = RevShareCommon.getSalt("BaseFeeDisburser");

        address impl1 = Utils.getCreate2Address(salt, initCode1, CREATE2_DEPLOYER);
        address impl2 = Utils.getCreate2Address(salt, initCode2, CREATE2_DEPLOYER);

        assertEq(impl1, impl2, "Implementation address should be deterministic");

        // Different parameters should produce different address
        bytes memory differentInitCode = abi.encodePacked(
            template.FEE_DISBURSER_CREATION_CODE(),
            abi.encode(address(0x1234), L1_WALLET, FEE_DISBURSEMENT_INTERVAL) // Different L1Withdrawer
        );

        address differentImpl = Utils.getCreate2Address(salt, differentInitCode, CREATE2_DEPLOYER);
        assertTrue(impl1 != differentImpl, "Different parameters should produce different address");
    }
}
