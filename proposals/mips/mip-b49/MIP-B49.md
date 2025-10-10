# MIP-B49: Moonwell Ecosystem USDC Vault Addition

**Author(s):** Anthias Labs **Submission Date:** October 10th, 2025

## Proposal Summary

This proposal creates a new Moonwell Ecosystem USDC Vault (meUSDC), accepts
ownership on behalf of the temporal governor and sets Anthias Labs as the
allocator. This proposal establishes a new Morpho vault for USDC as part of the
Moonwell ecosystem expansion. The vault will be managed by Anthias Labs as
allocator, providing professional vault management and risk oversight.

This MIP proposes:

1. Accept the Moonwell Ecosystem USDC Vault ownership
2. Set the allocator as Anthias Labs

## Background and Rationale

Building on the successful collaboration between the Moonwell DAO, Anthias Labs,
and Morpho, this proposal introduces a credit line for WELL tokens. This
facility establishes infrastructure to finance the next phase of Moonwell’s
growth through Morpho, enabling the DAO to fund operations and expansion in a
capital-efficient way that preserves long-term alignment.

## Vault Configuration and Roles

The Moonwell Ecosystem USDC Vault will be configured as follows:

- **Allocator:** Public allocator contract and Risk Manager Multisig
  (0x09f96462CA418aCf8f4570149d1533Ab5030EAdC)
- **Guardian:** Moonwell Security Council (specifically, setting the guardian to
  the security council multisig: 0x446342AF4F3bCD374276891C6bb3411bf2F8779E)
- **Vault name:** Moonwell Ecosystem USDC
- **Symbol:** meUSDC

## Performance Fee and Liquidity Incentives

This proposal seeks to implement a **0% performance fee** for the new Ecosystem
USDC Vault. This proposal will have no liquidity incentives as well.

## Implementation

fcur If this proposal passes, the following onchain actions will be executed:

1. Moonwell DAO will accept the Moonwell Ecosystem USDC Vault ownership
2. Set the allocator as Anthias Labs

## Voting Options

- **For:** Accept ownership of Moonwell Ecosystem USDC vault and proposed
  markets with a 0% performance fee.
- **Against:** Reject ownership of Moonwell Ecosystem USDC vault and proposed
  markets, and maintain current performance fee structure.
- **Abstain**

## Conclusion

The addition of a Moonwell Ecosystem USDC Vault represents a strategic expansion
of Moonwell on Base. By leveraging Morpho infrastructure and the risk management
expertise of Anthias Labs, this initiative supports the long-term growth of the
protocol and its ecosystem.
