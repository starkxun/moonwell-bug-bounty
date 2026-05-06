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
    uint256 internal constant CF_COLLATERAL = 0.8e18;

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
    // 切换 IRM 后, 余额不应该跳变
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

    // 切换 IRM 后,下一段时间的累积应使用新模型(更高利率 -> 更大增量)
    function testSetIRM_NewRateAppliesAfterSwitch() public {
        vm.warp(block.timestamp + 365 days);
        uint256 borrowAfterY1 = mBorrow.borrowBalanceCurrent(Alice);
        uint256 deltaY1 = borrowAfterY1 - ALICE_BORROW;     // 过去一年的增量

        // 切换利率模型
        // 借款年化 ≈ 10% + 0.5 * 50% = 35% 年化
        assertEq(mBorrow._setInterestRateModel(irmHigh), 0, "Set new Interest rate model failed");

        // 在走一年,按新的利率模型来计算
        vm.warp(block.timestamp + 365 days);
        uint256 borrowAfterY2 = mBorrow.borrowBalanceCurrent(Alice);
        uint256 deltaY2 = borrowAfterY2 - borrowAfterY1;

        // 新模型在相同 utilization（~50%）下年化 35% > 旧 12%，因此第二段增量必须显著大于第一段
        assertGt(deltaY2, deltaY1, "new IRM should produce large interest");

        // 粗略量级检查：新增量至少是旧增量的 2 倍
        assertGt(deltaY2, deltaY1 * 2, "delta ratio should reflect rate ratio (>2x)");
    }


    // 借款指数 borrowIndex 必须单调不减
    // 账户欠款 = 存储的本金 * 当前 borrowIndex / 账户的 interestIndex
    function testBorrowIndex_MonotonAcrossIRMSwap() public {
        uint256 idx0 = mBorrow.borrowIndex();

        // 模拟时间过去 30 天，累计新利率
        vm.warp(block.timestamp + 30 days);
        assertEq(mBorrow.accrueInterest(), 0);
        uint256 idx1 = mBorrow.borrowIndex();
        // q - borrowIndex 每次什么时候会变？计算公式是什么？
        // - 只有在调用 `accrueInterest()`（或其他触发结算的交互，如借/还/清算）时才会更新；单纯时间推进不会自动修改。
        // - 近似关系：`newIndex = oldIndex * (1 + borrowRatePerSecond * deltaT)`（如果利率按秒计）；按区块则用 borrowRatePerBlock。
        // - 在正常（非负利率）情况下 `borrowIndex` 应是单调不减（要么不变，要么增加）。
        assertGt(idx1, idx0);

        // 切换 IRM
        assertEq(mBorrow._setInterestRateModel(irmHigh), 0);
        // 同一个区块下切换，不发生改变
        // - `_setInterestRateModel` 仅替换利率模型地址，不会立刻结算利息或修改 `borrowIndex`，因此读取索引应保持不变。
        uint256 idx2 = mBorrow.borrowIndex();
        assertEq(idx2, idx1);

        vm.warp(block.timestamp + 30 days);
        assertEq(mBorrow.accrueInterest(), 0);
        // 经过时间并结算后，`borrowIndex` 应根据新 IRM 的借款利率继续增加（保持单调）。
        uint256 idx3 = mBorrow.borrowIndex();
        assertGt(idx3, idx2);
    }

    // 切换 IRM 时，记录的 accrualBlockTimestamp 应等于当前 block.timestamp
    // 否则下一次 accrue 会把"本次切换之前的时间段"重复计入新 IRM
    function testSetIRM_AccuralBlockTimestampAdvance() public {
        vm.warp(block.timestamp + 100 days);

        assertEq(mBorrow._setInterestRateModel(irmHigh), 0);

        assertEq(mBorrow.accrualBlockTimestamp(), block.timestamp, "timestamp should be equal");
    }

/****************************************************************************** 
 *                         ReserveFactor 切换的连续性                         * 
 ******************************************************************************/

    // 切换 reserveFactor 的那一刻，totalReserve 不应该跳变
    function testSetReserveFactor_NoJumpAtSwitchInstant() public {
        assertEq(mBorrow._setReserveFactor(0.10e18), 0);       // 先把 RF 设置非0，让储备金累计起来

        vm.warp(block.timestamp + 365 days);

        // 切换前，旧 RF 累计至此
        assertEq(mBorrow.accrueInterest(), 0);
        uint256 borrowBefore = mBorrow.totalBorrows();
        uint256 reservesBefore = mBorrow.totalReserves();

        assertEq(mBorrow._setReserveFactor(0.30e18), 0);     // 切换更大的 RF

        // 切换瞬间，余额不发生改变
        
        assertEq(mBorrow.totalBorrows(), borrowBefore);
        assertEq(mBorrow.totalReserves(), reservesBefore);
        assertEq(mBorrow.reserveFactorMantissa(), 0.3e18);
    }

    // 切换后下一段时间，储备金按新 RF 累积（更高 RF → 更大储备增量）
    function testSetReserveFactor_NewFactorAppliesAfterSwitch() public {
        // 起始 RF = 10%
        assertEq(mBorrow._setReserveFactor(0.10e18), 0);

        vm.warp(block.timestamp + 365 days);
        assertEq(mBorrow.accrueInterest(), 0);
        uint256 reservesY1 = mBorrow.totalReserves();

        // 切到 50%
        assertEq(mBorrow._setReserveFactor(0.50e18), 0);

        vm.warp(block.timestamp + 365 days);
        assertEq(mBorrow.accrueInterest(), 0);
        uint256 reservesY2 = mBorrow.totalReserves();

        uint256 delta1 = reservesY1;                 // 第一年增量（从 0 起）
        uint256 delta2 = reservesY2 - reservesY1;    // 第二年增量

        // 第二年的 RF 是 5x，单段储备增量应显著超过第一年
        assertGt(delta2, delta1, "higher RF should produce more reserves");
        assertGt(delta2, delta1 * 3, "rough magnitude: ~5x but allow rounding & utilization shift");
    }

    /****************************************************************************** 
     *                                权限 & 边界                                 * 
     ******************************************************************************/
    //  设置 reserveFactor 超过 1e18（100%）应当 revert
    function testSetReserveFactor_RejectsExceedsMax() public {
        uint256 ret = mBorrow._setReserveFactor(1e18 + 1);

        assertEq(ret, 2, "should return BAD_INPUT");
        assertEq(mBorrow.reserveFactorMantissa(), 0, "rserve factor should remain unchange");
    }


}