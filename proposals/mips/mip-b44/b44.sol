//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {Configs} from "@proposals/Configs.sol";
import {BASE_FORK_ID} from "@utils/ChainIds.sol";
import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice MIP-B44: Renewal of Moonwell Vaults Incentives Program
/// @dev Transfers 10M WELL tokens from Foundation multisig to Morpho URD
contract mipb44 is HybridProposal, Configs {
    /// @notice the name of the proposal
    string public constant override name = "MIP-B44";

    /// @notice transfer amount: 10M WELL tokens
    uint256 public constant TRANSFER_AMOUNT = 10_000_000 * 1e18;

    /// @notice storage for tracking URD balance before transfer
    uint256 public morphoURDBalanceBefore;

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b44/MIP-B44.md")
        );
        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function deploy(Addresses addresses, address) public override {
        // No deployment needed
    }

    function beforeSimulationHook(Addresses addresses) public override {
        address xWellToken = addresses.getAddress("xWELL_PROXY");
        address foundationMultisig = addresses.getAddress(
            "FOUNDATION_MULTISIG"
        );
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

    function build(Addresses addresses) public override {
        address xWellToken = addresses.getAddress("xWELL_PROXY");
        address foundationMultisig = addresses.getAddress(
            "FOUNDATION_MULTISIG"
        );
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

    function teardown(Addresses addresses, address) public pure override {
        // No teardown needed
    }

    function validate(Addresses addresses, address) public view override {
        address xWellToken = addresses.getAddress("xWELL_PROXY");
        address foundationMultisig = addresses.getAddress(
            "FOUNDATION_MULTISIG"
        );
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
}
