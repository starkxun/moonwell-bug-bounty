// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {SafeERC20} from "@openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {WETH9} from "@protocol/router/IWETH.sol";
import {MErc20} from "@protocol/MErc20.sol";

/// @notice WETH router for depositing raw ETH into Moonwell by wrapping into WETH then calling mint
/// allows for a single transaction to remove ETH from Moonwell
contract WETHRouter {
    using SafeERC20 for IERC20;

    /// @notice The WETH9 contract
    WETH9 public immutable weth;

    /// @notice The mToken contract
    MErc20 public immutable mToken;

    /// @notice construct the WETH router
    /// @param _weth The WETH9 contract
    /// @param _mToken The mToken contract
    constructor(WETH9 _weth, MErc20 _mToken) {
        weth = _weth;
        mToken = _mToken;
        // mToken 可以无限扣 router 的 WETH
        _weth.approve(address(_mToken), type(uint256).max);
    }

    /// @notice Deposit ETH into the Moonwell protocol
    /// @param recipient The address to receive the mToken
    function mint(address recipient) external payable {
        //  q - 这里 deposit 到哪里?
        // WETH 合约收到 ETH, 给调用者铸造等量 WETH
        // 调用者 是 router, 所以 WETH 会记到 router 的地址上
        weth.deposit{value: msg.value}();

        // mToken.mint 需要底层资产 WETH 才能铸造
        // 所以 router 必须要有 WETH（刚才的 deposit 已经完成）
        // 0 表示成功
        require(mToken.mint(msg.value) == 0, "WETHRouter: mint failed");

        // 这里转的是 mToken(凭证代币) 给用户, 并非 WETH
        // 构造函数里提前 approve 了 mToken 可无限扣 Router 的 WETH
        IERC20(address(mToken)).safeTransfer(
            recipient,
            mToken.balanceOf(address(this))
        );
    }

    /// @notice repay borrow using raw ETH with the most up to date borrow balance
    /// @dev all excess ETH will be returned to the sender
    /// @param borrower to repay on behalf of
    // deposit 负责把 ETH 变成可被 mToken 使用的 WETH；safeTransfer 负责把铸出的 mToken 凭证给用户
    function repayBorrowBehalf(address borrower) public payable {
        uint256 received = msg.value;
        uint256 borrows = mToken.borrowBalanceCurrent(borrower);

        // 偿还金额大于借款金额
        if (received > borrows) {
            // q - 这里 deposit 到哪里去了?
            // a - 同上, deposit WETH 给 router
            weth.deposit{value: borrows}();

            // mToken 从 Router 扣对应 WETH 去还款
            require(
                mToken.repayBorrowBehalf(borrower, borrows) == 0,
                "WETHRouter: repay borrow behalf failed"
            );

            // q - 这句的作用是什么?
            // a - 多余 ETH 没包成 WETH，最后原路退回 msg.sender
            (bool success, ) = msg.sender.call{value: address(this).balance}(
                ""
            );
            require(success, "WETHRouter: ETH transfer failed");
        } else {
            // 正常 repay
            weth.deposit{value: received}();

            require(
                mToken.repayBorrowBehalf(borrower, received) == 0,
                "WETHRouter: repay borrow behalf failed"
            );
        }
    }

    receive() external payable {
        require(msg.sender == address(weth), "WETHRouter: not weth"); // only accept ETH via fallback from the WETH contract
    }
}
