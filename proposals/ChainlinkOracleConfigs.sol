pragma solidity 0.8.19;

import "@forge-std/Test.sol";
import "@utils/ChainIds.sol";

abstract contract ChainlinkOracleConfigs is Test {
    struct OracleConfig {
        string oracleName; /// e.g., CHAINLINK_ETH_USD
        string symbol; /// e.g., as found in addresses
    }

    struct MorphoOracleConfig {
        string proxyName; /// e.g., CHAINLINK_stkWELL_USD (used for proxy identifier)
        string priceFeedName; /// e.g., CHAINLINK_WELL_USD (the actual price feed oracle)
    }

    /// oracle configurations per chain id
    mapping(uint256 => OracleConfig[]) internal _oracleConfigs;

    /// morpho market configurations per chain id
    mapping(uint256 => MorphoOracleConfig[]) internal _MorphoOracleConfigs;

    constructor() {
        /// Initialize oracle configurations for Base
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_ETH_USD", "WETH")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_BTC_USD", "cbBTC")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_EURC_USD", "EURC")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_WELL_USD", "xWELL_PROXY")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_USDS_USD", "USDS")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_TBTC_USD", "TBTC")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_VIRTUAL_USD", "VIRTUAL")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("CHAINLINK_AERO_ORACLE", "AERO")
        );
        _oracleConfigs[BASE_CHAIN_ID].push(
            OracleConfig("cbETHETH_ORACLE", "cbETH")
        );

        /// Initialize oracle configurations for Optimism
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_ETH_USD", "WETH")
        );
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_USDC_USD", "USDC")
        );
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_DAI_USD", "DAI")
        );
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_USDT_USD", "USDT")
        );
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_WBTC_USD", "WBTC")
        );
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_OP_USD", "OP")
        );
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_VELO_USD", "VELO")
        );
        _oracleConfigs[OPTIMISM_CHAIN_ID].push(
            OracleConfig("CHAINLINK_WELL_USD", "xWELL_PROXY")
        );

        /// Initialize Morpho market configurations for Base
        _MorphoOracleConfigs[BASE_CHAIN_ID].push(
            MorphoOracleConfig("CHAINLINK_WELL_USD", "CHAINLINK_WELL_USD")
        );
        _MorphoOracleConfigs[BASE_CHAIN_ID].push(
            MorphoOracleConfig("CHAINLINK_MAMO_USD", "CHAINLINK_MAMO_USD")
        );

        /// NOTE: stkWELL does not have an equivalent MToken to add reserves to, so use TEMPORAL_GOVERNOR as the fee recipient
        _MorphoOracleConfigs[BASE_CHAIN_ID].push(
            MorphoOracleConfig("CHAINLINK_stkWELL_USD", "CHAINLINK_WELL_USD")
        );
    }

    function getOracleConfigurations(
        uint256 chainId
    ) public view returns (OracleConfig[] memory) {
        OracleConfig[] memory configs = new OracleConfig[](
            _oracleConfigs[chainId].length
        );

        unchecked {
            uint256 configLength = configs.length;
            for (uint256 i = 0; i < configLength; i++) {
                configs[i] = OracleConfig({
                    oracleName: _oracleConfigs[chainId][i].oracleName,
                    symbol: _oracleConfigs[chainId][i].symbol
                });
            }
        }

        return configs;
    }

    function getMorphoOracleConfigurations(
        uint256 chainId
    ) public view returns (MorphoOracleConfig[] memory) {
        MorphoOracleConfig[] memory configs = new MorphoOracleConfig[](
            _MorphoOracleConfigs[chainId].length
        );

        unchecked {
            uint256 configLength = configs.length;
            for (uint256 i = 0; i < configLength; i++) {
                configs[i] = MorphoOracleConfig({
                    proxyName: _MorphoOracleConfigs[chainId][i].proxyName,
                    priceFeedName: _MorphoOracleConfigs[chainId][i]
                        .priceFeedName
                });
            }
        }

        return configs;
    }
}
