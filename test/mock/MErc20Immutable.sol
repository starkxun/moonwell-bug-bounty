// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import "@protocol/MErc20.sol";

// 把父合约的初始化流程封装到构造函数里，一次性部署完成
/// @notice unused in production so moved to mock folder
/**
 * @title Moonwell's MErc20Immutable Contract
 * @notice MTokens which wrap an EIP-20 underlying and are immutable
 * @author Moonwell
 */
contract MErc20Immutable is MErc20 {
    /**
     * @notice Construct a new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     */

    // underlying_: 底层资产地址
    // comptroller_: 风控入口
    // interestRateModel_: 利率模型
    // initialExchangeRateMantissa_: 初始汇率
    // name_/symbol_/decimals_: 代币元数据
    // 初始化结束后，把 admin 切换为你传入的 admin_

    constructor(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_
    ) {
        // Creator of the contract is admin during initialization
        admin = payable(msg.sender);

        // Initialize the market
        initialize(
            underlying_,
            comptroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_
        );

        // Set the proper admin now that initialization is done
        admin = admin_;
    }
}
