pragma solidity 0.8.19;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console} from "@forge-std/console.sol";

import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {MockChainlinkOracle} from "@test/mock/MockChainlinkOracle.sol";
import {MockChainlinkOracleWithoutLatestRound} from "@test/mock/MockChainlinkOracleWithoutLatestRound.sol";
import {DeployChainlinkOEVWrapper} from "@script/DeployChainlinkOEVWrapper.s.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {ChainIds, BASE_FORK_ID} from "@utils/ChainIds.sol";

contract ChainlinkOEVWrapperIntegrationTest is PostProposalCheck {
    using ChainIds for uint256;

    ChainlinkOEVWrapper public proxy;
    AggregatorV3Interface public originalFeed;
    DeployChainlinkOEVWrapper public deployer;

    function setUp() public override {
        uint256 primaryForkId = vm.envUint("PRIMARY_FORK_ID");

        super.setUp();
        vm.selectFork(primaryForkId);

        // revertt timestamp back
        vm.warp(proposalStartTime);

        deployer = new DeployChainlinkOEVWrapper();

        originalFeed = AggregatorV3Interface(
            addresses.getAddress("CHAINLINK_WELL_USD")
        );

        (
            TransparentUpgradeableProxy proxyContract,
            ChainlinkOEVWrapper implementation
        ) = deployer.deploy(addresses);
        proxy = ChainlinkOEVWrapper(address(proxyContract));

        // Validate deployment
        deployer.validate(addresses, proxyContract, implementation);
    }

    function testProxyReturnsEqualDecimals() public view {
        uint8 proxyDecimals = proxy.decimals();
        uint8 originalDecimals = originalFeed.decimals();

        assertEq(
            proxyDecimals,
            originalDecimals,
            "Proxy decimals should equal original feed decimals"
        );
    }

    function testProxyReturnsEqualDescription() public view {
        string memory proxyDescription = proxy.description();
        string memory originalDescription = originalFeed.description();

        assertEq(
            proxyDescription,
            originalDescription,
            "Proxy description should equal original feed description"
        );
    }

    function testProxyReturnsEqualVersion() public view {
        uint256 proxyVersion = proxy.version();
        uint256 originalVersion = originalFeed.version();

        assertEq(
            proxyVersion,
            originalVersion,
            "Proxy version should equal original feed version"
        );
    }

    function testProxyReturnsEqualLatestRoundData() public view {
        (
            uint80 proxyRoundId,
            int256 proxyAnswer,
            uint256 proxyStartedAt,
            uint256 proxyUpdatedAt,
            uint80 proxyAnsweredInRound
        ) = proxy.latestRoundData();

        (
            uint80 originalRoundId,
            int256 originalAnswer,
            uint256 originalStartedAt,
            uint256 originalUpdatedAt,
            uint80 originalAnsweredInRound
        ) = originalFeed.latestRoundData();

        assertEq(
            proxyRoundId,
            originalRoundId,
            "Proxy roundId should equal original feed roundId"
        );
        assertEq(
            proxyAnswer,
            originalAnswer,
            "Proxy answer should equal original feed answer"
        );
        assertEq(
            proxyStartedAt,
            originalStartedAt,
            "Proxy startedAt should equal original feed startedAt"
        );
        assertEq(
            proxyUpdatedAt,
            originalUpdatedAt,
            "Proxy updatedAt should equal original feed updatedAt"
        );
        assertEq(
            proxyAnsweredInRound,
            originalAnsweredInRound,
            "Proxy answeredInRound should equal original feed answeredInRound"
        );
    }

    function testProxyReturnsEqualLatestRound() public view {
        uint256 proxyLatestRound = proxy.latestRound();
        uint256 originalLatestRound = originalFeed.latestRound();

        assertEq(
            proxyLatestRound,
            originalLatestRound,
            "Proxy latestRound should equal original feed latestRound"
        );
    }

    function testProxyReturnsEqualGetRoundData() public view {
        uint80 roundId = uint80(originalFeed.latestRound());

        (
            uint80 proxyRoundId,
            int256 proxyAnswer,
            uint256 proxyStartedAt,
            uint256 proxyUpdatedAt,
            uint80 proxyAnsweredInRound
        ) = proxy.getRoundData(roundId);

        (
            uint80 originalRoundIdReturned,
            int256 originalAnswer,
            uint256 originalStartedAt,
            uint256 originalUpdatedAt,
            uint80 originalAnsweredInRound
        ) = originalFeed.getRoundData(roundId);

        assertEq(
            proxyRoundId,
            originalRoundIdReturned,
            "Proxy getRoundData roundId should equal original feed roundId"
        );
        assertEq(
            proxyAnswer,
            originalAnswer,
            "Proxy getRoundData answer should equal original feed answer"
        );
        assertEq(
            proxyStartedAt,
            originalStartedAt,
            "Proxy getRoundData startedAt should equal original feed startedAt"
        );
        assertEq(
            proxyUpdatedAt,
            originalUpdatedAt,
            "Proxy getRoundData updatedAt should equal original feed updatedAt"
        );
        assertEq(
            proxyAnsweredInRound,
            originalAnsweredInRound,
            "Proxy getRoundData answeredInRound should equal original feed answeredInRound"
        );
    }

    function testProxyPriceFeedAddress() public view {
        address proxyFeedAddress = address(proxy.priceFeed());
        address originalFeedAddress = addresses.getAddress(
            "CHAINLINK_WELL_USD"
        );

        assertEq(
            proxyFeedAddress,
            originalFeedAddress,
            "Proxy should point to correct price feed"
        );
    }

    function testProxyOwnership() public view {
        address proxyOwner = proxy.owner();

        assertEq(
            proxyOwner,
            addresses.getAddress("MRD_PROXY_ADMIN"),
            "Proxy owner should be MRD_PROXY_ADMIN"
        );
    }

    function testAnswerIsPositive() public view {
        (, int256 answer, , , ) = proxy.latestRoundData();

        assertTrue(answer > 0, "Price should be positive");
    }

    function testUpdatedAtIsRecent() public view {
        (, , , uint256 updatedAt, ) = proxy.latestRoundData();

        assertTrue(updatedAt > 0, "UpdatedAt should be set");
        assertTrue(
            block.timestamp - updatedAt < 86400,
            "Price should be updated within 24 hours"
        );
    }

    function testLatestRoundDataRevertsOnZeroPrice() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(0, 8);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        vm.expectRevert("Chainlink price cannot be lower or equal to 0");
        testProxy.latestRoundData();
    }

    function testLatestRoundDataRevertsOnNegativePrice() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(-1, 8);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        vm.expectRevert("Chainlink price cannot be lower or equal to 0");
        testProxy.latestRoundData();
    }

    function testLatestRoundDataRevertsOnZeroUpdatedAt() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        mockFeed.set(1, 100e8, 1, 0, 1);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        vm.expectRevert("Round is in incompleted state");
        testProxy.latestRoundData();
    }

    function testLatestRoundDataRevertsOnStalePrice() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        mockFeed.set(5, 100e8, 1, 1, 4);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        vm.expectRevert("Stale price");
        testProxy.latestRoundData();
    }

    function testGetRoundDataRevertsOnZeroPrice() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        mockFeed.set(5, 0, 1, 1, 5);

        vm.expectRevert("Chainlink price cannot be lower or equal to 0");
        testProxy.getRoundData(5);
    }

    function testGetRoundDataRevertsOnZeroUpdatedAt() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        mockFeed.set(5, 100e8, 1, 0, 5);

        vm.expectRevert("Round is in incompleted state");
        testProxy.getRoundData(5);
    }

    function testGetRoundDataRevertsOnStalePrice() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        mockFeed.set(5, 100e8, 1, 1, 4);

        vm.expectRevert("Stale price");
        testProxy.getRoundData(5);
    }

    function testLatestRoundFallbackWhenNotSupported() public {
        // Create a mock feed that doesn't support latestRound()
        MockChainlinkOracleWithoutLatestRound mockFeed = new MockChainlinkOracleWithoutLatestRound(
                100e8,
                8
            );
        mockFeed.set(12345, 100e8, 1, 1, 12345);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        // Call latestRound() - should fall back to getting roundId from latestRoundData()
        uint256 round = testProxy.latestRound();

        // Verify it returns the correct roundId from latestRoundData
        assertEq(round, 12345, "Should return roundId from fallback");
    }

    function testLatestRoundReturnsDirectlyWhenSupported() public {
        // Create a normal mock feed that supports latestRound()
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        mockFeed.set(99999, 100e8, 1, 1, 99999);

        ChainlinkOEVWrapper newProxy = new ChainlinkOEVWrapper();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(newProxy),
                addresses.getAddress("MRD_PROXY_ADMIN"),
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    addresses.getAddress("MRD_PROXY_ADMIN")
                )
            );
        ChainlinkOEVWrapper testProxy = ChainlinkOEVWrapper(
            address(proxyContract)
        );

        // Call latestRound() - should use the direct call
        uint256 round = testProxy.latestRound();

        // Verify it returns the correct roundId
        assertEq(round, 99999, "Should return roundId from direct call");
    }
}
