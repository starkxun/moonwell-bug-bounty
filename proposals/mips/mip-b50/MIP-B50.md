# MIP-B50: Moonwell Morpho Vault and stkWELL Incentive Campaigns

**Author(s):** Moonwell DAO, Joel Obafemi and Chidi Misheal **Submission Date:**
October 14th, 2025

## Summary

This proposal creates Merkle incentive campaigns for Moonwell's MetaMorpho
vaults (USDC, WETH, EURC, cbBTC, and meUSDC) and introduces a new incentive
campaign for stkWELL holders to encourage participation in the safety module.

The previous reward campaign contained an error where the staked WELL campaign
was set to September 10th rather than October 10th, as a result, that campaign
was cancelled. This new campaign promises retroactive reward distribution to
users since October 10th to rectify this error.

Merkl is an incentive distribution platform headed by the Angle Protocol team.
The protocol connects liquidity providers and distributes rewards on behalf of
both users and protocols. It leverages both onchain and offchain data to compute
rewards and points for campaigns, allowing for flexibility.

## Campaign Distribution

The proposal distributes a total of 11,108,152.23 WELL tokens across multiple
campaigns over the next 28 days:

- **USDC MetaMorpho Vault Campaign**: 1,500,000 WELL
- **WETH MetaMorpho Vault Campaign**: 750,000 WELL
- **EURC MetaMorpho Vault Campaign**: 400,000 WELL
- **cbBTC MetaMorpho Vault Campaign**: 400,000 WELL
- **meUSDC MetaMorpho Vault Campaign**: 923,076.92 WELL
- **stkWELL Safety Module Campaign**: 7,135,075.31 WELL

## Implementation

If this proposal passes, the following onchain actions will be executed:

1. Bridge required tokens from Moonbeam to Base (for MetaMorpho vault campaigns)
2. Approve Merkle campaign creator to spend WELL tokens
3. Accept Merkle campaign creator conditions
4. Create campaigns for all MetaMorpho vaults (USDC, WETH, EURC, cbBTC, meUSDC)
5. Create stkWELL safety module campaign (using existing Base funds)

## Voting Options

- **For:** Create the proposed incentive campaigns for MetaMorpho vaults and
  stkWELL
- **Against:** Do not create the incentive campaigns
- **Abstain**

## Conclusion

These incentive campaigns will drive liquidity to Moonwell's MetaMorpho vaults
and encourage participation in the safety module, strengthening the protocol's
security and growth. These incentive campaigns will also retroactively provide
rewards to users since October 10th to rectify the earlier proposal error.
