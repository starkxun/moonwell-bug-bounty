// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {WETH9} from "@protocol/router/IWETH.sol";
import {MTokenInterface} from "@protocol/MTokenInterfaces.sol";
import {MErc20} from "@protocol/MErc20.sol";
import {MWethOwnerWrapper} from "@protocol/MWethOwnerWrapper.sol";

import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {BASE_FORK_ID} from "@utils/ChainIds.sol";

/// @notice Integration tests for MWethOwnerWrapper on Base fork
/// @dev Tests the wrapper deployed by MIP-B53 after proposal execution
contract MWethOwnerWrapperIntegrationTest is PostProposalCheck {
    MWethOwnerWrapper public wrapper;

    address public temporalGovernor;
    address public moonwellWeth;
    address public weth;
    address public wethUnwrapper;
    address public mrdProxyAdmin;

    // Test addresses
    address public constant TEST_USER = address(0x1234);
    address public constant RECIPIENT = address(0x5678);

    event EthWrapped(uint256 amount);
    event TokenWithdrawn(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    function setUp() public override {
        // Run all proposals in development, including MIP-B53
        super.setUp();

        vm.selectFork(BASE_FORK_ID);

        // Get deployed contract addresses
        temporalGovernor = addresses.getAddress("TEMPORAL_GOVERNOR");
        moonwellWeth = addresses.getAddress("MOONWELL_WETH");
        weth = addresses.getAddress("WETH");
        wethUnwrapper = addresses.getAddress("WETH_UNWRAPPER");
        mrdProxyAdmin = addresses.getAddress("MRD_PROXY_ADMIN");

        // Get the wrapper deployed by MIP-B53
        address wrapperAddress = addresses.getAddress("MWETH_OWNER_WRAPPER");
        wrapper = MWethOwnerWrapper(payable(wrapperAddress));
    }

    // ============================================
    // Deployment and Configuration Tests
    // ============================================

    function testDeploymentOnBaseFork() public view {
        // Verify wrapper exists and was deployed correctly
        assertTrue(address(wrapper).code.length > 0, "Wrapper not deployed");

        assertEq(
            address(wrapper.mToken()),
            moonwellWeth,
            "mToken address mismatch"
        );
        assertEq(address(wrapper.weth()), weth, "WETH address mismatch");
        assertEq(
            wrapper.owner(),
            temporalGovernor,
            "Owner should be TEMPORAL_GOVERNOR"
        );
    }

    function testWrapperIsUpgradeable() public view {
        // Verify proxy admin
        ProxyAdmin admin = ProxyAdmin(mrdProxyAdmin);
        address actualImpl = admin.getProxyImplementation(
            ITransparentUpgradeableProxy(address(wrapper))
        );

        // Implementation should exist and have code
        assertTrue(actualImpl.code.length > 0, "Implementation not deployed");

        // Verify proxy admin is correct
        address actualProxyAdmin = admin.getProxyAdmin(
            ITransparentUpgradeableProxy(address(wrapper))
        );
        assertEq(actualProxyAdmin, mrdProxyAdmin, "Proxy admin mismatch");
    }

    function testProposalTransferredAdminToWrapper() public view {
        // Verify MIP-B53 successfully transferred admin
        MTokenInterface mToken = MTokenInterface(moonwellWeth);

        assertEq(
            mToken.admin(),
            address(wrapper),
            "MIP-B53 should have transferred admin to wrapper"
        );

        assertEq(
            mToken.pendingAdmin(),
            address(0),
            "Pending admin should be cleared after transfer"
        );
    }

    function testRealContractsExist() public view {
        // Verify all referenced contracts exist and have code
        assertTrue(
            temporalGovernor.code.length > 0,
            "TEMPORAL_GOVERNOR has no code"
        );
        assertTrue(moonwellWeth.code.length > 0, "MOONWELL_WETH has no code");
        assertTrue(weth.code.length > 0, "WETH has no code");
        assertTrue(wethUnwrapper.code.length > 0, "WETH_UNWRAPPER has no code");
    }

    // ============================================
    // Admin Transfer Tests
    // ============================================

    function testCanTransferAdminToAnotherAddress() public {
        // Wrapper (controlled by TEMPORAL_GOVERNOR) can transfer admin to another address
        MTokenInterface mToken = MTokenInterface(moonwellWeth);
        address newAdmin = address(0x9999);

        // Current admin should be wrapper
        assertEq(mToken.admin(), address(wrapper), "Admin should be wrapper");

        // Set new pending admin through wrapper
        vm.prank(temporalGovernor);
        uint256 result = wrapper._setPendingAdmin(payable(newAdmin));
        assertEq(result, 0, "setPendingAdmin should succeed");

        // Verify pending admin was set
        assertEq(
            mToken.pendingAdmin(),
            newAdmin,
            "Pending admin should be set"
        );

        // Transfer back to wrapper (cleanup)
        vm.prank(newAdmin);
        mToken._acceptAdmin();

        vm.prank(newAdmin);
        mToken._setPendingAdmin(payable(address(wrapper)));

        vm.prank(temporalGovernor);
        wrapper._acceptAdmin();
    }

    // ============================================
    // Reserve Reduction Tests (Real Workflow)
    // ============================================

    function testReduceReservesWithRealWethMarket() public {
        MTokenInterface mToken = MTokenInterface(moonwellWeth);

        // Admin should already be wrapper (transferred by MIP-B53)
        assertEq(mToken.admin(), address(wrapper), "Admin should be wrapper");

        // Accrue interest to get stable reserves value
        mToken.accrueInterest();

        // Record initial state after accrual
        uint256 initialReserves = mToken.totalReserves();
        require(initialReserves > 0, "WETH market should have reserves");

        // Calculate safe reduction amount (1% of reserves to avoid depleting reserves)
        uint256 reduceAmount = initialReserves / 100;
        require(reduceAmount > 0, "Reduce amount should be > 0");

        uint256 wrapperWethBefore = IERC20(weth).balanceOf(address(wrapper));

        // Reduce reserves through wrapper
        vm.prank(temporalGovernor);
        uint256 result = wrapper._reduceReserves(reduceAmount);

        assertEq(result, 0, "Reduce reserves should succeed");

        // Verify reserves were reduced (allow for small rounding differences)
        uint256 finalReserves = mToken.totalReserves();
        uint256 expectedFinalReserves = initialReserves - reduceAmount;

        // Allow up to 0.1% difference due to rounding
        uint256 tolerance = reduceAmount / 1000;
        assertApproxEqAbs(
            finalReserves,
            expectedFinalReserves,
            tolerance,
            "Reserves not reduced correctly"
        );

        // Verify wrapper received and auto-wrapped WETH
        uint256 wrapperWethAfter = IERC20(weth).balanceOf(address(wrapper));
        assertEq(
            wrapperWethAfter - wrapperWethBefore,
            reduceAmount,
            "Wrapper should have received WETH"
        );
    }

    function testFullReserveReductionWorkflow() public {
        MTokenInterface mToken = MTokenInterface(moonwellWeth);

        // Admin should already be wrapper (transferred by MIP-B53)
        assertEq(mToken.admin(), address(wrapper), "Admin should be wrapper");

        // Step 1: Reduce reserves
        uint256 initialReserves = mToken.totalReserves();
        uint256 reduceAmount = initialReserves / 100; // 1% of reserves

        vm.prank(temporalGovernor);
        uint256 result = wrapper._reduceReserves(reduceAmount);
        assertEq(result, 0, "Reduce reserves failed");

        // Verify WETH in wrapper
        uint256 wrapperBalance = IERC20(weth).balanceOf(address(wrapper));
        assertEq(wrapperBalance, reduceAmount, "WETH not in wrapper");

        // Step 2: Withdraw WETH to recipient
        uint256 recipientBefore = IERC20(weth).balanceOf(RECIPIENT);

        vm.prank(temporalGovernor);
        wrapper.withdrawToken(weth, RECIPIENT, reduceAmount);

        uint256 recipientAfter = IERC20(weth).balanceOf(RECIPIENT);
        assertEq(
            recipientAfter - recipientBefore,
            reduceAmount,
            "Recipient didn't receive WETH"
        );

        // Step 3: Verify wrapper is empty
        assertEq(
            IERC20(weth).balanceOf(address(wrapper)),
            0,
            "Wrapper should be empty"
        );
    }

    // ============================================
    // ETH Receiving and Wrapping Tests
    // ============================================

    function testReceiveEthAutoWrapsToWeth() public {
        uint256 amount = 5 ether;

        // Fund test user with ETH
        vm.deal(TEST_USER, amount);

        uint256 wrapperWethBefore = IERC20(weth).balanceOf(address(wrapper));

        // Send ETH to wrapper
        vm.prank(TEST_USER);
        (bool success, ) = address(wrapper).call{value: amount}("");
        assertTrue(success, "ETH transfer should succeed");

        // Verify WETH balance increased
        uint256 wrapperWethAfter = IERC20(weth).balanceOf(address(wrapper));
        assertEq(
            wrapperWethAfter - wrapperWethBefore,
            amount,
            "ETH should be auto-wrapped to WETH"
        );
    }

    function testWrapperCanReceiveEthFromUnwrapper() public {
        // Note: WethUnwrapper can only be called by mToken, not directly
        // This test verifies the wrapper can receive ETH (tested via direct send)
        // The full flow through mToken is tested in testReduceReservesWithRealWethMarket

        uint256 amount = 1 ether;

        // Simulate what WethUnwrapper does: send ETH to wrapper
        vm.deal(address(this), amount);

        uint256 wrapperWethBefore = IERC20(weth).balanceOf(address(wrapper));

        // Send raw ETH to wrapper (simulating unwrapper)
        (bool success, ) = address(wrapper).call{value: amount}("");
        assertTrue(success, "ETH transfer should succeed");

        // Verify wrapper received and auto-wrapped the ETH
        uint256 wrapperWethAfter = IERC20(weth).balanceOf(address(wrapper));
        assertEq(
            wrapperWethAfter - wrapperWethBefore,
            amount,
            "Wrapper should auto-wrap received ETH"
        );
    }

    // ============================================
    // Admin Function Delegation Tests
    // ============================================

    function testSetReserveFactorThroughWrapper() public {
        MTokenInterface mToken = MTokenInterface(moonwellWeth);

        // Admin should already be wrapper (transferred by MIP-B53)
        assertEq(mToken.admin(), address(wrapper), "Admin should be wrapper");

        // Get current reserve factor
        uint256 currentReserveFactor = mToken.reserveFactorMantissa();

        // Set new reserve factor (current + 0.01e18)
        uint256 newReserveFactor = currentReserveFactor + 0.01e18;

        vm.prank(temporalGovernor);
        uint256 result = wrapper._setReserveFactor(newReserveFactor);

        assertEq(result, 0, "setReserveFactor should succeed");
        assertEq(
            mToken.reserveFactorMantissa(),
            newReserveFactor,
            "Reserve factor not updated"
        );
    }

    function testSetProtocolSeizeShareThroughWrapper() public {
        MTokenInterface mToken = MTokenInterface(moonwellWeth);

        // Admin should already be wrapper (transferred by MIP-B53)
        assertEq(mToken.admin(), address(wrapper), "Admin should be wrapper");

        // Get current protocol seize share
        uint256 currentSeizeShare = mToken.protocolSeizeShareMantissa();

        // Set new protocol seize share (current + 0.01e18)
        uint256 newSeizeShare = currentSeizeShare + 0.01e18;

        vm.prank(temporalGovernor);
        uint256 result = wrapper._setProtocolSeizeShare(newSeizeShare);

        assertEq(result, 0, "setProtocolSeizeShare should succeed");
        assertEq(
            mToken.protocolSeizeShareMantissa(),
            newSeizeShare,
            "Protocol seize share not updated"
        );
    }

    // ============================================
    // Access Control Tests
    // ============================================

    function testOnlyTemporalGovernorCanCallAdminFunctions() public {
        // Try calling from unauthorized address
        vm.prank(TEST_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        wrapper._reduceReserves(1 ether);

        vm.prank(TEST_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        wrapper._setPendingAdmin(payable(TEST_USER));

        vm.prank(TEST_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        wrapper.withdrawToken(weth, TEST_USER, 1 ether);
    }

    // ============================================
    // Token Withdrawal Tests
    // ============================================

    function testWithdrawWethToRecipient() public {
        uint256 amount = 10 ether;

        // Fund wrapper with WETH
        vm.deal(address(this), amount);
        WETH9(weth).deposit{value: amount}();
        IERC20(weth).transfer(address(wrapper), amount);

        uint256 recipientBefore = IERC20(weth).balanceOf(RECIPIENT);

        // Withdraw through wrapper
        vm.prank(temporalGovernor);
        wrapper.withdrawToken(weth, RECIPIENT, amount);

        uint256 recipientAfter = IERC20(weth).balanceOf(RECIPIENT);
        assertEq(
            recipientAfter - recipientBefore,
            amount,
            "Recipient should receive WETH"
        );
        assertEq(
            IERC20(weth).balanceOf(address(wrapper)),
            0,
            "Wrapper should be empty"
        );
    }

    // ============================================
    // View Function Tests
    // ============================================

    function testGetTokenBalance() public {
        uint256 amount = 7 ether;

        // Fund wrapper with WETH
        vm.deal(address(this), amount);
        WETH9(weth).deposit{value: amount}();
        IERC20(weth).transfer(address(wrapper), amount);

        assertEq(
            wrapper.getTokenBalance(weth),
            amount,
            "getTokenBalance incorrect"
        );
    }

    // ============================================
    // Gas Optimization Tests
    // ============================================

    function testReduceReservesGasUsage() public {
        MTokenInterface mToken = MTokenInterface(moonwellWeth);

        // Admin should already be wrapper (transferred by MIP-B53)
        assertEq(mToken.admin(), address(wrapper), "Admin should be wrapper");

        uint256 reduceAmount = mToken.totalReserves() / 100;

        // Measure gas
        vm.prank(temporalGovernor);
        uint256 gasBefore = gasleft();
        wrapper._reduceReserves(reduceAmount);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas usage for reference
        emit log_named_uint("Gas used for _reduceReserves", gasUsed);

        // Sanity check: should use less than 500k gas
        assertLt(gasUsed, 500_000, "Gas usage too high");
    }

    // Helper to receive ETH
    receive() external payable {}
}
