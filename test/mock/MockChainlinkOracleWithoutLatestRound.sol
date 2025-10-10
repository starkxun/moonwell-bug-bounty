// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";

/// @notice Mock oracle that doesn't support latestRound() - reverts when called
/// @dev Used for testing the fallback mechanism in ChainlinkOracleProxy
contract MockChainlinkOracleWithoutLatestRound is AggregatorV3Interface {
    int256 public _value;
    uint8 public _decimals;
    uint80 public _roundId;
    uint256 public _startedAt;
    uint256 public _updatedAt;
    uint80 public _answeredInRound;

    constructor(int256 value, uint8 oracleDecimals) {
        _value = value;
        _decimals = oracleDecimals;
        _roundId = 42;
        _startedAt = 1620651856;
        _updatedAt = 1620651856;
        _answeredInRound = 42;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock Oracle Without LatestRound";
    }

    function getRoundData(
        uint80 _getRoundId
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_getRoundId, _value, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _value, _startedAt, _updatedAt, _answeredInRound);
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRound() external pure override returns (uint256) {
        // Revert to simulate an oracle that doesn't support this method
        revert("latestRound not supported");
    }

    function set(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) external {
        _roundId = roundId;
        _value = answer;
        _startedAt = startedAt;
        _updatedAt = updatedAt;
        _answeredInRound = answeredInRound;
    }
}
