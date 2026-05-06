// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";

/******************************************************************************
 *                              starkxun test                                  *
 *  step_1.md P1 #8 - 非标准 ERC20 行为                                        *
 *                                                                             *
 *  目标：当底层资产是非标准 ERC20 时，验证 mToken 行为是否正确：              *
 *    1. fee-on-transfer 在 mint 路径上 - MErc20.doTransferIn 用                *
 *       balanceAfter - balanceBefore 计算实际到账，应该正确处理（mToken       *
 *       发行量基于实际到账）                                                  *
 *    2. fee-on-transfer 在 redeem/borrow 路径上 - doTransferOut 不做差额检查， *
 *       存在已知不对称：cash 减少 amount，但用户收到 amount * (1-fee)         *
 *    3. 无返回值的 ERC20 (USDT 风格) - 应该被 assembly 兼容                    *
 *    4. transferFrom 显式返回 false - mint 必须 revert("TOKEN_TRANSFER_IN_FAILED") *
 *    5. rebasing token - mToken 没有抵御 cash 直接增减的机制（已知风险）      *
 ******************************************************************************/

/*------------------------------------------------------------------------------
                              非标 ERC20 mocks
------------------------------------------------------------------------------*/

/// 标准 ERC20，但每次 transfer/transferFrom 收 5% 手续费给 0xdead
contract FeeOnTransferToken {
    string public name = "FOT";
    string public symbol = "FOT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public constant FEE_BPS = 500; // 5%
    address public constant SINK = address(0xdead);

    function balanceOf(address a) external view returns (uint256) { return _bal[a]; }

    function mint(address to, uint256 amt) external {
        _bal[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(_bal[from] >= amt, "balance");
        _bal[from] -= amt;
        uint256 fee = (amt * FEE_BPS) / 10_000;
        _bal[SINK] += fee;
        _bal[to]   += amt - fee;
    }
}

/// USDT 风格：transfer/transferFrom 不返回任何值
contract NoReturnValueToken {
    string public name = "NRV";
    string public symbol = "NRV";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address a) external view returns (uint256) { return _bal[a]; }

    function mint(address to, uint256 amt) external {
        _bal[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    // 注意：没有返回值
    function transfer(address to, uint256 amt) external {
        require(_bal[msg.sender] >= amt, "bal");
        _bal[msg.sender] -= amt;
        _bal[to] += amt;
        // no return
        assembly { return(0, 0) }
    }

    function transferFrom(address from, address to, uint256 amt) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(_bal[from] >= amt, "bal");
        _bal[from] -= amt;
        _bal[to] += amt;
        assembly { return(0, 0) }
    }
}

/// transferFrom 显式返回 false（恶意/异常 ERC20）
contract FalseReturnToken {
    string public name = "FRT";
    string public symbol = "FRT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address a) external view returns (uint256) { return _bal[a]; }

    function mint(address to, uint256 amt) external {
        _bal[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// rebasing token：admin 可以直接修改任意账户余额
contract RebasingToken {
    string public name = "REB";
    string public symbol = "REB";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address a) external view returns (uint256) { return _bal[a]; }

    function mint(address to, uint256 amt) external {
        _bal[to] += amt;
        totalSupply += amt;
    }

    /// 模拟正向/负向 rebase 直接改余额
    function rebase(address target, int256 delta) external {
        if (delta >= 0) {
            _bal[target] += uint256(delta);
            totalSupply  += uint256(delta);
        } else {
            uint256 d = uint256(-delta);
            _bal[target] -= d;
            totalSupply  -= d;
        }
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(_bal[msg.sender] >= amt, "bal");
        _bal[msg.sender] -= amt;
        _bal[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(_bal[from] >= amt, "bal");
        _bal[from] -= amt;
        _bal[to] += amt;
        return true;
    }
}

/*------------------------------------------------------------------------------
                                 测试合约
------------------------------------------------------------------------------*/

contract NonStandardERC20UnitTest is Test {
    Comptroller internal comptroller;
    SimplePriceOracle internal oracle;
    InterestRateModel internal irm;

    address internal Alice;

    uint256 internal constant INIT_EXCHANGE_RATE = 2e16;

    function setUp() public {
        Alice = makeAddr("Alice");

        comptroller = new Comptroller();
        oracle      = new SimplePriceOracle();
        irm         = new WhitePaperInterestRateModel(0.02e18, 0.20e18);

        assertEq(comptroller._setPriceOracle(oracle), 0);
        assertEq(comptroller._setCloseFactor(0.5e18), 0);
        assertEq(comptroller._setLiquidationIncentive(1.08e18), 0);
    }

    // 使用给定的非标 underlying 创建并挂载市场
    function _deployMarket(address underlying) internal returns (MErc20Immutable mTok) {
        mTok = new MErc20Immutable(
            underlying, comptroller, irm,
            INIT_EXCHANGE_RATE, "Non-Std", "NSTD", 8, payable(address(this))
        );
        assertEq(comptroller._supportMarket(mTok), 0);
        oracle.setUnderlyingPrice(mTok, 1e18);
    }

    /******************************************************************************
     *  Test 1 - fee-on-transfer：mint 路径正确处理（按实际到账记账）              *
     ******************************************************************************/
    function testFeeOnTransfer_MintCreditsActualReceived() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        MErc20Immutable mTok = _deployMarket(address(fot));

        uint256 mintRequest = 1_000e18;
        uint256 expectedReceived = (mintRequest * 9_500) / 10_000; // 5% 手续费

        fot.mint(Alice, mintRequest);

        vm.startPrank(Alice);
        fot.approve(address(mTok), mintRequest);
        assertEq(mTok.mint(mintRequest), 0, "mint should succeed");
        vm.stopPrank();

        // mToken 合约持有的底层 = 实际到账（已扣除手续费）
        assertEq(fot.balanceOf(address(mTok)), expectedReceived, "cash equals net received");
        assertEq(mTok.getCash(), expectedReceived);

        // mToken 数量按实际到账折算（exchangeRate = 0.02 → 1 underlying = 50 mTokens）
        uint256 expectedMTokens = (expectedReceived * 1e18) / INIT_EXCHANGE_RATE;
        assertEq(mTok.balanceOf(Alice), expectedMTokens, "mTokens follow net amount");
    }

    /******************************************************************************
     *  Test 2 - fee-on-transfer：redeem 路径存在不对称（已知风险）                 *
     *  cash 按完整 amount 扣减，但用户收到 amount * 0.95，差额被 SINK 吞掉。      *
     *  此测试用于"档案归档"该风险，让回归发生时立刻被注意到。                       *
     ******************************************************************************/
    function testFeeOnTransfer_RedeemAsymmetry_DocumentedRisk() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        MErc20Immutable mTok = _deployMarket(address(fot));

        // Alice 先存 1000 进来（实际到账 950）
        uint256 mintRequest = 1_000e18;
        fot.mint(Alice, mintRequest);
        vm.startPrank(Alice);
        fot.approve(address(mTok), mintRequest);
        assertEq(mTok.mint(mintRequest), 0);

        uint256 cashBefore = mTok.getCash();              // 950
        uint256 aliceUnderlyingBefore = fot.balanceOf(Alice); // 0
        uint256 mTokenBalance = mTok.balanceOf(Alice);

        // 把全部 mToken 赎回
        assertEq(mTok.redeem(mTokenBalance), 0, "redeem should succeed");
        vm.stopPrank();

        uint256 cashAfter = mTok.getCash();
        uint256 aliceUnderlyingAfter = fot.balanceOf(Alice);

        uint256 cashDelta  = cashBefore - cashAfter;             // 协议账面减少量
        uint256 aliceDelta = aliceUnderlyingAfter - aliceUnderlyingBefore;

        // 协议账面减少了 cashBefore（≈950）
        assertEq(cashAfter, 0, "all cash drained per protocol accounting");

        // 但用户实际只收到 cashBefore * 0.95（FOT 又收了一次手续费）
        assertLt(aliceDelta, cashDelta, "user receives less than protocol decrements");

        uint256 expectedReceive = (cashDelta * 9_500) / 10_000;
        assertEq(aliceDelta, expectedReceive, "fee is taken on outbound transfer too");

        // 此测试通过 → 证实风险存在；若未来加上 wrapper 或 balance-after 检查，需重写本测试。
    }

    /******************************************************************************
     *  Test 3 - 无返回值的 ERC20 (USDT 风格)：mint / redeem 都正常                 *
     ******************************************************************************/
    function testNoReturnValueToken_MintAndRedeemWork() public {
        NoReturnValueToken nrv = new NoReturnValueToken();
        MErc20Immutable mTok = _deployMarket(address(nrv));

        uint256 amt = 500e18;
        nrv.mint(Alice, amt);

        vm.startPrank(Alice);
        nrv.approve(address(mTok), amt);
        assertEq(mTok.mint(amt), 0, "no-return mint should succeed");
        assertEq(mTok.getCash(), amt);
        assertEq(nrv.balanceOf(address(mTok)), amt);

        // 立即赎回
        uint256 mBal = mTok.balanceOf(Alice);
        assertEq(mTok.redeem(mBal), 0, "no-return redeem should succeed");
        assertEq(mTok.getCash(), 0);
        assertEq(nrv.balanceOf(Alice), amt);
        vm.stopPrank();
    }

    /******************************************************************************
     *  Test 4 - transferFrom 返回 false：mint 必须 revert                          *
     ******************************************************************************/
    function testFalseReturnToken_MintReverts() public {
        FalseReturnToken frt = new FalseReturnToken();
        MErc20Immutable mTok = _deployMarket(address(frt));

        uint256 amt = 100e18;
        frt.mint(Alice, amt);

        vm.startPrank(Alice);
        frt.approve(address(mTok), amt);
        vm.expectRevert(bytes("TOKEN_TRANSFER_IN_FAILED"));
        mTok.mint(amt);
        vm.stopPrank();
    }

    /******************************************************************************
     *  Test 5 - rebasing token：cash 漂移直接影响 exchangeRate（已知风险）         *
     ******************************************************************************/
    function testRebasing_DirectCashChangeAffectsExchangeRate() public {
        RebasingToken reb = new RebasingToken();
        MErc20Immutable mTok = _deployMarket(address(reb));

        // 初次 mint 1000，exchangeRate 起步是 INIT_EXCHANGE_RATE
        uint256 amt = 1_000e18;
        reb.mint(Alice, amt);
        vm.startPrank(Alice);
        reb.approve(address(mTok), amt);
        assertEq(mTok.mint(amt), 0);
        vm.stopPrank();

        uint256 erBefore = mTok.exchangeRateStored();

        // 模拟正向 rebase：协议合约平白多出 100 underlying，没人 mint 进来
        reb.rebase(address(mTok), int256(100e18));
        assertEq(reb.balanceOf(address(mTok)), amt + 100e18);

        // exchangeRateStored 是基于 (cash + borrows - reserves)/totalSupply 计算的，
        // 仅 cash 增加 → exchangeRate 上升 → 现有持有人受益、未来 mint 者收到更少 mToken
        uint256 erAfter = mTok.exchangeRateStored();
        assertGt(erAfter, erBefore, "positive rebase inflates exchange rate");

        // 反向 rebase
        reb.rebase(address(mTok), int256(-200e18));
        uint256 erAfterNeg = mTok.exchangeRateStored();
        assertLt(erAfterNeg, erAfter, "negative rebase deflates exchange rate");

        // 此测试是档案归档：mToken 不能抵御 underlying 余额直接增减，
        // 上线 rebasing 资产前必须用 wrapper（如 wstETH 之于 stETH）。
    }
}
