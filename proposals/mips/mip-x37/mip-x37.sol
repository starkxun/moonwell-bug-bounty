// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {console} from "forge-std/console.sol";
import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {ChainlinkOracleConfigs} from "@proposals/ChainlinkOracleConfigs.sol";
import {BASE_FORK_ID, OPTIMISM_FORK_ID, MOONBEAM_FORK_ID, BASE_CHAIN_ID, OPTIMISM_CHAIN_ID} from "@utils/ChainIds.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {Networks} from "@proposals/utils/Networks.sol";
import {ERC20} from "@openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {ChainlinkOEVMorphoWrapper} from "@protocol/oracles/ChainlinkOEVMorphoWrapper.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {validateProxy} from "@proposals/utils/ProxyUtils.sol";

// this proposal should
// 1. deploy new non-upgradeable ChainlinkOEVWrapper contracts for core markets
// 2. upgrade existing ChainlinkOEVMorphoWrapper proxy contracts for Morpho markets => test that storage can still be accessed
// 3. call setFeed on the ChainlinkOracle for all core markets, to point to the new ChainlinkOEVWrapper contracts
contract mipx37 is HybridProposal, ChainlinkOracleConfigs, Networks {
    string public constant override name = "MIP-X37";

    string public constant MORPHO_IMPLEMENTATION_NAME =
        "CHAINLINK_OEV_MORPHO_WRAPPER_IMPL";

    uint16 public constant FEE_MULTIPLIER = 9900;
    uint256 public constant MAX_ROUND_DELAY = 10;
    uint256 public constant MAX_DECREMENTS = 10;

    /// @dev description setup
    constructor() {
        _setProposalDescription(
            bytes(vm.readFile("./proposals/mips/mip-x37/x37.md"))
        );
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    // Deploy new instances of ChainlinkOEVWrapper (core markets) and ensure ChainlinkOEVMorphoWrapper implementation exists (Morpho)
    function deploy(Addresses addresses, address) public override {
        _deployCoreWrappers(addresses);
        _deployMorphoWrappers(addresses);

        vm.selectFork(OPTIMISM_FORK_ID);
        _deployCoreWrappers(addresses);
        // no morpho markets on optimism

        // switch back
        vm.selectFork(BASE_FORK_ID);
    }

    //
    function build(Addresses addresses) public override {
        // Base: upgrade Morpho wrappers and wire core feeds
        _upgradeMorphoWrappers(addresses, BASE_CHAIN_ID);
        _wireCoreFeeds(addresses, BASE_CHAIN_ID);

        // Optimism: only wire core feeds
        vm.selectFork(OPTIMISM_FORK_ID);
        _wireCoreFeeds(addresses, OPTIMISM_CHAIN_ID);

        vm.selectFork(BASE_FORK_ID);
    }

    function validate(Addresses addresses, address) public override {
        // Validate Optimism
        vm.selectFork(OPTIMISM_FORK_ID);
        _validateFeedsPointToWrappers(addresses, OPTIMISM_CHAIN_ID);
        _validateCoreWrappersConstructor(addresses, OPTIMISM_CHAIN_ID);

        // Validate Base
        vm.selectFork(BASE_FORK_ID);
        _validateFeedsPointToWrappers(addresses, BASE_CHAIN_ID);
        _validateCoreWrappersConstructor(addresses, BASE_CHAIN_ID);
        _validateMorphoWrappersImplementations(addresses, BASE_CHAIN_ID);
        _validateMorphoWrappersState(addresses, BASE_CHAIN_ID);
    }

    function _upgradeMorphoWrappers(
        Addresses addresses,
        uint256 chainId
    ) internal {
        MorphoOracleConfig[]
            memory morphoConfigs = getMorphoOracleConfigurations(chainId);

        require(
            addresses.isAddressSet(MORPHO_IMPLEMENTATION_NAME),
            "Morpho implementation not deployed"
        );
        address proxyAdmin = addresses.getAddress(
            "CHAINLINK_ORACLE_PROXY_ADMIN"
        );

        for (uint256 i = 0; i < morphoConfigs.length; i++) {
            string memory wrapperName = string(
                abi.encodePacked(morphoConfigs[i].proxyName, "_ORACLE_PROXY")
            );

            require(
                addresses.isAddressSet(wrapperName),
                "Morpho wrapper not deployed"
            );

            _pushAction(
                proxyAdmin,
                abi.encodeWithSignature(
                    "upgradeAndCall(address,address,bytes)",
                    addresses.getAddress(wrapperName),
                    addresses.getAddress(MORPHO_IMPLEMENTATION_NAME),
                    abi.encodeWithSelector(
                        ChainlinkOEVMorphoWrapper.initializeV2.selector,
                        addresses.getAddress(morphoConfigs[i].priceFeedName),
                        addresses.getAddress("TEMPORAL_GOVERNOR"),
                        addresses.getAddress("MORPHO_BLUE"),
                        addresses.getAddress("CHAINLINK_ORACLE"),
                        addresses.getAddress(
                            morphoConfigs[i].coreMarketAsFeeRecipient
                        ),
                        FEE_MULTIPLIER,
                        MAX_ROUND_DELAY,
                        MAX_DECREMENTS
                    )
                ),
                string.concat(
                    "Upgrade Morpho OEV wrapper via upgradeAndCall (with initializeV2) for ",
                    morphoConfigs[i].proxyName
                )
            );
        }
    }

    function _wireCoreFeeds(Addresses addresses, uint256 chainId) internal {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(chainId);
        console.log("=== Wiring %d core feeds ===", oracleConfigs.length);

        for (uint256 i = 0; i < oracleConfigs.length; i++) {
            OracleConfig memory config = oracleConfigs[i];
            string memory wrapperName = string(
                abi.encodePacked(config.oracleName, "_OEV_WRAPPER")
            );
            address chainlinkOracle = addresses.getAddress("CHAINLINK_ORACLE");
            string memory symbol = ERC20(addresses.getAddress(config.symbol))
                .symbol();

            address wrapperAddress = addresses.getAddress(wrapperName);
            console.log("Feed %d - Symbol: %s", i, symbol);
            console.log("  Wrapper name: %s", wrapperName);
            console.log("  Wrapper address: %s", wrapperAddress);
            console.log("  Pushed setFeed action to ChainlinkOracle");

            _pushAction(
                chainlinkOracle,
                abi.encodeWithSignature(
                    "setFeed(string,address)",
                    symbol,
                    wrapperAddress
                ),
                string.concat("Set feed to OEV wrapper for ", symbol)
            );
        }
        console.log("=== Finished wiring core feeds ===");
    }

    /// @dev deploy direct instances (non-upgradeable) for all core markets
    function _deployCoreWrappers(Addresses addresses) internal {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );

        if (oracleConfigs.length == 0) {
            console.log("No oracle configs found for chain %d", block.chainid);
            return;
        }

        console.log(
            "Deploying %d core wrappers for chain %d",
            oracleConfigs.length,
            block.chainid
        );
        vm.startBroadcast();

        for (uint256 i = 0; i < oracleConfigs.length; i++) {
            OracleConfig memory config = oracleConfigs[i];

            string memory wrapperName = string(
                abi.encodePacked(config.oracleName, "_OEV_WRAPPER")
            );

            console.log("--- Wrapper %d: %s ---", i, wrapperName);

            ChainlinkOEVWrapper wrapper = new ChainlinkOEVWrapper(
                addresses.getAddress(config.oracleName),
                addresses.getAddress("TEMPORAL_GOVERNOR"),
                addresses.getAddress("CHAINLINK_ORACLE"),
                FEE_MULTIPLIER,
                MAX_ROUND_DELAY,
                MAX_DECREMENTS
            );
            console.log("1. Deployed new wrapper at: %s", address(wrapper));

            // Set existing wrapper to deprecated and add new wrapper
            if (addresses.isAddressSet(wrapperName)) {
                address oldWrapper = addresses.getAddress(wrapperName);
                console.log("2. Old wrapper found at: %s", oldWrapper);

                string memory deprecatedName = string(
                    abi.encodePacked(wrapperName, "_DEPRECATED")
                );
                addresses.addAddress(deprecatedName, oldWrapper);
                console.log("3. Set old wrapper as: %s", deprecatedName);

                addresses.changeAddress(wrapperName, address(wrapper), true);
                console.log("4. Changed %s to new wrapper", wrapperName);
            } else {
                addresses.addAddress(wrapperName, address(wrapper));
                console.log("2. Added new wrapper (no previous wrapper)");
            }
        }

        vm.stopBroadcast();
        console.log("Finished deploying core wrappers");
    }

    function _deployMorphoWrappers(Addresses addresses) internal {
        // Only ensure implementation exists; do not deploy new proxies. We'll upgrade existing proxies instead.
        if (!addresses.isAddressSet("MORPHO_BLUE")) {
            return;
        }

        vm.startBroadcast();

        // Ensure proxy admin exists for Morpho wrapper upgrades
        if (!addresses.isAddressSet("CHAINLINK_ORACLE_PROXY_ADMIN")) {
            ProxyAdmin proxyAdmin = new ProxyAdmin();
            addresses.addAddress(
                "CHAINLINK_ORACLE_PROXY_ADMIN",
                address(proxyAdmin)
            );
        }

        // Deploy Morpho implementation if needed
        if (!addresses.isAddressSet(MORPHO_IMPLEMENTATION_NAME)) {
            ChainlinkOEVMorphoWrapper impl = new ChainlinkOEVMorphoWrapper();
            addresses.addAddress(MORPHO_IMPLEMENTATION_NAME, address(impl));
        }

        vm.stopBroadcast();
    }

    function _validateFeedsPointToWrappers(
        Addresses addresses,
        uint256 chainId
    ) internal view {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(chainId);
        address chainlinkOracle = addresses.getAddress("CHAINLINK_ORACLE");
        for (uint256 i = 0; i < oracleConfigs.length; i++) {
            OracleConfig memory config = oracleConfigs[i];
            string memory wrapperName = string(
                abi.encodePacked(config.oracleName, "_OEV_WRAPPER")
            );
            string memory symbol = ERC20(addresses.getAddress(config.symbol))
                .symbol();
            address configured = address(
                ChainlinkOracle(chainlinkOracle).getFeed(symbol)
            );
            address expected = addresses.getAddress(wrapperName);
            assertEq(
                configured,
                expected,
                string.concat("Feed not set to wrapper for ", symbol)
            );
        }
    }

    function _validateCoreWrappersConstructor(
        Addresses addresses,
        uint256 chainId
    ) internal view {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(chainId);
        address expectedOwner = addresses.getAddress("TEMPORAL_GOVERNOR");
        address expectedChainlinkOracle = addresses.getAddress(
            "CHAINLINK_ORACLE"
        );

        for (uint256 i = 0; i < oracleConfigs.length; i++) {
            OracleConfig memory config = oracleConfigs[i];
            string memory wrapperName = string(
                abi.encodePacked(config.oracleName, "_OEV_WRAPPER")
            );

            ChainlinkOEVWrapper wrapper = ChainlinkOEVWrapper(
                payable(addresses.getAddress(wrapperName))
            );

            // Validate priceFeed
            assertEq(
                address(wrapper.priceFeed()),
                addresses.getAddress(config.oracleName),
                string.concat(
                    "Core wrapper priceFeed mismatch for ",
                    wrapperName
                )
            );

            // Validate feeMultiplier
            assertEq(
                wrapper.feeMultiplier(),
                FEE_MULTIPLIER,
                string.concat(
                    "Core wrapper feeMultiplier mismatch for ",
                    wrapperName
                )
            );

            // Validate cachedRoundId (should be > 0 as it's set to priceFeed.latestRound())
            assertGt(
                wrapper.cachedRoundId(),
                0,
                string.concat(
                    "Core wrapper cachedRoundId should be > 0 for ",
                    wrapperName
                )
            );

            // Validate maxRoundDelay
            assertEq(
                wrapper.maxRoundDelay(),
                MAX_ROUND_DELAY,
                string.concat(
                    "Core wrapper maxRoundDelay mismatch for ",
                    wrapperName
                )
            );

            // Validate maxDecrements
            assertEq(
                wrapper.maxDecrements(),
                MAX_DECREMENTS,
                string.concat(
                    "Core wrapper maxDecrements mismatch for ",
                    wrapperName
                )
            );

            // Validate chainlinkOracle
            assertEq(
                address(wrapper.chainlinkOracle()),
                expectedChainlinkOracle,
                string.concat(
                    "Core wrapper chainlinkOracle mismatch for ",
                    wrapperName
                )
            );

            // Validate owner
            assertEq(
                wrapper.owner(),
                expectedOwner,
                string.concat("Core wrapper owner mismatch for ", wrapperName)
            );
        }
    }

    function _validateMorphoWrappersImplementations(
        Addresses addresses,
        uint256 chainId
    ) internal view {
        MorphoOracleConfig[]
            memory morphoConfigs = getMorphoOracleConfigurations(chainId);
        if (morphoConfigs.length == 0) return;

        for (uint256 i = 0; i < morphoConfigs.length; i++) {
            string memory wrapperName = string(
                abi.encodePacked(morphoConfigs[i].proxyName, "_ORACLE_PROXY")
            );

            validateProxy(
                vm,
                addresses.getAddress(wrapperName),
                addresses.getAddress(MORPHO_IMPLEMENTATION_NAME),
                addresses.getAddress("CHAINLINK_ORACLE_PROXY_ADMIN"),
                string.concat("morpho wrapper validation: ", wrapperName)
            );
        }
    }

    function _validateMorphoWrappersState(
        Addresses addresses,
        uint256 chainId
    ) internal view {
        MorphoOracleConfig[]
            memory morphoConfigs = getMorphoOracleConfigurations(chainId);
        if (morphoConfigs.length == 0) return;

        address morphoBlue = addresses.getAddress("MORPHO_BLUE");
        address expectedOwner = addresses.getAddress("TEMPORAL_GOVERNOR");
        address expectedChainlinkOracle = addresses.getAddress(
            "CHAINLINK_ORACLE"
        );

        for (uint256 i = 0; i < morphoConfigs.length; i++) {
            string memory wrapperName = string(
                abi.encodePacked(morphoConfigs[i].proxyName, "_ORACLE_PROXY")
            );
            ChainlinkOEVMorphoWrapper wrapper = ChainlinkOEVMorphoWrapper(
                addresses.getAddress(wrapperName)
            );

            // Validate priceFeed
            assertEq(
                address(wrapper.priceFeed()),
                addresses.getAddress(morphoConfigs[i].priceFeedName),
                string.concat(
                    "Morpho wrapper priceFeed mismatch for ",
                    wrapperName
                )
            );

            // Validate morphoBlue
            assertEq(
                address(wrapper.morphoBlue()),
                morphoBlue,
                string.concat(
                    "Morpho wrapper morphoBlue mismatch for ",
                    wrapperName
                )
            );

            // Validate chainlinkOracle
            assertEq(
                address(wrapper.chainlinkOracle()),
                expectedChainlinkOracle,
                string.concat(
                    "Morpho wrapper chainlinkOracle mismatch for ",
                    wrapperName
                )
            );

            // Validate feeRecipient
            assertEq(
                wrapper.feeRecipient(),
                addresses.getAddress(morphoConfigs[i].coreMarketAsFeeRecipient),
                string.concat(
                    "Morpho wrapper feeRecipient mismatch for ",
                    wrapperName
                )
            );

            // Validate feeMultiplier
            assertEq(
                wrapper.feeMultiplier(),
                FEE_MULTIPLIER,
                string.concat(
                    "Morpho wrapper feeMultiplier mismatch for ",
                    wrapperName
                )
            );

            // Validate cachedRoundId (should be > 0 as it's set to priceFeed.latestRound())
            assertGt(
                wrapper.cachedRoundId(),
                0,
                string.concat(
                    "Morpho wrapper cachedRoundId should be > 0 for ",
                    wrapperName
                )
            );

            // Validate maxRoundDelay
            assertEq(
                wrapper.maxRoundDelay(),
                MAX_ROUND_DELAY,
                string.concat(
                    "Morpho wrapper maxRoundDelay mismatch for ",
                    wrapperName
                )
            );

            // Validate maxDecrements
            assertEq(
                wrapper.maxDecrements(),
                MAX_DECREMENTS,
                string.concat(
                    "Morpho wrapper maxDecrements mismatch for ",
                    wrapperName
                )
            );

            // Validate owner
            assertEq(
                wrapper.owner(),
                expectedOwner,
                string.concat("Morpho wrapper owner mismatch for ", wrapperName)
            );

            // Validate decimals behavior
            uint8 d = wrapper.decimals();
            assertEq(
                d,
                AggregatorV3Interface(
                    addresses.getAddress(morphoConfigs[i].priceFeedName)
                ).decimals(),
                string.concat(
                    "Morpho wrapper decimals mismatch for ",
                    wrapperName
                )
            );

            // Validate latestRoundData behavior
            (uint80 roundId, int256 answer, , uint256 updatedAt, ) = wrapper
                .latestRoundData();
            assertGt(
                uint256(roundId),
                0,
                string.concat(
                    "Morpho wrapper roundId invalid for ",
                    wrapperName
                )
            );
            assertGt(
                uint256(updatedAt),
                0,
                string.concat(
                    "Morpho wrapper updatedAt invalid for ",
                    wrapperName
                )
            );
            assertGt(
                uint256(answer),
                0,
                string.concat("Morpho wrapper answer invalid for ", wrapperName)
            );
        }
    }
}
