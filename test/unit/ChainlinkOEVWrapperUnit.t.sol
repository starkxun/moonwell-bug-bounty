// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Test} from "@forge-std/Test.sol";
import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {MockChainlinkOracle} from "@test/mock/MockChainlinkOracle.sol";
import {MockChainlinkOracleWithoutLatestRound} from "@test/mock/MockChainlinkOracleWithoutLatestRound.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {EIP20Interface} from "@protocol/EIP20Interface.sol";
import {MockERC20Decimals} from "@test/mock/MockERC20Decimals.sol";

contract ChainlinkOEVWrapperUnitTest is Test {
    address public owner = address(0x1);
    address public chainlinkOracle = address(0x4);
    address public feeRecipient = address(0x5);
    uint16 public defaultFeeBps = 100; // 1%
    uint256 public defaultMaxRoundDelay = 300; // 5 minutes
    uint256 public defaultMaxDecrements = 5;

    // Tokens for decimal testing
    MockERC20Decimals token6;
    MockERC20Decimals token18;
    MockERC20Decimals token24;

    // Events mirrored for expectEmit
    event FeeMultiplierChanged(
        uint16 oldFeeMultiplier,
        uint16 newFeeMultiplier
    );

    event MaxRoundDelayChanged(
        uint256 oldMaxRoundDelay,
        uint256 newMaxRoundDelay
    );
    event MaxDecrementsChanged(
        uint256 oldMaxDecrements,
        uint256 newMaxDecrements
    );

    function setUp() public {
        // Create tokens with different decimals for decimal testing
        token6 = new MockERC20Decimals("Token6", "T6", 6);
        token18 = new MockERC20Decimals("Token18", "T18", 18);
        token24 = new MockERC20Decimals("Token24", "T24", 24);
    }

    function _deploy(
        address feed
    ) internal returns (ChainlinkOEVWrapper wrapper) {
        wrapper = new ChainlinkOEVWrapper(
            feed,
            owner,
            chainlinkOracle,
            feeRecipient,
            defaultFeeBps,
            defaultMaxRoundDelay,
            defaultMaxDecrements
        );
    }

    /// @notice Create a harness with a mock price feed of specific decimals
    function _createHarness(
        uint8 feedDecimals,
        int256 answer
    ) internal returns (ChainlinkOEVWrapperHarness) {
        MockAggregatorV3 mockFeed = new MockAggregatorV3(feedDecimals, answer);
        // Use address(1) for owner, feeRecipient and chainlinkOracle since we're just testing price calculation
        return
            new ChainlinkOEVWrapperHarness(
                address(mockFeed),
                address(1), // owner
                address(1), // chainlinkOracle (not used in this test)
                address(1), // feeRecipient
                5000, // feeMultiplier (50%)
                3600, // maxRoundDelay
                10 // maxDecrements
            );
    }

    function testLatestRoundFallbackWhenNotSupported() public {
        // Create a mock feed that doesn't support latestRound()
        MockChainlinkOracleWithoutLatestRound mockFeed = new MockChainlinkOracleWithoutLatestRound(
                100e8,
                8
            );
        mockFeed.set(12345, 100e8, 1, 1, 12345);

        // Constructor should revert because it calls latestRound()
        vm.expectRevert(bytes("latestRound not supported"));
        new ChainlinkOEVWrapper(
            address(mockFeed),
            owner,
            chainlinkOracle,
            feeRecipient,
            defaultFeeBps,
            defaultMaxRoundDelay,
            defaultMaxDecrements
        );
    }

    function testLatestRoundReturnsDirectlyWhenSupported() public {
        // Create a normal mock feed that supports latestRound()
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        mockFeed.set(99999, 100e8, 1, 1, 99999);

        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        // Call latestRound() - should use the direct call
        uint256 round = wrapper.latestRound();

        // Verify it returns the correct roundId
        assertEq(round, 99999, "Should return roundId from direct call");
    }

    function testLatestRoundMatchesLatestRoundDataRoundId() public {
        // When supported, latestRound should match the roundId from latestRoundData
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(150e8, 8);
        mockFeed.set(54321, 150e8, 100, 200, 54321);

        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        // Get roundId from latestRoundData
        (uint80 roundId, , , , ) = wrapper.latestRoundData();

        // Get round from latestRound
        uint256 round = wrapper.latestRound();

        // They should match
        assertEq(
            round,
            uint256(roundId),
            "latestRound should match latestRoundData roundId"
        );
    }

    function testSetFeeMultiplierUpdatesAndEmits() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        uint16 newFee = 250; // 2.5%
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(wrapper));
        emit FeeMultiplierChanged(defaultFeeBps, newFee);
        wrapper.setFeeMultiplier(newFee);

        assertEq(wrapper.feeMultiplier(), newFee, "feeMultiplier not updated");
    }

    function testSetFeeMultiplierAboveMaxReverts() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        uint16 overMax = wrapper.MAX_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(
            bytes(
                "ChainlinkOEVWrapper: fee multiplier cannot be greater than MAX_BPS"
            )
        );
        wrapper.setFeeMultiplier(overMax);
    }

    function testSetFeeMultiplierOnlyOwner() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        wrapper.setFeeMultiplier(200);
    }

    function testSetMaxRoundDelayUpdatesAndEmits() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        uint256 newDelay = 600; // 10 minutes
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(wrapper));
        emit MaxRoundDelayChanged(defaultMaxRoundDelay, newDelay);
        wrapper.setMaxRoundDelay(newDelay);

        assertEq(
            wrapper.maxRoundDelay(),
            newDelay,
            "maxRoundDelay not updated"
        );
    }

    function testSetMaxRoundDelayZeroReverts() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        vm.prank(owner);
        vm.expectRevert(
            bytes("ChainlinkOEVWrapper: max round delay cannot be zero")
        );
        wrapper.setMaxRoundDelay(0);
    }

    function testSetMaxRoundDelayOnlyOwner() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        wrapper.setMaxRoundDelay(600);
    }

    function testSetMaxDecrementsUpdatesAndEmits() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        uint256 newDec = 10;
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(wrapper));
        emit MaxDecrementsChanged(defaultMaxDecrements, newDec);
        wrapper.setMaxDecrements(newDec);

        assertEq(wrapper.maxDecrements(), newDec, "maxDecrements not updated");
    }

    function testSetMaxDecrementsZeroReverts() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        vm.prank(owner);
        vm.expectRevert(
            bytes("ChainlinkOEVWrapper: max decrements cannot be zero")
        );
        wrapper.setMaxDecrements(0);
    }

    function testSetMaxDecrementsOnlyOwner() public {
        MockChainlinkOracle mockFeed = new MockChainlinkOracle(100e8, 8);
        ChainlinkOEVWrapper wrapper = _deploy(address(mockFeed));

        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        wrapper.setMaxDecrements(10);
    }

    /// @notice Test feed decimals < 18, token decimals < 18
    function testGetCollateralTokenPrice_FeedLt18_TokenLt18() public {
        // Feed: 8 decimals (standard Chainlink), Token: 6 decimals (USDC)
        // Answer: $1.00 in 8 decimals = 1e8
        ChainlinkOEVWrapperHarness harness = _createHarness(8, 1e8);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e8,
            address(token6)
        );

        // Expected: 1e8 * 1e10 (scale to 18) * 1e12 (adjust for 6 decimal token) = 1e30
        assertEq(
            price,
            1e30,
            "Price should be 1e30 for $1 with 6 decimal token"
        );
    }

    /// @notice Test feed decimals < 18, token decimals = 18
    function testGetCollateralTokenPrice_FeedLt18_TokenEq18() public {
        // Feed: 8 decimals, Token: 18 decimals
        // Answer: $1.00 in 8 decimals = 1e8
        ChainlinkOEVWrapperHarness harness = _createHarness(8, 1e8);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e8,
            address(token18)
        );

        // Expected: 1e8 * 1e10 (scale to 18) = 1e18
        assertEq(
            price,
            1e18,
            "Price should be 1e18 for $1 with 18 decimal token"
        );
    }

    /// @notice Test feed decimals < 18, token decimals > 18
    function testGetCollateralTokenPrice_FeedLt18_TokenGt18() public {
        // Feed: 8 decimals, Token: 24 decimals
        // Answer: $1.00 in 8 decimals = 1e8
        ChainlinkOEVWrapperHarness harness = _createHarness(8, 1e8);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e8,
            address(token24)
        );

        // Expected: 1e8 * 1e10 (scale to 18) / 1e6 (adjust for 24 decimal token) = 1e12
        assertEq(
            price,
            1e12,
            "Price should be 1e12 for $1 with 24 decimal token"
        );
    }

    /// @notice Test feed decimals = 18, token decimals < 18
    function testGetCollateralTokenPrice_FeedEq18_TokenLt18() public {
        // Feed: 18 decimals, Token: 6 decimals
        // Answer: $1.00 in 18 decimals = 1e18
        ChainlinkOEVWrapperHarness harness = _createHarness(18, 1e18);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e18,
            address(token6)
        );

        // Expected: 1e18 (no feed scaling) * 1e12 (adjust for 6 decimal token) = 1e30
        assertEq(
            price,
            1e30,
            "Price should be 1e30 for $1 with 6 decimal token"
        );
    }

    /// @notice Test feed decimals = 18, token decimals = 18
    function testGetCollateralTokenPrice_FeedEq18_TokenEq18() public {
        // Feed: 18 decimals, Token: 18 decimals
        // Answer: $1.00 in 18 decimals = 1e18
        ChainlinkOEVWrapperHarness harness = _createHarness(18, 1e18);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e18,
            address(token18)
        );

        // Expected: 1e18 (no scaling needed)
        assertEq(
            price,
            1e18,
            "Price should be 1e18 for $1 with 18 decimal token"
        );
    }

    /// @notice Test feed decimals = 18, token decimals > 18
    function testGetCollateralTokenPrice_FeedEq18_TokenGt18() public {
        // Feed: 18 decimals, Token: 24 decimals
        // Answer: $1.00 in 18 decimals = 1e18
        ChainlinkOEVWrapperHarness harness = _createHarness(18, 1e18);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e18,
            address(token24)
        );

        // Expected: 1e18 / 1e6 (adjust for 24 decimal token) = 1e12
        assertEq(
            price,
            1e12,
            "Price should be 1e12 for $1 with 24 decimal token"
        );
    }

    /// @notice Test feed decimals > 18, token decimals < 18
    function testGetCollateralTokenPrice_FeedGt18_TokenLt18() public {
        // Feed: 24 decimals, Token: 6 decimals
        // Answer: $1.00 in 24 decimals = 1e24
        ChainlinkOEVWrapperHarness harness = _createHarness(24, 1e24);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e24,
            address(token6)
        );

        // Expected: 1e24 / 1e6 (scale to 18) * 1e12 (adjust for 6 decimal token) = 1e30
        assertEq(
            price,
            1e30,
            "Price should be 1e30 for $1 with 6 decimal token"
        );
    }

    /// @notice Test feed decimals > 18, token decimals = 18
    function testGetCollateralTokenPrice_FeedGt18_TokenEq18() public {
        // Feed: 24 decimals, Token: 18 decimals
        // Answer: $1.00 in 24 decimals = 1e24
        ChainlinkOEVWrapperHarness harness = _createHarness(24, 1e24);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e24,
            address(token18)
        );

        // Expected: 1e24 / 1e6 (scale to 18) = 1e18
        assertEq(
            price,
            1e18,
            "Price should be 1e18 for $1 with 18 decimal token"
        );
    }

    /// @notice Test feed decimals > 18, token decimals > 18
    function testGetCollateralTokenPrice_FeedGt18_TokenGt18() public {
        // Feed: 24 decimals, Token: 24 decimals
        // Answer: $1.00 in 24 decimals = 1e24
        ChainlinkOEVWrapperHarness harness = _createHarness(24, 1e24);

        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e24,
            address(token24)
        );

        // Expected: 1e24 / 1e6 (scale to 18) / 1e6 (adjust for 24 decimal token) = 1e12
        assertEq(
            price,
            1e12,
            "Price should be 1e12 for $1 with 24 decimal token"
        );
    }

    /// @notice Verify that feed decimals > 18 does NOT revert (regression test for underflow fix)
    function testGetCollateralTokenPrice_NoUnderflowFeedDecimals() public {
        // This test would have reverted before the fix due to underflow
        ChainlinkOEVWrapperHarness harness = _createHarness(20, 1e20);

        // Should not revert
        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e20,
            address(token18)
        );

        // Expected: 1e20 / 1e2 = 1e18
        assertEq(price, 1e18, "Price should be correctly calculated");
    }

    /// @notice Verify that token decimals > 18 does NOT revert (regression test for underflow fix)
    function testGetCollateralTokenPrice_NoUnderflowTokenDecimals() public {
        // This test would have reverted before the fix due to underflow
        ChainlinkOEVWrapperHarness harness = _createHarness(8, 1e8);

        // Should not revert
        uint256 price = harness.exposed_getCollateralTokenPrice(
            1e8,
            address(token24)
        );

        // Expected: 1e8 * 1e10 / 1e6 = 1e12
        assertEq(price, 1e12, "Price should be correctly calculated");
    }

    /// @notice Fuzz test to ensure no reverts for any valid decimal combination
    /// forge-config: default.fuzz.runs = 100
    function testFuzz_GetCollateralTokenPrice_NoRevert(
        uint8 feedDecimals,
        uint8 tokenDecimals,
        uint128 answer
    ) public {
        // Bound decimals to reasonable ranges (0-30)
        feedDecimals = uint8(bound(feedDecimals, 0, 30));
        tokenDecimals = uint8(bound(tokenDecimals, 0, 30));
        // Ensure answer is positive and non-zero
        vm.assume(answer > 0);

        MockAggregatorV3 mockFeed = new MockAggregatorV3(
            feedDecimals,
            int256(uint256(answer))
        );
        ChainlinkOEVWrapperHarness harness = new ChainlinkOEVWrapperHarness(
            address(mockFeed),
            address(1), // owner
            address(1), // chainlinkOracle
            address(1), // feeRecipient
            5000, // feeMultiplier
            3600, // maxRoundDelay
            10 // maxDecrements
        );

        MockERC20Decimals token = new MockERC20Decimals(
            "Test",
            "TST",
            tokenDecimals
        );

        // Should not revert for any decimal combination
        harness.exposed_getCollateralTokenPrice(
            int256(uint256(answer)),
            address(token)
        );
    }
}

/// @notice Mock price feed with configurable decimals for testing
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _answer;
    uint80 private _roundId;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _roundId = 1;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock Aggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, block.timestamp, block.timestamp, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, block.timestamp, block.timestamp, _roundId);
    }

    function latestRound() external view override returns (uint256) {
        return _roundId;
    }
}

/// @notice Test harness to expose internal _getCollateralTokenPrice function
contract ChainlinkOEVWrapperHarness is ChainlinkOEVWrapper {
    constructor(
        address _priceFeed,
        address _owner,
        address _chainlinkOracle,
        address _feeRecipient,
        uint16 _feeMultiplier,
        uint256 _maxRoundDelay,
        uint256 _maxDecrements
    )
        ChainlinkOEVWrapper(
            _priceFeed,
            _owner,
            _chainlinkOracle,
            _feeRecipient,
            _feeMultiplier,
            _maxRoundDelay,
            _maxDecrements
        )
    {}

    /// @notice Expose the internal _getCollateralTokenPrice for testing
    function exposed_getCollateralTokenPrice(
        int256 collateralAnswer,
        address underlyingCollateral
    ) external view returns (uint256) {
        return
            _getCollateralTokenPrice(
                collateralAnswer,
                EIP20Interface(underlyingCollateral)
            );
    }
}
