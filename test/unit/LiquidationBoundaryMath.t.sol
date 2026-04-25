// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";



/****************************************************************************** 
 *                                starkxuntest                                * 
 ******************************************************************************/

contract LiquidationBoundaryMathUintTest is Test {

    MockERC20 internal collateralUnderlying;
    MockERC20 internal borrowUnderlying;

    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;

    // q - 这连个值是干什么的？
    MErc20Immutable internal mCollateral;      // 用户把 collateralUnderlying 存进去当抵押
    MErc20Immutable internal mBorrow;          // 用户从这里借 borrowUnderlying

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

        _seedBorrowMarketCash();    // 借款市场注入资金

    }

    // 测试正常清算 和 超过清算值的异常情况
    function testCloseFactorBoundary_MaxCloseSucceeds_MaxClosePlusOneFails() public {
        _createShortfallPosition();
        
        // q - 获取应当偿还的本金和利息
        uint256 borrowBalance = mBorrow.borrowBalanceStored(borrower);
        // q - 这里计算的值是什么？
        // a - 乘以清算因子，计算目前最大清算额度
        uint256 maxClose = (borrowBalance * comptroller.closeFactorMantissa()) / 1e18;
        assertGt(maxClose, 0, "maxClose should be positive");

        _fundAndApprovalLiquidator(maxClose);   // mBorrow 市场注入资金
        vm.prank(liquidator);
        // 尝试清算
        // q - 此时 shortfall 已经产生 $200， 允许清算？
        uint256 okErr = mBorrow.liquidateBorrow(borrower, maxClose, mCollateral);
        assertEq(okErr, 0, "Liquidation at maxClose should be successed");

        // q - 重新创立测试环境？
        setUp();
        _createShortfallPosition();
        
        uint256 borrowBalance2 = mBorrow.borrowBalanceStored(borrower);
        uint256 maxClose2 = (borrowBalance2 * comptroller.closeFactorMantissa()) / 1e18;
        
        _fundAndApprovalLiquidator(maxClose2 + 1);
        vm.prank(liquidator);
        uint256 tooMuchErr = mBorrow.liquidateBorrow(borrower, maxClose2 + 1, mCollateral);
        assertTrue(tooMuchErr != 0, "maxClose2 + 1 should be reject");

    }

    // 验证清算计算出来的 seizeToken 是向下取整，且取整边界是 紧 的 
    // seizeToken: 清算后，借款人被没收并转给清算人抵押品 mToken 的数量
    
    // liquidateCalculateSeizeTokens 函数已给出计算公式：
    // seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
    // seizeTokens = seizeAmount / exchangeRate
    // 假设：
    // borrowed token = USDC
    // collateral token = ETH
    // actualRepayAmount = 1000 USDC
    // liquidationIncentive = 1.08
    // USDC price = 1 USD
    // ETH price = 2000 USD
    // mETH exchangeRate = 0.02 ETH / mETH
    // 也就是说，清算者偿还了 1000 USDC，但是可以拿到价值 1080 美元的 ETH 抵押品。
    // 第二步，把底层 ETH 数量换算成 mETH：
    // // seizeTokens = 0.54 / 0.02 = 27 mETH
    // 以清算者最终从 borrower 那里拿走的是：27 mETH
    // 不是直接拿 0.54 ETH。之后清算者可以选择继续持有 mETH，也可以 redeem 成底层 ETH

    function testSeizeFormula_RoundsDownWithTightBounds() public {
        _createShortfallPosition();

        uint256 repayAmount = 111e18;
        (uint256 errCode, uint256 seizeToken) = comptroller.liquidateCalculateSeizeTokens(
            address(mBorrow), address(mCollateral), repayAmount);
        assertEq(errCode, 0, "seize calculation should succeed");
        assertGt(seizeToken, 0, "seizeToken should be positive");

        // 拿到清算激励值？
        uint256 liqIncentive = comptroller.liquidationIncentiveMantissa();
        uint256 priceBorrow = oracle.getUnderlyingPrice(mBorrow);
        uint256 priceCollateral = oracle.getUnderlyingPrice(mCollateral);
        uint256 exchangeRate = mCollateral.exchangeRateStored();

        // 分子
        uint256 numerator = (liqIncentive * priceBorrow) / 1e18;
        uint256 denominator = (priceCollateral * exchangeRate) / 1e18;

        // 这两个值根据 liquidateCalculateSeizeTokens 的公式来理解
        uint256 lhs = seizeToken * denominator; // 用返回整数反推回去的值
        uint256 rhs = repayAmount * numerator;  // 真实分子

        // q - 这里的断言是啥意思？
        // a - lhs 应当小于 rhs, 表示向下取整, seizeToken 不会超发抵押品
        assertLe(lhs, rhs, "floor bound lower side violated");
        // + 1 则会超过真实值
        assertGt((seizeToken + 1) * denominator, rhs, "floor bound upper side violated");
 
    }

    // 测试清算后，借款人损失的抵押品 mToken，必须等于清算人拿到的部分 + 协议抽成的部分
    function testSeizeConservation_BorrowerLossEqualsLiquidatorGainPlusProtocolCut() public {
        _createShortfallPosition();

        uint256 repayAmount = 111e18;
        // q - 这里不使用调用者，是默认清算市场里的所有账户吗
        // a - 不用指定被清算者，仅需使用 repayAmount， 根据市场参数做换算，计算出需要没收抵押品 mToken 数量
        (uint256 errCode, uint256 expectSeizeToken) =  comptroller.liquidateCalculateSeizeTokens(
           address(mBorrow) , address(mCollateral), repayAmount);
        assertEq(errCode, 0, "liquidator should be succeed");
        assertGt(expectSeizeToken, 0, "expectSeizeToken should be positive");

        uint256 borrowerBefore = mCollateral.balanceOf(borrower);
        uint256 liquidatorBefore = mCollateral.balanceOf(liquidator);
        uint256 totalSupplyBefore = mCollateral.totalSupply(); 

        // 给清算者打钱
        _fundAndApprovalLiquidator(repayAmount);
        vm.prank(liquidator);
        uint256 err = mBorrow.liquidateBorrow(borrower, repayAmount, mCollateral);
        assertEq(err, 0, "liquidate should be success");

        uint256 borrowerAfter = mCollateral.balanceOf(borrower);
        uint256 liquidatorAfter = mCollateral.balanceOf(liquidator);
        uint256 totalSupplyAfter = mCollateral.totalSupply();

        uint256 borrowerLost = borrowerBefore - borrowerAfter;
        uint256 liquidatorGained = liquidatorAfter - liquidatorBefore;
        uint256 protocolSeizeToken = borrowerLost - liquidatorGained;   // q - 协议赚取的差价？

        assertEq(borrowerLost, expectSeizeToken, "borrower lost must match expect");
        assertEq(
            liquidatorGained + protocolSeizeToken,
            expectSeizeToken,
            "seize split must conserve mTokens units"
        );
        // q - 这句断言里的翻译怎么理解？
        // a - 总量变化完全由协议份额解释
        assertEq(
            totalSupplyAfter - totalSupplyBefore,
            protocolSeizeToken,
            "only protocol seize tokens should burn from totalSupply"
        );


    }

    // q - 这个函数 是干什么的？
    //  mBorrow 市场先“注入现金池”
    function _seedBorrowMarketCash() internal {
        uint256 seed = 10_000e18;
        borrowUnderlying.mint(supplier, seed);

        vm.startPrank(supplier);
        borrowUnderlying.approve(address(mBorrow), seed);
        assertEq(mBorrow.mint(seed), 0, "supplier mint to borrow market failed");
        vm.stopPrank();
    }

    // q - 这个函数的功能？
    // 构建一个“先健康， 后资不抵债” 的借款账户
    // 方便后续边界测试
    function _createShortfallPosition() internal {
        uint256 collateralDeposit = 1_000e18;   // 初始抵押 $1000
        uint256 borrowAmount = 600e18;          // collateral factor 为 0.8， 借款上限为 800$, 实际借款 600$

        collateralUnderlying.mint(borrower, collateralDeposit); // q - 给借款者mint
        
        vm.startPrank(borrower);
        collateralUnderlying.approve(address(mCollateral), collateralDeposit);
        assertEq(mCollateral.mint(collateralDeposit), 0, "borrwer mint collateral failed");

        address[] memory markets = new address[](1);
        markets[0] = address(mCollateral);
        comptroller.enterMarkets(markets);

        assertEq(mBorrow.borrow(borrowAmount), 0, "Borrow failed");     // 借款
        vm.stopPrank();

        // 之前价格是 1e18
        // 现在降低抵押品价格，是借款者负债超过贷款额度
        oracle.setUnderlyingPrice(mCollateral, 5e17);       // 跌价后抵押 $500 -> 新的借款上限: 400
        // q - borrower 是借款者，可以被用作 getAccountLiquidity 的参数吗？
        // a - 可以，getAccountLiquidity 查询任意账户的流动性
        // 此时借款仍是 600$, shortfall 应为 200$, 可以被清算
        (uint256 err, uint256 liquidity, uint256 shortfall) = comptroller.getAccountLiquidity(borrower);

        assertEq(err, 0, "account liquidity querry faild");
        assertEq(liquidity, 0, "liquidity should be zero after price drop");
        assertGt(shortfall, 0, "borrower should be liquidatable");  // q - shortfall 为 0 表示 具有清算能力？
    }

    // q - 这个函数的作用是什么？
    // 给结款市场注入资金，后续参与清算
    // 若 mBorrow 市场没有足够资金，则会导致失败
    function _fundAndApprovalLiquidator(uint256 repayAmount) internal {
        borrowUnderlying.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        borrowUnderlying.approve(address(mBorrow), repayAmount);
    }


}


