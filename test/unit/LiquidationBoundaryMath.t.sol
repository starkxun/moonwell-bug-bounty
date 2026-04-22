// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";

contract LiquidationBoundaryMathUintTest is Test {

    MockERC20 internal collateralUnderlying;
    MockERC20 internal borrowUnderlying;

    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;

    // q - 这连个值是干什么的？
    MErc20Immutable internal mCollateral;
    MErc20Immutable internal mBorrow;

    address internal borrower;
    address internal liquidator;
    address internal supplier;

    uint256 internal constant INTERNAL_EXCHANGE_RATE = 2e16;

    function setUp() public {
        borrower = makeAddr("borrower");
        liquidator = makeAddr("liquidator");
        supplier = makeAddr("supplier");

        collateralUnderlying = new MockERC20();
        borrowUnderlying = new MockERC20();

        comptroller = new Comptroller();
        oracle = new SimplePriceOracle();
        // 基础年化率 2%， 斜率年化 20%（利用率从 0 到 100% 时，最多再增加 20% 年化）
        // 借款年化率约等于 2% + 利用率 * 20%
        irm = new WhitePaperInterestRateModel(0.02e18, 0.2e18);

        

    }


}



/****************************************************************************** 
 *                                starkxuntest                                * 
 ******************************************************************************/