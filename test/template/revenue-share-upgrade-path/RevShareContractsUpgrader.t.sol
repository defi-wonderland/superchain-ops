// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing
import {Test} from "forge-std/Test.sol";

// Contract under test
import {RevShareContractsUpgrader} from "src/RevShareContractsUpgrader.sol";

// Libraries
import {RevShareLibrary} from "src/libraries/RevShareLibrary.sol";
import {Utils} from "src/libraries/Utils.sol";

// Interfaces
import {IOptimismPortal2} from "@eth-optimism-bedrock/interfaces/L1/IOptimismPortal2.sol";
import {IProxyAdmin} from "@eth-optimism-bedrock/interfaces/universal/IProxyAdmin.sol";
import {ICreate2Deployer} from "src/interfaces/ICreate2Deployer.sol";
import {IFeeSplitter} from "src/interfaces/IFeeSplitter.sol";
import {IFeeVault} from "src/interfaces/IFeeVault.sol";

/// @title RevShareContractsUpgrader_TestInit
/// @notice Base test contract with shared setup and helpers for RevShareContractsUpgrader tests.
contract RevShareContractsUpgrader_TestInit is Test {
    // Contract under test
    RevShareContractsUpgrader internal upgrader;

    // Test constants
    address internal immutable PORTAL_ONE = makeAddr("PORTAL_ONE");
    address internal immutable PORTAL_TWO = makeAddr("PORTAL_TWO");
    address internal immutable L1_RECIPIENT_ONE = makeAddr("L1_RECIPIENT_ONE");
    address internal immutable L1_RECIPIENT_TWO = makeAddr("L1_RECIPIENT_TWO");
    address internal immutable CHAIN_FEES_RECIPIENT_ONE = makeAddr("CHAIN_FEES_RECIPIENT_ONE");
    address internal immutable CHAIN_FEES_RECIPIENT_TWO = makeAddr("CHAIN_FEES_RECIPIENT_TWO");
    uint256 internal immutable MIN_WITHDRAWAL_AMOUNT = 1 ether;
    uint32 internal immutable GAS_LIMIT = 500_000;

    /// @notice Test setup
    function setUp() public {
        upgrader = new RevShareContractsUpgrader();
    }

    /// @notice Helper function to setup a mock and expect a call to it.
    function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
        vm.mockCall(_receiver, _calldata, _returned);
        vm.expectCall(_receiver, _calldata);
    }

    /// @notice Helper to create L1WithdrawerConfig
    function _createL1WithdrawerConfig(uint256 _minWithdrawalAmount, address _recipient, uint32 _gasLimit)
        internal
        pure
        returns (RevShareContractsUpgrader.L1WithdrawerConfig memory)
    {
        return RevShareContractsUpgrader.L1WithdrawerConfig({
            minWithdrawalAmount: _minWithdrawalAmount,
            recipient: _recipient,
            gasLimit: _gasLimit
        });
    }

    /// @notice Helper to calculate expected CREATE2 address
    function _calculateExpectedCreate2Address(string memory _suffix, bytes memory _initCode)
        internal
        pure
        returns (address _expectedAddress)
    {
        bytes32 salt = keccak256(abi.encodePacked("RevShare", ":", _suffix));
        _expectedAddress = Utils.getCreate2Address(salt, _initCode, RevShareLibrary.CREATE2_DEPLOYER);
        assertNotEq(_expectedAddress, address(0));
    }

    /// @notice Helper to mock L1Withdrawer deployment
    function _mockL1WithdrawerDeploy(
        address _portal,
        uint256 _minWithdrawalAmount,
        address _recipient,
        uint32 _gasLimit
    ) internal {
        bytes memory l1WithdrawerInitCode = bytes.concat(
            RevShareLibrary.l1WithdrawerCreationCode, abi.encode(_minWithdrawalAmount, _recipient, _gasLimit)
        );
        bytes32 salt = keccak256(abi.encodePacked("RevShare", ":", "L1Withdrawer"));

        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (
                    RevShareLibrary.CREATE2_DEPLOYER,
                    0,
                    RevShareLibrary.L1_WITHDRAWER_DEPLOYMENT_GAS_LIMIT,
                    false,
                    abi.encodeCall(ICreate2Deployer.deploy, (0, salt, l1WithdrawerInitCode))
                )
            ),
            abi.encode()
        );
    }

    /// @notice Helper to mock Calculator deployment
    function _mockCalculatorDeploy(address _portal, address _l1Withdrawer, address _chainFeesRecipient) internal {
        bytes memory calculatorInitCode = bytes.concat(
            RevShareLibrary.scRevShareCalculatorCreationCode, abi.encode(_l1Withdrawer, _chainFeesRecipient)
        );
        bytes32 salt = keccak256(abi.encodePacked("RevShare", ":", "SCRevShareCalculator"));

        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (
                    RevShareLibrary.CREATE2_DEPLOYER,
                    0,
                    RevShareLibrary.SC_REV_SHARE_CALCULATOR_DEPLOYMENT_GAS_LIMIT,
                    false,
                    abi.encodeCall(ICreate2Deployer.deploy, (0, salt, calculatorInitCode))
                )
            ),
            abi.encode()
        );
    }

    /// @notice Helper to mock FeeSplitter deployment
    function _mockFeeSplitterDeployAndSetup(address _portal, address _calculator) internal {
        // FeeSplitter deployment deposit
        bytes32 salt = keccak256(abi.encodePacked("RevShare", ":", "FeeSplitter"));
        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (
                    RevShareLibrary.CREATE2_DEPLOYER,
                    0,
                    RevShareLibrary.FEE_SPLITTER_DEPLOYMENT_GAS_LIMIT,
                    false,
                    abi.encodeCall(ICreate2Deployer.deploy, (0, salt, RevShareLibrary.feeSplitterCreationCode))
                )
            ),
            abi.encode()
        );

        // Initialize FeeSplitter with calculator deposit
        address feeSplitterImpl =
            _calculateExpectedCreate2Address("FeeSplitter", RevShareLibrary.feeSplitterCreationCode);

        bytes memory upgradeCall = abi.encodeCall(
            IProxyAdmin.upgradeAndCall,
            (payable(RevShareLibrary.FEE_SPLITTER), feeSplitterImpl, abi.encodeCall(IFeeSplitter.initialize, (_calculator)))
        );

        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (RevShareLibrary.PROXY_ADMIN, 0, RevShareLibrary.UPGRADE_GAS_LIMIT, false, upgradeCall)
            ),
            abi.encode()
        );
    }

    /// @notice Helper to mock FeeSplitter setSharesCalculator call
    function _mockFeeSplitterSetCalculator(address _portal, address _calculator) internal {
        bytes memory setCalculatorCall = abi.encodeCall(IFeeSplitter.setSharesCalculator, (_calculator));

        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (RevShareLibrary.FEE_SPLITTER, 0, RevShareLibrary.SETTERS_GAS_LIMIT, false, setCalculatorCall)
            ),
            abi.encode()
        );
    }

    /// @notice Helper to mock a single vault deployment and upgrade
    function _mockVaultUpgrade(address _portal, address _vault, string memory _vaultName, bytes memory _creationCode)
        internal
    {
        // Mock vault implementation deployment
        bytes32 salt = keccak256(abi.encodePacked("RevShare", ":", _vaultName));
        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (
                    RevShareLibrary.CREATE2_DEPLOYER,
                    0,
                    RevShareLibrary.FEE_VAULTS_DEPLOYMENT_GAS_LIMIT,
                    false,
                    abi.encodeCall(ICreate2Deployer.deploy, (0, salt, _creationCode))
                )
            ),
            abi.encode()
        );

        // Mock vault upgrade call
        address vaultImpl = _calculateExpectedCreate2Address(_vaultName, _creationCode);
        bytes memory vaultUpgradeCall = abi.encodeCall(
            IProxyAdmin.upgradeAndCall,
            (
                payable(_vault),
                vaultImpl,
                abi.encodeCall(IFeeVault.initialize, (RevShareLibrary.FEE_SPLITTER, 0, IFeeVault.WithdrawalNetwork.L2))
            )
        );

        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (RevShareLibrary.PROXY_ADMIN, 0, RevShareLibrary.UPGRADE_GAS_LIMIT, false, vaultUpgradeCall)
            ),
            abi.encode()
        );
    }

    /// @notice Helper to mock a single vault setter calls
    function _mockVaultSetter(address _portal, address _vault) internal {
        // Mock setRecipient call
        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (
                    _vault,
                    0,
                    RevShareLibrary.SETTERS_GAS_LIMIT,
                    false,
                    abi.encodeCall(IFeeVault.setRecipient, (RevShareLibrary.FEE_SPLITTER))
                )
            ),
            abi.encode()
        );

        // Mock setMinWithdrawalAmount call
        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (
                    _vault,
                    0,
                    RevShareLibrary.SETTERS_GAS_LIMIT,
                    false,
                    abi.encodeCall(IFeeVault.setMinWithdrawalAmount, (0))
                )
            ),
            abi.encode()
        );

        // Mock setWithdrawalNetwork call
        _mockAndExpect(
            _portal,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (
                    _vault,
                    0,
                    RevShareLibrary.SETTERS_GAS_LIMIT,
                    false,
                    abi.encodeCall(IFeeVault.setWithdrawalNetwork, (IFeeVault.WithdrawalNetwork.L2))
                )
            ),
            abi.encode()
        );
    }

    /// @notice Helper to mock all vault upgrades (4 vaults)
    function _mockAllVaultUpgrades(address _portal) internal {
        _mockVaultUpgrade(
            _portal, RevShareLibrary.OPERATOR_FEE_VAULT, "OperatorFeeVault", RevShareLibrary.operatorFeeVaultCreationCode
        );
        _mockVaultUpgrade(
            _portal, RevShareLibrary.SEQUENCER_FEE_WALLET, "SequencerFeeVault", RevShareLibrary.sequencerFeeVaultCreationCode
        );
        _mockVaultUpgrade(_portal, RevShareLibrary.BASE_FEE_VAULT, "BaseFeeVault", RevShareLibrary.baseFeeVaultCreationCode);
        _mockVaultUpgrade(_portal, RevShareLibrary.L1_FEE_VAULT, "L1FeeVault", RevShareLibrary.l1FeeVaultCreationCode);
    }

    /// @notice Helper to mock all vault setters (4 vaults, 3 calls each = 12 calls total)
    function _mockAllVaultSetters(address _portal) internal {
        _mockVaultSetter(_portal, RevShareLibrary.OPERATOR_FEE_VAULT);
        _mockVaultSetter(_portal, RevShareLibrary.SEQUENCER_FEE_WALLET);
        _mockVaultSetter(_portal, RevShareLibrary.BASE_FEE_VAULT);
        _mockVaultSetter(_portal, RevShareLibrary.L1_FEE_VAULT);
    }
}

/// @title RevShareContractsUpgrader_UpgradeAndSetupRevShare_Test
/// @notice Tests for the upgradeAndSetupRevShare function of the RevShareContractsUpgrader contract.
contract RevShareContractsUpgrader_UpgradeAndSetupRevShare_Test is RevShareContractsUpgrader_TestInit {
    /// @notice Test that upgradeAndSetupRevShare reverts when portals array is empty
    function test_upgradeAndSetupRevShare_whenEmptyArray_reverts() public {
        address[] memory portals = new address[](0);
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](0);
        address[] memory chainRecipients = new address[](0);

        vm.expectRevert(RevShareContractsUpgrader.EmptyArray.selector);
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that upgradeAndSetupRevShare reverts when portals array length is shorter than others
    function test_upgradeAndSetupRevShare_whenPortalsLengthMismatch_reverts() public {
        // Portals array has wrong length (1 instead of 2)
        address[] memory portals = new address[](1);
        portals[0] = PORTAL_ONE;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](2);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);
        configs[1] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_TWO, GAS_LIMIT);

        address[] memory chainRecipients = new address[](2);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;
        chainRecipients[1] = CHAIN_FEES_RECIPIENT_TWO;

        vm.expectRevert(RevShareContractsUpgrader.ArrayLengthMismatch.selector);
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that upgradeAndSetupRevShare reverts when configs array length doesn't match portals
    function test_upgradeAndSetupRevShare_whenConfigsLengthMismatch_reverts() public {
        address[] memory portals = new address[](2);
        portals[0] = PORTAL_ONE;
        portals[1] = PORTAL_TWO;

        // Configs array has wrong length (1 instead of 2)
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);

        address[] memory chainRecipients = new address[](2);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;
        chainRecipients[1] = CHAIN_FEES_RECIPIENT_TWO;

        vm.expectRevert(RevShareContractsUpgrader.ArrayLengthMismatch.selector);
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that upgradeAndSetupRevShare reverts when chainRecipients array length doesn't match portals
    function test_upgradeAndSetupRevShare_whenChainRecipientsLengthMismatch_reverts() public {
        address[] memory portals = new address[](2);
        portals[0] = PORTAL_ONE;
        portals[1] = PORTAL_TWO;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](2);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);
        configs[1] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_TWO, GAS_LIMIT);

        // ChainRecipients array has wrong length (1 instead of 2)
        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;

        vm.expectRevert(RevShareContractsUpgrader.ArrayLengthMismatch.selector);
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that upgradeAndSetupRevShare reverts when portal address is zero
    function test_upgradeAndSetupRevShare_whenPortalIsZero_reverts() public {
        address[] memory portals = new address[](1);
        portals[0] = address(0); // Portal is zero

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;

        vm.expectRevert(RevShareContractsUpgrader.PortalCannotBeZeroAddress.selector);
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that upgradeAndSetupRevShare reverts when L1Withdrawer recipient is zero
    function test_upgradeAndSetupRevShare_whenL1WithdrawerRecipientIsZero_reverts() public {
        address[] memory portals = new address[](1);
        portals[0] = PORTAL_ONE;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        // L1Withdrawer recipient is zero address
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, address(0), GAS_LIMIT);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;

        vm.expectRevert(RevShareContractsUpgrader.L1WithdrawerRecipientCannotBeZeroAddress.selector);
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that upgradeAndSetupRevShare reverts when chain fees recipient is zero
    function test_upgradeAndSetupRevShare_whenChainFeesRecipientIsZero_reverts() public {
        address[] memory portals = new address[](1);
        portals[0] = PORTAL_ONE;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = address(0); // Chain fees recipient is zero

        vm.expectRevert(RevShareContractsUpgrader.ChainFeesRecipientCannotBeZeroAddress.selector);
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Fuzz test successful upgradeAndSetupRevShare with single chain
    function testFuzz_upgradeAndSetupRevShare_singleChain_succeeds(
        address _portal,
        uint256 _minWithdrawalAmount,
        address _l1Recipient,
        uint32 _gasLimit,
        address _chainFeesRecipient
    ) public {
        // Bound inputs to valid ranges
        vm.assume(_portal != address(0));
        vm.assume(_l1Recipient != address(0));
        vm.assume(_chainFeesRecipient != address(0));
        bound(_gasLimit, 1, type(uint32).max);

        address[] memory portals = new address[](1);
        portals[0] = _portal;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(_minWithdrawalAmount, _l1Recipient, _gasLimit);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = _chainFeesRecipient;

        // Calculate expected L1Withdrawer address
        bytes memory l1WithdrawerInitCode = bytes.concat(
            RevShareLibrary.l1WithdrawerCreationCode, abi.encode(_minWithdrawalAmount, _l1Recipient, _gasLimit)
        );
        address expectedL1Withdrawer = _calculateExpectedCreate2Address("L1Withdrawer", l1WithdrawerInitCode);

        // Calculate expected Calculator address
        bytes memory calculatorInitCode = bytes.concat(
            RevShareLibrary.scRevShareCalculatorCreationCode, abi.encode(expectedL1Withdrawer, _chainFeesRecipient)
        );
        address expectedCalculator = _calculateExpectedCreate2Address("SCRevShareCalculator", calculatorInitCode);

        // Mock all calls with strict abi.encodeCall
        _mockL1WithdrawerDeploy(_portal, _minWithdrawalAmount, _l1Recipient, _gasLimit);
        _mockCalculatorDeploy(_portal, expectedL1Withdrawer, _chainFeesRecipient);
        _mockFeeSplitterDeployAndSetup(_portal, expectedCalculator);
        _mockAllVaultUpgrades(_portal);

        // Execute
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Fuzz test successful upgradeAndSetupRevShare with multiple chains
    function testFuzz_upgradeAndSetupRevShare_multipleChains_succeeds(uint8 _numChains, uint256 _seed) public {
        // Bound to reasonable range: 2-50 chains
        _numChains = uint8(bound(_numChains, 2, 50));

        // Setup arrays
        address[] memory portals = new address[](_numChains);
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](_numChains);
        address[] memory chainRecipients = new address[](_numChains);

        // Generate random configs and setup mocks for each chain
        for (uint256 i; i < _numChains; ++i) {
            // Use seed + index to generate pseudo-random but deterministic values
            uint256 chainSeed = uint256(keccak256(abi.encode(_seed, i)));

            // Generate random but valid addresses (non-zero)
            address portal = makeAddr(string.concat("portal_", vm.toString(chainSeed)));
            address l1Recipient = makeAddr(string.concat("l1recipient_", vm.toString(chainSeed)));
            address chainFeeRecipient = makeAddr(string.concat("chainfee_", vm.toString(chainSeed)));

            // Generate random config values
            uint256 minWithdrawalAmount =
                bound(uint256(keccak256(abi.encode(chainSeed, "minwithdrawal"))), 1, type(uint256).max);
            uint32 gasLimit = uint32(bound(uint256(keccak256(abi.encode(chainSeed, "gaslimit"))), 1, type(uint32).max));

            portals[i] = portal;
            configs[i] = _createL1WithdrawerConfig(minWithdrawalAmount, l1Recipient, gasLimit);
            chainRecipients[i] = chainFeeRecipient;

            // Calculate expected addresses for this chain
            bytes memory l1WithdrawerInitCode =
                bytes.concat(RevShareLibrary.l1WithdrawerCreationCode, abi.encode(minWithdrawalAmount, l1Recipient, gasLimit));
            address expectedL1Withdrawer = _calculateExpectedCreate2Address("L1Withdrawer", l1WithdrawerInitCode);

            bytes memory calculatorInitCode = bytes.concat(
                RevShareLibrary.scRevShareCalculatorCreationCode, abi.encode(expectedL1Withdrawer, chainFeeRecipient)
            );
            address expectedCalculator = _calculateExpectedCreate2Address("SCRevShareCalculator", calculatorInitCode);

            // Setup mocks for this chain
            _mockL1WithdrawerDeploy(portal, minWithdrawalAmount, l1Recipient, gasLimit);
            _mockCalculatorDeploy(portal, expectedL1Withdrawer, chainFeeRecipient);
            _mockFeeSplitterDeployAndSetup(portal, expectedCalculator);
            _mockAllVaultUpgrades(portal);
        }

        // Execute once with all chains
        upgrader.upgradeAndSetupRevShare(portals, configs, chainRecipients);
    }
}

/// @title RevShareContractsUpgrader_SetupRevShare_Test
/// @notice Tests for the setupRevShare function of the RevShareContractsUpgrader contract.
contract RevShareContractsUpgrader_SetupRevShare_Test is RevShareContractsUpgrader_TestInit {
    /// @notice Test that setupRevShare reverts when portals array is empty
    function test_setupRevShare_whenEmptyArray_reverts() public {
        address[] memory portals = new address[](0);
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](0);
        address[] memory chainRecipients = new address[](0);

        vm.expectRevert(RevShareContractsUpgrader.EmptyArray.selector);
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that setupRevShare reverts when portals array length is shorter than others
    function test_setupRevShare_whenPortalsLengthMismatch_reverts() public {
        // Portals array has wrong length (1 instead of 2)
        address[] memory portals = new address[](1);
        portals[0] = PORTAL_ONE;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](2);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);
        configs[1] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_TWO, GAS_LIMIT);

        address[] memory chainRecipients = new address[](2);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;
        chainRecipients[1] = CHAIN_FEES_RECIPIENT_TWO;

        vm.expectRevert(RevShareContractsUpgrader.ArrayLengthMismatch.selector);
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that setupRevShare reverts when configs array length doesn't match portals
    function test_setupRevShare_whenConfigsLengthMismatch_reverts() public {
        address[] memory portals = new address[](2);
        portals[0] = PORTAL_ONE;
        portals[1] = PORTAL_TWO;

        // Configs array has wrong length (1 instead of 2)
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);

        address[] memory chainRecipients = new address[](2);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;
        chainRecipients[1] = CHAIN_FEES_RECIPIENT_TWO;

        vm.expectRevert(RevShareContractsUpgrader.ArrayLengthMismatch.selector);
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that setupRevShare reverts when chainRecipients array length doesn't match portals
    function test_setupRevShare_whenChainRecipientsLengthMismatch_reverts() public {
        address[] memory portals = new address[](2);
        portals[0] = PORTAL_ONE;
        portals[1] = PORTAL_TWO;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](2);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);
        configs[1] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_TWO, GAS_LIMIT);

        // ChainRecipients array has wrong length (1 instead of 2)
        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;

        vm.expectRevert(RevShareContractsUpgrader.ArrayLengthMismatch.selector);
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that setupRevShare reverts when portal address is zero
    function test_setupRevShare_whenPortalIsZero_reverts() public {
        address[] memory portals = new address[](1);
        portals[0] = address(0); // Portal is zero

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;

        vm.expectRevert(RevShareContractsUpgrader.PortalCannotBeZeroAddress.selector);
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that setupRevShare reverts when L1Withdrawer recipient is zero
    function test_setupRevShare_whenL1WithdrawerRecipientIsZero_reverts() public {
        address[] memory portals = new address[](1);
        portals[0] = PORTAL_ONE;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        // L1Withdrawer recipient is zero address
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, address(0), GAS_LIMIT);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = CHAIN_FEES_RECIPIENT_ONE;

        vm.expectRevert(RevShareContractsUpgrader.L1WithdrawerRecipientCannotBeZeroAddress.selector);
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Test that setupRevShare reverts when chain fees recipient is zero
    function test_setupRevShare_whenChainFeesRecipientIsZero_reverts() public {
        address[] memory portals = new address[](1);
        portals[0] = PORTAL_ONE;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(MIN_WITHDRAWAL_AMOUNT, L1_RECIPIENT_ONE, GAS_LIMIT);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = address(0); // Chain fees recipient is zero

        vm.expectRevert(RevShareContractsUpgrader.ChainFeesRecipientCannotBeZeroAddress.selector);
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Fuzz test successful setupRevShare with single chain
    function testFuzz_setupRevShare_singleChain_succeeds(
        address _portal,
        uint256 _minWithdrawalAmount,
        address _l1Recipient,
        uint32 _gasLimit,
        address _chainFeesRecipient
    ) public {
        // Bound inputs to valid ranges
        vm.assume(_portal != address(0));
        vm.assume(_l1Recipient != address(0));
        vm.assume(_chainFeesRecipient != address(0));
        bound(_gasLimit, 1, type(uint32).max);

        address[] memory portals = new address[](1);
        portals[0] = _portal;

        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](1);
        configs[0] = _createL1WithdrawerConfig(_minWithdrawalAmount, _l1Recipient, _gasLimit);

        address[] memory chainRecipients = new address[](1);
        chainRecipients[0] = _chainFeesRecipient;

        // Calculate expected addresses
        bytes memory l1WithdrawerInitCode = bytes.concat(
            RevShareLibrary.l1WithdrawerCreationCode, abi.encode(_minWithdrawalAmount, _l1Recipient, _gasLimit)
        );
        address expectedL1Withdrawer = _calculateExpectedCreate2Address("L1Withdrawer", l1WithdrawerInitCode);

        bytes memory calculatorInitCode = bytes.concat(
            RevShareLibrary.scRevShareCalculatorCreationCode, abi.encode(expectedL1Withdrawer, _chainFeesRecipient)
        );
        address expectedCalculator = _calculateExpectedCreate2Address("SCRevShareCalculator", calculatorInitCode);

        // Mock all calls (setupRevShare deploys periphery, sets calculator, and configures vaults)
        _mockL1WithdrawerDeploy(_portal, _minWithdrawalAmount, _l1Recipient, _gasLimit);
        _mockCalculatorDeploy(_portal, expectedL1Withdrawer, _chainFeesRecipient);
        _mockFeeSplitterSetCalculator(_portal, expectedCalculator);
        _mockAllVaultSetters(_portal);

        // Execute
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }

    /// @notice Fuzz test successful setupRevShare with multiple chains
    function testFuzz_setupRevShare_multipleChains_succeeds(uint8 _numChains, uint256 _seed) public {
        // Bound to reasonable range: 2-50 chains
        _numChains = uint8(bound(_numChains, 2, 50));

        // Setup arrays
        address[] memory portals = new address[](_numChains);
        RevShareContractsUpgrader.L1WithdrawerConfig[] memory configs =
            new RevShareContractsUpgrader.L1WithdrawerConfig[](_numChains);
        address[] memory chainRecipients = new address[](_numChains);

        // Generate random configs and setup mocks for each chain
        for (uint256 i; i < _numChains; ++i) {
            // Use seed + index to generate pseudo-random but deterministic values
            uint256 chainSeed = uint256(keccak256(abi.encode(_seed, i)));

            // Generate random but valid addresses (non-zero)
            address portal = makeAddr(string.concat("portal_", vm.toString(chainSeed)));
            address l1Recipient = makeAddr(string.concat("l1recipient_", vm.toString(chainSeed)));
            address chainFeeRecipient = makeAddr(string.concat("chainfee_", vm.toString(chainSeed)));

            // Generate random config values
            uint256 minWithdrawalAmount =
                bound(uint256(keccak256(abi.encode(chainSeed, "minwithdrawal"))), 1, type(uint256).max);
            uint32 gasLimit = uint32(bound(uint256(keccak256(abi.encode(chainSeed, "gaslimit"))), 1, type(uint32).max));

            portals[i] = portal;
            configs[i] = _createL1WithdrawerConfig(minWithdrawalAmount, l1Recipient, gasLimit);
            chainRecipients[i] = chainFeeRecipient;

            // Calculate expected addresses for this chain
            bytes memory l1WithdrawerInitCode =
                bytes.concat(RevShareLibrary.l1WithdrawerCreationCode, abi.encode(minWithdrawalAmount, l1Recipient, gasLimit));
            address expectedL1Withdrawer = _calculateExpectedCreate2Address("L1Withdrawer", l1WithdrawerInitCode);

            bytes memory calculatorInitCode = bytes.concat(
                RevShareLibrary.scRevShareCalculatorCreationCode, abi.encode(expectedL1Withdrawer, chainFeeRecipient)
            );
            address expectedCalculator = _calculateExpectedCreate2Address("SCRevShareCalculator", calculatorInitCode);

            // Setup mocks for this chain (setupRevShare deploys periphery, sets calculator, and configures vaults)
            _mockL1WithdrawerDeploy(portal, minWithdrawalAmount, l1Recipient, gasLimit);
            _mockCalculatorDeploy(portal, expectedL1Withdrawer, chainFeeRecipient);
            _mockFeeSplitterSetCalculator(portal, expectedCalculator);
            _mockAllVaultSetters(portal);
        }

        // Execute once with all chains
        upgrader.setupRevShare(portals, configs, chainRecipients);
    }
}
