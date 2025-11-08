# MIP-B44 Implementation Plan

## Overview

Create a Solidity proposal contract that transfers 10M WELL tokens from the
Foundation multisig on Base to the Morpho URD contract using the `transferFrom`
mechanism.

## Contract Specification

### Contract Name

`mipb44`

### Inheritance

- Extends `HybridProposal`
- Uses `Configs` for configuration management

### Constants and Storage

```solidity
string public constant override name = "MIP-B44";
uint256 public constant TRANSFER_AMOUNT = 10_000_000 * 1e18; // 10M WELL tokens

// Storage for tracking balances
uint256 public morphoURDBalanceBefore;
```

### Address Mappings (from chains/8453.json)

- Foundation multisig: `FOUNDATION_MULTISIG`
  (0x74Cbb1E8B68dDD13B28684ECA202a351afD45EAa)
- Morpho URD: `MOONWELL_METAMORPHO_URD`
  (0x9e3380f8B29E8f85cA19EFFA80Fb41149417D943)
- xWELL token: `xWELL_PROXY` (0xA88594D404727625A9437C3f886C7643872296AE)

### Implementation Functions

#### Constructor

```solidity
constructor() {
  bytes memory proposalDescription = abi.encodePacked(
    vm.readFile("./proposals/mips/mip-b44/MIP-B44.md")
  );
  _setProposalDescription(proposalDescription);
}
```

#### primaryForkId()

```solidity
function primaryForkId() public pure override returns (uint256) {
  return BASE_FORK_ID;
}
```

#### build()

```solidity
function build(Addresses addresses) public override {
  address xWellToken = addresses.getAddress("xWELL_PROXY");
  address foundationMultisig = addresses.getAddress("FOUNDATION_MULTISIG");
  address morphoURD = addresses.getAddress("MOONWELL_METAMORPHO_URD");

  _pushAction(
    xWellToken,
    abi.encodeWithSignature(
      "transferFrom(address,address,uint256)",
      foundationMultisig,
      morphoURD,
      TRANSFER_AMOUNT
    ),
    "Transfer 10M WELL from Foundation multisig to Morpho URD"
  );
}
```

#### beforeSimulationHook()

```solidity
function beforeSimulationHook(Addresses addresses) public override {
  address xWellToken = addresses.getAddress("xWELL_PROXY");
  address foundationMultisig = addresses.getAddress("FOUNDATION_MULTISIG");
  address morphoURD = addresses.getAddress("MOONWELL_METAMORPHO_URD");
  address temporalGovernor = addresses.getAddress("TEMPORAL_GOVERNOR");

  // Store the initial URD balance before any operations
  morphoURDBalanceBefore = IERC20(xWellToken).balanceOf(morphoURD);

  // Deal tokens to foundation multisig for testing
  deal(xWellToken, foundationMultisig, TRANSFER_AMOUNT);

  // Mock the pre-approval from foundation multisig to temporal governor
  vm.prank(foundationMultisig);
  IERC20(xWellToken).approve(temporalGovernor, TRANSFER_AMOUNT);
}
```

#### validate()

```solidity
function validate(Addresses addresses, address) public view override {
  address xWellToken = addresses.getAddress("xWELL_PROXY");
  address foundationMultisig = addresses.getAddress("FOUNDATION_MULTISIG");
  address morphoURD = addresses.getAddress("MOONWELL_METAMORPHO_URD");
  address temporalGovernor = addresses.getAddress("TEMPORAL_GOVERNOR");

  // Get current URD balance
  uint256 morphoBalanceAfter = IERC20(xWellToken).balanceOf(morphoURD);

  // Verify the exact transfer amount was received
  uint256 balanceIncrease = morphoBalanceAfter - morphoURDBalanceBefore;
  assertEq(
    balanceIncrease,
    TRANSFER_AMOUNT,
    "Morpho URD should have received exactly 10M WELL tokens"
  );

  // Verify the final balance is correct
  assertEq(
    morphoBalanceAfter,
    morphoURDBalanceBefore + TRANSFER_AMOUNT,
    "Morpho URD final balance should equal initial balance plus 10M WELL"
  );

  // Verify allowance was consumed
  uint256 remainingAllowance = IERC20(xWellToken).allowance(
    foundationMultisig,
    temporalGovernor
  );
  assertEq(
    remainingAllowance,
    0,
    "Allowance should be consumed after transfer"
  );
}
```

#### teardown()

```solidity
function teardown(Addresses addresses, address) public pure override {
  // No teardown needed
}
```

## Required Imports

```solidity
import "@forge-std/Test.sol";
import { Configs } from "@proposals/Configs.sol";
import { BASE_FORK_ID } from "@utils/ChainIds.sol";
import { HybridProposal } from "@proposals/proposalTypes/HybridProposal.sol";
import { AllChainAddresses as Addresses } from "@proposals/Addresses.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
```

## Action Flow

1. Foundation multisig pre-approves Temporal Governor to spend 10M WELL
2. Proposal executes `transferFrom(foundationMultisig, morphoURD, 10M WELL)` on
   xWELL_PROXY contract
3. 10M WELL tokens are transferred from Foundation multisig to Morpho URD
4. Validation confirms successful transfer and allowance consumption

## Safety Considerations

- Uses existing address mappings from chains/8453.json
- Validates transfer completion in validate() function
- Checks allowance consumption to ensure proper execution
- Uses standard ERC20 transferFrom pattern

## Testing Strategy

- Mock pre-approval in beforeSimulationHook
- Deal tokens to Foundation multisig for testing
- Verify state changes in validation function
- Ensure proper error handling for insufficient allowance/balance scenarios
