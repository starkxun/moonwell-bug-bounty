//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Test} from "@forge-std/Test.sol";
import {MToken} from "@protocol/MToken.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {ExponentialNoError} from "@protocol/ExponentialNoError.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

contract MarketBase is ExponentialNoError, Test {
    Comptroller comptroller;

    constructor(Comptroller _comptroller) {
        comptroller = _comptroller;
    }

    function getMaxSupplyAmount(MToken mToken) public returns (uint256) {
        mToken.accrueInterest();

        uint256 supplyCap = comptroller.supplyCaps(address(mToken));

        if (supplyCap == 0) {
            return type(uint128).max;
        }

        uint256 totalCash = mToken.getCash();
        uint256 totalBorrows = mToken.totalBorrows();
        uint256 totalReserves = mToken.totalReserves();

        uint256 totalSupplies = sub_(
            add_(totalCash, totalBorrows),
            totalReserves
        );

        if (totalSupplies - 1 >= supplyCap) {
            return 0;
        }

        return supplyCap - totalSupplies - 1;
    }

    function getMaxBorrowAmount(MToken mToken) public view returns (uint256) {
        uint256 borrowCap = comptroller.borrowCaps(address(mToken));
        uint256 totalBorrows = mToken.totalBorrows();

        if (borrowCap == 0) {
            return type(uint128).max;
        } else if (borrowCap < totalBorrows) {
            return 0;
        } else {
            return borrowCap - totalBorrows;
        }
    }

    function getMaxUserBorrowAmount(
        MToken mToken,
        address user
    ) public view returns (uint256) {
        uint256 borrowCap = comptroller.borrowCaps(address(mToken));
        uint256 totalBorrows = mToken.totalBorrows();

        (, uint256 mTokenBalance, , uint256 exchangeRate) = mToken
            .getAccountSnapshot(user);

        uint256 oraclePrice = comptroller.oracle().getUnderlyingPrice(mToken);
        (, uint256 collateralFactor) = comptroller.markets(address(mToken));

        // First convert mTokens to underlying
        uint256 underlyingAmount = mul_ScalarTruncate(
            Exp({mantissa: exchangeRate}),
            mTokenBalance
        );

        // Scale up the calculations to preserve precision
        underlyingAmount = underlyingAmount * 1e18;

        // Convert to USD value with scaling
        uint256 usdValue = mul_ScalarTruncate(
            Exp({mantissa: oraclePrice}),
            underlyingAmount
        );

        // Apply collateral factor
        uint256 maxBorrowUSD = mul_ScalarTruncate(
            Exp({mantissa: collateralFactor}),
            usdValue
        );

        uint256 maxUserBorrow = div_(maxBorrowUSD, oraclePrice);

        uint256 borrowableAmount;
        if (borrowCap == 0) {
            borrowableAmount = type(uint128).max;
        } else if (borrowCap < totalBorrows) {
            borrowableAmount = 0;
        } else {
            borrowableAmount = borrowCap - totalBorrows;
        }

        if (maxUserBorrow == 0 || borrowableAmount == 0) {
            return 0;
        }

        return
            (
                borrowableAmount > maxUserBorrow
                    ? maxUserBorrow
                    : borrowableAmount
            ) - 1;
    }

    /// @notice Ensures sufficient borrow cap for a given borrow amount
    /// @dev If the current borrow cap would be exceeded, this function increases it
    /// @dev Adds a 10% buffer to account for interest accrual between check and borrow
    /// @param mToken The market token to check/increase borrow cap for
    /// @param borrowAmount The amount to be borrowed
    /// @param addresses The addresses contract to get TEMPORAL_GOVERNOR
    function ensureSufficientBorrowCap(
        MToken mToken,
        uint256 borrowAmount,
        Addresses addresses
    ) public {
        uint256 currentBorrowCap = comptroller.borrowCaps(address(mToken));
        uint256 totalBorrows = mToken.totalBorrows();
        uint256 nextTotalBorrows = totalBorrows + borrowAmount;

        // If borrow would hit cap, increase it with a buffer for interest accrual
        if (currentBorrowCap != 0 && nextTotalBorrows >= currentBorrowCap) {
            vm.startPrank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            MToken[] memory mTokens = new MToken[](1);
            mTokens[0] = mToken;
            uint256[] memory newBorrowCaps = new uint256[](1);
            // Add 10% buffer to account for interest accrual and ensure borrow succeeds
            newBorrowCaps[0] = nextTotalBorrows + (borrowAmount / 10);
            comptroller._setMarketBorrowCaps(mTokens, newBorrowCaps);
            vm.stopPrank();
        }
    }
}
