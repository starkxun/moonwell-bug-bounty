// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";

/****************************************************************************** 
 *                               Starkxun Test                                * 
 *                利率模型 / reserveFactor 参数突变后的连续性                 * 
 ******************************************************************************/



contract InterestRateModelContinuityUnitTest is Test {
    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;

    // q - 这两个参数是什么意思?
    // a - 低利率配置 和 高利率配置
    // 用于测试切换市场利率模型 观察行为差异
    InterestRateModel internal irmLow;
    InterestRateModel internal irmHigh;

    MockERC20 internal mCollateralUnderlying;
    MockERC20 internal mBorrowUnderlying;

    MErc20Immutable internal mCollateral;
    MErc20Immutable internal mBorrow;

    address internal Alice;
    address internal Supplier;
    address internal NotAdmin;
    
    uint256 internal constant  INIT_EXCHANGE_RATE = 2e16;
    uint256 internal constant CF_COLLATERAL = 0.8e16;
    // q - 这个参数是干什么的?
    // a - 一年对应的秒数
    uint256 internal constant SECOND_PER_YEAR = 31_536_000;

    // 初始借贷规模
    uint256 internal constant SUPPLIER_SEED = 1_000e18;
    uint256 internal constant ALICE_COLLATERAL = 1_000e18;
    uint256 internal constant ALICE_BORROW = 500e18;

    function setUp() public {

        Alice    = makeAddr("Alice");
        Supplier = makeAddr("Supplier");
        NotAdmin = makeAddr("NotAdmin");

        mCollateralUnderlying = new MockERC20();
        mBorrowUnderlying     = new MockERC20();

        comptroller = new Comptroller();
        oracle      = new SimplePriceOracle();

        // q - 这两句是什么意思?
        // a - 构造两个 WhitePaper 模型
        irmLow = new WhitePaperInterestRateModel(0.02e18, 0.20e18);  
        irmHigh = new WhitePaperInterestRateModel(0.10e18, 0.50e18);

        assertEq(comptroller._setPriceOracle(oracle), 0);    // q - 这里不应该设置为: _setPriceOracle(oracle) 吗?
        assertEq(comptroller._setCloseFactor(0.5e18), 0);
        assertEq(comptroller._setLiquidationIncentive(1.08e18), 0);

        mCollateral = new MErc20Immutable(
            address(mCollateralUnderlying),
            comptroller,
            irmLow,
            INIT_EXCHANGE_RATE,
            "Moonwell Collateral",
            "mCOL",
            8,
            payable(address(this))
        );
        mBorrow = new MErc20Immutable(
            address(mBorrowUnderlying),
            comptroller,
            irmLow,
            INIT_EXCHANGE_RATE,
            "Moonwell Borrow",
            "mBRW",
            8,
            payable(address(this))
        );

        assertEq(comptroller._supportMarket(mCollateral), 0);
        assertEq(comptroller._supportMarket(mBorrow), 0);

        oracle.setUnderlyingPrice(mCollateral, 1e18);
        oracle.setUnderlyingPrice(mBorrow, 1e18);

        assertEq(comptroller._setCollateralFactor(mCollateral, CF_COLLATERAL), 0);
        assertEq(comptroller._setCollateralFactor(mBorrow, 0), 0);

        // 借款市场注入流动性
        mBorrowUnderlying.mint(Supplier, SUPPLIER_SEED);
        vm.startPrank(Supplier);
        mBorrowUnderlying.approve(address(mBorrow), SUPPLIER_SEED);
        assertEq(mBorrow.mint(SUPPLIER_SEED), 0);
        vm.stopPrank();

        
        // Alice 抵押 + 借款
        mCollateralUnderlying.mint(Alice, ALICE_COLLATERAL);
        vm.startPrank(Alice);
        mCollateralUnderlying.approve(address(mCollateral), ALICE_COLLATERAL);
        assertEq(mCollateral.mint(ALICE_COLLATERAL), 0);
        address[] memory markets = new address[](1);
        markets[0] = address(mCollateral);
        comptroller.enterMarkets(markets);
        assertEq(mBorrow.borrow(ALICE_BORROW), 0);
        vm.stopPrank();
    }

/****************************************************************************** 
 *                              IRM 切换的连续性                              * 
 ******************************************************************************/

    function testSetIRM_NojumpAtSwitchInstant() public {
        vm.warp(block.timestamp + 365 days);        // q - 这里推进时间干什么?
        // a - 模拟时间流逝,让利息在这段时间内产生／累积
        // 从而在切换模型前后能观测到借款余额、储备、borrowIndex 等是否有跳变或不连续的情况

        // 过结算后的实时欠款
        uint256 borrowBefore = mBorrow.borrowBalanceCurrent(Alice);
        // q - 这两个值是什么?
        // a - totalReserves()：协议当前累积的准备金（来自借款利息中分配到协议的那部分），表示协议可提取/记录的储备数量
        // 全局的借款指数（累积因子），用于按时间把每个账户的本金放大以计算利息；随着利息结算，borrowIndex 会增加,
        // 个人借款账户用 interestIndex 字段结合 borrowIndex 来计算应付利息
        uint256 reservesBefore = mBorrow.totalReserves();
        uint256 indexBefore = mBorrow.borrowIndex();

        // 治理切换
        assertEq(mBorrow._setInterestRateModel(irmHigh), 0, "Set irm should secceed");

        uint256 borrowAfter = mBorrow.borrowBalanceCurrent(Alice);
        uint256 reservesAfter = mBorrow.totalReserves();
        uint256 indexAfter = mBorrow.borrowIndex();

        // 借款利率本身已经反应新模型
        assertEq(address(mBorrow.interestRateModel()), address(irmHigh), "new model installed");
    }


}