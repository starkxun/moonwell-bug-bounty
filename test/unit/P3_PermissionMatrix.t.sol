// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test, Vm} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MToken} from "@protocol/MToken.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";

/****************************************************************************
 *                              starkxun test                                *
 *  step_1.md P3 #13 - 权限边界的"可调用但应失败"路径未系统化                    *
 *                                                                          *
 *  Moonwell 的权限检查混用两套语义：                                          *
 *   1) 错误码模式（_setCollateralFactor / _setReserveFactor /                 *
 *      _setProtocolSeizeShare / _setInterestRateModel / _setPauseGuardian）  *
 *      → 非 admin 调用不会 revert，仅返回非零错误码。测试必须额外断言            *
 *      "状态未变化"和"未 emit 事件"，否则会漏。                                *
 *                                                                          *
 *   2) Revert 模式（_setCloseFactor / _setMint(Borrow/Transfer/Seize)Paused / *
 *      _setMarket{Borrow,Supply}Caps / _set{Borrow,Supply}CapGuardian）     *
 *      → 直接 require 失败时 revert。                                        *
 *                                                                          *
 *  特别覆盖"可调用但应失败"路径：pauseGuardian 能调 _setMintPaused，但传        *
 *  state=false 必须 revert "only admin can unpause"。                       *
 ****************************************************************************/

contract P3_PermissionMatrix is Test {
    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;
    InterestRateModel internal irmAlt; // 用来尝试切换 IRM

    MockERC20 internal underlying;
    MErc20Immutable internal mTok;

    address internal admin = address(this); // setUp 部署者就是 admin
    address internal pauseG;
    address internal borrowCapG;
    address internal supplyCapG;
    address internal randomUser;

    uint256 internal constant INIT_EXCHANGE_RATE = 2e16;
    uint256 internal constant INIT_CF = 0.5e18;
    uint256 internal constant INIT_RF = 0.1e18;
    uint256 internal constant INIT_PSS = 0.025e18; // protocol seize share, 默认 2.5%

    // 关键状态变更事件 topic（用于"未 emit"断言）
    // 注意：错误码模式的函数失败时会 emit 一个 Failure 事件，那是预期的；
    // 我们真正要确认的是"代表状态被改"的那条事件没有出现。
    bytes32 internal constant TOPIC_NEW_COLLATERAL_FACTOR =
        keccak256("NewCollateralFactor(address,uint256,uint256)");
    bytes32 internal constant TOPIC_NEW_RESERVE_FACTOR =
        keccak256("NewReserveFactor(uint256,uint256)");
    bytes32 internal constant TOPIC_NEW_IRM =
        keccak256("NewMarketInterestRateModel(address,address)");
    bytes32 internal constant TOPIC_NEW_PROTOCOL_SEIZE_SHARE =
        keccak256("NewProtocolSeizeShare(uint256,uint256)");
    bytes32 internal constant TOPIC_NEW_PAUSE_GUARDIAN =
        keccak256("NewPauseGuardian(address,address)");

    function setUp() public {
        pauseG = makeAddr("pauseGuardian");
        borrowCapG = makeAddr("borrowCapGuardian");
        supplyCapG = makeAddr("supplyCapGuardian");
        randomUser = makeAddr("randomUser");

        underlying = new MockERC20();
        comptroller = new Comptroller();
        oracle = new SimplePriceOracle();
        irm = new WhitePaperInterestRateModel(0.02e18, 0.20e18);
        irmAlt = new WhitePaperInterestRateModel(0.05e18, 0.30e18);

        assertEq(comptroller._setPriceOracle(oracle), 0);

        mTok = new MErc20Immutable(
            address(underlying), comptroller, irm, INIT_EXCHANGE_RATE,
            "mT", "mT", 8, payable(address(this))
        );
        assertEq(comptroller._supportMarket(mTok), 0);
        oracle.setUnderlyingPrice(mTok, 1e18);
        assertEq(comptroller._setCollateralFactor(mTok, INIT_CF), 0);
        assertEq(mTok._setReserveFactor(INIT_RF), 0);
        // protocolSeizeShare 默认 2.8e16，这里手动设一个干净的初值
        assertEq(mTok._setProtocolSeizeShare(INIT_PSS), 0);

        // 把三个 guardian 角色都接上
        assertEq(comptroller._setPauseGuardian(pauseG), 0);
        comptroller._setBorrowCapGuardian(borrowCapG);
        comptroller._setSupplyCapGuardian(supplyCapG);
    }

    // ============================================================
    //  组 A：错误码模式 —— 必须断言"状态未变化 + 没 emit 事件"
    // ============================================================

    /// 非 admin 调 _setCollateralFactor：返回非零错误码，CF 不变，没 emit。
    /// 同时遍历 4 种身份（pauseG / borrowCapG / supplyCapG / 随机用户）。
    function testNonAdmin_CannotSetCollateralFactor() public {
        address[4] memory callers = [pauseG, borrowCapG, supplyCapG, randomUser];

        for (uint256 i = 0; i < callers.length; i++) {
            uint256 cfBefore = _readCF();
            vm.recordLogs();

            vm.prank(callers[i]);
            uint256 err = comptroller._setCollateralFactor(mTok, 0.7e18);

            assertGt(err, 0, "non-admin must get non-zero error code");
            assertEq(_readCF(), cfBefore, "CF must not change on rejected call");
            _assertTopicNotEmitted(
                vm.getRecordedLogs(),
                TOPIC_NEW_COLLATERAL_FACTOR,
                "NewCollateralFactor must not be emitted"
            );
        }
    }

    /// 非 admin 调 MToken._setReserveFactor：错误码 + 状态不变 + 无事件。
    function testNonAdmin_CannotSetReserveFactor() public {
        address[4] memory callers = [pauseG, borrowCapG, supplyCapG, randomUser];

        for (uint256 i = 0; i < callers.length; i++) {
            uint256 rfBefore = mTok.reserveFactorMantissa();
            vm.recordLogs();

            vm.prank(callers[i]);
            uint256 err = mTok._setReserveFactor(0.3e18);

            assertGt(err, 0, "non-admin must get non-zero error code");
            assertEq(mTok.reserveFactorMantissa(), rfBefore, "RF must not change");
            _assertTopicNotEmitted(
                vm.getRecordedLogs(),
                TOPIC_NEW_RESERVE_FACTOR,
                "NewReserveFactor must not be emitted"
            );
        }
    }

    /// 非 admin 调 MToken._setProtocolSeizeShare：错误码 + 状态不变 + 无事件。
    function testNonAdmin_CannotSetProtocolSeizeShare() public {
        address[4] memory callers = [pauseG, borrowCapG, supplyCapG, randomUser];

        for (uint256 i = 0; i < callers.length; i++) {
            uint256 pssBefore = mTok.protocolSeizeShareMantissa();
            vm.recordLogs();

            vm.prank(callers[i]);
            uint256 err = mTok._setProtocolSeizeShare(0.05e18);

            assertGt(err, 0, "non-admin must get non-zero error code");
            assertEq(
                mTok.protocolSeizeShareMantissa(),
                pssBefore,
                "protocolSeizeShare must not change"
            );
            _assertTopicNotEmitted(
                vm.getRecordedLogs(),
                TOPIC_NEW_PROTOCOL_SEIZE_SHARE,
                "NewProtocolSeizeShare must not be emitted"
            );
        }
    }

    /// 非 admin 调 MToken._setInterestRateModel：错误码 + 模型未替换 + 无事件。
    function testNonAdmin_CannotSetInterestRateModel() public {
        address[4] memory callers = [pauseG, borrowCapG, supplyCapG, randomUser];

        for (uint256 i = 0; i < callers.length; i++) {
            address irmBefore = address(mTok.interestRateModel());
            vm.recordLogs();

            vm.prank(callers[i]);
            uint256 err = mTok._setInterestRateModel(irmAlt);

            assertGt(err, 0, "non-admin must get non-zero error code");
            assertEq(
                address(mTok.interestRateModel()),
                irmBefore,
                "IRM must not change"
            );
            _assertTopicNotEmitted(
                vm.getRecordedLogs(),
                TOPIC_NEW_IRM,
                "NewMarketInterestRateModel must not be emitted"
            );
        }
    }

    /// 非 admin 调 _setPauseGuardian：错误码 + guardian 地址未变 + 无事件。
    /// 防止 guardian 自己提升自己 / 互相替换。
    function testNonAdmin_CannotChangePauseGuardian() public {
        address[4] memory callers = [pauseG, borrowCapG, supplyCapG, randomUser];

        for (uint256 i = 0; i < callers.length; i++) {
            address guardianBefore = comptroller.pauseGuardian();
            vm.recordLogs();

            vm.prank(callers[i]);
            uint256 err = comptroller._setPauseGuardian(callers[i]);

            assertGt(err, 0, "non-admin must get non-zero error code");
            assertEq(
                comptroller.pauseGuardian(),
                guardianBefore,
                "pauseGuardian must not change"
            );
            _assertTopicNotEmitted(
                vm.getRecordedLogs(),
                TOPIC_NEW_PAUSE_GUARDIAN,
                "NewPauseGuardian must not be emitted"
            );
        }
    }

    // ============================================================
    //  组 B：Revert 模式 —— 用 expectRevert + 状态校验
    // ============================================================

    /// 非 admin 调 _setCloseFactor：直接 revert，状态不变。
    function testNonAdmin_CannotSetCloseFactor() public {
        address[4] memory callers = [pauseG, borrowCapG, supplyCapG, randomUser];
        uint256 cfBefore = comptroller.closeFactorMantissa();

        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(bytes("only admin can set close factor"));
            comptroller._setCloseFactor(0.6e18);
        }
        assertEq(
            comptroller.closeFactorMantissa(),
            cfBefore,
            "closeFactor must not change after rejected calls"
        );
    }

    /// 非 admin 调 _setBorrowCapGuardian / _setSupplyCapGuardian：revert。
    /// guardian 自己也不能"互换"或"自我提升"。
    function testNonAdmin_CannotChangeCapGuardians() public {
        address borrowCapGBefore = comptroller.borrowCapGuardian();
        address supplyCapGBefore = comptroller.supplyCapGuardian();

        // 让现任 borrowCapG 试图把自己升级成 supplyCapG（应失败）
        vm.prank(borrowCapG);
        vm.expectRevert(bytes("only admin can set supply cap guardian"));
        comptroller._setSupplyCapGuardian(borrowCapG);

        // 让现任 supplyCapG 试图把自己升级成 borrowCapG（应失败）
        vm.prank(supplyCapG);
        vm.expectRevert(bytes("only admin can set borrow cap guardian"));
        comptroller._setBorrowCapGuardian(supplyCapG);

        // 普通用户也不能动
        vm.prank(randomUser);
        vm.expectRevert(bytes("only admin can set borrow cap guardian"));
        comptroller._setBorrowCapGuardian(randomUser);

        assertEq(comptroller.borrowCapGuardian(), borrowCapGBefore);
        assertEq(comptroller.supplyCapGuardian(), supplyCapGBefore);
    }

    /// borrowCapGuardian 只能调 _setMarketBorrowCaps，不能去调 supplyCaps。
    /// 反之同理。
    function testCapGuardians_CannotCrossAccess() public {
        MToken[] memory mks = new MToken[](1);
        mks[0] = mTok;
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1_000e18;

        // borrowCapG 调 supplyCaps：必须 revert
        vm.prank(borrowCapG);
        vm.expectRevert(
            bytes("only admin or supply cap guardian can set supply caps")
        );
        comptroller._setMarketSupplyCaps(mks, caps);

        // supplyCapG 调 borrowCaps：必须 revert
        vm.prank(supplyCapG);
        vm.expectRevert(
            bytes("only admin or borrow cap guardian can set borrow caps")
        );
        comptroller._setMarketBorrowCaps(mks, caps);

        // 但他们调"自己的"那条仍然要能成功，否则回归就被破坏了
        vm.prank(borrowCapG);
        comptroller._setMarketBorrowCaps(mks, caps);
        assertEq(comptroller.borrowCaps(address(mTok)), 1_000e18);

        vm.prank(supplyCapG);
        comptroller._setMarketSupplyCaps(mks, caps);
        assertEq(comptroller.supplyCaps(address(mTok)), 1_000e18);
    }

    // ============================================================
    //  组 C："可调用但应失败"路径 —— pauseGuardian 能 pause，不能 unpause
    // ============================================================

    /// pauseGuardian 调用 _setMintPaused(true) 必须成功；
    /// 紧接着 pauseGuardian 调用 _setMintPaused(false) 必须 revert "only admin can unpause"；
    /// 只有 admin 才能解除暂停。
    /// 这就是 step_1.md 所说"可调用但应失败"的字面体现：
    /// guardian 通过了 "msg.sender 是 guardian 或 admin" 检查，但被第二条
    /// "msg.sender 是 admin 或 state==true" 拦下。
    function testPauseGuardian_CanPauseButCannotUnpause_Mint() public {
        // 1) guardian 能 pause
        vm.prank(pauseG);
        comptroller._setMintPaused(mTok, true);
        assertTrue(comptroller.mintGuardianPaused(address(mTok)));

        // 2) guardian 不能 unpause
        vm.prank(pauseG);
        vm.expectRevert(bytes("only admin can unpause"));
        comptroller._setMintPaused(mTok, false);
        assertTrue(
            comptroller.mintGuardianPaused(address(mTok)),
            "still paused after rejected unpause"
        );

        // 3) 普通用户连 pause 都不能调
        vm.prank(randomUser);
        vm.expectRevert(bytes("only pause guardian and admin can pause"));
        comptroller._setMintPaused(mTok, true);

        // 4) admin 能 unpause
        comptroller._setMintPaused(mTok, false);
        assertFalse(comptroller.mintGuardianPaused(address(mTok)));
    }

    /// 同样的"可调用但应失败"规则在 _setBorrowPaused / _setTransferPaused / _setSeizePaused
    /// 上必须复制成立，避免某条 paused 路径漏了第二行 require。
    function testPauseGuardian_CanPauseButCannotUnpause_AllSwitches() public {
        // borrow
        vm.prank(pauseG);
        comptroller._setBorrowPaused(mTok, true);
        assertTrue(comptroller.borrowGuardianPaused(address(mTok)));
        vm.prank(pauseG);
        vm.expectRevert(bytes("only admin can unpause"));
        comptroller._setBorrowPaused(mTok, false);

        // transfer
        vm.prank(pauseG);
        comptroller._setTransferPaused(true);
        assertTrue(comptroller.transferGuardianPaused());
        vm.prank(pauseG);
        vm.expectRevert(bytes("only admin can unpause"));
        comptroller._setTransferPaused(false);

        // seize
        vm.prank(pauseG);
        comptroller._setSeizePaused(true);
        assertTrue(comptroller.seizeGuardianPaused());
        vm.prank(pauseG);
        vm.expectRevert(bytes("only admin can unpause"));
        comptroller._setSeizePaused(false);

        // 由 admin 一次性恢复，确保恢复路径 admin 走得通
        comptroller._setBorrowPaused(mTok, false);
        comptroller._setTransferPaused(false);
        comptroller._setSeizePaused(false);
    }

    // ============================================================
    //  helpers
    // ============================================================

    function _readCF() internal view returns (uint256) {
        (, uint256 cf) = comptroller.markets(address(mTok));
        return cf;
    }

    /// 断言 recorded logs 中不存在某个 topic[0]。
    /// 错误码模式的函数即使失败也会 emit Failure(...)，那不算状态变更；
    /// 这里要排除的是"代表状态改了"的事件。
    function _assertTopicNotEmitted(
        Vm.Log[] memory entries,
        bytes32 topic,
        string memory msg_
    ) internal pure {
        for (uint256 i = 0; i < entries.length; i++) {
            require(entries[i].topics.length > 0, "log without topic");
            assertNotEq(entries[i].topics[0], topic, msg_);
        }
    }
}
