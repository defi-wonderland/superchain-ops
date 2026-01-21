# 040-base-fee-disburser-update: Base FeeDisburser Update

Status: [DRAFT]()

## Objective

Update Base's `FeeDisburser` contract to point its `OPTIMISM_WALLET` immutable to the already-deployed `L1Withdrawer`. This enables Base to participate in the Superchain revenue sharing system.

### Key Changes

1. **Deploy new FeeDisburser implementation** with:
   - `OPTIMISM_WALLET` = L1Withdrawer address (`0x5f077b4c3509C2c192e50B6654d924Fcb8126A60`)
   - `L1_WALLET` = preserved from current (`0x23B597f33f6f2621F77DA117523Dffd634cDf4ea`)
   - `FEE_DISBURSEMENT_INTERVAL` = preserved from current (`86400` / 24 hours)

2. **Upgrade FeeDisburser proxy** to point to the new implementation

### Addresses

| Contract | Address | Network |
|----------|---------|---------|
| Base Portal (L1) | `0x49048044D57e1C92A77f79988d21Fa8fAF74E97e` | Ethereum Mainnet |
| FeeDisburser Proxy | `0x09c7bad99688a55a2e83644bfaed09e62bdcccba` | Base L2 |
| L1Withdrawer | `0x5f077b4c3509C2c192e50B6654d924Fcb8126A60` | Base L2 |
| Current OPTIMISM_WALLET | `0x9c3631dDE5c8316bE5B7554B0CcD2631C15a9A05` | Base L2 |
| L1_WALLET | `0x23B597f33f6f2621F77DA117523Dffd634cDf4ea` | Ethereum Mainnet |

## Simulation & Signing

Simulation commands:

```bash
cd src/tasks/eth/040-base-fee-disburser-update
SIMULATE_WITHOUT_LEDGER=1 just --dotenv-path "$(pwd)"/.env --justfile ../../../justfile simulate
```

Signing commands:

```bash
cd src/tasks/eth/040-base-fee-disburser-update
just --dotenv-path "$(pwd)"/.env --justfile ../../../justfile sign
```

## Pre-requisites

Before executing this task:

1. **Deploy `BaseFeeDisburserUpgrader`** to Ethereum mainnet
2. Update `baseFeeDisburserUpgrader` address in `config.toml`

## Verification

After execution, verify:

1. FeeDisburser proxy implementation is updated
2. `OPTIMISM_WALLET()` returns L1Withdrawer address
3. `L1_WALLET()` is unchanged
4. `FEE_DISBURSEMENT_INTERVAL()` is unchanged
5. `disburseFees()` sends Optimism share to L1Withdrawer
