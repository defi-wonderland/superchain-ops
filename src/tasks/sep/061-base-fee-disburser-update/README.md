# 061-base-fee-disburser-update: Base Sepolia FeeDisburser Update

Status: [DRAFT]()

## Objective

Update Base Sepolia's `FeeDisburser` contract to point its `OPTIMISM_WALLET` immutable to the already-deployed `L1Withdrawer`. This enables Base Sepolia to participate in the Superchain revenue sharing system.

### Key Changes

1. **Deploy new FeeDisburser implementation** with:
   - `OPTIMISM_WALLET` = L1Withdrawer address (`0x7E077dB4e625bbc516c99FD2B0Dbf971D95E5Dff`)
   - `L1_WALLET` = preserved from current (`0x8D1b5e5614300F5c7ADA01fFA4ccF8F1752D9A57`)
   - `FEE_DISBURSEMENT_INTERVAL` = preserved from current (`604800` / 7 days)

2. **Upgrade FeeDisburser proxy** to point to the new implementation

### Addresses

| Contract | Address | Network |
|----------|---------|---------|
| Base Sepolia Portal (L1) | `0x49f53e41452C74589E85cA1677426Ba426459e85` | Ethereum Sepolia |
| FeeDisburser Proxy | `0x76355a67fcbcde6f9a69409a8ead5eaa9d8d875d` | Base Sepolia L2 |
| L1Withdrawer | `0x7E077dB4e625bbc516c99FD2B0Dbf971D95E5Dff` | Base Sepolia L2 |
| Current OPTIMISM_WALLET | `0x5A822ea15764a6090b86B1EABfFc051cEC99AFE9` | Base Sepolia L2 |
| L1_WALLET | `0x8D1b5e5614300F5c7ADA01fFA4ccF8F1752D9A57` | Ethereum Sepolia |

## Simulation & Signing

Simulation commands:

```bash
cd src/tasks/sep/061-base-fee-disburser-update
SIMULATE_WITHOUT_LEDGER=1 just --dotenv-path "$(pwd)"/.env --justfile ../../../justfile simulate
```

Signing commands:

```bash
cd src/tasks/sep/061-base-fee-disburser-update
just --dotenv-path "$(pwd)"/.env --justfile ../../../justfile sign
```

## Pre-requisites

Before executing this task:

1. **Deploy `BaseFeeDisburserUpgrader`** to Ethereum Sepolia
2. Update `baseFeeDisburserUpgrader` address in `config.toml`

## Verification

After execution, verify:

1. FeeDisburser proxy implementation is updated
2. `OPTIMISM_WALLET()` returns L1Withdrawer address
3. `L1_WALLET()` is unchanged
4. `FEE_DISBURSEMENT_INTERVAL()` is unchanged
5. `disburseFees()` sends Optimism share to L1Withdrawer
