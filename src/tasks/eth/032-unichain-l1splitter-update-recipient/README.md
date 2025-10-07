# 032-unichain-l1splitter-update-recipient

Status: [DRAFT, NOT READY TO SIGN]()

## Objective

This task updates the L1 Recipient of the `L1Splitter` contract on Unichain.

## Simulation & Signing

### Safe: 0x9245d5D10AA8a842B31530De71EA86c0760Ca1b1

```bash
cd src/tasks/eth/032-unichain-l1splitter-update-recipient
SIMULATE_WITHOUT_LEDGER=1 just --dotenv-path $(pwd)/.env simulate
```

Signing commands for each safe:

```bash
cd src/tasks/eth/029-swell-main-u13-to-u16a
just --dotenv-path $(pwd)/.env sign
```
