# 037-rev-share-ink-soneium: RevShare Upgrade and Setup for Ink and Soneium Mainnets

Status: [DRAFT, NOT READY TO SIGN]()

## Objective

Upgrade proxies and setup RevShare contracts for Ink and Soneium Mainnets. This task:

1. Upgrades the fee vault proxy implementations (SequencerFeeVault, BaseFeeVault, L1FeeVault, OperatorFeeVault) on Ink and Soneium L2s and the FeeSplitter
2. Initializes the FeeSplitter with the RevShareCalculator and L1Withdrawer addresses
3. Configures the fee distribution to send the Optimism Collective's 15% revenue share to the FeesDepositor on L1

Target chains:

- Ink Mainnet (chainId: 57073)
- Soneium Mainnet (chainId: 1868)

## Simulation & Signing

Simulation commands for each safe:

```bash
cd src/tasks/eth/037-rev-share-ink-soneium
SIMULATE_WITHOUT_LEDGER=1 just --dotenv-path "$(pwd)"/.env --justfile ../../../justfile simulate <council|foundation>
```

Signing commands for each safe:

```bash
cd src/tasks/eth/037-rev-share-ink-soneium
SIMULATE_WITHOUT_LEDGER=1 just --dotenv-path "$(pwd)"/.env --justfile ../../../justfile sign <council|foundation>
```
