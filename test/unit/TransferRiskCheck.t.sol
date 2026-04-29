// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";

/****************************************************************************** 
 *                                starkxunTest                                * 
 *                                转账相关测试                                * 
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

    /****************************************************************************** 
     *                                核心场景测试                                * 
     ******************************************************************************/

    // 有借款时转出所有抵押品，必须失败
    function testTransfer_AfterBorrow_FullTransferFails_StateUnchanged() public {
        _createBorrowingPosition(1000e18, 600e18);
        
        uint256 AliceBefore = mCollateral.balanceOf(Alice);
        uint256 BobBefore = mCollateral.balanceOf(Bob);
        uint256 BorrowBefore = mBorrow.borrowBalanceStored(Alice);  // 当前的债务

        // 尝试转账，应当失败
        vm.prank(Alice);
        bool ok = mCollateral.transfer(Bob, AliceBefore);
        assertFalse(ok, "Transfer shoud be failed");

        // 断言状态未发生改变
        assertEq(mCollateral.balanceOf(Alice), AliceBefore, "Alice's balance shoudn't be change");
        assertEq(mCollateral.balanceOf(Bob), BobBefore, "Bob's balance shoudn't be change");
        assertEq(mBorrow.borrowBalanceStored(Alice), BorrowBefore, "Alice's borrowBalance shoudn't be change");

        // 断言账户流动性未发生改变
        (uint256 err, uint256 liq, uint256 shortfall) = comptroller.getAccountLiquidity(Alice);
        assertEq(err, 0, "liquidity query ok");
        assertGt(liq, 0, "liquidity should be positive");
        assertEq(shortfall, 0 ,"shortfall should be 0 after transfer be reject");
    }

    // 借款后转出部分 mToken，只要不超过上限，就允许通过
    function testTransfer_AfterBorrow_PartialWithSafeyMagin_Succeed() public {
        // moonwell 协议的抵押率为 0.8
        _createBorrowingPosition(1000e18, 400e18);  // 抵押 1000， 借款 400 （liquidity = 400）
        

        // q - 为什么这里要用二分法找到最大可赎回数量
        // a - getHypotheticalAccountLiquidity 只能获取 shortfall 的值
        uint256 maxSafeMTokens = _maxRedeemableSafe(Alice);
        assertGt(maxSafeMTokens, 0, "should have no-zero safetransable amount");

        uint256 Amount = maxSafeMTokens / 2;   // 取一半，防止超出边界

        uint256 AliceBefore = mCollateral.balanceOf(Alice);
        uint256 BobBefore = mCollateral.balanceOf(Bob);
        uint256 BorrowBefore = mBorrow.borrowBalanceStored(Alice);

        vm.prank(Alice);
        bool ok = mCollateral.transfer(Bob, Amount);   // 稍后替换成 AliceBefore
        assertTrue(ok, "Transfer should be succeed");

        // 断言状态发生改变
        assertEq(mCollateral.balanceOf(Alice), AliceBefore - Amount, "Alice's balance should change");
        assertEq(mCollateral.balanceOf(Bob), BobBefore + Amount, "Bob should get the transfer");
        assertEq(mBorrow.borrowBalanceStored(Alice), BorrowBefore, "Alice's borrow shouldn't change");

        // 断言状态发生改变
        (uint256 err, uint256 liq, uint256 shortfall) = comptroller.getAccountLiquidity(Alice);
        assertEq(err, 0, "Transfer should succeed");
        assertGt(liq, 0, "After transfer should still have liquidity");       // q - transfer 之后流动性不应该减少吗
        assertEq(shortfall, 0, "borrow amount is not overflow so shortfall should be 0");
    }

    // 边界测试，maxSafeMTokens + 1 必须失败，maxSafe 通过
    function testTransfer_AfterBorrow_BoundryIsTight_MaxOkPlusOneFails() public {
        _createBorrowingPosition(1000e18, 800e18); //  抵押 1000， 借满 800， liquidity = 0

        uint256 maxSafeTokens = _maxRedeemableSafe(Alice);
        
        uint256 AliceBefore = mCollateral.balanceOf(Alice);
        uint256 BobBefore = mCollateral.balanceOf(Bob);
        
        // 尝试转账 maxSafeTokens + 1
        vm.prank(Alice);
        bool okOver = mCollateral.transfer(Bob, maxSafeTokens + 1);     // q - 在这里不久应该失败revert吗，但是只是返回失败值？ 
        assertFalse(okOver, "Plus one trasfer should be failed");
        assertEq(mCollateral.balanceOf(Alice), AliceBefore, "Alice's balance shouldn't be change");
        assertEq(mCollateral.balanceOf(Bob), BobBefore, "Bob's balance shouldn't be change");

        // 如果 maxSafe = 0 则表示 1 wei 都不让转，跳过该分支
        if(maxSafeTokens > 0) {
            vm.prank(Alice);
            bool ok = mCollateral.transfer(Bob, maxSafeTokens);
            assertTrue(ok, "Transfer should be succeed");
            assertEq(mCollateral.balanceOf(Alice), AliceBefore - maxSafeTokens);
            assertEq(mCollateral.balanceOf(Bob), BobBefore + maxSafeTokens);
        }

    } 

    // 粉尘测试，liquidity = 0 时，单笔极小 mToken （1 wei） 由于整数截断仍能通过
    // threshold: 零界点
    // q - 该测试成立的话，是否会造成资金损失呢？ -> Alice 转账后 shortfall > 0, 导致被清算？ 或者是否可以取回抵押品？
    function testTransfer_AfterBorrow_DustBelowRoundingThreshold_PassesDueToRounding() public {
        _createBorrowingPosition(1000e18, 800e18);  // liquidity = 0

        // 获取当前 shortfall
        (uint256 err, uint256 liq, uint256 shortfall) = comptroller.getAccountLiquidity(Alice);
        assertEq(liq, 0, "liquidity should be 0");
        assertEq(shortfall, 0 ,"shortfall should be 0");

        // 转账前的状态
        uint256 AliceBefore = mCollateral.balanceOf(Alice);
        uint256 BobBefore = mCollateral.balanceOf(Bob);

        // 尝试极小额度转账
        vm.prank(Alice);
        bool ok = mCollateral.transfer(Bob, 1);
        assertTrue(ok, "Current behavior: 1 wei transfer slips through due to truncation");
        assertEq(mCollateral.balanceOf(Alice), AliceBefore - 1, "Alice debited by 1 wei");
        assertEq(mCollateral.balanceOf(Bob), BobBefore + 1, "Bob credited by 1 wei");
    }
    


    /****************************************************************************** 
     *                                边角分支测试                                * 
     ******************************************************************************/

    // 从 src => dst 的转账失败，被内部拦截(出发 BAD_INPUT)
    function testTransfer_ToSelf_Fails() public {
        _supplyCollateral(Alice, 1000e18);

        uint256 AliceBefore = mCollateral.balanceOf(Alice);
        assertGt(AliceBefore, 0, "Alice should hold mTokens");
        
        // Alice 尝试转账给自己
        vm.prank(Alice);
        bool ok = mCollateral.transfer(Alice, AliceBefore);
        assertFalse(ok, "Self Transfer should be failed");
        
        assertEq(mCollateral.balanceOf(Alice), AliceBefore, "Balance unchange on self-transfer");

    }

    // 转账为 0 时应成功
    // 符合常理吗？不应该拒绝吗？还是前端会阻止这个操作？
    function testTransfer_ZeroAmoumt_Succeed() public {
        _supplyCollateral(Alice, 1000e18);
        
        uint256 AliceBefore = mCollateral.balanceOf(Alice);
        uint256 BobBefore = mCollateral.balanceOf(Bob);
        assertGt(AliceBefore, 0, "Alice should hold mTokens");

        vm.prank(Alice);
        bool ok = mCollateral.transfer(Bob, 0);
        assertTrue(ok, "zero amount transfer succeed");
        
        // 状态检查
        assertEq(mCollateral.balanceOf(Alice), AliceBefore);
        assertEq(mCollateral.balanceOf(Bob), BobBefore);
    }

    // transferGuardianPaused = true 时，所有 transfer 都会 revert
    function testTransfer_WhenPaused_Reverts() public {
        _supplyCollateral(Alice, 1000e18);

        // 测试合约部署了 Comptroller，所以为 admin
        assertTrue(comptroller._setTransferPaused(true), "should set transfer state succeed");

        vm.prank(Alice);
        vm.expectRevert(bytes("transfer is paused"));
        mCollateral.transfer(Bob, 1);
    }


    // audit - 转账给 address(0) 时，资产会被永久锁死
    function testTransfer_ToZeroAddress_LocksToken_AuditObservation() public {
        _supplyCollateral(Alice, 100e18);

        uint256 AliceBefore = mCollateral.balanceOf(Alice);     // q - 这里获取的是 Alice 的可用流动性？
        uint256 zeroAddressBefore = mCollateral.balanceOf(address(0));
        uint256 totalSupplyBefore = mCollateral.totalSupply();
        
        vm.prank(Alice);
        (bool ok) = mCollateral.transfer(address(0), AliceBefore);
        
        assertTrue(ok, "Transfer succeed");
        assertEq(mCollateral.balanceOf(Alice), 0, "Alice's balance should be 0");
        assertEq(mCollateral.balanceOf(address(0)), zeroAddressBefore + AliceBefore);
        assertEq(mCollateral.totalSupply(), totalSupplyBefore, "totalSupply will not change, mToken is lost");

    }

    // 边界测试：Alice 仅有 1 wei， 转出后余额应该归零
    function testTransfer_TransferOneWei_Succeed() public {
        
        // 用最小 underlying 单位让 Alice 获得极少 mToken
        // q - mToken 数 = underlying * 1e18 / exchangeRate；exchangeRate=2e16 → 1 underlying ≈ 50 mToken
        _supplyCollateral(Alice, 1);
        
        uint256 AliceBeforeDust = mCollateral.balanceOf(Alice);
        uint256 BobBefore = mCollateral.balanceOf(Bob);

        vm.prank(Alice);
        bool ok = mCollateral.transfer(Bob, AliceBeforeDust);
        assertTrue(ok, "Transfer should be succeed");
        assertEq(mCollateral.balanceOf(Alice), 0, "Alice's balance should be 0");
        assertEq(mCollateral.balanceOf(Bob), AliceBeforeDust, "Bob's balance should be 1");

    }


    // 二分发找到最大可赎回数量
    function _maxRedeemableSafe(address who) internal view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = mCollateral.balanceOf(who);

        // 二分：找到最大的 x 使得 redeem x 后 shortfall == 0
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2; // 向上取整，避免死循环
            (uint err, , uint shortfall) = comptroller.getHypotheticalAccountLiquidity(
                who,
                address(mCollateral),
                mid,
                0
            );
            if (err == 0 && shortfall == 0) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }


    // 构建一个：已进入市场 + 已借款 的账户
    function _createBorrowingPosition(
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal {
        // 先给 借款 账户 mint 
        // 授权 抵押品市场 使用
        // 进入市场

        mCollateralUnderlying.mint(Alice, collateralAmount);
        vm.startPrank(Alice);
        mCollateralUnderlying.approve(address(mCollateral), collateralAmount);
        assertEq(mCollateral.mint(collateralAmount), 0 , "Alice supply failed");

        address[] memory markets = new address[](1);
        markets[0] = address(mCollateral);
        comptroller.enterMarkets(markets);
        
        assertEq(mBorrow.borrow(borrowAmount), 0 , "Alice Borrow failed");
        vm.stopPrank();

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