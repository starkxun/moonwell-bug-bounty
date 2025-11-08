# MIP-X25: Change Borrow & Supply Cap Guardian to Anthias Labs

Author(s): Darren Mims Created: June 24th 2025  
Governance Type: Protocol Parameter Change

---

## Summary

This proposal transfers the Borrow & Supply Cap Guardian role for all Moonwell
deployments from Gauntlet to Anthias Labs. Anthias brings real‑time risk
analytics tooling and 24/7 monitoring that will allow caps to respond faster to
on‑chain conditions while remaining conservative during abnormal market events.
No other protocol parameters are modified.

## Motivation

- Operational agility: Anthias’ automated dashboards surface utilization spikes
  within minutes, enabling proactive cap adjustments rather than reactive
  changes hours later.
- Fresh incentives: Anthias is compensated on a fixed retainer rather than AUM,
  reducing conflicts of interest.
- Expanded market coverage: Anthias already tracks Base, Moonbeam and Ethereum
  L2 assets, giving Moonwell unified analytics across deployments.
- Community alignment: Anthias has participated in multiple Moonwell governance
  calls and committed to publishing transparent monthly reports.

## Background

Moonwell’s Comptroller contract implements several guardian roles that can pause
actions or edit risk limits. The Borrow & Supply Cap Guardian can update
per‑asset borrow and supply caps through methods like
`_setMarketBorrowCaps(...)`. Having a responsive and independent guardian is
critical to avoid runaway debt growth that could impair solvency.

## Specification

| Item             | Value                                                   |
| ---------------- | ------------------------------------------------------- |
| Networks         | Base, OP Mainnet, Moonbeam, and Moonriver               |
| Contracts        | `Comptroller.sol` on each network                       |
| Function         | `_setBorrowCapGuardian(address newGuardian)`            |
| Current guardian | `0xGauntletMultisig`                                    |
| New guardian     | `0xAnthiasMultisig` (2‑of‑3 multisig)                   |
| Execution        | Queued & executed through the Timelock (Governor Bravo) |

## Security & Risk Considerations

- Guardian key management: Anthias multisig requires 2/3 hardware‑wallet
  signers.
- Process transparency: All cap changes will be announced ≥24h in advance on the
  forum & X.
- Fail‑safe: The Pause Guardian (Moonwell Foundation) remains unchanged and can
  pause markets if rogue caps are set.
- No smart‑contract upgrades: This is a single variable update; code hash
  untouched.

## References

- [Moonwell Docs – Guardian Roles](https://docs.moonwell.fi/moonwell/developers/comptroller)
- [Anthias Labs risk methodology](https://anthias.xyz/methodology)

---

_Copyright © 2025 Moonwell Community. Licensed under CC‑BY‑SA 4.0._
