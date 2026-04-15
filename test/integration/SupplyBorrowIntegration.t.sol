//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {IERC20Metadata as IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@forge-std/Test.sol";

import {MErc20} from "@protocol/MErc20.sol";
import {MToken} from "@protocol/MToken.sol";
import {Configs} from "@proposals/Configs.sol";
import {WETH9} from "@protocol/router/IWETH.sol";
import {Unitroller} from "@protocol/Unitroller.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MarketBase} from "@test/utils/MarketBase.sol";
import {WETHRouter} from "@protocol/router/WETHRouter.sol";
import {MErc20Delegator} from "@protocol/MErc20Delegator.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {MarketAddChecker} from "@protocol/governance/MarketAddChecker.sol";
import {MultiRewardDistributor} from "@protocol/rewards/MultiRewardDistributor.sol";
import {ChainIds, OPTIMISM_CHAIN_ID, BASE_FORK_ID} from "@utils/ChainIds.sol";
import {MultiRewardDistributorCommon} from "@protocol/rewards/MultiRewardDistributorCommon.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MockRedstoneMultiFeedAdapter} from "@test/mock/MockRedstoneMultiFeedAdapter.sol";

contract SupplyBorrowLiveSystem is Test, PostProposalCheck {
    using ChainIds for uint256;

    MultiRewardDistributor mrd;
    Comptroller comptroller;

    MToken[] mTokens;   // q - 这个变量存储的是什么内容？
    MarketAddChecker checker;
    MarketBase public marketBase;

    // q - rewardTokens 存储的是什么数据？
    mapping(MToken => address[] rewardTokens) rewardsConfig;

    function setUp() public override {
        uint256 primaryForkId = vm.envUint("PRIMARY_FORK_ID");
        
        // q - 调用父类的 setUp(), 是 PostProposalCheck 的 setUp 吗？
        super.setUp();

        // 切换到目标fork
        vm.selectFork(primaryForkId);

        mrd = MultiRewardDistributor(addresses.getAddress("MRD_PROXY"));        // 奖励分发器
        comptroller = Comptroller(addresses.getAddress("UNITROLLER"));          // 风控入口
        checker = MarketAddChecker(addresses.getAddress("MARKET_ADD_CHECKER")); // 市场检查器
        marketBase = new MarketBase(comptroller);                               // 测试辅助工具（算 max supply/borrow）

        // 拉取所有 market
        MToken[] memory markets = comptroller.getAllMarkets();

        // 提取一个废弃 market
        MToken deprecatedMoonwellVelo = MToken(
            addresses.getAddress("DEPRECATED_MOONWELL_VELO", OPTIMISM_CHAIN_ID)
        );

        for (uint256 i = 0; i < markets.length; i++) {
            // 过滤掉一个 废弃 market
            if (markets[i] == deprecatedMoonwellVelo) {
                continue;
            }
            mTokens.push(markets[i]);

            // 读取每个 market 的 MRD 配置
            // 把每个 emissionToken 存进 rewardsConfig[market]
            // 后续后面测试可直接遍历某市场有哪些奖励币，不用每次重复链上查询测试
            MultiRewardDistributorCommon.MarketConfig[] memory configs = mrd
                .getAllMarketConfigs(markets[i]);

            for (uint256 j = 0; j < configs.length; j++) {
                rewardsConfig[markets[i]].push(configs[j].emissionToken);
            }
        }

        // 因为测试会 warp 时间，真实 Redstone 可能报 stale price；这里用 vm.etch 替换目标地址代码
        // 避免喂价过期导致无关失败
        if (primaryForkId == BASE_FORK_ID) {
            // mock redstone internal call to avoid stale price error (we cannot warp more than 30 hours to the future)
            MockRedstoneMultiFeedAdapter redstoneMock = new MockRedstoneMultiFeedAdapter();

            vm.etch(
                0xb81131B6368b3F0a83af09dB4E39Ac23DA96C2Db,
                address(redstoneMock).code
            );
        }

        // 确保 mTokens 不为空，否则后续测试没有意义
        assertEq(mTokens.length > 0, true, "No markets found");
    }

    //  q - 给用户 mint MToken?
    function _mintMToken(
        address user,
        address mToken,
        uint256 amount
    ) internal {
        // 找到这个市场对应的底层代币
        address underlying = MErc20(mToken).underlying();

        // 对 WETH 做一个特殊处理
        // 避免后续和 WETH 相关路径因为原生 ETH 不足出现干扰问题
        if (underlying == addresses.getAddress("WETH")) {
            vm.deal(addresses.getAddress("WETH"), amount);
        }
        deal(underlying, user, amount);
        
        // 模拟真实用户行为
        vm.startPrank(user);

        IERC20(underlying).approve(mToken, amount);

        assertEq(
            MErc20Delegator(payable(mToken)).mint(amount),
            0,
            "Mint failed"
        );
        vm.stopPrank();
    }

    // 参数
    // emissionToken: 要奖励的币种
    function _calculateSupplyRewards(
        MToken mToken,
        address emissionToken,
        uint256 amount,
        uint256 timeBefore,
        uint256 timeAfter
    ) private view returns (uint256 expectedRewards) {
        // 读取该市场该奖励币的配置
        // supplyEmissionsPerSec：每秒发多少该奖励币
        MultiRewardDistributorCommon.MarketConfig memory marketConfig = mrd
            .getConfigForMarket(mToken, emissionToken);

        // 奖励发放截止时间
        uint256 endTime = marketConfig.endTime;

        // 计算有效时间 timeDelta
        uint256 timeDelta;

        if (timeAfter > endTime) {
            if (timeBefore > endTime) {
                timeDelta = 0;
            } else {
                timeDelta = endTime - timeBefore;
            }
        } else {
            timeDelta = timeAfter - timeBefore;
        }

        // 最总计算
        // 在这段有效时间里，市场总共发出 timeDelta × 每秒发放量
        // 按自己供应占比 amount / totalSupply 分到对应份额
        expectedRewards =
            (timeDelta * marketConfig.supplyEmissionsPerSec * amount) /
            MErc20(address(mToken)).totalSupply();
    }

    function _calculateBorrowRewards(
        MToken mToken,
        address emissionToken,
        uint256 amount,
        uint256 timeBefore,
        uint256 timeAfter
    ) private view returns (uint256 expectedRewards) {
        MultiRewardDistributorCommon.MarketConfig memory config = mrd
            .getConfigForMarket(mToken, emissionToken);

        uint256 endTime = config.endTime;

        uint256 timeDelta;

        if (timeAfter > endTime) {
            if (timeBefore > endTime) {
                timeDelta = 0;
            } else {
                timeDelta = endTime - timeBefore;
            }
        } else {
            timeDelta = timeAfter - timeBefore;
        }

        expectedRewards =
            (timeDelta * config.borrowEmissionsPerSec * amount) /
            mToken.totalBorrows();
    }

    // q - 断言每个 market 的 totalSupply 和 balance 不为空
    // q - totalSuppley 的断言条件为什么要大于 2000？
    // assertGT -> 断言左边大于右边
    function testAllMarketsNonZeroTotalSupply() public view {
        MToken[] memory markets = comptroller.getAllMarkets();

        for (uint256 i = 0; i < markets.length; i++) {
            assertGt(markets[i].totalSupply(), 2_000, "empty market");
            assertGt(markets[i].balanceOf(address(0)), 0, "no burnt tokens");
        }
    }

    // q - 检查所有市场是否正常初始化
    // Moonwell 协议里 cbETH 对应的市场合约地址
    // UNITROLLER 是“管理所有市场的控制器入口
    function testMarketAddChecker() public view {
        checker.checkMarketAdd(addresses.getAddress("MOONWELL_cbETH"));
        checker.checkAllMarkets(addresses.getAddress("UNITROLLER"));
    }

    function _mintMTokenSucceed(
        uint256 mTokenIndex,
        uint256 mintAmount
    ) private {
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = marketBase.getMaxSupplyAmount(mToken);

        // q - 这里的边界是什么意思？
        if (max <= 10e8) {
            return;
        }

        // 把 fuzz 进来的 minAmount 限制到一个安全区间
        mintAmount = _bound(mintAmount, 10e8, max);

        // q - 这句是什么意思？
        IERC20 token = IERC20(MErc20(address(mToken)).underlying());

        address sender = address(this);
        uint256 startingTokenBalance = token.balanceOf(address(mToken));

        _mintMToken(address(this), address(mToken), mintAmount);

        // q - 这里的断言，是针对 mint 给合约自己的 token 是否成功吗？
        assertTrue(
            MErc20Delegator(payable(address(mToken))).balanceOf(sender) > 0,
            "mToken balance should be gt 0 after mint"
        ); /// ensure balance is gt 0

        assertEq(
            token.balanceOf(address(mToken)) - startingTokenBalance,
            mintAmount,
            "Underlying balance not updated"
        ); /// ensure underlying balance is sent to mToken
    }

    function testFuzzMintMTokenSucceed(uint256 mintAmount) public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _mintMTokenSucceed(i, mintAmount);
        }
    }

    // 测试流程
    // 先存款当抵押，再借款
    // 验证借的钱是否正确到账
    function _borrowMTokenSucceed(
        uint256 mTokenIndex,
        uint256 mintAmount
    ) private {
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = marketBase.getMaxSupplyAmount(mToken);

        if (max <= 10e8) {
            return;
        }

        mintAmount = _bound(mintAmount, 10e8, max);

        // 把底层资产存进市场，拿到 mToken （借款前必须要有抵押品）
        _mintMToken(address(this), address(mToken), mintAmount);

        uint256 expectedCollateralFactor = 0.5e18;
        //  collateralFactorMantissa： 抵押资产可计入借款能力的比例
        // q - 使用控制器获取可用的抵押因子？ -> 为了让测试在不同市场配置下更稳定地走到借款成功路径
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        // q - 这里的意思是提高 抵押因子 吗？
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        uint256 balanceBefore = sender.balance;

        address[] memory _mTokens = new address[](1);
        _mTokens[0] = address(mToken);

        // q - 这里为什么要进入 market？ 这个借款函数的逻辑是什么？
        // a - 把该地址的抵押登记为可用于借款，不进入市场，Comptroller 的流动性检查会失败，borrowAllowed 会拒绝
        comptroller.enterMarkets(_mTokens);
        assertTrue(
            comptroller.checkMembership(sender, mToken),
            "Membership check failed"
        );

        uint256 borrowAmount = marketBase.getMaxUserBorrowAmount(
            mToken,
            address(this)
        );

        if (borrowAmount < 1e12) {
            return;
        }

        // 断言 0， 表示借款成功
        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
            0,
            "Borrow failed"
        );

        IERC20 token = IERC20(MErc20(address(mToken)).underlying());

        // WETH 市场
        if (address(token) == addresses.getAddress("WETH")) {
            // 这里按“收到原生 ETH”路径检查 sender.balance 增量
            // q - 为什么这么写？ 是之前给账户 mint 了一些 WETH 的原因吗？
            assertEq(
                sender.balance - balanceBefore,
                borrowAmount,
                "Wrong borrow amount"
            );
        } else {
            // 普通 ERC20 市场
            assertEq(
                token.balanceOf(sender),
                borrowAmount,
                "Wrong borrow amount"
            );
        }
    }

    // fuzz borrow 数量
    function testFuzzBorrowMTokenSucceed(uint256 mintAmount) public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _borrowMTokenSucceed(i, mintAmount);
        }
    }

    // q - 这个函数是干什么的？
    // 内部的计算都是围绕奖励数据展开的，所以这个函数实际是在做什么呢？
    // 先 supply 一笔资金，时间快进一段
    // 对比 mrd 计算值 和 测试内手工计算值 是否一致
    // 即 供应测奖励正确性 的正确性 测试
    function _supplyReceivesRewards(
        uint256 mTokenIndex,
        uint256 supplyAmount,
        uint256 toWarp
    ) public {
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = marketBase.getMaxSupplyAmount(mToken);

        if (max <= 1000e8) {
            return;
        }

        // 1000e8 to 90% of max supply
        // 实际最多是 max
        supplyAmount = _bound(supplyAmount, 1000e8, max);

        _mintMToken(address(this), address(mToken), supplyAmount);

        // q - 这里的 1_000_000 单位是多少？
        // a - 单位是秒，1_000_000 大约 11.57 天
        toWarp = _bound(toWarp, 1_000_000, 4 weeks);

        uint256 timeBefore = vm.getBlockTimestamp();
        vm.warp(timeBefore + toWarp);
        uint256 timeAfter = vm.getBlockTimestamp();

        //  计算应该拿到的奖励
        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            uint256 expectedReward = _calculateSupplyRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.balanceOf(address(this)),
                timeBefore,
                timeAfter
            );

            // 获取奖励数据
            MultiRewardDistributorCommon.RewardInfo[] memory rewards = mrd
                .getOutstandingRewardsForUser(MToken(mToken), address(this));

            // q - 这里的遍历在判断什么？
            for (uint256 j = 0; j < rewards.length; j++) {
                // 在返回数组里找到相同 emmisionToken 的那一项
                if (rewards[j].emissionToken != rewardsConfig[mToken][i]) {
                    continue;
                }
                // rewards[j].supplySide ≈ expectedReward
                // 允许 10% 相对误差，避免精度/四舍五入导致的微差
                assertApproxEqRel(
                    rewards[j].supplySide,
                    expectedReward,
                    0.1e18,
                    "Supply rewards not correct"
                );
                // rewards[j].totalAmount ≈ expectedReward
                // 允许 10% 相对误差，避免精度/四舍五入导致的微差
                assertApproxEqRel(
                    rewards[j].totalAmount,
                    expectedReward,
                    0.1e18,
                    "Total rewards not correct"
                );
            }
        }
    }

    function testFuzzSupplyReceivesRewards(
        uint256 supplyAmount,
        uint256 toWarp
    ) public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _supplyReceivesRewards(i, supplyAmount, toWarp);
        }
    }

    function _borrowReceivesRewards(
        uint256 mTokenIndex,
        uint256 supplyAmount,
        uint256 toWarp
    ) private {
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = marketBase.getMaxSupplyAmount(mToken);

        if (max <= 1000e8) {
            return;
        }

        toWarp = _bound(toWarp, 1_000_000, 4 weeks);
        supplyAmount = _bound(supplyAmount, 1000e8, max);

        _mintMToken(address(this), address(mToken), supplyAmount);

        uint256 expectedCollateralFactor = 0.5e18;
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        {
            address[] memory _mTokens = new address[](1);
            _mTokens[0] = address(mToken);

            comptroller.enterMarkets(_mTokens);
        }

        assertTrue(
            comptroller.checkMembership(sender, MToken(mToken)),
            "Membership check failed"
        );

        uint256 maxBorrow = marketBase.getMaxUserBorrowAmount(mToken, sender);

        uint256 borrowAmount = supplyAmount / 3 > maxBorrow
            ? maxBorrow
            : supplyAmount / 3;

        if (borrowAmount < 1e12) {
            return;
        }

        assertEq(
            comptroller.borrowAllowed(address(mToken), sender, borrowAmount),
            0,
            "Borrow allowed"
        );

        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
            0,
            "Borrow failed"
        );

        uint256 timeBefore = vm.getBlockTimestamp();
        vm.warp(timeBefore + toWarp);
        uint256 timeAfter = vm.getBlockTimestamp();

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            uint256 expectedReward = _calculateBorrowRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.borrowBalanceStored(sender),
                timeBefore,
                timeAfter
            );
            MultiRewardDistributorCommon.RewardInfo[] memory rewards = mrd
                .getOutstandingRewardsForUser(MToken(mToken), sender);

            for (uint256 j = 0; j < rewards.length; j++) {
                if (rewards[j].emissionToken != rewardsConfig[mToken][i]) {
                    continue;
                }
                assertApproxEqRel(
                    rewards[j].borrowSide,
                    expectedReward,
                    0.1e18,
                    "Borrow rewards not correct"
                );
            }
        }
    }

    function testFuzzBorrowReceivesRewards(
        uint256 supplyAmount,
        uint256 toWarp
    ) public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _borrowReceivesRewards(i, supplyAmount, toWarp);
        }
    }

    // 供应侧 和 借款侧 的奖励 
    function _supplyBorrowReceiveRewards(
        uint256 mTokenIndex,
        uint256 supplyAmount,
        uint256 toWarp
    ) private {
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = marketBase.getMaxSupplyAmount(mToken);

        if (max <= 1e12) {
            return;
        }

        toWarp = _bound(toWarp, 1_000_000, 4 weeks);
        supplyAmount = _bound(supplyAmount, 1e12, max);

        _mintMToken(address(this), address(mToken), supplyAmount);

        uint256 expectedCollateralFactor = 0.5e18;
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        address[] memory _mTokens = new address[](1);
        _mTokens[0] = address(mToken);

        comptroller.enterMarkets(_mTokens);
        assertTrue(
            comptroller.checkMembership(sender, mToken),
            "Membership check failed"
        );

        {
            uint256 borrowAmount = marketBase.getMaxUserBorrowAmount(
                mToken,
                address(this)
            );

            if (borrowAmount < 1e12) {
                return;
            }

            assertEq(
                MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
                0,
                "Borrow failed"
            );
        }

        uint256 timeBefore = vm.getBlockTimestamp();
        vm.warp(timeBefore + toWarp);
        uint256 timeAfter = vm.getBlockTimestamp();

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            uint256 expectedSupplyReward = _calculateSupplyRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.balanceOf(sender),
                timeBefore,
                timeAfter
            );

            uint256 expectedBorrowReward = _calculateBorrowRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.borrowBalanceStored(sender),
                timeBefore,
                timeAfter
            );

            MultiRewardDistributorCommon.RewardInfo[] memory rewards = mrd
                .getOutstandingRewardsForUser(MToken(mToken), sender);

            for (uint256 j = 0; j < rewards.length; j++) {
                if (rewards[j].emissionToken != rewardsConfig[mToken][i]) {
                    continue;
                }

                assertApproxEqRel(
                    rewards[j].supplySide,
                    expectedSupplyReward,
                    0.1e18,
                    "Supply rewards not correct"
                );

                assertApproxEqRel(
                    rewards[j].borrowSide,
                    expectedBorrowReward,
                    0.1e18,
                    "Borrow rewards not correct"
                );

                assertApproxEqRel(
                    rewards[j].totalAmount,
                    expectedSupplyReward + expectedBorrowReward,
                    0.1e18,
                    "Total rewards not correct"
                );
            }
        }
    }

    function testFuzzSupplyBorrowReceiveRewards(
        uint256 supplyAmount,
        uint256 toWarp
    ) public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _supplyBorrowReceiveRewards(i, supplyAmount, toWarp);
        }
    }

    // 借款测奖励 和  供应测奖励
    mapping(address token => uint256 borrowRewardPerToken) borrowRewardPerToken;
    mapping(address token => uint256 supplyRewardPerToken) supplyRewardPerToken;

    // q - LPer 接收奖励测试？
    // a - 测试 供给侧 和 借款侧 的奖励是否符合预期
    // 用户先 供给 + 借款， 然后进入可清算状态进行清算
    function _liquidateAccountReceiveRewards(
        uint256 mTokenIndex,
        uint256 mintAmount,
        uint256 toWarp
    ) private {
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = marketBase.getMaxSupplyAmount(mToken);

        if (max <= 10e8) {
            return;
        }

        toWarp = _bound(toWarp, 1_000_000, 4 weeks);

        mintAmount = _bound(mintAmount, 10e8, max);

        // uses different users to each market ensuring that previous liquidations do not impact this test
        // 用每个市场不同 user 地址测试（q - 为什么可以做到？）
        // 避免前一个市场 / 清算 的残留状态污染这一次的断言
        address user = address(uint160(mTokenIndex + 123));

        _mintMToken(user, address(mToken), mintAmount);

        {
            uint256 expectedCollateralFactor = 0.5e18;
            (, uint256 collateralFactorMantissa) = comptroller.markets(
                address(mToken)
            );
            // check colateral factor
            if (collateralFactorMantissa < expectedCollateralFactor) {
                vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
                comptroller._setCollateralFactor(
                    MToken(mToken),
                    expectedCollateralFactor
                );
            }

            address[] memory _mTokens = new address[](1);
            _mTokens[0] = address(mToken);

            vm.startPrank(user);
            comptroller.enterMarkets(_mTokens);

            assertTrue(
                comptroller.checkMembership(user, MToken(mToken)),
                "Membership check failed"
            );
        }

        // 这一步判断是什么意义？
        //  1/3 minAmount 大于最大借款数额，就 return ？
        if (mintAmount / 3 > marketBase.getMaxUserBorrowAmount(mToken, user)) {
            return;
        }

        // q - 这一步判断是什么意思？
        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(mintAmount / 3),
            0,
            "Borrow failed"
        );

        vm.stopPrank();

        uint256 timeBefore = vm.getBlockTimestamp();
        vm.warp(timeBefore + toWarp);
        uint256 timeAfter = vm.getBlockTimestamp();

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            supplyRewardPerToken[
                rewardsConfig[mToken][i]
            ] = _calculateSupplyRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.balanceOf(user) / 3,
                timeBefore,
                timeAfter
            );

            borrowRewardPerToken[
                rewardsConfig[mToken][i]
            ] = _calculateBorrowRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.borrowBalanceStored(user),
                timeBefore,
                timeAfter
            );
        }

        /// borrower is now underwater on loan
        // q - 这里什么意思？ 为什么借款人现在负债过重 ？
        // 使用 deal 强行把 用户的 mToken 抵押余额 降低到 较低水平（q - 为什么这么做？）
        // 抵押值下降，债务仍在， shortfall > 0, 进入清算状态
        deal(address(mToken), user, mToken.balanceOf(user) / 3);

        {
            // q - 这里获取的内容是什么？
            // err: 错误码, 0 表示成功
            // liquidity: 剩余可用流动性(还能借多少)
            // shortfall: 可清算程度
            (uint256 err, uint256 liquidity, uint256 shortfall) = comptroller
                .getHypotheticalAccountLiquidity(user, address(mToken), 0, 0);

            assertEq(err, 0, "Error in hypothetical liquidity calculation");
            // liquidity = 0 && shortfall > 0
            // 即表示可以清算了
            assertEq(liquidity, 0, "Liquidity not 0"); 
            assertGt(shortfall, 0, "Shortfall not gt 0");
        }

        {
            // q - reapy 数量为什么 是 mint 数量 除以 6 ？
            // a - 部分清算,不清算全部
            uint256 repayAmount = mintAmount / 6;
            deal(
                MErc20(address(mToken)).underlying(),       // q - 这句语法是什么意思？ -> 该市场底层资产地址
                address(100_000_000),                       // q - 这里 address(100_000_000) 是什么意思？ -> 整数强制转换为地址
                repayAmount
            );

            vm.startPrank(address(100_000_000));
            IERC20(MErc20(address(mToken)).underlying()).approve(
                address(mToken),
                repayAmount
            );

            assertEq(
                MErc20Delegator(payable(address(mToken))).liquidateBorrow(
                    user,
                    repayAmount,
                    MErc20(address(mToken))
                ),
                0,
                "Liquidation failed"
            );

            vm.stopPrank();
        }

        // RewardInfo 结构：
        // struct RewardInfo {
        //     address emissionToken;
        //     uint totalAmount;
        //     uint supplySide;
        //     uint borrowSide;
        // }

        MultiRewardDistributorCommon.RewardInfo[] memory rewardsPaid = mrd
            .getOutstandingRewardsForUser(MToken(mToken), user);

        for (uint256 j = 0; j < rewardsPaid.length; j++) {
            uint256 expectedSupplyReward = supplyRewardPerToken[
                rewardsPaid[j].emissionToken
            ];
            uint256 expectedBorrowReward = borrowRewardPerToken[
                rewardsPaid[j].emissionToken
            ];

            assertApproxEqRel(
                rewardsPaid[j].supplySide,
                expectedSupplyReward,
                0.1e18,
                "Supply rewards not correct"
            );

            assertApproxEqRel(
                rewardsPaid[j].borrowSide,
                expectedBorrowReward,
                0.1e18,
                "Borrow rewards not correct"
            );

            assertApproxEqRel(
                rewardsPaid[j].totalAmount,
                expectedSupplyReward + expectedBorrowReward,
                0.1e18,
                "Total rewards not correct"
            );
        }
    }

    function testFuzzLiquidateAccountReceiveRewards(
        uint256 mintAmount,
        uint256 toWarp
    ) public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _liquidateAccountReceiveRewards(i, mintAmount, toWarp);
        }
    }

    // q - 函数的作用 -> 测试路由偿还借款   [目前测试到这里]
    function testRepayBorrowBehalfWethRouter() public {
        MToken mToken = MToken(addresses.getAddress("MOONWELL_WETH"));
        uint256 mintAmount = marketBase.getMaxSupplyAmount(mToken);

        _mintMToken(address(this), address(mToken), mintAmount);

        uint256 expectedCollateralFactor = 0.5e18;
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        address[] memory _mTokens = new address[](1);
        _mTokens[0] = address(mToken);

        comptroller.enterMarkets(_mTokens);
        assertTrue(
            comptroller.checkMembership(sender, mToken),
            "Membership check failed"
        );

        uint256 borrowAmount = marketBase.getMaxUserBorrowAmount(
            mToken,
            address(this)
        );

        if (borrowAmount < 1e12) {
            return;
        }

        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
            0,
            "Borrow failed"
        );

        address mweth = addresses.getAddress("MOONWELL_WETH");
        WETH9 weth = WETH9(addresses.getAddress("WETH"));

        WETHRouter router = new WETHRouter(
            weth,
            MErc20(addresses.getAddress("MOONWELL_WETH"))
        );

        vm.deal(address(this), borrowAmount);

        router.repayBorrowBehalf{value: borrowAmount}(address(this));

        // 断言已经偿还完成
        assertEq(MErc20(mweth).borrowBalanceStored(address(this)), 0); /// fully repaid
    }

    // q - 测试偿还多于(两倍) borrowAmount 数量的金额
    function testRepayMoreThanBorrowBalanceWethRouter() public {
        MToken mToken = MToken(addresses.getAddress("MOONWELL_WETH"));
        uint256 mintAmount = marketBase.getMaxSupplyAmount(mToken);

        _mintMToken(address(this), address(mToken), mintAmount);

        uint256 expectedCollateralFactor = 0.5e18;
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        address[] memory _mTokens = new address[](1);
        _mTokens[0] = address(mToken);

        comptroller.enterMarkets(_mTokens);
        assertTrue(
            comptroller.checkMembership(sender, mToken),
            "Membership check failed"
        );

        uint256 borrowAmount = marketBase.getMaxUserBorrowAmount(
            mToken,
            address(this)
        );

        if (borrowAmount < 1e12) {
            return;
        }

        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
            0,
            "Borrow failed"
        );

        uint256 borrowRepayAmount = borrowAmount * 2;

        address mweth = addresses.getAddress("MOONWELL_WETH");
        WETH9 weth = WETH9(addresses.getAddress("WETH"));

        WETHRouter router = new WETHRouter(
            weth,
            MErc20(addresses.getAddress("MOONWELL_WETH"))
        );

        vm.deal(address(this), borrowRepayAmount);

        router.repayBorrowBehalf{value: borrowRepayAmount}(address(this));

        // 断言 偿还成功（借款 + 利息 为 0 表示还款成功）
        // 多付的钱自动退还给用户了
        assertEq(MErc20(mweth).borrowBalanceStored(address(this)), 0); /// fully repaid
        assertEq(address(this).balance, borrowRepayAmount / 2); /// excess eth returned
    }

    // q - 测试使用路由 mint ?
    // ETH -> router 包装成 WETH 进入 market -> mint 等量 mToken份额给 测试合约(用户) ->
    // ->  reedem() -> 资本回到原始状态
    function testMintWithRouter() public {
        WETH9 weth = WETH9(addresses.getAddress("WETH"));
        MErc20 mToken = MErc20(addresses.getAddress("MOONWELL_WETH"));
        // 记录市场当前持有的 WETH 余额
        // 用于验证存入市场后 WETH 增加了多少
        uint256 startingMTokenWethBalance = weth.balanceOf(address(mToken));

        uint256 mintAmount = marketBase.getMaxSupplyAmount(mToken);
        // q - 这里给这个合约打钱干什么？
        // 后面调用 路由mint, 没这笔 ETH 会导致失败
        vm.deal(address(this), mintAmount);     

        WETHRouter router = new WETHRouter(
            weth,
            MErc20(addresses.getAddress("MOONWELL_WETH"))
        );

        // q - 这里调用路由给这个测试合约 mint WETH 代币？
        // a - 给测试合约 mint Token 份额, WETH 被送进了 market
        router.mint{value: mintAmount}(address(this));

        // 断言发送出去的 ETH 没有残留在测试合约里
        assertEq(address(this).balance, 0, "incorrect test contract eth value");
        // 断言市场收到了等量的 WETH 作为底层资产
        assertEq(
            weth.balanceOf(address(mToken)),
            mintAmount + startingMTokenWethBalance,
            "incorrect mToken weth value after mint"
        );

        // 赎回
        // 调用链 redeem() -> redeemInternal() -> redeemFresh()
        mToken.redeem(type(uint256).max);

        // 断言拿回来的钱近似于 mintAmount
        assertApproxEqRel(
            address(this).balance,
            mintAmount,
            1e15, /// tiny loss due to rounding down
            "incorrect test contract eth value after redeem"
        );
        // 断言市场余额基本回到起点
        assertApproxEqRel(
            startingMTokenWethBalance,
            weth.balanceOf(address(mToken)),
            1e15, /// tiny gain due to rounding down in protocol's favor
            "incorrect mToken weth value after redeem"
        );
    }

    // 供给数量超过供给上限必然导致失败
    function _supplyingOverSupplyCapFails(uint256 mTokenIndex) private {
        MToken mToken = mTokens[mTokenIndex];

        uint256 amount = marketBase.getMaxSupplyAmount(mToken) + 1;

        // 意味着该市场 max 是 0（不可供给或异常状态），继续测意义不大
        if (amount == 1) {
            return;
        }

        address underlying = MErc20(address(mToken)).underlying();

        // q - 特殊处理? 为什么?
        // a - 这是测试层面的防御性处理，避免 fork/live 场景里 wrapped native 相关路径出现非目标干扰
        if (underlying == addresses.getAddress("WETH")) {
            vm.deal(addresses.getAddress("WETH"), amount);
        }

        deal(underlying, address(this), amount);
        // approve 给 mToken 防止余额不足
        // q - 授权 mToken 使用本测试合约的余额?
        IERC20(underlying).approve(address(mToken), amount);  

        vm.expectRevert("market supply cap reached");
        MErc20Delegator(payable(address(mToken))).mint(amount); // 通过代理如果调用 mint 逻辑
    }

    function testSupplyingOverSupplyCapFails() public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _supplyingOverSupplyCapFails(i);
        }
    }

    function _borrowingOverBorrowCapFails(uint256 mTokenIndex) private {
        MToken mToken = mTokens[mTokenIndex];

        uint256 mintAmount = marketBase.getMaxSupplyAmount(mToken);

        // q - 不可借款或异常状态?
        if (mintAmount == 0) {
            return;
        }

        _mintMToken(address(this), address(mToken), mintAmount);

        address[] memory _mTokens = new address[](1);
        _mTokens[0] = address(mToken);

        comptroller.enterMarkets(_mTokens);

        uint256 amount = marketBase.getMaxBorrowAmount(mToken) + 1;

        // q - 这里的判断是什么意思?
        if (amount == 1 || amount > type(uint128).max) {
            return;
        }

        address underlying = MErc20(address(mToken)).underlying();

        if (underlying == addresses.getAddress("WETH")) {
            vm.deal(addresses.getAddress("WETH"), amount);
        }

        deal(underlying, address(this), amount);
        IERC20(underlying).approve(address(mToken), amount);

        vm.expectRevert("market borrow cap reached");
        MErc20Delegator(payable(address(mToken))).borrow(amount);
    }

    function testBorrowingOverBorrowCapFails() public {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _borrowingOverBorrowCapFails(i);
        }
    }

    function _oraclesReturnCorrectValues(uint256 mTokenIndex) private view {
        MToken mToken = mTokens[mTokenIndex];

        ChainlinkOracle oracle = ChainlinkOracle(
            addresses.getAddress("CHAINLINK_ORACLE")
        );

        // 价格应当大于 1
        assertGt(
            oracle.getUnderlyingPrice(mToken),
            1,
            "oracle price must be non zero"
        );
    }

    function testOraclesReturnCorrectValues() public view {
        for (uint256 i = 0; i < mTokens.length; i++) {
            _oraclesReturnCorrectValues(i);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //  starkxun's test
    ///////////////////////////////////////////////////////////////////////////////////

    // 测试跨市场供应+借款+流动性变化
    function testExitMarketFailsWhenNeededCrossCollateral() public {
        address user = address(this);

        // 选 3 个市场
        MToken collateralA = mTokens[0];
        MToken collateralC = mTokens[1];
        MToken borrowMarketB = mTokens[2];

        uint256 maxSupplyA = marketBase.getMaxSupplyAmount(collateralA);
        uint256 maxSupplyC = marketBase.getMaxSupplyAmount(collateralC);

        // 某些 live 市场在该 fork 下可能没有可用供给空间，避免无意义失败
        if (maxSupplyA == 0 || maxSupplyC == 0) {
            return;
        }

        // 留出边界余量，避免“恰好打满 cap”因取整触发回滚
        uint256 mintAmountA = (maxSupplyA * 9) / 10;
        uint256 mintAmountC = (maxSupplyC * 9) / 10;

        if (mintAmountA == 0 || mintAmountC == 0) {
            return;
        }

        // 供给两个抵押市场
        _mintMToken(user, address(collateralA), mintAmountA);
        _mintMToken(user, address(collateralC), mintAmountC);

        // enter 两个抵押市场
        address[] memory entered = new address[](2);
        entered[0] = address(collateralA);
        entered[1] = address(collateralC);
        comptroller.enterMarkets(entered);

        assertTrue(comptroller.checkMembership(user, collateralA));
        assertTrue(comptroller.checkMembership(user, collateralC));

        {
            // 借款市场也 enter
            address[] memory enterBorrow = new address[](1);
            enterBorrow[0] = address(borrowMarketB);
            comptroller.enterMarkets(enterBorrow);

            // 借到接近上限，制造退出任意关键抵押都会 shortfall 的状态
            uint256 maxBorrow = marketBase.getMaxBorrowAmount(borrowMarketB);
            require(maxBorrow > 0, "maxBorrow = 0");
            uint256 borrowAmount = (maxBorrow * 95) / 100;
            assertEq(MErc20Delegator(payable(address(borrowMarketB))).borrow(borrowAmount), 0);
        }

        // 用 hypothetical 预演退出 A 是否会 shortfall
        uint256 redeemAllA = collateralA.balanceOf(user);
        (uint errHypo, , uint shortfallHypo) = 
            comptroller.getHypotheticalAccountLiquidity(
                user,
                address(collateralA),
                redeemAllA,
                0
        );
        assertEq(errHypo, 0);

        // 调用 exitMarket, 和预演结果对齐
        uint exitErr = comptroller.exitMarket(address(collateralA));

        _assertExitMarketOutcome(user, collateralA, shortfallHypo, exitErr);

        // 双向一致性
        _assertAssetsInAndMembershipConsistent(user, collateralA);
    }

    // 拆成函数使用，解决 stack too deep 的问题
    function _assertExitMarketOutcome(
        address user,
        MToken collateralA,
        uint256 shortfallHypo,
        uint256 exitErr
    ) private view {
        if (shortfallHypo > 0) {
            assertTrue(
                exitErr != 0,
                "should reject exit when hypothetical shortfall > 0"
            );
            assertTrue(
                comptroller.checkMembership(user, collateralA),
                "membership must reamin true on failed exit"
            );
        } else {
            assertEq(
                exitErr,
                0,
                "should allow exit when hypothetical shortfall = 0"
            );
            assertFalse(
                comptroller.checkMembership(user, collateralA),
                "membership must be false after successful exit"
            );
        }
    }

    // q - 这里的双向一致性不是太清楚？
    // a - 结构A: 用户资产列表 getAssetsIn(user) 是否包含该市场
    //     结构B: 布尔映射 checkMembership(user, market) 是否为 true
    // import:
    // exitMarket 会改 membership，也会改 accountAssets 列表
    // 只要其中一个改了、另一个没改，就会导致后续流动性计算或风控判断异常
    function _assertAssetsInAndMembershipConsistent(
        address user,
        MToken collateralA
    ) private view {
        MToken[] memory assets = comptroller.getAssetsIn(user);
        bool foundA = false;

        for (uint256 i = 0; i < assets.length; i++) {
            if (address(assets[i]) == address(collateralA)) {
                foundA = true;
                break;
            }
        }

        assertEq(foundA, comptroller.checkMembership(user, collateralA));
    }

    function _getHypotheticalShortfall(
        address user,
        MToken collateral,
        uint256 redeemTokens
    ) private view returns (uint256 shortfall) {
        (uint256 err, , uint256 shortfall_) = comptroller
            .getHypotheticalAccountLiquidity(
                user,
                address(collateral),
                redeemTokens,
                0
            );

        assertEq(err, 0, "hypothetical liquidity calculation failed");
        return shortfall_;
    }


    // 测试 抵押率 变更，退出 市场 会导致revert
    function testExitAfterCollateralFactorDrop() public {
        address user = address(this);

        MToken collateralA = mTokens[0];
        MToken collateralB = mTokens[1];
        MToken borrowC = mTokens[2];
        
        // market 最大 supply
        uint256 mintA = marketBase.getMaxSupplyAmount(collateralA);
        uint256 mintB = marketBase.getMaxSupplyAmount(collateralB);

        // supply 为 0, 测试无意义 
        if(mintA == 0 || mintB == 0){
            return;
        }

        // 这里传入 address(MToken)
        // _mintMToken 会处理找到 该 market 的 underly 代币
        _mintMToken(user, address(collateralA), mintA);
        _mintMToken(user, address(collateralB), mintB);


        // 进入 market, 通过一个数组统一进入 market
        address[] memory entered = new address[](3);
        entered[0] = address(collateralA);
        entered[1] = address(collateralB);
        entered[2] = address(borrowC);
        comptroller.enterMarkets(entered);

        // 借款? borrowC 
        {
            uint256 maxBorrow = marketBase.getMaxBorrowAmount(borrowC);
            require(maxBorrow > 0, "Insufficient borrow amount");
            uint256 borrowAmount = (maxBorrow * 5) / 10;
            assertEq(
                MErc20Delegator(payable(address(borrowC))).borrow(borrowAmount),
                0
            );
        }

        // 模拟赎回 A
        uint256 redeemA = collateralA.balanceOf(user);
        uint256 shortfallHypoBefore = _getHypotheticalShortfall(
            user,
            collateralA,
            redeemA
        );

        // 修改 借款市场C 的抵押因子
        // 默认抵押因子为: collateralFactorMaxMantissa = 0.9
        vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));    // q - 这是什么, 治理者吗?
        comptroller._setCollateralFactor(collateralB, 0.01e18);     // 这里可能有问题, 该函数会校验 抵押因子 不能小于 0.9, 设置为 0.1 可能会失败
        
        // 再次尝试赎回 A（模拟，断言 shortfall 差值）
        uint256 shortfallHypoAfter = _getHypotheticalShortfall(
            user,
            collateralA,
            redeemA
        );

        assertGe(
            shortfallHypoAfter,
            shortfallHypoBefore,
            "shortfall should not improved after CF drop"
        );

        // 退出 marketA，应当 revert
        uint256 exitErr = comptroller.exitMarket(address(collateralA));

        _assertExitMarketOutcome(user, collateralA, shortfallHypoAfter, exitErr);
        
        // 双向一致
        _assertAssetsInAndMembershipConsistent(user, collateralA);
    }


    receive() external payable {}
}
