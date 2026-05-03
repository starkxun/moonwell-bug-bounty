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
    uint256 internal constant SECOND_PER_YEAR = 31_536_000;     // q - 这个参数是干什么的?

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






}