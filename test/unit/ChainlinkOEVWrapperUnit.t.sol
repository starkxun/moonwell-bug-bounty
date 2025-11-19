// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Test} from "@forge-std/Test.sol";
import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {MockChainlinkOracle} from "@test/mock/MockChainlinkOracle.sol";
import {MockChainlinkOracleWithoutLatestRound} from "@test/mock/MockChainlinkOracleWithoutLatestRound.sol";

contract ChainlinkOEVWrapperUnitTest is Test {
    address public owner = address(0x1);
    address public chainlinkOracle = address(0x4);
    address public feeRecipient = address(0x5);
    uint16 public defaultFeeBps = 100; // 1%
    uint256 public defaultMaxRoundDelay = 300; // 5 minutes
    uint256 public defaultMaxDecrements = 5;

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
}
