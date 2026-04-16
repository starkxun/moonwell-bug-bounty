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

    //  如果需要测试价格变动后 exit
    //  用 TEMPORAL_GOVERNOR 调用 ChainlinkOracle 的 setUnderlyingPrice(collateralB, newPrice)
    //  其他断言不变


    



    receive() external payable {}


}