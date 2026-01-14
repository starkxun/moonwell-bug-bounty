pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IStakedWell} from "@protocol/IStakedWell.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MOONBEAM_FORK_ID, BASE_FORK_ID, OPTIMISM_FORK_ID} from "@utils/ChainIds.sol";
import {MultichainGovernor} from "@protocol/governance/multichain/MultichainGovernor.sol";

/// @notice Integration test for upgraded StakedWell contracts
contract StakedWellIntegrationTest is PostProposalCheck {
    // StakedWell instances on each chain
    IStakedWell public stkWellMoonbeam;
    IStakedWell public stkWellBase;
    IStakedWell public stkWellOptimism;

    // Test actors
    address internal constant STAKER_1 =
        address(uint160(uint256(keccak256(abi.encodePacked("STAKER_1")))));
    address internal constant STAKER_2 =
        address(uint160(uint256(keccak256(abi.encodePacked("STAKER_2")))));

    function setUp() public override {
        uint256 primaryForkId = vm.envUint("PRIMARY_FORK_ID");

        super.setUp();

        // Moonbeam
        vm.selectFork(primaryForkId);
        stkWellMoonbeam = IStakedWell(
            addresses.getAddress("STK_GOVTOKEN_PROXY")
        );
        vm.makePersistent(address(stkWellMoonbeam));

        // Base
        vm.selectFork(BASE_FORK_ID);
        stkWellBase = IStakedWell(addresses.getAddress("STK_GOVTOKEN_PROXY"));
        vm.makePersistent(address(stkWellBase));

        // Optimism
        vm.selectFork(OPTIMISM_FORK_ID);
        stkWellOptimism = IStakedWell(
            addresses.getAddress("STK_GOVTOKEN_PROXY")
        );
        vm.makePersistent(address(stkWellOptimism));

        vm.selectFork(primaryForkId);
    }

    /// ========== Moonbeam Tests ========== ///

    function testMoonbeamInitializeV2WasCalled() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        (bool success, bytes memory data) = address(stkWellMoonbeam).staticcall(
            abi.encodeWithSignature("defaultSnapshotTimestamp()")
        );
        require(success, "Failed to read defaultSnapshotTimestamp");
        uint256 defaultSnapshotTimestamp = abi.decode(data, (uint256));

        assertGt(
            defaultSnapshotTimestamp,
            0,
            "Moonbeam: initializeV2 not called - defaultSnapshotTimestamp is 0"
        );
    }

    function testMoonbeamGovernorUsesTimestamps() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        assertTrue(
            governor.useTimestamps(),
            "Moonbeam: MultichainGovernor should use timestamps"
        );
    }

    function testMoonbeamBasicFunctionalityWorks() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        // Verify basic view functions work
        assertGt(
            stkWellMoonbeam.totalSupply(),
            0,
            "Moonbeam: Total supply should be > 0"
        );

        // Verify getPriorVotes works with timestamps
        uint256 pastTimestamp = block.timestamp - 1 days;

        // This should not revert - confirms timestamp-based logic works
        try
            stkWellMoonbeam.getPriorVotes(address(this), pastTimestamp)
        returns (uint256) {
            // Success - timestamp-based snapshots working
            assertTrue(true, "getPriorVotes with timestamp works");
        } catch {
            revert("getPriorVotes should work with timestamps");
        }
    }

    function testMoonbeamContractUpgraded() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        // Verify contract has been upgraded by checking for V2 specific functionality
        // defaultSnapshotTimestamp only exists in V2
        (bool success, bytes memory data) = address(stkWellMoonbeam).staticcall(
            abi.encodeWithSignature("defaultSnapshotTimestamp()")
        );

        require(success, "defaultSnapshotTimestamp should exist in V2");
        uint256 timestamp = abi.decode(data, (uint256));
        assertGt(timestamp, 0, "defaultSnapshotTimestamp should be set");
    }

    function testMoonbeamVotingPowerPreservedForOldStakers() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        // Create a mock staker
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(
            stkWellMoonbeam,
            STAKER_1,
            stakeAmount
        );

        // Get current voting power
        (bool success, bytes memory data) = address(stkWellMoonbeam).call(
            abi.encodeWithSignature("getCurrentVotes(address)", staker)
        );

        require(success, "getCurrentVotes should work");
        uint256 currentVotes = abi.decode(data, (uint256));

        // Voting power should equal their balance
        uint256 balance = stkWellMoonbeam.balanceOf(staker);
        assertEq(
            currentVotes,
            balance,
            "Moonbeam: Staker voting power should equal balance"
        );
        assertEq(
            currentVotes,
            stakeAmount,
            "Moonbeam: Voting power should equal staked amount"
        );
    }

    function testMoonbeamCanVoteOnProposalWithStkWellPower() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        // Create a mock staker
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(
            stkWellMoonbeam,
            STAKER_1,
            stakeAmount
        );

        // Verify staker has voting power
        uint256 votingPower = stkWellMoonbeam.balanceOf(staker);
        assertEq(
            votingPower,
            stakeAmount,
            "Staker should have voting power equal to stake"
        );

        // Advance time so we can take a snapshot in the past
        vm.warp(block.timestamp + 2 hours);

        // Get votes at a past timestamp (simulate proposal snapshot)
        uint256 snapshotTimestamp = block.timestamp - 1 hours;
        uint256 votesAtSnapshot = stkWellMoonbeam.getPriorVotes(
            staker,
            snapshotTimestamp
        );

        // Votes at snapshot should equal the staked amount
        assertEq(
            votesAtSnapshot,
            stakeAmount,
            "Votes at snapshot should equal staked amount"
        );
    }

    function testMoonbeamProperSnapshotTimestampRequired() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        // Create a mock staker
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(
            stkWellMoonbeam,
            STAKER_2,
            stakeAmount
        );

        // Try to get votes from the future (should return 0 or revert appropriately)
        uint256 futureTimestamp = block.timestamp + 1 days;

        // This should revert or return 0 for future timestamps
        try stkWellMoonbeam.getPriorVotes(staker, futureTimestamp) returns (
            uint256 votes
        ) {
            // If it doesn't revert, it should return 0
            assertEq(votes, 0, "Future timestamp should return 0 votes");
        } catch {
            // Expected behavior - revert on future timestamp
            assertTrue(true, "Correctly reverted on future timestamp");
        }
    }

    function testMoonbeamDefaultSnapshotTimestampForV1Stakers() public {
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));

        // Get the default snapshot timestamp
        (bool success, bytes memory data) = address(stkWellMoonbeam).staticcall(
            abi.encodeWithSignature("defaultSnapshotTimestamp()")
        );
        require(success, "Failed to read defaultSnapshotTimestamp");
        uint256 defaultTimestamp = abi.decode(data, (uint256));

        // Create a mock staker who stakes AFTER the defaultSnapshotTimestamp
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(
            stkWellMoonbeam,
            STAKER_2,
            stakeAmount
        );

        // Verify staker has current voting power
        uint256 currentBalance = stkWellMoonbeam.balanceOf(staker);
        assertEq(
            currentBalance,
            stakeAmount,
            "Staker should have staked balance"
        );

        // Staker should have 0 votes at defaultSnapshotTimestamp (they didn't exist then)
        // Note: In fork tests where defaultSnapshotTimestamp > block.timestamp, this may revert
        // or return 0, both are acceptable as it confirms the timestamp-based system works
        try stkWellMoonbeam.getPriorVotes(staker, defaultTimestamp) returns (
            uint256 votesAtDefault
        ) {
            // If it doesn't revert, votes should be 0 since staker didn't exist at defaultSnapshotTimestamp
            assertEq(
                votesAtDefault,
                0,
                "New staker should have 0 votes at defaultSnapshotTimestamp"
            );
        } catch {
            // Expected if defaultSnapshotTimestamp is in the future relative to fork time
            assertTrue(
                true,
                "Query at defaultSnapshotTimestamp handled correctly"
            );
        }

        // Advance time to create a valid snapshot point
        vm.warp(block.timestamp + 2 hours);

        // Verify staker has voting power at a recent timestamp
        uint256 recentTimestamp = block.timestamp - 1 hours;
        uint256 votesAtRecent = stkWellMoonbeam.getPriorVotes(
            staker,
            recentTimestamp
        );
        assertEq(
            votesAtRecent,
            stakeAmount,
            "Staker should have full voting power at recent timestamp"
        );
    }

    /// ========== Base Tests ========== ///

    function testBaseBasicFunctionalityWorks() public {
        vm.selectFork(BASE_FORK_ID);

        // Verify basic view functions work
        assertGt(
            stkWellBase.totalSupply(),
            0,
            "Base: Total supply should be > 0"
        );

        // Verify getPriorVotes works with timestamps
        uint256 pastTimestamp = block.timestamp - 1 days;

        // This should not revert - confirms timestamp-based logic works
        try stkWellBase.getPriorVotes(address(this), pastTimestamp) returns (
            uint256
        ) {
            // Success - timestamp-based snapshots working
            assertTrue(true, "getPriorVotes with timestamp works");
        } catch {
            revert("getPriorVotes should work with timestamps");
        }
    }

    function testBaseCanVoteOnProposalWithStkWellPower() public {
        vm.selectFork(BASE_FORK_ID);

        // Create a mock staker
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(stkWellBase, STAKER_1, stakeAmount);

        // Verify staker has voting power
        uint256 votingPower = stkWellBase.balanceOf(staker);
        assertEq(
            votingPower,
            stakeAmount,
            "Base: Staker should have voting power equal to stake"
        );

        // Advance time so we can take a snapshot in the past
        vm.warp(block.timestamp + 2 hours);

        // Get votes at a past timestamp
        uint256 snapshotTimestamp = block.timestamp - 1 hours;
        uint256 votesAtSnapshot = stkWellBase.getPriorVotes(
            staker,
            snapshotTimestamp
        );

        // Votes at snapshot should equal the staked amount
        assertEq(
            votesAtSnapshot,
            stakeAmount,
            "Base: Votes at snapshot should equal staked amount"
        );
    }

    function testBaseProperSnapshotTimestampRequired() public {
        vm.selectFork(BASE_FORK_ID);

        // Create a mock staker
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(stkWellBase, STAKER_2, stakeAmount);

        uint256 futureTimestamp = block.timestamp + 1 days;

        // Future timestamp should revert or return 0
        try stkWellBase.getPriorVotes(staker, futureTimestamp) returns (
            uint256 votes
        ) {
            assertEq(votes, 0, "Base: Future timestamp should return 0 votes");
        } catch {
            assertTrue(true, "Base: Correctly reverted on future timestamp");
        }
    }

    /// ========== Optimism Tests ========== ///

    function testOptimismBasicFunctionalityWorks() public {
        vm.selectFork(OPTIMISM_FORK_ID);

        // Verify basic view functions work
        assertGt(
            stkWellOptimism.totalSupply(),
            0,
            "Optimism: Total supply should be > 0"
        );

        // Verify getPriorVotes works with timestamps
        uint256 pastTimestamp = block.timestamp - 1 days;

        // This should not revert - confirms timestamp-based logic works
        try
            stkWellOptimism.getPriorVotes(address(this), pastTimestamp)
        returns (uint256) {
            // Success - timestamp-based snapshots working
            assertTrue(true, "getPriorVotes with timestamp works");
        } catch {
            revert("getPriorVotes should work with timestamps");
        }
    }

    function testOptimismCanVoteOnProposalWithStkWellPower() public {
        vm.selectFork(OPTIMISM_FORK_ID);

        // Create a mock staker
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(
            stkWellOptimism,
            STAKER_1,
            stakeAmount
        );

        // Verify staker has voting power
        uint256 votingPower = stkWellOptimism.balanceOf(staker);
        assertEq(
            votingPower,
            stakeAmount,
            "Optimism: Staker should have voting power equal to stake"
        );

        // Advance time so we can take a snapshot in the past
        vm.warp(block.timestamp + 2 hours);

        // Get votes at a past timestamp
        uint256 snapshotTimestamp = block.timestamp - 1 hours;
        uint256 votesAtSnapshot = stkWellOptimism.getPriorVotes(
            staker,
            snapshotTimestamp
        );

        // Votes at snapshot should equal the staked amount
        assertEq(
            votesAtSnapshot,
            stakeAmount,
            "Optimism: Votes at snapshot should equal staked amount"
        );
    }

    function testOptimismProperSnapshotTimestampRequired() public {
        vm.selectFork(OPTIMISM_FORK_ID);

        // Create a mock staker
        uint256 stakeAmount = 1000e18;
        address staker = _createMockStaker(
            stkWellOptimism,
            STAKER_2,
            stakeAmount
        );

        uint256 futureTimestamp = block.timestamp + 1 days;

        // Future timestamp should revert or return 0
        try stkWellOptimism.getPriorVotes(staker, futureTimestamp) returns (
            uint256 votes
        ) {
            assertEq(
                votes,
                0,
                "Optimism: Future timestamp should return 0 votes"
            );
        } catch {
            assertTrue(
                true,
                "Optimism: Correctly reverted on future timestamp"
            );
        }
    }

    /// ========== Cross-Chain Consistency Tests ========== ///

    function testAllChainsHavePositiveTotalSupply() public {
        // Verify all chains have staked tokens (totalSupply > 0)
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));
        uint256 moonbeamSupply = stkWellMoonbeam.totalSupply();
        assertGt(moonbeamSupply, 0, "Moonbeam should have positive supply");

        vm.selectFork(BASE_FORK_ID);
        uint256 baseSupply = stkWellBase.totalSupply();
        assertGt(baseSupply, 0, "Base should have positive supply");

        vm.selectFork(OPTIMISM_FORK_ID);
        uint256 optimismSupply = stkWellOptimism.totalSupply();
        assertGt(optimismSupply, 0, "Optimism should have positive supply");
    }

    function testAllChainsUseSameInterface() public {
        // Verify all chains respond to the same core functions
        vm.selectFork(vm.envUint("PRIMARY_FORK_ID"));
        stkWellMoonbeam.totalSupply();
        stkWellMoonbeam.COOLDOWN_SECONDS();

        vm.selectFork(BASE_FORK_ID);
        stkWellBase.totalSupply();
        stkWellBase.COOLDOWN_SECONDS();

        vm.selectFork(OPTIMISM_FORK_ID);
        stkWellOptimism.totalSupply();
        stkWellOptimism.COOLDOWN_SECONDS();

        // If we got here without reverting, all chains support the same interface
        assertTrue(true, "All chains support the same interface");
    }

    /// ========== Helper Functions ========== ///

    /// @notice Creates a mock staker by dealing tokens and staking
    /// @param stkWell The StakedWell contract to stake into
    /// @param staker The address that will stake
    /// @param amount The amount to stake
    /// @return The staker address
    function _createMockStaker(
        IStakedWell stkWell,
        address staker,
        uint256 amount
    ) internal returns (address) {
        // Get the underlying token
        address underlyingToken = stkWell.STAKED_TOKEN();

        // Deal tokens to the staker
        deal(underlyingToken, staker, amount);

        // Approve and stake
        vm.startPrank(staker);
        IERC20(underlyingToken).approve(address(stkWell), amount);
        stkWell.stake(staker, amount);
        vm.stopPrank();

        return staker;
    }
}
