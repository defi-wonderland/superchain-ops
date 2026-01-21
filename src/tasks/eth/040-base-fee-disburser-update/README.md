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

## Simulation & Signing

TODO