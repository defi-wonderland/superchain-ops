# Validation

This document can be used to validate the inputs and result of the execution of the upgrade transaction which you are
signing.

The steps are:

1. [Expected Domain and Message Hashes](#expected-domain-and-message-hashes)
2. [Normalized State Diff Hash Attestation](#normalized-state-diff-hash-attestation)
3. [Understanding Task Calldata](#understanding-task-calldata)
4. [Task State Changes](#task-state-changes)

## Expected Domain and Message Hashes

First, we need to validate the domain and message hashes. These values should match both the values on your ledger and
the values printed to the terminal when you run the task.

> [!CAUTION]
>
> Before signing, ensure the below hashes match what is on your ledger.
>
> ### SystemConfigOwner (`0x9245d5d10aa8a842b31530de71ea86c0760ca1b1`)
>
> - Domain Hash: `0xbea15583997db2831ec7dea58be331771c073bea8444c2b48ded663621f2260e`
> - Message Hash: `0xee63f474e2692515a974c3853f4ed586fa93a85c87b958e2687a615f8bc8ae9b`

## Normalized State Diff Hash Attestation

The normalized state diff hash is a single fingerprint of all the onchain state changes your task would make if executed. We “normalize” the diff first (stable ordering and encoding) so the hash only changes when the actual intended state changes do. You **MUST** ensure that the normalized hash produced from your simulation matches the normalized hash in this document.

**Normalized hash:** `0x569e75fc77c1a856f6daaf9e69d8a9566ca34aa47f9133711ce065a571af0cfd`

## Understanding Task Calldata

The command to encode the calldata is:

# TODO(17505): This address MUST be updated once the appropriate FeesDepositor is deployed

```bash
cast calldata 'updateL1Recipient(address)' 0xdeadbeef1234567890abcdef1234567890abcdef
```

The resulting calldata:

```
0xf62b6105000000000000000000000000deadbeef1234567890abcdef1234567890abcdef
```

# State Validations

For each contract listed in the state diff, please verify that no contracts or state changes shown in the Tenderly diff are missing from this document. Additionally, please verify that for each contract:

- The following state changes (and none others) are made to that contract. This validates that no unexpected state
  changes occur.
- All addresses (in section headers and storage values) match the provided name, using the Etherscan and Superchain
  Registry links provided. This validates the bytecode deployed at the addresses contains the correct logic.
- All key values match the semantic meaning provided, which can be validated using the storage layout links provided.

### Task State Changes

### `0x0bd48f6b86a26d3a217d0fa6ffe2b491b956a7a2` (OptimismPortal2) - Chain ID: 130

- **Key:** `0x0000000000000000000000000000000000000000000000000000000000000001`
  - **Decoded Kind:** `struct ResourceMetering.ResourceParams`
  - **Before:** ``
  - **After:** ``
  - **Summary:** params
  - **Detail:**

---

### `0x9245d5d10aa8a842b31530de71ea86c0760ca1b1` (SystemConfigOwner (GnosisSafe)) - Chain ID: 130

- **Key:** `0x0000000000000000000000000000000000000000000000000000000000000005`
  - **Decoded Kind:** `uint256`
  - **Before:** `4`
  - **After:** `5`
  - **Summary:** nonce
  - **Detail:**
