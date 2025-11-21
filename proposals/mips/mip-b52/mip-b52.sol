//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {MErc20} from "@protocol/MErc20.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {HybridProposal, ActionType} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {BASE_FORK_ID} from "@utils/ChainIds.sol";
import {ProposalActions} from "@proposals/utils/ProposalActions.sol";

/// @title MIP-B52: Bad Debt Remediation
/// @notice Proposal to reduce reserves from two Base markets and transfer to EOA for repaying bad debt:
///         1. Reduce 490,000 USDC from MOONWELL_USDC market
///         2. Reduce 3 cbBTC from MOONWELL_cbBTC market
///         3. Transfer all tokens to BAD_DEBT_REPAYER_EOA for swapping to VIRTUALS and cbXRP
contract mipb52 is HybridProposal {
    using ProposalActions for *;

    string public constant override name = "MIP-B52";

    // Reserve amounts to reduce
    uint256 public constant USDC_AMOUNT = 490_000e6; // 490,000 USDC
    uint256 public constant cbBTC_AMOUNT = 3e8; // 3 cbBTC

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b52/b52.md")
        );
        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function deploy(Addresses, address) public override {}

    function build(Addresses addresses) public override {
        vm.selectFork(BASE_FORK_ID);

        address eoa = addresses.getAddress("BAD_DEBT_REPAYER_EOA");

        // === USDC Reserve Reduction ===
        address moonwellUsdc = addresses.getAddress("MOONWELL_USDC");
        address usdc = MErc20(moonwellUsdc).underlying();

        _pushAction(
            moonwellUsdc,
            abi.encodeWithSignature("_reduceReserves(uint256)", USDC_AMOUNT),
            "Reduce 490,000 USDC reserves from MOONWELL_USDC",
            ActionType.Base
        );

        _pushAction(
            usdc,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                eoa,
                USDC_AMOUNT
            ),
            "Transfer 490,000 USDC to BAD_DEBT_REPAYER_EOA",
            ActionType.Base
        );

        // === cbBTC Reserve Reduction ===
        address moonwellCbBtc = addresses.getAddress("MOONWELL_cbBTC");
        address cbBtc = MErc20(moonwellCbBtc).underlying();

        _pushAction(
            moonwellCbBtc,
            abi.encodeWithSignature("_reduceReserves(uint256)", cbBTC_AMOUNT),
            "Reduce 3 cbBTC reserves from MOONWELL_cbBTC",
            ActionType.Base
        );

        _pushAction(
            cbBtc,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                eoa,
                cbBTC_AMOUNT
            ),
            "Transfer 3 cbBTC to BAD_DEBT_REPAYER_EOA",
            ActionType.Base
        );
    }

    function validate(Addresses addresses, address) public override {
        vm.selectFork(BASE_FORK_ID);

        address eoa = addresses.getAddress("BAD_DEBT_REPAYER_EOA");

        // Validate USDC transfer
        address usdc = MErc20(addresses.getAddress("MOONWELL_USDC"))
            .underlying();
        uint256 usdcBalance = IERC20(usdc).balanceOf(eoa);
        assertGe(
            usdcBalance,
            USDC_AMOUNT,
            "BAD_DEBT_REPAYER_EOA should have received USDC"
        );

        // Validate cbBTC transfer
        address cbBtc = MErc20(addresses.getAddress("MOONWELL_cbBTC"))
            .underlying();
        uint256 cbBtcBalance = IERC20(cbBtc).balanceOf(eoa);
        assertGe(
            cbBtcBalance,
            cbBTC_AMOUNT,
            "BAD_DEBT_REPAYER_EOA should have received cbBTC"
        );
    }
}
