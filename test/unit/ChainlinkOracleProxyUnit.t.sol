// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Test} from "@forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ChainlinkOracleProxy} from "@protocol/oracles/ChainlinkOracleProxy.sol";
import {MockChainlinkOracle} from "@test/mock/MockChainlinkOracle.sol";
import {MockChainlinkOracleWithoutLatestRound} from "@test/mock/MockChainlinkOracleWithoutLatestRound.sol";

contract ChainlinkOracleProxyUnitTest is Test {
    address public owner = address(0x1);
    address public proxyAdmin = address(0x2);

    function testLatestRoundFallbackWhenNotSupported() public {
        // Create a mock feed that doesn't support latestRound()
        MockChainlinkOracleWithoutLatestRound mockFeed = new MockChainlinkOracleWithoutLatestRound(
                100e8,
                8
            );
        mockFeed.set(12345, 100e8, 1, 1, 12345);

        ChainlinkOracleProxy implementation = new ChainlinkOracleProxy();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(implementation),
                proxyAdmin,
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    owner
                )
            );
        ChainlinkOracleProxy proxy = ChainlinkOracleProxy(
            address(proxyContract)
        );

        // Call latestRound() - should fall back to getting roundId from latestRoundData()
        uint256 round = proxy.latestRound();

        // Verify it returns the correct roundId from latestRoundData
        assertEq(round, 12345, "Should return roundId from fallback");
    }

    function testLatestRoundReturnsDirectlyWhenSupported() public {
        // Create a normal mock feed that supports latestRound()
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        mockFeed.set(99999, 100e8, 1, 1, 99999);

        ChainlinkOracleProxy implementation = new ChainlinkOracleProxy();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(implementation),
                proxyAdmin,
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    owner
                )
            );
        ChainlinkOracleProxy proxy = ChainlinkOracleProxy(
            address(proxyContract)
        );

        // Call latestRound() - should use the direct call
        uint256 round = proxy.latestRound();

        // Verify it returns the correct roundId
        assertEq(round, 99999, "Should return roundId from direct call");
    }

    function testLatestRoundMatchesLatestRoundDataRoundId() public {
        // Test that when fallback is used, it matches the roundId from latestRoundData
        MockChainlinkOracleWithoutLatestRound mockFeed = new MockChainlinkOracleWithoutLatestRound(
                150e8,
                8
            );
        mockFeed.set(54321, 150e8, 100, 200, 54321);

        ChainlinkOracleProxy implementation = new ChainlinkOracleProxy();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
                address(implementation),
                proxyAdmin,
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    address(mockFeed),
                    owner
                )
            );
        ChainlinkOracleProxy proxy = ChainlinkOracleProxy(
            address(proxyContract)
        );

        // Get roundId from latestRoundData
        (uint80 roundId, , , , ) = proxy.latestRoundData();

        // Get round from latestRound
        uint256 round = proxy.latestRound();

        // They should match
        assertEq(
            round,
            uint256(roundId),
            "latestRound should match latestRoundData roundId"
        );
    }
}
