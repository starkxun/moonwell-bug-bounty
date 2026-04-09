// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {MToken} from "@protocol/MToken.sol";
import {Comptroller} from "@protocol/Comptroller.sol";

/// @notice stateless contract to check that all markets are correctly
/// initialized. Do this by checking that the total supply is greater
/// than zero, and that the address(0) has a balance greater than zero.
contract MarketAddChecker {
    /// @notice check that a market has been correctly initialized
    /// @param market address of the market to check
    // q - 新增市场时的健康检查
    function checkMarketAdd(address market) public view {
        // 代币市场的总供应量至少有 100 wei（确认初始化）
        require(MToken(market).totalSupply() >= 100, "Total supply lt 100 wei");
        // 零地址上必须有被销毁（或保留）的代币余额，以此确定 market 完成了初始化
        require(MToken(market).balanceOf(address(0)) > 0, "No balance burnt");
    }

    /// @notice check all markets in a given comptroller
    /// @param comptroller address to check
    // 检查所有 market 是否已经初始化
    function checkAllMarkets(address comptroller) public view {
        MToken[] memory markets = Comptroller(comptroller).getAllMarkets();

        for (uint256 i = 0; i < markets.length; i++) {
            checkMarketAdd(address(markets[i]));
        }
    }
}
