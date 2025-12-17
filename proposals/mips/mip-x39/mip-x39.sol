//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {ChainlinkCompositeOracle} from "@protocol/oracles/ChainlinkCompositeOracle.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";

import {HybridProposal, ActionType} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MOONBEAM_FORK_ID, BASE_FORK_ID, OPTIMISM_FORK_ID} from "@utils/ChainIds.sol";
import {ProposalActions} from "@proposals/utils/ProposalActions.sol";
import {ChainIds} from "@utils/ChainIds.sol";

/// @title MIP-X39: rETH Market Exchange Rate Feed Update
/// @author Moonwell Contributors
/// @notice Proposal to:
///         1. Update rETH oracle on Base to use exchange-rate feed instead of market price
///         2. Update rETH oracle on Optimism to use exchange-rate feed instead of market price
contract mipx39 is HybridProposal {
    using ProposalActions for *;
    using ChainIds for uint256;

    string public constant override name = "MIP-X39";

    // Storage for deployed oracles
    ChainlinkCompositeOracle public baseRethOracle;
    ChainlinkCompositeOracle public optimismRethOracle;

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

        // Deploy new ChainlinkCompositeOracle for rETH on Optimism
        vm.selectFork(OPTIMISM_FORK_ID);

        if (
            !addresses.isAddressSet(
                "CHAINLINK_RETH_ETH_EXCHANGE_RATE_ORACLE",
                block.chainid
            )
        ) {
            vm.startBroadcast();

            address optimismEthUsdFeed = addresses.getAddress(
                "CHAINLINK_ETH_USD"
            );
            address optimismRethEthExchangeRateFeed = addresses.getAddress(
                "CHAINLINK_RETH_ETH_EXCHANGE_RATE"
            );

            optimismRethOracle = new ChainlinkCompositeOracle(
                optimismEthUsdFeed,
                optimismRethEthExchangeRateFeed,
                address(0)
            );

            vm.stopBroadcast();

            addresses.addAddress(
                "CHAINLINK_RETH_ETH_EXCHANGE_RATE_ORACLE",
                address(optimismRethOracle)
            );
        } else {
            optimismRethOracle = ChainlinkCompositeOracle(
                addresses.getAddress(
                    "CHAINLINK_RETH_ETH_EXCHANGE_RATE_ORACLE",
                    block.chainid
                )
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

        // Update rETH oracle price feed on Optimism
        address optimismChainlinkOracle = addresses.getAddress(
            "CHAINLINK_ORACLE"
        );
        _pushAction(
            optimismChainlinkOracle,
            abi.encodeWithSignature(
                "setFeed(string,address)",
                "rETH",
                address(optimismRethOracle)
            ),
            "Update rETH oracle to exchange rate feed on Optimism",
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

        // Validate oracle is updated on Optimism
        ChainlinkOracle optimismChainlinkOracle = ChainlinkOracle(
            addresses.getAddress("CHAINLINK_ORACLE")
        );
        AggregatorV3Interface optimismFeed = optimismChainlinkOracle.getFeed(
            "rETH"
        );
        assertEq(
            address(optimismFeed),
            address(optimismRethOracle),
            "Optimism rETH oracle not updated"
        );

        // Validate price can be fetched on Optimism
        (, int256 optimismPrice, , , ) = optimismFeed.latestRoundData();
        assertGt(uint256(optimismPrice), 0, "Optimism rETH price check failed");
    }
}
