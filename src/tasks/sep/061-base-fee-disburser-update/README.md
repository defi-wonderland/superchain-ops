# 061-base-fee-disburser-update: Base Sepolia FeeDisburser Update

Status: [DRAFT]()

## Objective

Update Base's `FeeDisburser` contract to point its `OPTIMISM_WALLET` immutable to the already-deployed `L1Withdrawer`. This enables Base to participate in the Superchain revenue sharing system.

### Key Changes

1. **Deploy new FeeDisburser implementation** with:
   - `OPTIMISM_WALLET` = L1Withdrawer address (`0x7E077dB4e625bbc516c99FD2B0Dbf971D95E5Dff`)
   - `L1_WALLET` = preserved from current (`0x8D1b5e5614300F5c7ADA01fFA4ccF8F1752D9A57`)
   - `FEE_DISBURSEMENT_INTERVAL` = preserved from current (`604800` / 7 days)

2. **Upgrade FeeDisburser proxy** to point to the new implementation

## Simulation & Signing

TODO