# VALIDATION

This document describes the validation steps for the Base Sepolia FeeDisburser Update task.

## Overview

This task upgrades Base Sepolia's FeeDisburser proxy to a new implementation where `OPTIMISM_WALLET` points to the L1Withdrawer contract, enabling revenue sharing.

## Pre-Upgrade State

Before the upgrade, verify the current FeeDisburser state on Base Sepolia L2:

```bash
# Current OPTIMISM_WALLET (should be 0x5A822ea15764a6090b86B1EABfFc051cEC99AFE9)
cast call 0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d "OPTIMISM_WALLET()(address)" --rpc-url https://sepolia.base.org

# Current L1_WALLET (should be 0x8D1b5e5614300F5c7ADA01fFA4ccF8F1752D9A57)
cast call 0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d "L1_WALLET()(address)" --rpc-url https://sepolia.base.org

# Current FEE_DISBURSEMENT_INTERVAL (should be 604800)
cast call 0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d "FEE_DISBURSEMENT_INTERVAL()(uint256)" --rpc-url https://sepolia.base.org
```

## Post-Upgrade State

After the L1 deposit transactions are relayed to L2, verify:

### 1. OPTIMISM_WALLET Updated

```bash
# Should return L1Withdrawer address: 0x7E077dB4e625bbc516c99FD2B0Dbf971D95E5Dff
cast call 0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d "OPTIMISM_WALLET()(address)" --rpc-url https://sepolia.base.org
```

### 2. L1_WALLET Preserved

```bash
# Should still be: 0x8D1b5e5614300F5c7ADA01fFA4ccF8F1752D9A57
cast call 0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d "L1_WALLET()(address)" --rpc-url https://sepolia.base.org
```

### 3. FEE_DISBURSEMENT_INTERVAL Preserved

```bash
# Should still be: 604800
cast call 0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d "FEE_DISBURSEMENT_INTERVAL()(uint256)" --rpc-url https://sepolia.base.org
```

### 4. Implementation Address Updated

```bash
# Get the new implementation address from ProxyAdmin
cast call 0x4200000000000000000000000000000000000018 "getProxyImplementation(address)(address)" 0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d --rpc-url https://sepolia.base.org
```

## Functional Verification

After upgrade, verify `disburseFees()` works correctly:

1. Wait for the disbursement interval to pass (7 days on Sepolia, or test on a fork)
2. Call `disburseFees()` on the FeeDisburser
3. Verify that the Optimism share (15% of net revenue or 2.5% of gross revenue, whichever is higher) is sent to L1Withdrawer
4. Verify L1Withdrawer receives the funds and can initiate withdrawal to L1

## Security Considerations

- The upgrade only changes `OPTIMISM_WALLET` - no other behavior is modified
- `L1_WALLET` and `FEE_DISBURSEMENT_INTERVAL` are preserved from the current contract
- The new implementation uses the same FeeDisburser logic from base-contracts
