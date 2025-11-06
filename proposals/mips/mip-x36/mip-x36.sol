//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {MToken} from "@protocol/MToken.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MErc20} from "@protocol/MErc20.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {ChainlinkCompositeOracle} from "@protocol/oracles/ChainlinkCompositeOracle.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";

import {HybridProposal, ActionType} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MOONBEAM_FORK_ID, BASE_FORK_ID, OPTIMISM_FORK_ID} from "@utils/ChainIds.sol";
import {ProposalActions} from "@proposals/utils/ProposalActions.sol";
import {ChainIds} from "@utils/ChainIds.sol";

/// @title MIP-X36: Deprecate wrsETH Markets with Exchange-Rate Oracle Transition
/// @author Moonwell Contributors
/// @notice Proposal to deprecate wrsETH markets on Base and Optimism by:
///         1. Setting supply and borrow caps to 0
///         2. Deploying new ChainlinkCompositeOracle contracts using exchange rate feeds
///         3. Updating oracle addresses for wrsETH markets
contract mipx36 is HybridProposal {
    using ProposalActions for *;
    using ChainIds for uint256;

    string public constant override name = "MIP-X36";

    uint256 public constant NEW_SUPPLY_CAP = 0.1;
    uint256 public constant NEW_BORROW_CAP = 0.1;

    // Storage for deployed oracles
    ChainlinkCompositeOracle public baseWrsethOracle;
    ChainlinkCompositeOracle public optimismWrsethOracle;

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-x36/x36.md")
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
        // Deploy new ChainlinkCompositeOracle for Base wrsETH
        vm.selectFork(BASE_FORK_ID);
        vm.startBroadcast();

        address baseEthUsdFeed = addresses.getAddress("CHAINLINK_ETH_USD");
        address baseWrsethEthExchangeRateFeed = addresses.getAddress("CHAINLINK_wrsETH_ETH_EXCHANGE_RATE");

        baseWrsethOracle = new ChainlinkCompositeOracle(
            baseEthUsdFeed,
            baseWrsethEthExchangeRateFeed,
            address(0)
        );

        vm.stopBroadcast();

        // Deploy new ChainlinkCompositeOracle for Optimism wrsETH
        vm.selectFork(OPTIMISM_FORK_ID);
        vm.startBroadcast();

        address optimismEthUsdFeed = addresses.getAddress("CHAINLINK_ETH_USD");
        address optimismWrsethEthExchangeRateFeed = addresses.getAddress("CHAINLINK_wrsETH_ETH_EXCHANGE_RATE");

        optimismWrsethOracle = new ChainlinkCompositeOracle(
            optimismEthUsdFeed,
            optimismWrsethEthExchangeRateFeed,
            address(0)
        );

        vm.stopBroadcast();
    }

    function afterDeploy(Addresses addresses, address) public override {
        vm.selectFork(BASE_FORK_ID);
        addresses.changeAddress("CHAINLINK_wrsETH_COMPOSITE_ORACLE", address(baseWrsethOracle), true);

        vm.selectFork(OPTIMISM_FORK_ID);
        addresses.changeAddress("CHAINLINK_wrsETH_COMPOSITE_ORACLE", address(optimismWrsethOracle), true);
    }

    function build(Addresses addresses) public override {
        // ============ BASE CHAIN ACTIONS ============
        vm.selectFork(BASE_FORK_ID);

        address baseComptroller = addresses.getAddress("UNITROLLER");
        address baseWrsethMToken = addresses.getAddress("MOONWELL_wrsETH");

        address[] memory baseMarkets = new address[](1);
        baseMarkets[0] = baseWrsethMToken;

        uint256[] memory baseSupplyCaps = new uint256[](1);
        baseSupplyCaps[0] = NEW_SUPPLY_CAP;

        uint256[] memory baseBorrowCaps = new uint256[](1);
        baseBorrowCaps[0] = NEW_BORROW_CAP;

        // Set supply cap to 0 on Base
        _pushAction(
            baseComptroller,
            abi.encodeWithSignature(
                "_setMarketSupplyCaps(address[],uint256[])",
                baseMarkets,
                baseSupplyCaps
            ),
            "Set supply cap to 0 for wrsETH on Base",
            ActionType.Base
        );

        // Set borrow cap to 0 on Base
        _pushAction(
            baseComptroller,
            abi.encodeWithSignature(
                "_setMarketBorrowCaps(address[],uint256[])",
                baseMarkets,
                baseBorrowCaps
            ),
            "Set borrow cap to 0 for wrsETH on Base",
            ActionType.Base
        );

        // Update oracle price feed on Base
        address baseChainlinkOracle = addresses.getAddress("CHAINLINK_ORACLE");
        _pushAction(
            baseChainlinkOracle,
            abi.encodeWithSignature(
                "setFeed(string,address)",
                "wrsETH",
                address(baseWrsethOracle)
            ),
            "Update wrsETH oracle to exchange rate feed on Base",
            ActionType.Base
        );

        // ============ OPTIMISM CHAIN ACTIONS ============
        vm.selectFork(OPTIMISM_FORK_ID);

        address optimismComptroller = addresses.getAddress("UNITROLLER");
        address optimismWrsethMToken = addresses.getAddress("MOONWELL_wrsETH");

        address[] memory optimismMarkets = new address[](1);
        optimismMarkets[0] = optimismWrsethMToken;

        uint256[] memory optimismSupplyCaps = new uint256[](1);
        optimismSupplyCaps[0] = NEW_SUPPLY_CAP;

        uint256[] memory optimismBorrowCaps = new uint256[](1);
        optimismBorrowCaps[0] = NEW_BORROW_CAP;

        // Set supply cap to 0 on Optimism
        _pushAction(
            optimismComptroller,
            abi.encodeWithSignature(
                "_setMarketSupplyCaps(address[],uint256[])",
                optimismMarkets,
                optimismSupplyCaps
            ),
            "Set supply cap to 0 for wrsETH on Optimism",
            ActionType.Optimism
        );

        // Set borrow cap to 0 on Optimism
        _pushAction(
            optimismComptroller,
            abi.encodeWithSignature(
                "_setMarketBorrowCaps(address[],uint256[])",
                optimismMarkets,
                optimismBorrowCaps
            ),
            "Set borrow cap to 0 for wrsETH on Optimism",
            ActionType.Optimism
        );

        // Update oracle price feed on Optimism
        address optimismChainlinkOracle = addresses.getAddress("CHAINLINK_ORACLE");
        _pushAction(
            optimismChainlinkOracle,
            abi.encodeWithSignature(
                "setFeed(string,address)",
                "wrsETH",
                address(optimismWrsethOracle)
            ),
            "Update wrsETH oracle to exchange rate feed on Optimism",
            ActionType.Optimism
        );
    }

    function teardown(Addresses addresses, address) public pure override {}

    function validate(Addresses addresses, address) public override {
        // ============ VALIDATE BASE CHAIN ============
        vm.selectFork(BASE_FORK_ID);

        Comptroller baseComptroller = Comptroller(addresses.getAddress("UNITROLLER"));
        address baseWrsethMToken = addresses.getAddress("MOONWELL_wrsETH");

        // Validate supply cap is 0
        uint256 baseSupplyCap = baseComptroller.supplyCaps(baseWrsethMToken);
        assertEq(
            baseSupplyCap,
            NEW_SUPPLY_CAP,
            "Base wrsETH supply cap not set to 0"
        );

        // Validate borrow cap is 0
        uint256 baseBorrowCap = baseComptroller.borrowCaps(baseWrsethMToken);
        assertEq(
            baseBorrowCap,
            NEW_BORROW_CAP,
            "Base wrsETH borrow cap not set to 0"
        );

        // Validate oracle is updated
        ChainlinkOracle baseChainlinkOracle = ChainlinkOracle(
            addresses.getAddress("CHAINLINK_ORACLE")
        );
        AggregatorV3Interface baseFeed = baseChainlinkOracle.getFeed("wrsETH");
        assertEq(
            address(baseFeed),
            address(baseWrsethOracle),
            "Base wrsETH oracle not updated"
        );

        // Validate price can be fetched
        (, int256 basePrice, , , ) = baseFeed.latestRoundData();
        assertGt(uint256(basePrice), 0, "Base wrsETH price check failed");

        // ============ VALIDATE OPTIMISM CHAIN ============
        vm.selectFork(OPTIMISM_FORK_ID);

        Comptroller optimismComptroller = Comptroller(addresses.getAddress("UNITROLLER"));
        address optimismWrsethMToken = addresses.getAddress("MOONWELL_wrsETH");

        // Validate supply cap is 0
        uint256 optimismSupplyCap = optimismComptroller.supplyCaps(optimismWrsethMToken);
        assertEq(
            optimismSupplyCap,
            NEW_SUPPLY_CAP,
            "Optimism wrsETH supply cap not set to 0"
        );

        // Validate borrow cap is 0
        uint256 optimismBorrowCap = optimismComptroller.borrowCaps(optimismWrsethMToken);
        assertEq(
            optimismBorrowCap,
            NEW_BORROW_CAP,
            "Optimism wrsETH borrow cap not set to 0"
        );

        // Validate oracle is updated
        ChainlinkOracle optimismChainlinkOracle = ChainlinkOracle(
            addresses.getAddress("CHAINLINK_ORACLE")
        );
        AggregatorV3Interface optimismFeed = optimismChainlinkOracle.getFeed("wrsETH");
        assertEq(
            address(optimismFeed),
            address(optimismWrsethOracle),
            "Optimism wrsETH oracle not updated"
        );

        // Validate price can be fetched
        (, int256 optimismPrice, , , ) = optimismFeed.latestRoundData();
        assertGt(uint256(optimismPrice), 0, "Optimism wrsETH price check failed");
    }
}
