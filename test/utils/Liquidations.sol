//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {BASE_CHAIN_ID} from "@utils/ChainIds.sol";

/// @notice Struct to represent a liquidation event
struct LiquidationData {
    uint256 timestamp;
    uint256 blockNumber;
    string borrowedToken;
    string collateralToken;
    string borrowMTokenKey;
    string collateralMTokenKey;
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
    uint256 borrowerBorrowAfter;
    uint256 borrowerCollateralAfter;
    uint256 reservesAfter;
    uint256 protocolFee; // in mToken units
    uint256 liquidatorFeeReceived; // in mToken units
    uint256 protocolFeeRedeemed; // underlying tokens added to reserves after redemption
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
                borrowMTokenKey: "MOONWELL_USDC",
                collateralMTokenKey: "MOONWELL_AERO",
                borrower: 0x46560b7207bb490A2115c334E36a70D6aD4BdEBD,
                liquidator: 0x4de911f6b0a3ACE9c25cf198Fe6027415051Eb60,
                repayAmount: 409205466639,
                seizedCollateralAmount: 32669011298294140000000000,
                liquidationSizeUSD: 409201783789800250000000000000000
            })
        );

        // https://basescan.org/tx/0xf83352d2f10aa4ab985516e5514d3ec3593fe9e66b1f5093af7fabff211d1fb8
        // _liquidationsByChain[BASE_CHAIN_ID].push(
        //     LiquidationData({
        //         timestamp: 1760131433,
        //         blockNumber: 36671043,
        //         borrowedToken: "USDC",
        //         collateralToken: "AERO",
        //         borrowMTokenKey: "MOONWELL_USDC",
        //         collateralMTokenKey: "MOONWELL_AERO",
        //         borrower: 0x2F9677016cB1e92e8F8a999c4541650C80C8637A,
        //         liquidator: 0x4de911f6b0a3ACE9c25cf198Fe6027415051Eb60,
        //         repayAmount: 238226106376,
        //         seizedCollateralAmount: 19018835267936348228550656,
        //         liquidationSizeUSD: 238223962341042611390266940208002287796224
        //     })
        // );

        // https://basescan.org/tx/0xf913f30fc0d2cdafe3e9a0f1cf82a1d0d9cda19549031f60a765960108b275ee
        // _liquidationsByChain[BASE_CHAIN_ID].push(
        //     LiquidationData({
        //         timestamp: 1760131529,
        //         blockNumber: 36671091,
        //         borrowedToken: "USDC",
        //         collateralToken: "AERO",
        //         borrowMTokenKey: "MOONWELL_USDC",
        //         collateralMTokenKey: "MOONWELL_AERO",
        //         borrower: 0x2F9677016cB1e92e8F8a999c4541650C80C8637A,
        //         liquidator: 0xDD50cD62869d41961f052522d6E20069F82b9DFA,
        //         repayAmount: 118654047697,
        //         seizedCollateralAmount: 11711121057389770298097664,
        //         liquidationSizeUSD: 118659980399384857607665087350398856986624
        //     })
        // );

        // // https://basescan.org/tx/0x44831fafe2b261dc91717dab8ca521c3b0ed70c0e836b4419b09e58028f84205
        // _liquidationsByChain[BASE_CHAIN_ID].push(
        //     LiquidationData({
        //         timestamp: 1760130921,
        //         blockNumber: 36670787,
        //         borrowedToken: "USDC",
        //         collateralToken: "cbETH",
        //         borrowMTokenKey: "MOONWELL_USDC",
        //         collateralMTokenKey: "MOONWELL_cbETH",
        //         borrower: 0xa4E057E58a11de90f6e63dC9B6c51025bD2c9646,
        //         liquidator: 0xeEEc65C4987a3a0B60Bd535C011080e544Acb1aE,
        //         repayAmount: 17871319504,
        //         seizedCollateralAmount: 240401644490000000000,
        //         liquidationSizeUSD: 17866690832248463000000000000000000
        //     })
        // );

        // // https://basescan.org/tx/0x0603c93de1f96debf8e8759fd483ff66ccfdc97b3efce9678dfb640e193f3551
        // _liquidationsByChain[BASE_CHAIN_ID].push(
        //     LiquidationData({
        //         timestamp: 1760131153,
        //         blockNumber: 36670903,
        //         borrowedToken: "USDC",
        //         collateralToken: "cbETH",
        //         borrowMTokenKey: "MOONWELL_USDC",
        //         collateralMTokenKey: "MOONWELL_cbETH",
        //         borrower: 0x35Fdad33177B6ACC608091E2Cc1F4b22FA2D6D89,
        //         liquidator: 0x4de911f6b0a3ACE9c25cf198Fe6027415051Eb60,
        //         repayAmount: 890915180,
        //         seizedCollateralAmount: 12350477230000000000,
        //         liquidationSizeUSD: 890907161763379900000000000000000
        //     })
        // );

        // // https://basescan.org/tx/0xbeaf7b851a7c56786779e9c84a748c1a5fdb14349e0b8de21d3ae4df2411ed29
        // _liquidationsByChain[BASE_CHAIN_ID].push(
        //     LiquidationData({
        //         timestamp: 1728595740,
        //         blockNumber: 20456036,
        //         borrowedToken: "USDC",
        //         collateralToken: "cbETH",
        //         borrowMTokenKey: "MOONWELL_USDC",
        //         collateralMTokenKey: "MOONWELL_cbETH",
        //         borrower: 0x9f110445ed4389ec1c4ca3edf69e13d6ac28b103,
        //         liquidator: 0x4de911f6b0a3ace9c25cf198fe6027415051eb60,
        //         repayAmount: 1568017162,
        //         seizedCollateralAmount: 22119741600000000000,
        //         liquidationSizeUSD: 1568003049845542100000000000000000
        //     })
        // );
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
                    borrowMTokenKey: chainLiquidations[i].borrowMTokenKey,
                    collateralMTokenKey: chainLiquidations[i]
                        .collateralMTokenKey,
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
