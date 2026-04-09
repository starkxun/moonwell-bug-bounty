// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata as IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MToken} from "@protocol/MToken.sol";
import {MErc20Delegator} from "@protocol/MErc20Delegator.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MarketBase} from "@test/utils/MarketBase.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

contract Handler is Test {
	uint256 public constant MAX_USERS = 16;
	uint256 public constant MIN_SUPPLY = 1e8;
	uint256 public constant MIN_BORROW = 1e8;

	Comptroller public immutable comptroller;
	Addresses public immutable addresses;
	MarketBase public immutable marketBase;

	MToken[] internal markets;
	address[] internal users;

	constructor(
		Comptroller _comptroller,
		Addresses _addresses,
		MToken[] memory _markets
	) {
		comptroller = _comptroller;
		addresses = _addresses;
		marketBase = new MarketBase(_comptroller);

		for (uint256 i = 0; i < _markets.length; i++) {
			markets.push(_markets[i]);
		}

		for (uint256 i = 0; i < MAX_USERS; i++) {
			users.push(address(uint160(10_000 + i)));
		}
	}

	function getUsers() external view returns (address[] memory) {
		return users;
	}

	function getMarkets() external view returns (MToken[] memory) {
		return markets;
	}

	/// @notice 参数约束：marketIndex -> [0, markets.length-1]
	function enterMarket(uint8 userSeed, uint8 marketIndexSeed) external {
		if (markets.length == 0) return;

		address user = _pickUser(userSeed);
		MToken mToken = _pickMarket(marketIndexSeed);

		address[] memory mTokens = new address[](1);
		mTokens[0] = address(mToken);

		vm.prank(user);
		comptroller.enterMarkets(mTokens);
	}

	/// @notice 参数约束：mintAmount 绑定到 [MIN_SUPPLY, maxSupply]
	function mint(uint8 userSeed, uint8 marketIndexSeed, uint256 mintAmount) external {
		if (markets.length == 0) return;

		address user = _pickUser(userSeed);
		MToken mToken = _pickMarket(marketIndexSeed);

		(bool ok, address underlying) = _underlyingOf(address(mToken));
		if (!ok) {
			// TODO: 若目标市场不是 MErc20 风格（无 underlying()），补充专用 handler。
			return;
		}

		uint256 maxSupply = marketBase.getMaxSupplyAmount(mToken);
		if (maxSupply < MIN_SUPPLY) return;

		mintAmount = _bound(mintAmount, MIN_SUPPLY, maxSupply);

		deal(underlying, user, mintAmount);

		vm.prank(user);
		IERC20(underlying).approve(address(mToken), mintAmount);

		vm.prank(user);
		try MErc20Delegator(payable(address(mToken))).mint(mintAmount) returns (
			uint256
		) {
			// no-op
		} catch {
			// TODO: 记录失败类型，区分预期拒绝与异常拒绝。
		}
	}

	/// @notice 参数约束：redeemTokens 绑定到 [1, userMTokenBalance]
	function redeem(
		uint8 userSeed,
		uint8 marketIndexSeed,
		uint256 redeemTokens
	) external {
		if (markets.length == 0) return;

		address user = _pickUser(userSeed);
		MToken mToken = _pickMarket(marketIndexSeed);

		uint256 userBalance = mToken.balanceOf(user);
		if (userBalance == 0) return;

		redeemTokens = _bound(redeemTokens, 1, userBalance);

		vm.prank(user);
		try MErc20Delegator(payable(address(mToken))).redeem(redeemTokens) returns (
			uint256
		) {
			// no-op
		} catch {
			// TODO: 记录是否由 liquidity/cash 不足触发。
		}
	}

	/// @notice 参数约束：borrowAmount 绑定到 [MIN_BORROW, maxUserBorrow]
	function borrow(uint8 userSeed, uint8 marketIndexSeed, uint256 borrowAmount) external {
		if (markets.length == 0) return;

		address user = _pickUser(userSeed);
		MToken mToken = _pickMarket(marketIndexSeed);

		// 借款前尝试入市，避免大量无意义拒绝。
		address[] memory mTokens = new address[](1);
		mTokens[0] = address(mToken);
		vm.prank(user);
		comptroller.enterMarkets(mTokens);

		uint256 maxUserBorrow = marketBase.getMaxUserBorrowAmount(mToken, user);
		if (maxUserBorrow < MIN_BORROW) return;

		borrowAmount = _bound(borrowAmount, MIN_BORROW, maxUserBorrow);

		vm.prank(user);
		try MErc20Delegator(payable(address(mToken))).borrow(borrowAmount) returns (
			uint256
		) {
			// no-op
		} catch {
			// TODO: 收集拒绝原因（cap、liquidity、pause）。
		}
	}

	/// @notice 参数约束：repayAmount 绑定到 [1, borrowBalanceStored(user)]
	function repayBorrow(
		uint8 userSeed,
		uint8 marketIndexSeed,
		uint256 repayAmount
	) external {
		if (markets.length == 0) return;

		address user = _pickUser(userSeed);
		MToken mToken = _pickMarket(marketIndexSeed);

		(bool ok, address underlying) = _underlyingOf(address(mToken));
		if (!ok) {
			// TODO: 若存在非 MErc20 市场，补充还款适配逻辑。
			return;
		}

		uint256 debt = mToken.borrowBalanceStored(user);
		if (debt == 0) return;

		repayAmount = _bound(repayAmount, 1, debt);
		deal(underlying, user, repayAmount);

		vm.prank(user);
		IERC20(underlying).approve(address(mToken), repayAmount);

		vm.prank(user);
		try MErc20Delegator(payable(address(mToken))).repayBorrow(repayAmount) returns (
			uint256
		) {
			// no-op
		} catch {
			// TODO: 补充异常路径分类。
		}
	}

	/// @notice 参数约束：repayAmount 绑定到 [1, borrowerDebt]
	function repayBorrowBehalf(
		uint8 payerSeed,
		uint8 borrowerSeed,
		uint8 marketIndexSeed,
		uint256 repayAmount
	) external {
		if (markets.length == 0) return;

		address payer = _pickUser(payerSeed);
		address borrower = _pickUser(borrowerSeed);
		MToken mToken = _pickMarket(marketIndexSeed);

		(bool ok, address underlying) = _underlyingOf(address(mToken));
		if (!ok) {
			// TODO: 若存在非 MErc20 市场，补充还款适配逻辑。
			return;
		}

		uint256 debt = mToken.borrowBalanceStored(borrower);
		if (debt == 0) return;

		repayAmount = _bound(repayAmount, 1, debt);
		deal(underlying, payer, repayAmount);

		vm.prank(payer);
		IERC20(underlying).approve(address(mToken), repayAmount);

		vm.prank(payer);
		try
			MErc20Delegator(payable(address(mToken))).repayBorrowBehalf(
				borrower,
				repayAmount
			)
		returns (uint256) {
			// no-op
		} catch {
			// TODO: 补充异常路径分类。
		}
	}

	/// @notice 参数约束：transferAmount 绑定到 [1, fromBalance]
	function transferMToken(
		uint8 fromSeed,
		uint8 toSeed,
		uint8 marketIndexSeed,
		uint256 transferAmount
	) external {
		if (markets.length == 0) return;

		address from = _pickUser(fromSeed);
		address to = _pickUser(toSeed);
		MToken mToken = _pickMarket(marketIndexSeed);

		if (from == to) return;

		uint256 bal = mToken.balanceOf(from);
		if (bal == 0) return;

		transferAmount = _bound(transferAmount, 1, bal);

		vm.prank(from);
		try
			MErc20Delegator(payable(address(mToken))).transfer(to, transferAmount)
		returns (bool) {
			// no-op
		} catch {
			// TODO: 记录 transfer 被风控拒绝的场景（例如 pause）。
		}
	}

	/// @notice 参数约束：无（claim 目标 holder 由 userSeed 选择）
	function claimReward(uint8 callerSeed, uint8 holderSeed) external {
		address caller = _pickUser(callerSeed);
		address holder = _pickUser(holderSeed);

		vm.prank(caller);
		try comptroller.claimReward(holder) {
			// no-op
		} catch {
			// TODO: 若 rewardDistributor 未配置，按预期失败处理。
		}
	}

	/// @notice 参数约束：warpDelta 绑定到 [1, 30 days]
	function warpTime(uint32 warpDelta) external {
		warpDelta = uint32(_bound(warpDelta, 1, 30 days));
		vm.warp(block.timestamp + warpDelta);
	}

	function _pickUser(uint8 seed) internal view returns (address) {
		return users[_bound(seed, 0, users.length - 1)];
	}

	function _pickMarket(uint8 seed) internal view returns (MToken) {
		return markets[_bound(seed, 0, markets.length - 1)];
	}

	function _underlyingOf(
		address mToken
	) internal view returns (bool ok, address underlying) {
		bool success;
		bytes memory ret;
		(success, ret) = mToken.staticcall(
			abi.encodeWithSignature("underlying()")
		);
		if (success && ret.length >= 32) {
			ok = true;
			underlying = abi.decode(ret, (address));
		}
	}
}
