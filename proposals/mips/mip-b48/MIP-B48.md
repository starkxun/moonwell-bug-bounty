# MIP-B48: Add MAMO Market to Moonwell on Base

## Summary

This proposal seeks to onboard $MAMO, the token behind the AI financial
management application, [Mamo](https://mamo.bot/), as a new collateral asset on
Moonwell’s Base deployment. Mamo is designed to make decentralized finance more
accessible by providing users with an AI-powered companion that helps them save,
invest, and manage digital assets with clarity and security. Backed by audited
smart contracts, Mamo provides an intuitive user experience with automated
portfolio management, giving individuals the ability to grow their wealth
without navigating complex DeFi mechanics. For additional details, please review
the Mamo documentation.

## Token Information

- **Name:** MAMO
- **Token Standard:** ERC20
- **Total Supply:** 1,000,000,000 MAMO
- **Circulating Supply (Base):** 376,110,694 MAMO
- **Token Contract:**
  [0x7300b37dfdfab110d83290a29dfb31b1740219fe](https://basescan.org/token/0x7300b37dfdfab110d83290a29dfb31b1740219fe)
- **Price Feed:**
  [Chainlink MAMO/USD](https://basescan.org/address/0xeF7541b388a77C1709a3d44BfBfC5c1ED3F0Ac94)

## Anthias' Risk Analysis and Recommendations

### Initial Risk Parameters

| **Parameter**          | **Value** |
| ---------------------- | --------- |
| Collateral Factor (CF) | 50%       |
| Reserve Factor         | 30%       |
| Liquidation Incentive  | 110%      |
| Supply Cap             | 20M MAMO  |
| Borrow Cap             | 12M MAMO  |
| Base Rate              | 0%        |
| Multiplier             | .45       |
| Jump Multiplier        | 5         |
| Kink                   | 0.6       |

### Projected APYs

With a reserve factor of 30%

| Utilization | Borrow APY | Supply APY |
| ----------- | ---------- | ---------- |
| 0%          | 0%         | 0%         |
| 60% (kink)  | 27%        | 11.34%     |
| 100%        | 227%       | 158.9%     |

The proposed curve is designed to establish a broad initial range for smooth
discovery of borrow rates (between 0 and 27%). This is mainly because the
rewards for supplying MAMO on mamo.bot are particularly high. The proposed curve
will allow for smooth discovery for a carry trade strategy where users borrow
MAMO on Moonwell and supply it on mamo.bot earning the spread between the borrow
rate and supply rewards. As this market is populated, and utilization trends
emerge, further optimizations to IR parameters can be made.

#### Interest Rate Curve

| Name            | Value                                      | Description              |
| --------------- | ------------------------------------------ | ------------------------ |
| loanToken       | 0x833589fcd6edb6e08f4c7c32d4f71b54bda02913 | USDC on Base             |
| collateralToken | 0x7300B37DfdfAb110d83290A29DfB31B1740219fE | MAMO on Base             |
| oracle          | \*                                         | TBD                      |
| irm             | 0x46415998764C29aB2a25CbeA6254146D50D22687 | AdaptiveCurveIRM on Base |
| lltv            | 625_000_000_000_000_000 (6.25e+17)         | 62.5% scaled by 1e18     |

### Supporting Data

- **Volatility:** The 30 day annualized volatility trends for MAMO show that it
  is a volatile asset but within bounds. Nevertheless, Mamo is consistently 2-3x
  more volatile than well.
- **Liquidity:** Currently around $200k of MAMO can be swapped instantly for
  stables while slippage stays below the liquidation bonus of 7%.

## Voting Options

- **Aye:** Approve the proposal to activate a core lending market for $MAMO on
  Base with Anthias' specified initial risk parameters.
- **Nay:** Reject the proposal.
- **Abstain:** Abstain from voting on this proposal.
