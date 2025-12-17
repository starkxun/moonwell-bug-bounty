//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {MErc20} from "@protocol/MErc20.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {ChainlinkCompositeOracle} from "@protocol/oracles/ChainlinkCompositeOracle.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";

import {HybridProposal, ActionType} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MOONBEAM_FORK_ID, BASE_FORK_ID, OPTIMISM_FORK_ID} from "@utils/ChainIds.sol";
import {ProposalActions} from "@proposals/utils/ProposalActions.sol";
import {ChainIds} from "@utils/ChainIds.sol";

/// @title MIP-X39: rETH Market Exchange Rate Feed and Debt Management
/// @author Moonwell Contributors
/// @notice Proposal to:
///         1. Update rETH oracle on Base to use exchange-rate feed instead of market price
///         2. Withdraw WETH reserves on Optimism and transfer to BAD_DEBT_REPAYER_EOA
///            for repaying bad debt on rETH and cbETH markets
contract mipx39 is HybridProposal {
    using ProposalActions for *;
    using ChainIds for uint256;

    string public constant override name = "MIP-X39";

    // Storage for deployed oracle
    ChainlinkCompositeOracle public baseRethOracle;

    // Debt management constants
    uint256 public constant WETH_AMOUNT = 2.6 ether;

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-x39/x39.md")
        );
        _setProposalDescription(proposalDescription);
    }

    function run() public override {
        primaryForkId().createForksAndSelect();

        Addresses addresses = new Addresses();
        vm.makePersistent(address(addresses));

        initProposal(addresses);

        (, address deployerAddress, ) = vm.readCallers();

        if (DO_DEPLOY) deploy(addresses, deployerAddress);
        if (DO_AFTER_DEPLOY) afterDeploy(addresses, deployerAddress);

        if (DO_BUILD) build(addresses);
        if (DO_RUN) run(addresses, deployerAddress);
        if (DO_TEARDOWN) teardown(addresses, deployerAddress);
        if (DO_VALIDATE) {
            validate(addresses, deployerAddress);
            console.log("Validation completed for proposal ", this.name());
        }
        if (DO_PRINT) {
            printProposalActionSteps();

            addresses.removeAllRestrictions();
            printCalldata(addresses);

            _printAddressesChanges(addresses);
        }
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function deploy(Addresses addresses, address) public override {
        // Deploy new ChainlinkCompositeOracle for rETH on Base
        vm.selectFork(BASE_FORK_ID);

        if (
            !addresses.isAddressSet("CHAINLINK_RETH_ETH_EXCHANGE_RATE_ORACLE")
        ) {
            vm.startBroadcast();

            address baseEthUsdFeed = addresses.getAddress("CHAINLINK_ETH_USD");
            address baseRethEthExchangeRateFeed = addresses.getAddress(
                "CHAINLINK_RETH_ETH_EXCHANGE_RATE"
            );

            baseRethOracle = new ChainlinkCompositeOracle(
                baseEthUsdFeed,
                baseRethEthExchangeRateFeed,
                address(0)
            );

            vm.stopBroadcast();

            addresses.addAddress(
                "CHAINLINK_RETH_ETH_EXCHANGE_RATE_ORACLE",
                address(baseRethOracle)
            );
        } else {
            baseRethOracle = ChainlinkCompositeOracle(
                addresses.getAddress("CHAINLINK_RETH_ETH_EXCHANGE_RATE_ORACLE")
            );
        }
    }

    function build(Addresses addresses) public override {
        // ============ BASE CHAIN ACTIONS ============
        vm.selectFork(BASE_FORK_ID);

        // Update rETH oracle price feed on Base
        address baseChainlinkOracle = addresses.getAddress("CHAINLINK_ORACLE");
        _pushAction(
            baseChainlinkOracle,
            abi.encodeWithSignature(
                "setFeed(string,address)",
                "rETH",
                address(baseRethOracle)
            ),
            "Update rETH oracle to exchange rate feed on Base",
            ActionType.Base
        );

        // ============ OPTIMISM CHAIN ACTIONS ============
        vm.selectFork(OPTIMISM_FORK_ID);

        address moonwellWeth = addresses.getAddress("MOONWELL_WETH");
        address weth = addresses.getAddress("WETH");
        address badDebtRepayerEoa = addresses.getAddress(
            "BAD_DEBT_REPAYER_EOA"
        );

        // Reduce WETH reserves
        _pushAction(
            moonwellWeth,
            abi.encodeWithSignature("_reduceReserves(uint256)", WETH_AMOUNT),
            "Reduce 2.6 WETH reserves from MOONWELL_WETH on Optimism",
            ActionType.Optimism
        );

        // Transfer WETH to BAD_DEBT_REPAYER_EOA
        _pushAction(
            weth,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                badDebtRepayerEoa,
                WETH_AMOUNT
            ),
            "Transfer 2.6 WETH to BAD_DEBT_REPAYER_EOA on Optimism",
            ActionType.Optimism
        );
    }

    function teardown(Addresses addresses, address) public pure override {}

    function validate(Addresses addresses, address) public override {
        // ============ VALIDATE BASE CHAIN ============
        vm.selectFork(BASE_FORK_ID);

        // Validate oracle is updated
        ChainlinkOracle baseChainlinkOracle = ChainlinkOracle(
            addresses.getAddress("CHAINLINK_ORACLE")
        );
        AggregatorV3Interface baseFeed = baseChainlinkOracle.getFeed("rETH");
        assertEq(
            address(baseFeed),
            address(baseRethOracle),
            "Base rETH oracle not updated"
        );

        // Validate price can be fetched
        (, int256 basePrice, , , ) = baseFeed.latestRoundData();
        assertGt(uint256(basePrice), 0, "Base rETH price check failed");

        // ============ VALIDATE OPTIMISM CHAIN ============
        vm.selectFork(OPTIMISM_FORK_ID);

        address weth = addresses.getAddress("WETH");
        address badDebtRepayerEoa = addresses.getAddress(
            "BAD_DEBT_REPAYER_EOA"
        );

        // Validate WETH was transferred to BAD_DEBT_REPAYER_EOA
        uint256 wethBalance = IERC20(weth).balanceOf(badDebtRepayerEoa);
        assertGe(
            wethBalance,
            WETH_AMOUNT,
            "BAD_DEBT_REPAYER_EOA should have received WETH on Optimism"
        );
    }
}
