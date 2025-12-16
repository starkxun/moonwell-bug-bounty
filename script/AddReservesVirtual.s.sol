// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MErc20} from "@protocol/MErc20.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title AddReservesVirtual
/// @notice Script to add reserves to the VIRTUAL market on Moonwell
contract AddReservesVirtual is Script, Test {
    /// @notice Amount of VIRTUAL tokens to add as reserves (18 decimals)
    uint256 public constant AMOUNT = 812458954110173493585657;

    /// @notice Addresses contract
    Addresses public addresses;

    /// @notice VIRTUAL underlying token
    IERC20 public virtualToken;

    /// @notice Moonwell VIRTUAL market
    MErc20 public mVirtual;

    constructor() {
        addresses = new Addresses();
    }

    function run() public {
        // Load addresses
        virtualToken = IERC20(addresses.getAddress("VIRTUAL", 8453));
        mVirtual = MErc20(addresses.getAddress("MOONWELL_VIRTUAL", 8453));

        console.log("VIRTUAL token:", address(virtualToken));
        console.log("MOONWELL_VIRTUAL market:", address(mVirtual));
        console.log("Amount to add:", AMOUNT);

        // Capture state before
        uint256 reservesBefore = mVirtual.totalReserves();
        uint256 senderBalanceBefore = virtualToken.balanceOf(msg.sender);

        console.log("\n--- Before ---");
        console.log("Total reserves:", reservesBefore);
        console.log("Sender VIRTUAL balance:", senderBalanceBefore);

        require(senderBalanceBefore >= AMOUNT, "Insufficient VIRTUAL balance");

        vm.startBroadcast();

        // Approve mToken to spend underlying
        virtualToken.approve(address(mVirtual), AMOUNT);

        // Add reserves
        uint256 result = mVirtual._addReserves(AMOUNT);
        require(result == 0, "Failed to add reserves");

        vm.stopBroadcast();

        // Validate
        validate(reservesBefore, senderBalanceBefore);
    }

    /// @notice Validates that reserves were correctly added
    /// @param reservesBefore Total reserves before the operation
    /// @param senderBalanceBefore Sender's VIRTUAL balance before the operation
    function validate(
        uint256 reservesBefore,
        uint256 senderBalanceBefore
    ) public view {
        uint256 reservesAfter = mVirtual.totalReserves();
        uint256 senderBalanceAfter = virtualToken.balanceOf(msg.sender);

        console.log("\n--- After ---");
        console.log("Total reserves:", reservesAfter);
        console.log("Sender VIRTUAL balance:", senderBalanceAfter);

        // Verify reserves increased by at least AMOUNT
        // (may be slightly more due to interest accrual between before/after snapshots)
        assertGe(
            reservesAfter,
            reservesBefore + AMOUNT,
            "Reserves did not increase by at least the expected amount"
        );

        // Verify sender's balance decreased by AMOUNT
        assertEq(
            senderBalanceAfter,
            senderBalanceBefore - AMOUNT,
            "Sender balance did not decrease by expected amount"
        );

        uint256 reservesIncrease = reservesAfter - reservesBefore;

        console.log("\n--- Validation Passed ---");
        console.log("Reserves increased by:", reservesIncrease);
        console.log("Amount added:", AMOUNT);
    }
}
