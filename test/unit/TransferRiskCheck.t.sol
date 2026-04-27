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
 *                                starkxun test                               * 
 ******************************************************************************/

contract TransferRiskCheckUnitTest is Test {

    MockERC20 internal mCollateralUnderlying;
    MockERC20 internal mBorrowUnderlying;

    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;

    MErc20Immutable internal mCollateral;
    MErc20Immutable internal mBorrow;

    address internal Alice;
    address internal Bob;
    address internal Supplier;
    
    uint256 internal constant INTERNAL_CHANGE_RATE = 2e16; //  0.02 
    
    function setUp() public {
        Alice = makeAddr("Alice");
        Bob = makeAddr("Bob");
        Supplier = makeAddr("Supplier");

        mCollateralUnderlying = new MockERC20();
        mBorrowUnderlying = new MockERC20();

        comptroller = new Comptroller();
        oracle = new SimplePriceOracle();
        // 基础年化率 2%， 斜率年化 20%（利用率从 0 到 100% 时，最多再增加 20% 年化）
        // 借款年化率约等于 2% + 利用率 * 20%
        irm = new WhitePaperInterestRateModel(0.02e18, 0.2e18);

        // 设置语言机
        assertEq(comptroller._setPriceOracle(oracle), 0, "Set oracle should succeed");
        // 设置清算上限
        assertEq(comptroller._setCloseFactor(0.5e18), 0, "set closeFactor should succeed");
        // 设置清算激励
        assertEq(comptroller._setLiquidationIncentive(1.08e18), 0, "set liqIncentive should succeed");

        mBorrow = new MErc20Immutable(
            address(mBorrowUnderlying),
            comptroller,
            irm,
            uint(INTERNAL_CHANGE_RATE),
            "Moonwell Borrow",
            "mBRW",
            8,
            payable(address(this))
        );

        mCollateral = new MErc20Immutable(
            address(mCollateralUnderlying),
            comptroller,
            irm,
            uint(INTERNAL_CHANGE_RATE),
            "Moonwell Collateral",
            "mCOL",
            8,
            payable(address(this))
        );
        
        assertEq(comptroller._supportMarket(mCollateral), 0);
        assertEq(comptroller._supportMarket(mBorrow), 0);

        oracle.setUnderlyingPrice(mCollateral, 1e18);
        oracle.setUnderlyingPrice(mBorrow, 1e18);

        // 抵押品市场 CF = 80%，借款市场 CF = 0（不能拿借出的资产再当抵押）
        // q - 这句注释是什么意思？
        assertEq(comptroller._setCollateralFactor(mCollateral, 0.8e18), 0);
        assertEq(comptroller._setCollateralFactor(mBorrow, 0), 0);

        _seedBorrowMarketCash();

    }



    
    // 用户没有借款时候，转出全部 mToken 应当成功
    function testTransfer_NoBorrow_FullTransferSucceed() public {
        uint256 deposit = 1_000e18;
        // Alice 仅共给 抵押品， 没有借款，没有 enter market
        _supplyCollateral(Alice, deposit);
        
        uint256 AliceBefore = mCollateral.balanceOf(Alice);
        uint256 BobBefore = mCollateral.balanceOf(Bob);
        assertGt(AliceBefore, 0, "Alice should hold MToken");
        
        vm.prank(Alice);
        bool ok = mCollateral.transfer(Bob, AliceBefore);
        assertTrue(ok, "Healthy transfer should succeed");

        assertEq(mCollateral.balanceOf(Alice), 0, "Alice should drain to 0");
        assertEq(mCollateral.balanceOf(Bob), AliceBefore + BobBefore, "Bob receives all");

    }

    
    // 给借款市场注入资金，让 借款交易 有底层资产可拿
    function _seedBorrowMarketCash() internal {
        uint256 seed = 10_000e18;
        mBorrowUnderlying.mint(Supplier, seed);

        vm.startPrank(Supplier);
        mBorrowUnderlying.approve(address(mBorrow), seed);
        // q - 这里是 Supplier 调用 mint， 给 Borrow market 铸造代币吗？
        assertEq(mBorrow.mint(seed), 0, "supplier mint to borrow market failed");
        vm.stopPrank();
    }

    // 账户在抵押市场存入 指定 underlying，但不进入市场
    function _supplyCollateral(address user, uint256 amount) internal {
        mCollateralUnderlying.mint(user, amount);
        vm.startPrank(user);
        mCollateralUnderlying.approve(address(mCollateral), amount);
        assertEq(mCollateral.mint(amount), 0, "supply mint failed");
        vm.stopPrank();
    }





}