// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "forge-std/Test.sol";

import {MToken} from "@protocol/MToken.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {Handler} from "@test/invariant/Handler.sol";
import {OPTIMISM_CHAIN_ID} from "@utils/ChainIds.sol";

contract BaseInvariant is PostProposalCheck {
	Handler public handler;
	Comptroller public comptroller;

	MToken[] internal mTokens;

	function setUp() public override {
		super.setUp();

		uint256 primaryForkId = vm.envUint("PRIMARY_FORK_ID");
		vm.selectFork(primaryForkId);

		comptroller = Comptroller(addresses.getAddress("UNITROLLER"));

		// 剔除 DEPRECATED_MOONWELL_VELO
		MToken[] memory markets = comptroller.getAllMarkets();
		MToken deprecatedMoonwellVelo = MToken(
			addresses.getAddress("DEPRECATED_MOONWELL_VELO", OPTIMISM_CHAIN_ID)
		);

		for (uint256 i = 0; i < markets.length; i++) {
			if (markets[i] == deprecatedMoonwellVelo) {
				continue;
			}
			mTokens.push(markets[i]);
		}

		// q - 这里是什么意思? Handler 的定义接受多少参数?
		handler = new Handler(comptroller, addresses, mTokens);

		bytes4[] memory selectors = new bytes4[](9);
		selectors[0] = handler.enterMarket.selector;
		selectors[1] = handler.mint.selector;
		selectors[2] = handler.redeem.selector;
		selectors[3] = handler.borrow.selector;
		selectors[4] = handler.repayBorrow.selector;
		selectors[5] = handler.repayBorrowBehalf.selector;
		selectors[6] = handler.transferMToken.selector;
		selectors[7] = handler.claimReward.selector;
		selectors[8] = handler.warpTime.selector;

		targetContract(address(handler));
		targetSelector(
			FuzzSelector({addr: address(handler), selectors: selectors})
		);
	}

	// ---------------------------------------------------------------------
	// Global Invariants (保守断言 + TODO)
	// ---------------------------------------------------------------------

	function invariant_marketsAreListedAndUnique() public view {
		MToken[] memory markets = comptroller.getAllMarkets();

		for (uint256 i = 0; i < markets.length; i++) {
			(bool isListed, ) = comptroller.markets(address(markets[i]));
			assertTrue(isListed, "market in allMarkets must be listed");

			for (uint256 j = i + 1; j < markets.length; j++) {
				assertTrue(
					address(markets[i]) != address(markets[j]),
					"duplicate market in allMarkets"
				);
			}
		}
	}

	function invariant_liquidityAndShortfallMutuallyExclusive() public view {
		address[] memory users = handler.getUsers();

		for (uint256 i = 0; i < users.length; i++) {
			(, uint256 liquidity, uint256 shortfall) = comptroller
				.getAccountLiquidity(users[i]);
			assertEq(
				liquidity * shortfall,
				0,
				"liquidity and shortfall cannot both be positive"
			);
		}
	}

	// ---------------------------------------------------------------------
	// Account / Accounting / Permission / Post-action Templates
	// ---------------------------------------------------------------------

	function invariant_accountMembershipBidirectionalTemplate() public view {
		// TODO:
		// 1) 为每个 user 拉取 comptroller.getAssetsIn(user)
		// 2) 对每个 asset 校验 comptroller.checkMembership(user, asset) == true
		// 3) 再反向验证 membership==true 的资产都出现在 getAssetsIn 中
		// 注意：这里需要额外索引结构，避免 O(n^2) 误伤 gas/time。
	}

	function invariant_coreAccountingTemplate() public view {
		// TODO:
		// 对每个 market 检查近似会计关系（容差 epsilon）：
		// exchangeRateStored ~= (cash + totalBorrows - totalReserves) / totalSupply
		// 注意：totalSupply==0 时需跳过。
		// 注意：fee/rebasing 资产可能导致误报。
	}

	function invariant_permissionTemplate() public pure {
		// TODO:
		// 在独立权限测试中完成：
		// - 非 admin 调治理函数应失败
		// - pauseGuardian 不能 unpause
		// 说明：invariant 主循环里不建议直接做大量 revert 断言，避免噪声。
	}

	function invariant_postRedeemAndPostLiquidationTemplate() public pure {
		// TODO:
		// 通过 handler 内部记录 pre/post 快照后，在这里检查：
		// - redeem 成功后 totalSupply 与用户 mToken 余额同步下降
		// - liquidation 成功后 borrower 债务下降、collateral 转移方向正确
	}

	function invariant_sharePriceUtilizationDebtIndexTemplate() public pure {
		// TODO:
		// 检查模板：
		// 1) borrowIndex 单调不减
		// 2) totalSupply>0 时 exchangeRateStored>0
		// 3) utilization in [0,1]（分母>0时）
		// 需要在 handler 中维护上次观测值并设置容差。
	}
}
