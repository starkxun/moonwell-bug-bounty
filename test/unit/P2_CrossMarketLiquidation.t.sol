// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";

/****************************************************************************
 *                              starkxun test                                *
 *  step_1.md P2 #11 - 清算资产与借款资产为同一市场/不同市场的分支差异         *
 *                                                                          *
 *  关键源码：MToken.sol:1595-1610，liquidateBorrowFresh 中根据                 *
 *      address(mTokenCollateral) == address(this)                          *
 *  分别走 seizeInternal（内部）或 mTokenCollateral.seize（外部）两条路径。       *
 *                                                                          *
 *  本测试验证三条不变量：                                                    *
 *   A. liquidateCalculateSeizeTokens 在两条分支输入下结果完全一致              *
 *   B. 份额守恒：borrowerLost == liquidatorGained + protocolCut             *
 *      （totalSupply 减少量 == protocolCut，因为 protocolShare 是 burn 掉的）  *
 *   C. closeFactor 上限两条分支都严格执行                                    *
 ****************************************************************************/

contract P2_CrossMarketLiquidation is Test {
    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;

    MockERC20 internal underlyingA;
    MockERC20 internal underlyingB;
    MErc20Immutable internal mCollateral;
    MErc20Immutable internal mBorrow;

    address internal borrower;
    address internal liquidator;
    address internal supplier;

    uint256 internal constant INIT_EXCHANGE_RATE = 2e16;
    uint256 internal constant CLOSE_FACTOR = 0.5e18;
    uint256 internal constant LIQ_INCENTIVE = 1.08e18;
    uint256 internal constant CF = 0.8e18;

    function setUp() public {
        borrower = makeAddr("borrower");
        liquidator = makeAddr("liquidator");
        supplier = makeAddr("supplier");

        underlyingA = new MockERC20();
        underlyingB = new MockERC20();

        comptroller = new Comptroller();
        oracle = new SimplePriceOracle();
        irm = new WhitePaperInterestRateModel(0.02e18, 0.20e18);

        assertEq(comptroller._setPriceOracle(oracle), 0);
        assertEq(comptroller._setCloseFactor(CLOSE_FACTOR), 0);
        assertEq(comptroller._setLiquidationIncentive(LIQ_INCENTIVE), 0);

        mCollateral = new MErc20Immutable(
            address(underlyingA), comptroller, irm, INIT_EXCHANGE_RATE,
            "mCollateral", "mCOLL", 8, payable(address(this))
        );
        mBorrow = new MErc20Immutable(
            address(underlyingB), comptroller, irm, INIT_EXCHANGE_RATE,
            "mBorrow", "mBRW", 8, payable(address(this))
        );

        assertEq(comptroller._supportMarket(mCollateral), 0);
        assertEq(comptroller._supportMarket(mBorrow), 0);
        oracle.setUnderlyingPrice(mCollateral, 1e18);
        oracle.setUnderlyingPrice(mBorrow, 1e18);
        // 两边都允许做抵押，这样同/跨市场场景都能复用同一份 setUp
        assertEq(comptroller._setCollateralFactor(mCollateral, CF), 0);
        assertEq(comptroller._setCollateralFactor(mBorrow, CF), 0);

        // 两边都先注入流动性，避免 borrow 时市场没有 cash
        _seedMarketCash(mCollateral, underlyingA, 10_000e18);
        _seedMarketCash(mBorrow, underlyingB, 10_000e18);
    }

    // ---------------- 不变量 A：清算数学不感知分支 ----------------

    /// liquidateCalculateSeizeTokens 完全是一个纯函数：
    ///   seizeAmount = repayAmount * liqIncentive * priceBorrow / priceCollateral
    ///   seizeTokens = seizeAmount / exchangeRate
    /// 它不知道两个 mToken 是不是同一个；当价格、利率、汇率都相等时，
    /// 同/跨市场两次调用的结果应该完全一致。
    function testSeizeFormulaParity_SameMarketEqualsCrossMarket() public {
        uint256 repayAmount = 100e18;

        // 跨市场场景调用：借 mBorrow，扣押 mCollateral 抵押
        (uint256 errCross, uint256 seizeCross) = comptroller
            .liquidateCalculateSeizeTokens(address(mBorrow), address(mCollateral), repayAmount);

        // 同市场场景调用：借 mCollateral，扣押 mCollateral 抵押（borrowed == collateral）
        (uint256 errSame, uint256 seizeSame) = comptroller
            .liquidateCalculateSeizeTokens(address(mCollateral), address(mCollateral), repayAmount);

        assertEq(errCross, 0, "cross-market seize calc should succeed");
        assertEq(errSame, 0, "same-market seize calc should succeed");
        assertEq(
            seizeCross,
            seizeSame,
            "branch should not change seize math when prices match"
        );
        assertGt(seizeSame, 0, "seizeTokens should be positive");
    }

    // ---------------- 不变量 B：份额守恒（两条分支） ----------------

    /// 同市场清算路径（mTokenCollateral == this，走 seizeInternal）：
    /// borrower 在 mCollateral 同时供给+借款，被清算后份额守恒。
    function testSameMarketLiquidation_ConservesShares() public {
        _createSameMarketShortfall();

        uint256 repayAmount = mCollateral.borrowBalanceStored(borrower) / 4; // 远小于 closeFactor 上限

        uint256 borrowerBefore = mCollateral.balanceOf(borrower);
        uint256 liquidatorBefore = mCollateral.balanceOf(liquidator);
        uint256 totalSupplyBefore = mCollateral.totalSupply();

        _fundAndApprove(liquidator, underlyingA, mCollateral, repayAmount);
        vm.prank(liquidator);
        // 这一行走的是 seizeInternal 分支
        assertEq(mCollateral.liquidateBorrow(borrower, repayAmount, mCollateral), 0);

        uint256 borrowerLost = borrowerBefore - mCollateral.balanceOf(borrower);
        uint256 liquidatorGained = mCollateral.balanceOf(liquidator) - liquidatorBefore;
        // protocolSeizeShare 那部分是直接从 totalSupply burn 掉的
        uint256 protocolCut = totalSupplyBefore - mCollateral.totalSupply();

        assertGt(borrowerLost, 0, "borrower must lose collateral");
        assertEq(
            borrowerLost,
            liquidatorGained + protocolCut,
            "same-market: borrowerLost == liquidatorGained + protocolCut"
        );
    }

    /// 跨市场清算路径（mTokenCollateral != this，走 mTokenCollateral.seize 外部调用）：
    /// borrower 在 mCollateral 抵押、mBorrow 借款，被清算后份额同样守恒。
    function testCrossMarketLiquidation_ConservesShares() public {
        _createCrossMarketShortfall();

        uint256 repayAmount = mBorrow.borrowBalanceStored(borrower) / 4;

        uint256 borrowerBefore = mCollateral.balanceOf(borrower);
        uint256 liquidatorBefore = mCollateral.balanceOf(liquidator);
        uint256 totalSupplyBefore = mCollateral.totalSupply();

        _fundAndApprove(liquidator, underlyingB, mBorrow, repayAmount);
        vm.prank(liquidator);
        // 这一行走的是 mTokenCollateral.seize（外部）分支
        assertEq(mBorrow.liquidateBorrow(borrower, repayAmount, mCollateral), 0);

        uint256 borrowerLost = borrowerBefore - mCollateral.balanceOf(borrower);
        uint256 liquidatorGained = mCollateral.balanceOf(liquidator) - liquidatorBefore;
        uint256 protocolCut = totalSupplyBefore - mCollateral.totalSupply();

        assertGt(borrowerLost, 0, "borrower must lose collateral");
        assertEq(
            borrowerLost,
            liquidatorGained + protocolCut,
            "cross-market: borrowerLost == liquidatorGained + protocolCut"
        );
    }

    // ---------------- 不变量 C：closeFactor 在两条分支都生效 ----------------

    /// 跨市场分支：repayAmount > closeFactor × debt 必须被拒绝。
    function testCrossMarket_RejectAboveCloseFactor() public {
        _createCrossMarketShortfall();
        uint256 debt = mBorrow.borrowBalanceStored(borrower);
        uint256 maxClose = (debt * comptroller.closeFactorMantissa()) / 1e18;

        _fundAndApprove(liquidator, underlyingB, mBorrow, maxClose + 1);
        vm.prank(liquidator);
        uint256 err = mBorrow.liquidateBorrow(borrower, maxClose + 1, mCollateral);
        assertGt(err, 0, "cross-market must reject repay > closeFactor*debt");
    }

    /// 同市场分支：repayAmount > closeFactor × debt 必须被拒绝。
    function testSameMarket_RejectAboveCloseFactor() public {
        _createSameMarketShortfall();
        uint256 debt = mCollateral.borrowBalanceStored(borrower);
        uint256 maxClose = (debt * comptroller.closeFactorMantissa()) / 1e18;

        _fundAndApprove(liquidator, underlyingA, mCollateral, maxClose + 1);
        vm.prank(liquidator);
        uint256 err = mCollateral.liquidateBorrow(borrower, maxClose + 1, mCollateral);
        assertGt(err, 0, "same-market must reject repay > closeFactor*debt");
    }

    // ====================== helpers ======================

    function _seedMarketCash(
        MErc20Immutable mTok,
        MockERC20 underlying_,
        uint256 amt
    ) internal {
        underlying_.mint(supplier, amt);
        vm.startPrank(supplier);
        underlying_.approve(address(mTok), amt);
        assertEq(mTok.mint(amt), 0, "supplier mint failed");
        vm.stopPrank();
    }

    function _fundAndApprove(
        address user,
        MockERC20 underlying_,
        MErc20Immutable mTok,
        uint256 amt
    ) internal {
        underlying_.mint(user, amt);
        vm.prank(user);
        underlying_.approve(address(mTok), amt);
    }

    /// 同市场 shortfall：borrower 在 mCollateral 同时供给+借款。
    /// 注意：单纯降价对 self-collateral 无效（价格在分子分母都出现，自动抵消），
    ///       所以这里用"下调 collateral factor"来制造 shortfall。
    function _createSameMarketShortfall() internal {
        uint256 deposit = 1_000e18;
        uint256 borrow = 600e18;

        underlyingA.mint(borrower, deposit);
        vm.startPrank(borrower);
        underlyingA.approve(address(mCollateral), deposit);
        assertEq(mCollateral.mint(deposit), 0);

        address[] memory mks = new address[](1);
        mks[0] = address(mCollateral);
        comptroller.enterMarkets(mks);

        assertEq(mCollateral.borrow(borrow), 0, "borrow should succeed pre-CF-drop");
        vm.stopPrank();

        // 借款上限原本 = 1000 * 0.8 = 800，现在 CF 调到 0.4 → 上限 400 < 600 → shortfall
        assertEq(comptroller._setCollateralFactor(mCollateral, 0.4e18), 0);

        (uint256 err, , uint256 shortfall) = comptroller.getAccountLiquidity(
            borrower
        );
        assertEq(err, 0, "liquidity query should succeed");
        assertGt(shortfall, 0, "same-market borrower must be liquidatable");
    }

    /// 跨市场 shortfall：borrower 在 mCollateral 抵押、mBorrow 借款，靠"降低 mCollateral 抵押品价格"触发。
    function _createCrossMarketShortfall() internal {
        uint256 deposit = 1_000e18;
        uint256 borrow = 600e18;

        underlyingA.mint(borrower, deposit);
        vm.startPrank(borrower);
        underlyingA.approve(address(mCollateral), deposit);
        assertEq(mCollateral.mint(deposit), 0);

        address[] memory mks = new address[](1);
        mks[0] = address(mCollateral);
        comptroller.enterMarkets(mks);

        assertEq(mBorrow.borrow(borrow), 0, "cross-market borrow should succeed");
        vm.stopPrank();

        // mCollateral 抵押品价格 1.0 → 0.5，借款上限 = 1000 * 0.5 * 0.8 = 400 < 600 → shortfall
        oracle.setUnderlyingPrice(mCollateral, 0.5e18);

        (uint256 err, , uint256 shortfall) = comptroller.getAccountLiquidity(
            borrower
        );
        assertEq(err, 0, "liquidity query should succeed");
        assertGt(shortfall, 0, "cross-market borrower must be liquidatable");
    }
}
