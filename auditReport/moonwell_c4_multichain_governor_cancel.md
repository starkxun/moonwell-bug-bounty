# [M] `MultichainGovernor.cancel()` cannot invalidate below-threshold proposals once they enter cross-chain vote collection

## Summary

`MultichainGovernor.cancel()` is documented as supporting permissionless cancellation when a proposer's voting power falls below `proposalThreshold`, including after the proposal has progressed past the local voting window. In practice, the implementation only allows cancellation while the proposal is still in the `Active` state.

As a result, a proposer can:

1. temporarily gather enough voting power to create a proposal,
2. cast enough votes for the proposal to eventually pass,
3. drop below the proposal threshold after the local voting period ends, and
4. still have the proposal remain uncancelable and executable.

This breaks the contract's own threshold-enforcement model and allows proposals from now-ineligible proposers to survive through execution.

## Vulnerability Details

The `cancel()` docstring explicitly states that cancellation is allowed when:

- the proposer cancels, or
- anyone cancels after the proposer's current voting power drops below `proposalThreshold`,

and that this should apply while the proposal is in one of the following states:

- `Succeeded`
- `Active`
- `CrossChainVoteCollection`

This intent is documented in `src/governance/multichain/MultichainGovernor.sol` around lines 766-777.

However, the actual implementation only accepts the `Active` state:

```solidity
function cancel(uint256 proposalId) external override {
    require(
        msg.sender == proposals[proposalId].proposer ||
            getCurrentVotes(proposals[proposalId].proposer) <
            proposalThreshold,
        "MultichainGovernor: unauthorized cancel"
    );

    ProposalState proposalState = state(proposalId);

    require(
        proposalState == ProposalState.Active,
        "MultichainGovernor: cannot cancel non active proposal"
    );
    ...
}
```

Because the state check is stricter than the documented and intended behavior, proposers who are no longer above the threshold become protected from permissionless cancellation as soon as the proposal enters `CrossChainVoteCollection`.

## Impact

The protocol clearly treats the proposal threshold as an ongoing eligibility condition, not just a one-time gate at proposal creation:

- `cancel()` explicitly supports permissionless cancellation when the proposer's current voting power drops below the threshold.
- the inline comments describe this as an intended edge-case safeguard.

The current implementation silently disables that safeguard for all proposals that have already moved past `Active`.

This lets a proposer use temporary voting power only long enough to create and seed a proposal, then shed that voting power before cross-chain vote collection finishes, while the proposal still remains valid and executable.

That weakens governance assumptions in two ways:

- threshold loss is no longer enforceable during a meaningful part of the proposal lifecycle,
- proposals from currently ineligible proposers can still execute privileged governance actions.

This issue does not rely on:

- a malicious governor,
- a malicious Wormhole deployment,
- a malicious vote collection contract,
- any of the known out-of-scope assumptions listed for the contest.

It is a direct local state-machine inconsistency inside `MultichainGovernor`.

## Proof of Concept

The following Foundry test demonstrates the issue:

`test/unit/MultichainGovernorCancel.t.sol::testProposalCanStillSucceedAndExecuteAfterThresholdLossInCollectionPeriod`

PoC flow:

1. A proposer is given exactly `proposalThreshold` voting power.
2. The proposer creates a governance proposal and casts a `YES` vote.
3. Time advances until the proposal enters `CrossChainVoteCollection`.
4. The proposer transfers away their voting power and falls below `proposalThreshold`.
5. A call to `cancel(proposalId)` reverts with `MultichainGovernor: cannot cancel non active proposal`.
6. After the collection window ends, the proposal reaches `Succeeded`.
7. The proposal can still be executed successfully.

Relevant test excerpt:

```solidity
assertEq(
    uint256(governor.state(proposalId)),
    uint256(IMultichainGovernor.ProposalState.CrossChainVoteCollection),
    "proposal should be in cross-chain vote collection"
);
assertLt(
    governor.getCurrentVotes(proposer),
    governor.proposalThreshold(),
    "proposer should be below threshold"
);

vm.expectRevert("MultichainGovernor: cannot cancel non active proposal");
governor.cancel(proposalId);

vm.warp(block.timestamp + governor.crossChainVoteCollectionPeriod() + 1);

assertEq(
    uint256(governor.state(proposalId)),
    uint256(IMultichainGovernor.ProposalState.Succeeded),
    "proposal should still succeed"
);

governor.execute(proposalId);
```

Validation command used:

```bash
forge test --offline --match-path test/unit/MultichainGovernorCancel.t.sol -vv
```

## Recommendation

Align the implementation with the documented threshold-enforcement model by allowing permissionless cancellation when the proposer falls below `proposalThreshold` during every intended pre-execution state.

At minimum, the state gate in `cancel()` should be expanded to include:

- `Active`
- `CrossChainVoteCollection`

If the intended design truly also allows cancelling `Succeeded` proposals before execution, that state should be supported as well.

If the current behavior is actually intended, then:

- the docstring should be corrected,
- the threshold-loss cancellation design comments should be removed,
- and the governance assumptions should explicitly state that proposer eligibility is only checked during proposal creation and the `Active` phase.
