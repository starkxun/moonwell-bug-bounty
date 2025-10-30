# MIP-B51: Change Moonwell USDC Ecosystem Vault Timelock

**Author(s):** Moonwell DAO **Submission Date:** October 27th, 2025

## Summary

This proposal updates the Moonwell USDC Ecosystem Vault Timelock to a 72-hour
delay, aligning it with the latest risk management and operational standards
requested by Anthias and confirmed by the team. The The Moonwell Ecosystem USDC
vault allows for borrowable liquidity for three new isolated markets on Base,
WELL/USDC, stkWELL/USDC, and MAMO/USDC. Vault depositors are rewarded with fees
creating a beneficial relationship. The stkWELL/USDC market in particular will
allow for new utility by giving liquid access for safety module users. Finally,
this launch culminates the creation of a credit facility to support Moonwell and
its operational expansion.

## Motivation

The current timelock setting does not provide an optimal delay for governance
and operational safety. Per Morpho documentation and confirmed by the
MetaMorphoV1_1 contract implementation, only the vault owner can modify the
timelock parameter.

This proposal ensures the vault’s delay aligns with community standards and
allows sufficient buffer time for review before execution.

## Implementation

If this proposal passes, the following onchain actions will be executed:

Action:

- Call setTimelock(72 hours) on the Vault contract.

## Voting Options

- **For:** Change the timelock
- **Against:** Do not change the timelock
- **Abstain**

## Conclusion

Updating the timelock to 72 hours for the Moonwell USDC Ecosystem Vault enhances
operational security while maintaining flexibility for governance and curators.
This adjustment aligns the vault with Moonwell’s broader risk management
standards and ensures that all future vault actions are subject to a
standardized 72-hour review window, improving transparency and stakeholder
confidence.
