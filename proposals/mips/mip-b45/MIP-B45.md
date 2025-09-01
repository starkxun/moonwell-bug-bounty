# MIP-B45: Remediation of Base Safety Module Rewards (Phase 1)

## Summary

This proposal reimburses **stkWELL stakers on Base** who lost rewards due to the
reward calculation bug triggered by **MIP-X28**.

It creates a **Merkl airdrop** campaign to fully refund affected users for their
pre-bug rewards, sets Base Safety Module emissions to zero going forward, and
transitions reward distribution to Merkl claims.

For those unfamiliar, **Merkl** is an incentive distribution platform headed by
the Angle Protocol team. The protocol connects liquidity providers and
distributes rewards on behalf of both users and protocols. It leverages both
onchain and offchain data to compute rewards and points for campaigns, giving it
a range of flexibility.
[Read more here.](https://github.com/AngleProtocol/merkl-docs)

Wallets that **overclaimed WELL** following the execution of MIP-X28 will not
receive additional tokens. A list of these addresses is published below, and
they are encouraged to voluntarily return the excess tokens to the **Temporal
Governor contract**. However, these wallets face no legal action should they
choose not to.

---

## Excluded Wallets

| Address                                    | Amount Claimed            | Amount Earned | Over Claimed |
| ------------------------------------------ | ------------------------- | ------------- | ------------ |
| 0xE22B0ebE4b97be51fbB007871bC85FB6E1158Ef8 | 445968896216449815419140  | 445968.9      | 445472.34    |
| 0x3d0cFCC2BaAf94a8ef9eba1A2C577CC35F20E4bF | 40533524780949628548216   | 40533.52      | 40512.11     |
| 0xe66E3A37C3274Ac24FE8590f7D84A2427194DC17 | 1567206220420383081996524 | 1567206.22    | 1567195.79   |
| 0xeb2751d509f2b04d748b2e32e6a7a307a51e8c29 | 271630709894679949014495  | 271630.71     | 271478.02    |
| 0xFB3E5CBCc4e995114025862Ceffec1AC94796FDe | 222530391861173085739049  | 222530.39     | 222412.42    |
| 0x98f6484b2400b251705822767117b6BA89A5d70e | 3463079512667266617736402 | 3463079.51    | 3460859.66   |
| 0x9F3fc75C2aA56DB0da8B70A70E63Dc0D27ba4628 | 1142270956817290842301362 | 1142270.96    | 1141659.17   |
| 0x6134F7D28B4E6C4b266c36acd6542B7a832c118b | 14037633947533432454061   | 14037.63      | 14032.35     |
| 0x1c0eC596303Ce6666f5a4D24c29e78Cf881cb5d3 | 1098265359039080330390138 | 1098265.36    | 1097542.95   |
| 0x200e073f2bb2E6c420dd986F52234815599B58Dd | 97536352569904478791370   | 97536.35      | 96423.28     |
| 0x9C5a7A7326Cb38765990aCfEeeD8F52316a8c0A7 | 865287767464643428565     | 865.29        | 861.10       |
| 0xbb7809A2bF7B788CbEf16CA8F1e9D8Ab44756C90 | 3517936867507719451852    | 3517.94       | 3515.69      |
| 0x27f52Daa475DA8DCd1e456b2d5e6C7382Bb0774D | 21842574285183188700      | 21.84         | 21.83        |
| 0x40d858CbD3Dfd86397dd9478e2287044419f8926 | 5703457272455087508267    | 5703.46       | 5585.58      |
| 0x85c9C226a6287d1A62F77857b687277C9c5011d6 | 9033210431513985570000    | 9033.21       | 8861.52      |
| 0xE009ed8E562FC31a88c2B2D8d53d22cd6E65257E | 30596256691950541470402   | 30596.26      | 30580.62     |
| 0x1bB0BdEE9a305de2ebD0a9d9752d690F839DaaA7 | 2632701197927798369423    | 2632.7        | 2628.60      |
| 0x35e5f7158957DaabE0c3C27D585e01a32A1C405c | 664035960555524858855     | 664.04        | 651.43       |
| 0xc8a5CE9ea6716B04F8c971b591DD0611318ec9D3 | 5199022686051629619699    | 5199.02       | 5087.26      |
| 0x5A2F97034b259e53568890cAf132164D5A9a3760 | 137760144044125155504     | 137.76        | 137.59       |
| 0x04003e7b28D08bA3A3F9111702Ca8279d786c74C | 459670116144668201550     | 459.67        | 451.86       |
| 0x255aAf3e91f40eF6558f67d10Fcd19cFF44e3582 | 2731674306562829953632    | 2731.67       | 2729.89      |
| 0x22723cc5aE5a1B4514ca41F2466E2ADe15Cf529B | 1148798372408811878716    | 1148.8        | 1144.60      |

---

## Background

On **August 13, 2025**, the execution of MIP-X28 updated reward speeds for the
Base Safety Module. This triggered a bug in the reward configuration due to an
edge case:

- An address transferred **stkWELL** to the **stkWELL contract**, creating a
  non-zero balance in the contract.
- An admin function was then called on Base to update the reward configuration,
  which caused reward accruals to inflate.

### Key Points

- Impact was limited to Base only.
- User funds were never at risk.
- The overflow caused reward accruals to spike, allowing the first **23
  claimants** to drain the full four-week reward budget (**8.4M WELL**).
- Thanks to security practices that only fund rewards on a per-period basis,
  losses were limited to that reward window.

This proposal ensures **stkWELL stakers** are fully reimbursed for their
legitimate rewards.

---

## Proposal

If approved, this proposal will:

1. Allocate WELL to fund a **Merkl airdrop** for all stkWELL stakers entitled to
   rewards prior to MIP-X28.
2. Set emissions on the Base Safety Module to **zero**, preventing further
   distribution via the staking contract.
3. Transition all Base Safety Module rewards to **Merkl-based claims** going
   forward, using Angle Protocol.
4. Exclude the **23 wallets that overclaimed** during the bug window.

   - They may voluntarily return excess WELL by transferring to the **Temporal
     Governor contract**:  
     `0x8b621804a7637b781e2BbD58e256a591F2dF7d51`
   - Regardless of whether these wallets return the funds or not, they will not
     face any legal repercussions.
   - If you send within 100 WELL of the overclaimed amount we will consider your
     debt repaid.

---

## Rationale

- Restores trust in Moonwell staking by making affected users whole.
- Provides a clean path forward by moving reward distribution to Angle Protocol,
  avoiding the need for a complete Safety Module liquidity migration on Base.
- Maintains long-term alignment between stkWELL holders and Moonwell governance.

---

## Implementation

- Take a snapshot of **stkWELL balances** at the block immediately prior to
  MIP-X28 execution.
- Generate a **Merkl root** of stkWELL staker entitlements.
- Deploy a **Merkl distributor** via Angle Protocol.
- Fund the distributor with the required WELL.
- Communicate claim instructions to stkWELL holders.

---

## Next Steps

This proposal covers **Phase 1 remediation**:

- Reimbursing pre-bug rewards.
- Transitioning to Merkl claims.

A future governance proposal will address **post-bug rewards** using a
time-weighted distribution.

---

## Voting Options

- **For:** Approve the Merkl airdrop, set Base Safety Module emissions to zero,
  and transition rewards to Merkl claims.
- **Against:** Do not reimburse stkWELL stakers or change Base Safety Module
  reward distribution.
- **Abstain**
