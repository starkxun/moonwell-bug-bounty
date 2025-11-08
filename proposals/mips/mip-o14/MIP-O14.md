# MIP-O14 Add USDT0 Market to Moonwell on Optimism

## Sumary

I am pleased to present a proposal for the addition of USDT0, a multichain
variant of Tether (USDT), to the Moonwell protocol’s Core lending markets. USDT0
brings the stability and familiarity of Tether into an advanced cross-chain
infrastructure, powered by LayerZero’s Omnichain Fungible Token (OFT) standard.
With high trading volume, a circulating market cap of $900M, and rapidly
expanding adoption across chains like Ink and Unichain, listing USDT0 will
further strengthen Moonwell’s position as a leader in onchain lending. This
proposal details the technical, economic, and governance aspects of USDT0 and
argues for its inclusion as a Core Market on OP Mainnet for Moonwell.

## General Information

**Token:** [USDT0](https://usdt0.to/)

USDT0 is an omnichain version of Tether’s stablecoin built to unify fragmented
USDT liquidity across chains. It is backed 1:1 by locked USDT on Ethereum,
enabling seamless minting and redemption across ecosystems via LayerZero. Unlike
wrapped assets or bridge tokens, USDT0 achieves direct interoperability through
native mint/burn logic and a dual-DVN (Decentralized Verification Network)
security configuration. It is designed for high throughput, regulatory
compliance, and rapid settlement.

### Benefits to the Moonwell Community

1. **Enhanced Liquidity and Volume**  
   Listing USDT0 will inject a stable, high-volume asset into the protocol. With
   a 30D trading volume of $2.9B and 24H volume of $215M (as of April 22, 2025),
   USDT0 can anchor borrowing activity and reduce slippage across all Core
   Markets.

2. **Stable Collateral Type**  
   USDT0 offers price stability backed by redeemable assets on Ethereum. It
   serves as an ideal stable collateral option for borrowers and liquidity
   providers seeking predictability.

3. **Interoperable and Cross-Chain Compatible**  
   Because it conforms to the OFT standard, USDT0 is natively bridgeable across
   ecosystems without relying on fragmented liquidity pools. This improves UX
   and opens up Moonwell to cross-chain integrations.

4. **DeFi Access and Integration**  
   USDT0 is already integrated with major DeFi protocols and CEX/DEXs. Listing
   on Moonwell aligns with its usage as a stablecoin rail across Inkchain,
   Optimism, Arbitrum, and more.

## Resources and Socials

- [USDT0 Website](https://usdt0.to/)
- [Token Documentation](https://docs.usdt0.to/technical-documentation/developer)
- [Twitter](https://x.com/USDT0_to)

**USDT0 Social Channels Metrics**

- Twitter: 11.4k followers

## Market Risk Assessment

![Market Cap Chart](https://europe1.discourse-cdn.com/flex017/uploads/moonwell/original/2X/4/47094a567ad7716a0295fb1d369475df1b976901.png)  
_Chart Source: CoinGecko_

## Market Metrics

- **Market Cap:** [\$900M](https://www.coingecko.com/en/coins/usdt0)
- **Minimum/Maximum Market Cap (Last 6 months):** $0 (October 21st 2024) / $900M
  (April 22nd 2025)
- **Circulating Supply:** $899M USDT0
- **Maximum Supply:** ∞ USDT0
- **30D Total Volume (CEX/DEX):**
  [$2.9B](https://www.coingecko.com/en/coins/usdt0/historical_data)
- **24 Hour Trading Volume:** Varies heavily, as of April 22nd, 2025 it is $215M

### Liquidity on Centralized Exchanges

This does not apply to this token as it stands to be a multichain deploy of
USDT.

### Liquidity on Decentralized Exchanges

- **Uniswap (Unichain)** -2% Depth: $272,972
- **Aerodrome SlipStream (Optimism)** -2%: $45,277

### Herfindahl Index

- 0.80 (on Inkchain), 0.80 (on Unichain)

The Herfindahl Index quantifies token concentration among holders. A value of
0.80 reflects significant concentration among wallets for the USDT0 token,
indicating that governance risks stemming from concentrated holdings are high.
It should be noted however that Tether is a reputable company, and that the OFT
borrows from Tether’s supply on ETH Mainnet, and so this may not be a completely
accurate representation.

## Decentralization

- [Top 10 Holders](https://explorer.inkonchain.com/token/0x0200C29006150606B650577BBE7B6248F58470c1?tab=holders)
  (Majority is concentrated in a Kraken-Inkchain wallet)
- **Token Contract:** `0x01bff41798a0bcf287b996046ca68b395dbc1071`

### Ownership and Administration

USDT0 operates as an Omnichain Fungible Token (OFT), leveraging LayerZero’s
infrastructure. The token contracts across supported chains are controlled by
Tether and its designated administrative roles, depending on the deployment
context. Ownership and upgrade privileges for the token are modular and vary by
deployment, enabling independent upgrades of the messaging layer and token
logic.

### Multichain Governance Structure

- Each deployment uses an upgradeable framework via LayerZero adapters and
  TetherTokenOFTExtension contracts
- On Ethereum, the USDT adapter is responsible for locking native USDT and
  authorizing cross-chain messages
- On other chains, minting and burning of USDT0 are handled by OFT-compatible
  contracts controlled via administrative safes
- The system allows efficient contract upgrades and emergency control without
  affecting interoperability

### Security and Controls

- All cross-chain transfers must be verified by two independent Decentralized
  Verification Networks (DVNs): LayerZero DVN and a USDT0-specific DVN,
  providing robust guarantees against message tampering or spoofing.

### Blacklist Functionality

USDT0 supports blacklist and freezing functionality in line with regulatory
compliance tools, enabling enforcement actions if needed.

## Economic Risks

USDT0 is a fiat-backed stablecoin and does not participate in governance voting
like native protocol tokens. Therefore, it carries no governance risk (e.g.,
malicious voting attacks). However, standard risk controls such as supply caps,
borrow limits, and oracle safeguards should be considered to minimize systemic
protocol risk in extreme market scenarios. There is also some concentration risk
in the current supply of USDT0 that is deployed to the Superchain; however, it
is held by a reputable actor.

## Smart Contract Risks

### Codebase and Onchain Activity

- The USDT0 system is built on audited smart contracts maintained by Tether and
  the LayerZero team. Here are the available audits and bounties:
  [OpenZeppelin](https://blog.openzeppelin.com/usdt0-audit),
  [ChainSecurity](https://github.com/Everdawn-Labs/usdt0-audit-reports/blob/main/ChainSecurity/ChainSecurity_USDT0_audit.pdf),
  [ImmuneFi Bug Bounty](https://immunefi.com/bug-bounty/usdt0/information/)
- The OFT logic is live across multiple networks including Ethereum, Optimism,
  Ink, Arbitrum, Berachain, and others.
- Source code is publicly available via GitHub repositories.

### Security Posture

- Tether maintains a robust operational and compliance infrastructure.
- OFT deployments use verified contracts with multisig safes and formal
  auditing.
- LayerZero messaging uses a dual-DVN configuration to ensure message validity
  before minting or burning USDT0 across chains.

### Upgradability

- USDT0 contracts are upgradeable to support evolving chain integrations and
  compliance features.
- Upgrades are secured through governance processes managed by Tether and
  related multisigs.

## Oracle Assessment

- **Chainlink oracle price feed address:**  
  `0xECEf79E109e997bCA29c1c0897ec9d7b03647F5E` (USDT-USD Oracle OP Mainnet)

- **Is the asset a wrapped, staked, or synthetic version of a different
  underlying asset?**  
  Yes. The asset is wrapped. USDT0 is an OFT that represents USDT.
  Users/Integrators deposit USDT to the `OAdapterUpgradeable` proxy in a
  lock-and-mint model on Ethereum mainnet. After dual verification by the L0 DVN
  and the Tether DVN (`0x3b0531eB02aB4Ad72E7a531180bEEf9493A00dD2`) an equal
  amount of USDT0 is minted on the destination chain.

- **How can you verify that the amount of the asset that is minted is never more
  than the amount of the underlying asset that is locked, staked, or used as
  collateral?**

  - Read the `ERC20.balanceOf(OAdapterUpgradeable)` for USDT on Ethereum (shows
    the locked amount of USDT).
  - Sum `totalSupply()` of USDT0 contracts across all chains (LayerZeroScan has
    an API).
  - L0 security stack refuses messages that violate collateral > supply; both
    DVNs must sign mint/burn messages.

- **Is there a way to verify proof of reserves (PoR) on the same network as the
  market?**

  - Chaos Labs’ “Proof Oracle” keeps track of the proof of reserves for USDT0
    (though this is not live yet).

- **What specific events might cause the price to “depeg” or no longer be the
  same as the price of the underlying asset?**
  - Underlying risk: USDT itself de-pegs.
  - Bridge logic failure: bug or upgrade mishap in `OAdapterUpgradeable` emits
    excess mint.
  - Oracle/DVN compromise: both DVNs fail or are captured, allowing fake
    messages.
  - Proof-of-Reserve downtime: traders apply a discount until transparency is
    restored.
  - Regulatory freeze: court order pauses the Ethereum reserve contract,
    blocking redemptions.
  - Extreme thin-liquidity on a newly added chain: temporary ±1–2% drift until
    arbitrage.

## Swap Size Requirement

USDT0 meets the new MALF criterion requiring that a $500,000 swap incur no more
than a 25% price impact across decentralized exchanges and aggregators with some
considerations. The token currently holds meaningful liquidity across platforms
such as Uniswap (on Unichain) and Aerodrome (on Optimism). As of April 2025, the
-2% depth on Uniswap for USDT0 is approximately $272,972, and $45,277 on
Aerodrome. A swap of $500,000 on Uniswap on Unichain incurs a .24% price impact,
which shows that it is substantially liquid on prospective chains. However,
currently, on OP Mainnet, USDT0 is illiquid and sustains a high price impact
upon trade, though this is expected to change rapidly.

## Liquidity Threshold

USDT0 satisfies the minimum liquidity threshold of $2 million in total value
locked (TVL) across decentralized exchanges. The asset benefits from its native
OFT architecture, which allows deployment of USDT from ETH Mainnet and deep
integration across a variety of onchain ecosystems. Below is an image of pool
TVL just for Unichain, and it far surpasses the benchmark.

![Unichain USDT0 TVL Chart](https://europe1.discourse-cdn.com/flex017/uploads/moonwell/original/2X/d/db82606dd3c9285e48cbf9fd7e3e9ad4dc59cc59.png)

## Commercial Viability

USDT0 is projected to generate protocol revenue through its high demand as a
stablecoin collateral and borrowable asset. Historical utilization data from
Moonwell shows that stablecoins like USDC and USDT consistently maintain
utilization rates between 65–90%. Using a conservative 85% utilization rate for
USDT0, combined with a 10% reserve factor and expected total supplied of $10
million, the protocol could generate approximately $7,000/month in revenue.

In case this is not a satisfying answer, here’s some back-of-napkin math:

- **Total Supplied:** $10,000,000  
  Chosen as a middle ground between EURC ($5M) and USDC ($57M)

- **Utilization Rate:** 85%  
  Based on historical averages for stablecoins on Moonwell

- **Total Borrowed:** $8,500,000  
  Equals 85% of supplied USDT0

- **Average Borrow Interest Rate (APY):** 10%  
  Slightly higher due to proximity to kink point on Moonwell’s interest rate
  curve

- **Annual Interest Paid:** $850,000  
  Derived from $8.5M × 10%

- **Reserve Factor:** 10%  
  Standard for major stablecoins like USDC, USDT, and USDS

- **Annual Protocol Revenue:** $85,000  
  Equals 10% of $850,000 interest paid

- **Monthly Protocol Revenue:** ~$7,083  
  Equals $850,000 ÷ 12

---

## Voting Options

- **Aye:** Approve the proposal to activate a MORPHO market on Moonwell (Base)
  using Gauntlet's recommended initial risk parameters
- **Nay:** Reject the proposal
- **Abstain:** Abstain from voting
