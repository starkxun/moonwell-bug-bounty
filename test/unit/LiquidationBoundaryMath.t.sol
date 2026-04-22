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

        // q - 设置价格语言机？ 返回 0 表示成功？
        assertEq(comptroller._setPriceOracle(oracle), 0);
        // 设置清算上限 50% （这里的清算逻辑还没完全理解）
        assertEq(comptroller._setCloseFactor(0.5e18), 0);
        // 设置清算激励为 1.08， 偿还 100$ 的债务， 清算人能到 $108 的抵押品
        assertEq(comptroller._setLiquidationIncentive(1.08e18), 0);

        // 部署 MErc20Immutable 后，如果用 admin 调 supportMarket，列表检查通常能过
        // 但要借款/抵押真正可用，还需要配置 oracle 价格和 collateral factor 等参数。
        mCollateral = new MErc20Immutable(
            address(collateralUnderlying),
            comptroller,
            irm,
            uint(INTERNAL_EXCHANGE_RATE),
            "Moonwell Collateral",
			"mCOL",
            8,
            payable(address(this))
        );
        
        mBorrow = new MErc20Immutable(
            address(borrowUnderlying),
            comptroller,
            irm,
            uint(INTERNAL_EXCHANGE_RATE),
            "Moonwell Borrow",
			"mBRW",
            8,
            payable(address(this))
        );
        
        assertEq(comptroller._supportMarket(mCollateral), 0);
        assertEq(comptroller._supportMarket(mBorrow), 0);
        
        oracle.setUnderlyingPrice(mCollateral, 1e18);
        oracle.setUnderlyingPrice(mBorrow, 1e18);

        // q - 这里断言的意义是什么？
        assertEq(comptroller._setCollateralFactor(mCollateral, 0.8e18), 0);
        assertEq(comptroller._setCollateralFactor(mBorrow, 0), 0);

        _seedBorrowMarketCash();        // info - 尚未定义

    }

    // q - 这个函数 是干什么的？
    function _seedBorrowMarketCash() internal {
        uint256 seed = 10_000e18;
        borrowUnderlying.mint(supplier, seed);

        vm.startPrank(supplier);
        borrowUnderlying.approve(address(mBorrow), seed);
        assertEq(mBorrow.mint(seed), 0, "supplier mint to borrow market failed");
        vm.stopPrank();
    }


}



/****************************************************************************** 
 *                                starkxuntest                                * 
 ******************************************************************************/