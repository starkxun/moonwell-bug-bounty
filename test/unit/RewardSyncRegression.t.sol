// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MToken} from "@protocol/MToken.sol";
import {MultiRewardDistributor} from "@protocol/rewards/MultiRewardDistributor.sol";
import {MultiRewardDistributorCommon} from "@protocol/rewards/MultiRewardDistributorCommon.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/******************************************************************************
 *                              starkxun test                                  *
 *  step_1.md P1 #5 - 奖励-账本同步回归                                         *
 *                                                                             *
 *  生产事故关注点：                                                            *
 *    1. claim 之后未领奖励应清零（防止重复领取）                               *
 *    2. repayBorrowBehalf 应只更新借款人的 reward index，不能给 payer 记奖励   *
 *    3. 清算后被扣押的 mToken 上的 supply 奖励应归清算人，不能继续给借款人     *
 *    4. 多 emission token 下每种独立守恒                                       *
 ******************************************************************************/

contract RewardSyncRegressionUnitTest is Test, MultiRewardDistributorCommon {
    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;

    MultiRewardDistributor internal distributor;

    MockERC20 internal mCollateralUnderlying;
    MockERC20 internal mBorrowUnderlying;
    MockERC20 internal emissionTokenA;
    MockERC20 internal emissionTokenB;

    MErc20Immutable internal mCollateral;
    MErc20Immutable internal mBorrow;

    address internal Alice;       // 借款人/被清算人
    address internal Bob;          // 普通供给者
    address internal Carol;        // repayBehalf 的 payer
    address internal Liquidator;
    address internal Supplier;     // 给借款市场注入流动性

    address internal constant PROXY_ADMIN = address(0x1337);

    uint256 internal constant INIT_EXCHANGE_RATE = 2e16;
    uint256 internal constant CF_COLLATERAL      = 0.8e18;
    uint256 internal constant SUPPLY_EMISSION_PS = 1e15;   // 0.001 token/sec
    uint256 internal constant BORROW_EMISSION_PS = 2e15;   // 0.002 token/sec

    function setUp() public {
        Alice      = makeAddr("Alice");
        Bob        = makeAddr("Bob");
        Carol      = makeAddr("Carol");
        Liquidator = makeAddr("Liquidator");
        Supplier   = makeAddr("Supplier");

        mCollateralUnderlying = new MockERC20();
        mBorrowUnderlying     = new MockERC20();

        comptroller = new Comptroller();
        oracle      = new SimplePriceOracle();
        irm         = new WhitePaperInterestRateModel(0.02e18, 0.20e18);

        assertEq(comptroller._setPriceOracle(oracle), 0);
        assertEq(comptroller._setCloseFactor(0.5e18), 0);
        assertEq(comptroller._setLiquidationIncentive(1.08e18), 0);

        mCollateral = new MErc20Immutable(
            address(mCollateralUnderlying), comptroller, irm,
            INIT_EXCHANGE_RATE, "mCOL", "mCOL", 8, payable(address(this))
        );
        mBorrow = new MErc20Immutable(
            address(mBorrowUnderlying), comptroller, irm,
            INIT_EXCHANGE_RATE, "mBRW", "mBRW", 8, payable(address(this))
        );

        assertEq(comptroller._supportMarket(mCollateral), 0);
        assertEq(comptroller._supportMarket(mBorrow), 0);
        oracle.setUnderlyingPrice(mCollateral, 1e18);
        oracle.setUnderlyingPrice(mBorrow, 1e18);
        assertEq(comptroller._setCollateralFactor(mCollateral, CF_COLLATERAL), 0);
        assertEq(comptroller._setCollateralFactor(mBorrow, 0), 0);

        // 部署 distributor (proxy 模式，因为实现合约 _disableInitializers)
        MultiRewardDistributor impl = new MultiRewardDistributor();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)", address(comptroller), address(this)
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), PROXY_ADMIN, initData
        );
        distributor = MultiRewardDistributor(address(proxy));

        comptroller._setRewardDistributor(distributor);

        // 两种 emission token，便于测试多奖励独立性
        emissionTokenA = new MockERC20();
        emissionTokenB = new MockERC20();

        // 给 distributor 充足的奖励池
        emissionTokenA.mint(address(distributor), 1_000_000e18);
        emissionTokenB.mint(address(distributor), 1_000_000e18);

        // 在 mCollateral 上配置 emissionTokenA
        distributor._addEmissionConfig(
            mCollateral,
            address(this),
            address(emissionTokenA),
            SUPPLY_EMISSION_PS,
            BORROW_EMISSION_PS,
            block.timestamp + 365 days
        );
        // 在 mBorrow 上配置 emissionTokenA
        distributor._addEmissionConfig(
            mBorrow,
            address(this),
            address(emissionTokenA),
            SUPPLY_EMISSION_PS,
            BORROW_EMISSION_PS,
            block.timestamp + 365 days
        );

        // 给借款市场注入流动性
        _supply(Supplier, mBorrowUnderlying, mBorrow, 10_000e18);
    }

    /******************************************************************************
     *  Test 1 - claim 之后未领奖励应基本清零                                       *
     ******************************************************************************/
    function testClaim_DrainsOutstandingRewards() public {
        // Alice 在 mCollateral 上 supply（有 supply 奖励）
        _supply(Alice, mCollateralUnderlying, mCollateral, 1000e18);
        _enterMarket(Alice, address(mCollateral));

        // Alice 在 mBorrow 上 borrow（有 borrow 奖励）
        vm.prank(Alice);
        assertEq(mBorrow.borrow(300e18), 0);

        // 走 30 天积累奖励
        vm.warp(block.timestamp + 30 days);

        // 查询应得奖励（mCollateral 的 supplySide + mBorrow 的 borrowSide 应都 > 0）
        uint256 outstandingCollateral = _outstandingTotal(mCollateral, Alice);
        uint256 outstandingBorrow     = _outstandingTotal(mBorrow, Alice);
        assertGt(outstandingCollateral, 0, "should have supply rewards on mCollateral");
        assertGt(outstandingBorrow, 0,    "should have borrow rewards on mBorrow");

        uint256 expectedClaim = outstandingCollateral + outstandingBorrow;
        uint256 balanceBefore = emissionTokenA.balanceOf(Alice);

        comptroller.claimReward(Alice);

        uint256 balanceAfter = emissionTokenA.balanceOf(Alice);
        uint256 received = balanceAfter - balanceBefore;

        // claim 在同一区块继续推进 1 个 timestamp 内的 emission，所以会比预期略多 1 秒
        // 取一个宽松的下界即可
        assertGe(received, expectedClaim, "received >= queried");
        // 上界：不会拿到双倍
        assertLt(received, expectedClaim * 2, "claim should not double-pay");

        // 同 timestamp 再查询，剩余应基本为 0（claim 内部已经把 index 推到 now）
        uint256 leftCollateral = _outstandingTotal(mCollateral, Alice);
        uint256 leftBorrow     = _outstandingTotal(mBorrow, Alice);
        assertEq(leftCollateral, 0, "supply leftover should be 0");
        assertEq(leftBorrow, 0,     "borrow leftover should be 0");
    }

    /******************************************************************************
     *  Test 2 - repayBorrowBehalf 不应给 payer 记奖励                              *
     ******************************************************************************/
    function testRepayBehalf_DoesNotCreditPayer() public {
        // Alice 借款
        _supply(Alice, mCollateralUnderlying, mCollateral, 1000e18);
        _enterMarket(Alice, address(mCollateral));
        vm.prank(Alice);
        assertEq(mBorrow.borrow(300e18), 0);

        vm.warp(block.timestamp + 10 days);

        // Carol 完全没参与协议（既没 supply 也没 borrow）
        // 但她替 Alice 还款
        uint256 repay = 50e18;
        mBorrowUnderlying.mint(Carol, repay);
        vm.startPrank(Carol);
        mBorrowUnderlying.approve(address(mBorrow), repay);
        assertEq(mBorrow.repayBorrowBehalf(Alice, repay), 0, "repayBehalf failed");
        vm.stopPrank();

        // Carol 在 mBorrow 上不应有任何奖励
        uint256 carolBorrowSide  = _outstandingBorrow(mBorrow, Carol);
        uint256 carolSupplySide  = _outstandingSupply(mBorrow, Carol);
        assertEq(carolBorrowSide, 0, "Carol must not get borrow rewards");
        assertEq(carolSupplySide, 0, "Carol must not get supply rewards");

        // Alice 仍应有借款侧奖励（前 10 天累积）
        assertGt(_outstandingBorrow(mBorrow, Alice), 0, "Alice should keep borrow rewards");

        // Carol 直接 claim 也拿不到 emission token
        uint256 carolBefore = emissionTokenA.balanceOf(Carol);
        comptroller.claimReward(Carol);
        uint256 carolAfter = emissionTokenA.balanceOf(Carol);
        assertEq(carolAfter, carolBefore, "Carol must not be paid");
    }

    /******************************************************************************
     *  Test 3 - 清算之后，被扣押的 mToken 上的 supply 奖励归清算人                  *
     ******************************************************************************/
    function testLiquidation_FutureSupplyRewardsAccrueToLiquidator() public {
        // Alice 抵押 + 借款，制造可清算
        _supply(Alice, mCollateralUnderlying, mCollateral, 1000e18);
        _enterMarket(Alice, address(mCollateral));
        vm.prank(Alice);
        assertEq(mBorrow.borrow(700e18), 0);

        // 跑一段时间让奖励指数推进
        vm.warp(block.timestamp + 5 days);

        // 抵押品价格腰斩 → shortfall
        oracle.setUnderlyingPrice(mCollateral, 0.5e18);

        // Liquidator 准备资金
        uint256 debt = mBorrow.borrowBalanceCurrent(Alice);
        uint256 repayAmt = (debt * 0.5e18) / 1e18 / 2;
        mBorrowUnderlying.mint(Liquidator, repayAmt);

        // 清算：把 Alice 的 mCollateral 扣押给 Liquidator
        uint256 aliceColBefore = mCollateral.balanceOf(Alice);
        vm.startPrank(Liquidator);
        mBorrowUnderlying.approve(address(mBorrow), repayAmt);
        assertEq(mBorrow.liquidateBorrow(Alice, repayAmt, mCollateral), 0);
        vm.stopPrank();

        uint256 aliceColAfter = mCollateral.balanceOf(Alice);
        uint256 liquidatorCol = mCollateral.balanceOf(Liquidator);
        assertLt(aliceColAfter, aliceColBefore, "Alice's collateral should drop");
        assertGt(liquidatorCol, 0, "Liquidator should hold collateral");

        // 清算"瞬间"再查 outstanding：清算 path 内部已经把双方索引推到 now，所以为 0
        // 关键检查：清算 *之后* 的时间段，supply 奖励只继续累计在 Liquidator 身上
        uint256 lAliceBefore = _outstandingSupply(mCollateral, Alice);
        uint256 lLiqBefore   = _outstandingSupply(mCollateral, Liquidator);

        vm.warp(block.timestamp + 10 days);

        uint256 lAliceAfter = _outstandingSupply(mCollateral, Alice);
        uint256 lLiqAfter   = _outstandingSupply(mCollateral, Liquidator);

        uint256 deltaAlice = lAliceAfter - lAliceBefore;
        uint256 deltaLiq   = lLiqAfter - lLiqBefore;

        // Alice 还有部分 mCollateral（不是被全部扣押），她仍按剩余份额累积
        // Liquidator 累积的 supply 奖励应与其持有的份额成比例
        // 用 mToken 余额比例验证
        uint256 totalSupply = mCollateral.totalSupply();
        // Liquidator 占总份额的比例
        uint256 liqShare   = (liquidatorCol * 1e18) / totalSupply;
        uint256 aliceShare = (mCollateral.balanceOf(Alice) * 1e18) / totalSupply;

        // 量级检查：deltaLiq / deltaAlice ≈ liqShare / aliceShare（允许较大误差）
        assertGt(deltaLiq, 0, "liquidator must accrue supply rewards");
        if (deltaAlice > 0) {
            // 比例大致匹配（粗略 ±20% 容忍）
            uint256 expectedRatio = (liqShare * 1e18) / aliceShare;
            uint256 actualRatio   = (deltaLiq * 1e18) / deltaAlice;
            // 取宽松的上下界
            assertGt(actualRatio, expectedRatio * 80 / 100, "ratio too low");
            assertLt(actualRatio, expectedRatio * 120 / 100, "ratio too high");
        }
    }

    /******************************************************************************
     *  Test 4 - 多 emission token 各自独立累计                                     *
     ******************************************************************************/
    function testTwoEmissionTokens_AccrueIndependently() public {
        // 在 mCollateral 上再加一个 emission token B，发射速率不同
        uint256 BORROW_PS_B = 5e15;
        uint256 SUPPLY_PS_B = 3e15;
        distributor._addEmissionConfig(
            mCollateral,
            address(this),
            address(emissionTokenB),
            SUPPLY_PS_B,
            BORROW_PS_B,
            block.timestamp + 365 days
        );

        // Bob supply 一些 mCollateral
        _supply(Bob, mCollateralUnderlying, mCollateral, 1000e18);

        vm.warp(block.timestamp + 7 days);

        // 查询 Bob 在 mCollateral 上的所有 emission rewards
        RewardInfo[] memory rewards = distributor.getOutstandingRewardsForUser(mCollateral, Bob);

        uint256 amtA;
        uint256 amtB;
        for (uint256 i = 0; i < rewards.length; i++) {
            if (rewards[i].emissionToken == address(emissionTokenA)) amtA = rewards[i].totalAmount;
            if (rewards[i].emissionToken == address(emissionTokenB)) amtB = rewards[i].totalAmount;
        }
        assertGt(amtA, 0, "tokenA accrued");
        assertGt(amtB, 0, "tokenB accrued");

        // ratio 应大致匹配两者 supplyEmissionsPerSec 的比值（误差 <1%）
        // SUPPLY_PS_B / SUPPLY_EMISSION_PS = 3e15 / 1e15 = 3
        uint256 ratio = (amtB * 100) / amtA;
        assertGe(ratio, 295, "B/A ratio must be ~300");
        assertLe(ratio, 305, "B/A ratio must be ~300");

        // claim 时两种 token 都应到账
        uint256 balABefore = emissionTokenA.balanceOf(Bob);
        uint256 balBBefore = emissionTokenB.balanceOf(Bob);
        comptroller.claimReward(Bob);
        assertGt(emissionTokenA.balanceOf(Bob) - balABefore, 0, "got A");
        assertGt(emissionTokenB.balanceOf(Bob) - balBBefore, 0, "got B");
    }

    /******************************************************************************
     *                                helpers                                       *
     ******************************************************************************/

    function _supply(
        address user,
        MockERC20 underlying,
        MErc20Immutable mTok,
        uint256 amount
    ) internal {
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(address(mTok), amount);
        assertEq(mTok.mint(amount), 0);
        vm.stopPrank();
    }

    function _enterMarket(address user, address market) internal {
        address[] memory markets = new address[](1);
        markets[0] = market;
        vm.prank(user);
        comptroller.enterMarkets(markets);
    }

    function _outstandingTotal(MErc20Immutable mTok, address user) internal view returns (uint256 t) {
        RewardInfo[] memory rs = distributor.getOutstandingRewardsForUser(mTok, user);
        for (uint256 i = 0; i < rs.length; i++) t += rs[i].totalAmount;
    }

    function _outstandingSupply(MErc20Immutable mTok, address user) internal view returns (uint256 s) {
        RewardInfo[] memory rs = distributor.getOutstandingRewardsForUser(mTok, user);
        for (uint256 i = 0; i < rs.length; i++) s += rs[i].supplySide;
    }

    function _outstandingBorrow(MErc20Immutable mTok, address user) internal view returns (uint256 b) {
        RewardInfo[] memory rs = distributor.getOutstandingRewardsForUser(mTok, user);
        for (uint256 i = 0; i < rs.length; i++) b += rs[i].borrowSide;
    }
}
