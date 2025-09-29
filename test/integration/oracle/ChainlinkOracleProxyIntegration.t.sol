pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainlinkOracleProxy} from "@protocol/oracles/ChainlinkOracleProxy.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {DeployChainlinkOracleProxy} from "@script/DeployChainlinkOracleProxy.s.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {ChainIds, BASE_FORK_ID} from "@utils/ChainIds.sol";

contract ChainlinkOracleProxyIntegrationTest is Test {
    using ChainIds for uint256;

    ChainlinkOracleProxy public proxy;
    AggregatorV3Interface public originalFeed;
    Addresses public addresses;
    DeployChainlinkOracleProxy public deployer;

    function setUp() public {
        ChainIds.createForksAndSelect(BASE_FORK_ID);

        addresses = new Addresses();
        deployer = new DeployChainlinkOracleProxy();

        originalFeed = AggregatorV3Interface(
            addresses.getAddress("CHAINLINK_WELL_USD")
        );

        (
            TransparentUpgradeableProxy proxyContract,
            ChainlinkOracleProxy implementation
        ) = deployer.deploy(addresses);
        proxy = ChainlinkOracleProxy(address(proxyContract));

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
            address(deployer),
            "Proxy owner should be the deployer"
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
}
