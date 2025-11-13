# Simulating L2 Deposit Transactions with Integration Tests

The following steps describe how to automatically simulate L2 deposit transactions prior to L1 task execution using integration tests. This approach is based on the [manual Tenderly simulation approach](./simulate-l2-ownership-transfer.md), with the difference that it uses a local supersim instance and automated transaction replay instead of manual Tenderly simulation.

## Overview

When executing L1 transactions that trigger L2 deposit transactions (via an OptimismPortal), we can gain additional confidence by automatically replaying these deposit transactions on a local L2 fork, simulating what op-node does. The `IntegrationBase` contract provides a `_relayAllMessages` function that:

1. Extracts all `TransactionDeposited` events from the L1 execution
2. Decodes the deposit transaction parameters
3. Executes each transaction on the L2 fork(s) with the correct aliased (if contract) sender
4. Asserts that all transactions succeed

This automated approach is particularly useful for complex tasks that emit multiple deposit transactions, such as the revenue share upgrade path which can emit 12+ deposit transactions per execution.

## Prerequisites

### Supersim Setup

You'll need to run supersim with forked chains to test against real network state. Supersim is a lightweight tool that runs local L1 and L2 nodes with forking capabilities.

Install supersim if you haven't already:

 https://github.com/ethereum-optimism/supersim

Start supersim with forked chains:
```bash
supersim fork --chains=op
```

**Note:** You can use any L2 chain supported by supersim (e.g., `op`, `base`, `mode`, etc.). The default ports are:
- L1 (Ethereum): `http://127.0.0.1:8545`
- L2 (OP Mainnet): `http://127.0.0.1:9545`

For different L2 chains, adjust the RPC URLs and network IDs accordingly.

## Creating an Integration Test

### Step 1: Inherit from IntegrationBase

Create a test contract that inherits from `IntegrationBase`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IntegrationBase} from "test/integration/IntegrationBase.t.sol";
import {YourTemplate} from "src/template/YourTemplate.sol";

contract YourIntegrationTest is IntegrationBase {
    YourTemplate public template;
    
    // Fork IDs
    uint256 internal _mainnetForkId;
    uint256 internal _l2ForkId;
    
    function setUp() public {
        // Create forks pointing to supersim instances
        _mainnetForkId = vm.createFork("http://127.0.0.1:8545");
        _l2ForkId = vm.createFork("http://127.0.0.1:9545");
        
        // Deploy template on L1 fork
        vm.selectFork(_mainnetForkId);
        template = new YourTemplate();
    }
}
```

### Step 2: Execute L1 Transaction and Relay Messages

In your test function, execute the L1 transaction while recording logs, then relay all deposit messages to L2:

```solidity
function test_yourTask_integration() public {
    string memory _configPath = "path/to/your/config.toml";
    
    // Step 1: Execute L1 transaction recording logs
    vm.recordLogs();
    template.simulate(_configPath, new address[](0));
    
    // Step 2: Relay messages from L1 to L2
    // Pass true for _isSimulate since simulate() emits events twice
    // (once during dry-run validation, once during actual simulation)
    _relayAllMessages(_l2ForkId, true);
    
    // Step 3: Assert the state of the L2 contracts
    string memory _config = vm.readFile(_configPath);
    
    // Add your L2 state assertions here...
}
```

### Step 3: Add State Assertions

After relaying messages, assert that the L2 state matches expectations:

```solidity
// Example: Checking a contract's owner
assertEq(
    OwnableUpgradeable(l2Contract).owner(),
    vm.parseTomlAddress(_config, ".newOwner")
);

// Example: Checking a configuration value
assertEq(
    IYourContract(l2Contract).someValue(),
    vm.parseTomlUint(_config, ".expectedValue")
);
```

## Example: Revenue Share Integration Test

See [RevenueShareIntegration.t.sol](../../test/integration/RevenueShareIntegration.t.sol) for a complete example that:

- Tests opt-in scenarios
- Validates multiple L2 contracts (L1Withdrawer, RevShareCalculator, FeeSplitter, FeeVaults)
- Asserts complex state relationships between contracts

Key test structure:
```solidity
function test_optInRevenueShare_integration() public {
    // 1. Execute L1 transaction
    vm.recordLogs();
    revenueShareTemplate.simulate(_configPath, new address[](0));
    
    // 2. Relay messages to L2
    _relayAllMessages(_l2ForkId, true);
    
    // 3. Assert L2 state
    assertEq(IL1Withdrawer(L1_WITHDRAWER).minWithdrawalAmount(), expectedValue);
    assertEq(IFeeSplitter(FEE_SPLITTER).sharesCalculator(), REV_SHARE_CALCULATOR);
    // ... more assertions
}
```

## Understanding the Output

When you run an integration test, `_relayAllMessages` will output:

```
================================================================================
=== Replaying Deposit Transactions on L2                                     ===
=== Network is set to 10                                                     ===
================================================================================

=== Summary ===
Total transactions: 11
Successful transactions: 11
Failed transactions: 0
```

## Troubleshooting

### Fork Issues
When first running the fork test against supersim, do it with a `--match-test` that does only one fork for caching the network states. If you try to run more than one at the same time by, for example, using `--match-contract`, you might get timeout issues
