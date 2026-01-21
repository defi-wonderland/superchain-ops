# VALIDATION

This document describes the validation steps for the Base FeeDisburser Update task.

## Overview

This task upgrades Base's FeeDisburser proxy to a new implementation where `OPTIMISM_WALLET` points to the L1Withdrawer contract, enabling revenue sharing.

## Pre-Upgrade State

Before the upgrade, verify the current FeeDisburser state on Base L2:

```bash
# Current OPTIMISM_WALLET (should be 0x9c3631dDE5c8316bE5B7554B0CcD2631C15a9A05)
cast call 0x09c7bad99688a55a2e83644bfaed09e62bdcccba "OPTIMISM_WALLET()(address)" --rpc-url https://mainnet.base.org

# Current L1_WALLET (should be 0x23B597f33f6f2621F77DA117523Dffd634cDf4ea)
cast call 0x09c7bad99688a55a2e83644bfaed09e62bdcccba "L1_WALLET()(address)" --rpc-url https://mainnet.base.org

# Current FEE_DISBURSEMENT_INTERVAL (should be 86400)
cast call 0x09c7bad99688a55a2e83644bfaed09e62bdcccba "FEE_DISBURSEMENT_INTERVAL()(uint256)" --rpc-url https://mainnet.base.org
```

## Post-Upgrade State

After the L1 deposit transactions are relayed to L2, verify:

### 1. OPTIMISM_WALLET Updated

```bash
# Should return L1Withdrawer address: 0x5f077b4c3509C2c192e50B6654d924Fcb8126A60
cast call 0x09c7bad99688a55a2e83644bfaed09e62bdcccba "OPTIMISM_WALLET()(address)" --rpc-url https://mainnet.base.org
```

### 2. L1_WALLET Preserved

```bash
# Should still be: 0x23B597f33f6f2621F77DA117523Dffd634cDf4ea
cast call 0x09c7bad99688a55a2e83644bfaed09e62bdcccba "L1_WALLET()(address)" --rpc-url https://mainnet.base.org
```

### 3. FEE_DISBURSEMENT_INTERVAL Preserved

```bash
# Should still be: 86400
cast call 0x09c7bad99688a55a2e83644bfaed09e62bdcccba "FEE_DISBURSEMENT_INTERVAL()(uint256)" --rpc-url https://mainnet.base.org
```

### 4. Implementation Address Updated

```bash
# Get the new implementation address from ProxyAdmin
cast call 0x4200000000000000000000000000000000000018 "getProxyImplementation(address)(address)" 0x09c7bad99688a55a2e83644bfaed09e62bdcccba --rpc-url https://mainnet.base.org
```

## Functional Verification

After upgrade, verify `disburseFees()` works correctly:

1. Wait for the disbursement interval to pass (or test on a fork)
2. Call `disburseFees()` on the FeeDisburser
3. Verify that the Optimism share (15% of net revenue or 2.5% of gross revenue, whichever is higher) is sent to L1Withdrawer
4. Verify L1Withdrawer receives the funds and can initiate withdrawal to L1

## Security Considerations

- The upgrade only changes `OPTIMISM_WALLET` - no other behavior is modified
- `L1_WALLET` and `FEE_DISBURSEMENT_INTERVAL` are preserved from the current contract
- The new implementation uses the same FeeDisburser logic from base-contracts
