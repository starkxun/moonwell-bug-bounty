# MIP-M42: API3s' Oracle Extracted Value (OEV) Solution on GLMR Core Market on Moonbeam

**Summary**

Moonwell is one of the highest revenue generating protocols in DeFi
(https://defillama.com/fees?category=Lending), currently sitting at 11th over
the last year with over $1.2m generated. The yield that Moonwell's Moonbeam
deployment generates could be significantly improved by switching to using
API3’s dAPIs (data feeds) for all markets. This proposal is to switch Moonwell's
oracle on Moonbeam from Chainlink to API3. API3’s OEV data feeds have been used
in production without problems for months by many lending markets, including
Compound V2 forks (like Moonwell) and have just been integrated by Compound
itself. API3’s OEV feeds
[can be switched to easily from contracts](https://www.youtube.com/watch?v=yM54Kiy9uNg)
expecting a "push" oracle, like Chainlink, without the need to change any code,
reducing risks.

This proposal is intended to act as a proof of concept for Moonwell using an
alternative oracle in a comparatively low TVL deployment, and demonstrate the
value that OEV can bring. Similarly, demonstrating the value and reliability of
API3’s feeds will open up possibilities for Moonwell to deploy on chains where
existing oracle infrastructure partners are unavailable.

This proposal will direct the revenue from OEV to the addReserves function of
the GLMR core market on Moonbeam. There are many alternatives that could be
explored in future proposals, such reducing effective liquidation penalties,
that would make interesting community discussions. API3 will also develop a Dune
dashboard to demonstrate the value that OEV is bringing to Moonwell in an easily
accessible way for Moonwell users.

OEV solutions introduce complexities so this proposal will be as detailed as
possible. Where possible, further resources are linked to, but questions are
encouraged and welcomed where something is insufficiently well explained

**Overview**

To ensure any positions eligible for liquidation are promptly liquidated,
reducing the risk of protocol level bad debt, Moonwell pays an incentive to
whoever is able to trigger them fastest ("searchers"). This process is open to
everyone. Triggering a successful liquidation pays 7% of the liquidated position
to whichever searcher was able to trigger it.

This setup for decentralising liquidations is common in defi, with almost every
other lending market paying similar incentives to ensure reliable triggering of
liquidations. As this is effectively a source of free money, it tends to be
incredibly competitive. On various chains it is possible for searchers to bid
for priority over other searchers. There are multiple mechanisms that allow
searchers to compete for these liquidations - on some chains it takes the form
of third-party auctions, and on others it becomes primarily latency-driven.
Quite often they are willing to pay a large percentage of what they expect to
make as a reward for this - because making some money, even a small amount, is
better than none if they are outbid.

Where the ability to bid for priority exists, searchers are happy with a much
smaller amount in exchange for triggering liquidations than lending markets
typically pay. From the point of view of the lending market, this can be
considered wasted liquidity, as it is effectively not needed, and does not end
up with whoever triggered the liquidation, who was happy receiving less.

Moonwell is a Compound V2 fork. Lending markets based on Compound V2 are built
expecting "push" oracles. A push oracle can be described as an oracle that keeps
an on-chain reference price updated, so that it can be used at any time by smart
contracts on the same chain.

Price updates by push oracles like Chainlink and API3 are pushed on chain based
on two criteria - time and deviation. Time is a set frequency of update,
regardless of price movement. Deviation based updates allow the on chain price
to vary by up to a set percentage of the real time price before an update is
triggered. The actual data providers update their prices offchain at a far more
granular level. When a Searcher sees one of these more current prices offchain
that would trigger a liquidation onchain, they can bid for the right to pull
that more current price on chain and to bundle a liquidation with it thus
ensuring they get the associated rewards. These additional updates simply
provide redundancy and granularity to the existing push updates.

API3’s OEV data feeds allow searchers to trigger additional data feed updates
which in effect gives them a "fast lane" for liquidations, and gives those
willing to pay priority over the other people competing. The searchers are
unable to change data values, and can only trigger an earlier update (from the
same data providers) than would otherwise occur based on time or deviation
alone. There is more information about how this works
exactly[ here](https://docs.api3.org/oev-searchers/overview.html), but a brief
summary is:

- Searchers monitor positions on lending markets that can be liquidated at
  certain price points
- Searchers also monitor the aggregated prices from API3’s Data providers.
- When the providers show a price offchain that would trigger a liquidation,
  searchers are able to bid for the right to trigger an extra update. The
  winning bid goes to API3, who split this with the dapp that the searchers
  trigger the update for
- The winning searcher gets a signed transaction that only they can use, which
  triggers a data feed update for a specific pair, eg ETH/USD
- The searcher then bundles this price update transaction in a multicall with
  the liquidation transaction. As the update is signed, only the winning bidder
  can issue the update, giving them priority to trigger the liquidation.
- API3’s dAPIs have a 15 second delay for deviation based updates to allow
  winning searchers time to update the feed. This ensures that searchers know
  they're able to use the update to trigger the liquidation, which optimises the
  value they're willing to bid.

API3 then gives 80% of these bid proceeds back to the dapp, and retains 20% to
split with data providers. It can be expected that competition between searchers
to win these auctions will have similar effects as the ability to bid for
priority on mainnet had, and trend towards the total value of the liquidation
incentive.

For Moonwell, users pay a 10% penalty when they are liquidated, with 3% going
into a safety reserve to guard against bad debt. Fully using API3’s OEV feeds
would mean that up to 5.6% (80% of 7%) of the total amount liquidated would be
returned to Moonwell.

All of API3’s feeds have OEV functionality built in, and have never had a
misreport or downtime on any feed since inception… Large lending markets like
Compound, YEI Finance, Init Capital, Silo, Mendi, Ionic and Orbit have switched
over. Multiple users (YEI, Orbit, Zerolend are also Compound V2 forks, similar
to Moonwell, further proving compatibility. API3 will assume the costs of
operating the necessary data feeds, and of the integration itself where
necessary.

**Redundancy vs Dependency**

These updates are simply more current prices from the same providers. The OEV
Network serves as a layer of redundancy and ensures liquidations happen exactly
when they should rather than delaying or waiting for time or deviation-based
prices to hit. If the entire OEV Network went down, the regularly pushed prices
would update as they currently do and Searchers participating would be able to
trigger liquidations exactly as they do now, OEV just adds additional updates
from the same sources and additional venues where searchers can compete.

**Motivation**

OEV represents a new source of income for Moonwell. API3’s OEV solution offers a
market leading 80% of OEV back to Moonwell, in comparison to Redstone's 50%, and
has the added benefit of demonstrated production usage for many months. API3
will also develop a Dune dashboard to demonstrate the value that OEV is bringing
to Moonwell in an easily accessible way for Moonwell users.

**Implementation**

API3 will ensure all feeds needed to support Moonwell on Moonbeam are provided
indefinitely. Moonwell will switch from reading prices from Chainlink's data
feed to API3’s dAPIs. There is a Quantstamp audited version of the current
Chainlink adapter available
[here](https://github.com/api3dao/migrate-from-chainlink-to-api3). Integration
is as simple as updating the oracle source with a more frequent update schedule.
API3 is happy to provide all necessary technical assistance for this switch.

OEV accrued will be distributed to the GLMR core market on Moonbeam's reserves
using the addReserve function. This process will be visible on chain and
verifiable by Moonwell community members

**Voting**

Yay - Moonwell will switch from using Chainlink to API3 on Moonbeam for all
markets. API3 will distribute 80% of the OEV proceeds to Moonwell, via the
addReserves function on the GLMR core market on Moonbeam.

Nay - No changes will be made
