// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";

/****************************************************************************
 *                              starkxun test                                *
 *  step_1.md P2 #10 - 极端时间跳跃（长时间不交互）后的首次交互行为               *
 ****************************************************************************/

contract P2_ExtremeTimeWarp is Test {
    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;

    MockERC20 internal underlying;
    MErc20Immutable internal mTok;

    address internal Alice;

    uint256 internal constant INIT_EXCHANGE_RATE = 2e16;

    function setUp() public {
        Alice = makeAddr("Alice");
        underlying = new MockERC20();
        comptroller = new Comptroller();
        oracle = new SimplePriceOracle();
        irm = new WhitePaperInterestRateModel(0.02e18, 0.20e18);

        assertEq(comptroller._setPriceOracle(oracle), 0);
        mTok = new MErc20Immutable(address(underlying), comptroller, irm, INIT_EXCHANGE_RATE, "mT", "mT", 8, payable(address(this)));
        assertEq(comptroller._supportMarket(mTok), 0);
        oracle.setUnderlyingPrice(mTok, 1e18);
        assertEq(comptroller._setCollateralFactor(mTok, 0.8e18), 0);
        // seed protocol liquidity so borrow can succeed
        underlying.mint(address(this), 10_000e18);
        underlying.approve(address(mTok), 10_000e18);
        assertEq(mTok.mint(10_000e18), 0);
    }

    function testExtremeWarp_FirstInteractionDoesNotOverflowOrRevert() public {
        // Alice 初次 supply
        underlying.mint(Alice, 1_000e18);
        vm.startPrank(Alice);
        underlying.approve(address(mTok), 1_000e18);
        assertEq(mTok.mint(1_000e18), 0);
        vm.stopPrank();

        // warp 180 天（极端不交互）
        vm.warp(block.timestamp + 180 days);

        // 首次 borrow：不应 revert，且会计数据合理
        vm.prank(Alice);
        comptroller.enterMarkets(_mkArr(address(mTok)));
        vm.startPrank(Alice);
        // 尝试借一小部分（用 low-level call 捕捉 ERC20 revert 信息）
        uint256 preBorrowIndex = mTok.borrowIndex();
        (bool ok, bytes memory data) = address(mTok).call(abi.encodeWithSignature("borrow(uint256)", 1e18));
        console.log("borrow ok", ok);
        if (!ok) console.logBytes(data);
        require(ok, "borrow call failed");
        uint256 postBorrowIndex = mTok.borrowIndex();
        vm.stopPrank();

        // borrowIndex 应该保持或上升（单调不减）
        assertGe(postBorrowIndex, preBorrowIndex, "borrowIndex must be monotonic");

        // 再 warp 更久并触发 repay，确保没有极大异常
        vm.warp(block.timestamp + 365 days);
        vm.startPrank(Alice);
        underlying.approve(address(mTok), 1e18);
        assertEq(mTok.repayBorrow(1e18), 0);
        vm.stopPrank();
    }

    function _mkArr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
