// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MToken} from "@protocol/MToken.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";


/****************************************************************************** 
 *                                starkxunTest                                * 
 *                 验证 Comptroller 对各种操作的暂停是否生效                  * 
 ******************************************************************************/

contract PauseCapMatrixUintTest is Test {
    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;     // q - 利率模型？

    MockERC20 internal mCollateralUnderlying;
    MockERC20 internal mBorrowUnderlying;

    MErc20Immutable internal mCollateral;
    MErc20Immutable internal mBorrow;

    address internal Alice;
    address internal Bob;
    address internal Liquiditor;
    address internal Supplier;
    address internal Guardian;  // 非 admin 的 Pause Guardain

    uint256 internal constant INIT_EXCHANGE_RATE = 2e16; // 0.02  q - 这个值的作用是： 初始兑换率
    uint256 internal constant CF_COLLATERAL = 0.8e18;    // 抵押率
    uint256 internal constant CLOSE_FACTOR = 0.5e18;     // 单次清算上限
    uint256 internal constant LIQ_INCENTIVE = 1.08e18;   // 清算激励


    function setUp() public {
        
        Alice = makeAddr("Aice");
        Bob = makeAddr("Bob");
        Liquiditor = makeAddr("Liquiditor");
        Supplier = makeAddr("Supplier");
        Guardian = makeAddr("Guardian");

        mCollateralUnderlying = new MockERC20();
        mBorrowUnderlying = new MockERC20();

        comptroller = new Comptroller();
        oracle = new SimplePriceOracle();
        // 基础年化率 2%， 斜率年化 20%（利用率从 0 到 100% 时，最多再增加 20% 年化）
        // 借款年化率约等于 2% + 利用率 * 20%
        irm = new WhitePaperInterestRateModel(0.02e18, 0.2e18);

        // 测试合约部署 Comptroller，所以测试合约是 admin。
        assertEq(comptroller._setPriceOracle(oracle), 0);
        assertEq(comptroller._setCloseFactor(CLOSE_FACTOR), 0);
        assertEq(comptroller._setLiquidationIncentive(LIQ_INCENTIVE), 0);

        mCollateral = new MErc20Immutable(
            address(mCollateralUnderlying),
            comptroller,
            irm,
            INIT_EXCHANGE_RATE,
            "Moonwell Collateral",
            "mCOL",
            8,
            payable(address(this))
        );
        mBorrow = new MErc20Immutable(
            address(mBorrowUnderlying),
            comptroller,
            irm,
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

        _seedBorrowMarketCash();

    }

    /****************************************************************************** 
     *                                   主测试 mint                              * 
     ******************************************************************************/

    // mint: Pause -> mint: Revert
    // mint 暂停后尝试 mint 必须失败
    function testMint_MintPaused_MintRevert() public {
        assertTrue(comptroller._setMintPaused(mCollateral, true), "set mint paused");

        mCollateralUnderlying.mint(Alice, 100e18);  // q - 这里的 mint 不会触发 revert 吗？（准备底层资产，不等同于市场 mint）
        vm.startPrank(Alice);
        mCollateralUnderlying.approve(address(mCollateral), 100e18);
        vm.expectRevert(bytes("mint is paused"));
        mCollateral.mint(100e18);     // q - 这里是 mint 给 mCollateral 吗？
        vm.stopPrank();
    }

    // mint 暂停不影响其他市场动作： redeem 和 borrow
    function testMintPaused_RedeemAndBorrowStillWork() public {
        // 正常存入
        _supplyCollateral(Alice, 1_000e18);
        _enterMarkets(Alice, address(mCollateral));


        // 暂停 mint
        assertTrue(comptroller._setMintPaused(mCollateral, true), "set mint paused");
        
        // 尝试部分赎回
        uint256 mTokenAmount = mCollateral.balanceOf(Alice);
        vm.prank(Alice);
        assertEq(mCollateral.redeem(mTokenAmount / 4), 0, "redeem should succeed");

        // 尝试借款
        vm.prank(Alice);
        assertEq(mBorrow.borrow(100e18), 0, "borrow should succeed");

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
    
    // 进入市场
    function _enterMarkets(address user, address market) internal {
        address[] memory markets = new address[](1);
        markets[0] = market;
        vm.prank(user);                         // q - 这里用 user 的地址干啥
        comptroller.enterMarkets(markets);
    }



}