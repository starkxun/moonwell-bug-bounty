//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {BASE_CHAIN_ID} from "@utils/ChainIds.sol";

/// @notice Struct to represent a liquidation event
struct LiquidationData {
    uint256 timestamp;
    uint256 blockNumber;
    string borrowedToken;
    string collateralToken;
    address borrower;
    address liquidator;
    uint256 repayAmount;
    uint256 seizedCollateralAmount;
    uint256 liquidationSizeUSD;
}

/// @notice Struct to hold liquidation state
struct LiquidationState {
    uint256 borrowerBorrowBefore;
    uint256 borrowerCollateralBefore;
    uint256 reservesBefore;
    uint256 liquidatorCollateralBefore;
    uint256 borrowerBorrowAfter;
    uint256 borrowerCollateralAfter;
    uint256 reservesAfter;
    uint256 liquidatorCollateralAfter;
    uint256 protocolFee;
    uint256 liquidatorFeeReceived;
}

/// @notice Abstract contract to provide liquidation data from 10/10; used by ChainlinkOEVWrapperIntegration.t.sol
/// https://dune.com/queries/4326964/7267425
abstract contract Liquidations {
    /// @notice Mapping from chainId to liquidation data array
    mapping(uint256 => LiquidationData[]) internal _liquidationsByChain;

    constructor() {
        // Base chain liquidations (chainId: 8453)
        // https://basescan.org/tx/0x24782acfe7faef5bad1e4545a617c733a632e0aa20810f4500fbaf2c05354c7f
        _liquidationsByChain[BASE_CHAIN_ID].push(
            LiquidationData({
                timestamp: 1760131433,
                blockNumber: 36671043,
                borrowedToken: "USDC",
                collateralToken: "AERO",
                borrower: 0x46560b7207bb490A2115c334E36a70D6aD4BdEBD,
                liquidator: 0x4de911f6b0a3ACE9c25cf198Fe6027415051Eb60,
                repayAmount: 409205466639,
                seizedCollateralAmount: 32669011298294140000000000,
                liquidationSizeUSD: 409201783789800250000000000000000
            })
        );
    }

    /// @notice Get liquidation data for the current chain
    function getLiquidations() public view returns (LiquidationData[] memory) {
        LiquidationData[] storage chainLiquidations = _liquidationsByChain[
            block.chainid
        ];
        LiquidationData[] memory liquidations = new LiquidationData[](
            chainLiquidations.length
        );

        unchecked {
            uint256 liquidationsLength = liquidations.length;
            for (uint256 i = 0; i < liquidationsLength; i++) {
                liquidations[i] = LiquidationData({
                    timestamp: chainLiquidations[i].timestamp,
                    blockNumber: chainLiquidations[i].blockNumber,
                    borrowedToken: chainLiquidations[i].borrowedToken,
                    collateralToken: chainLiquidations[i].collateralToken,
                    borrower: chainLiquidations[i].borrower,
                    liquidator: chainLiquidations[i].liquidator,
                    repayAmount: chainLiquidations[i].repayAmount,
                    seizedCollateralAmount: chainLiquidations[i]
                        .seizedCollateralAmount,
                    liquidationSizeUSD: chainLiquidations[i].liquidationSizeUSD
                });
            }
        }

        return liquidations;
    }
}
