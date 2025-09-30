// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "./AggregatorV3Interface.sol";

/**
 * @title ChainlinkOracleProxy
 * @notice A TransparentUpgradeableProxy compliant contract that implements AggregatorV3Interface
 * and forwards calls to a configurable Chainlink price feed
 */
contract ChainlinkOracleProxy is
    Initializable,
    OwnableUpgradeable,
    AggregatorV3Interface
{
    /// @notice The Chainlink price feed this proxy forwards to
    AggregatorV3Interface public priceFeed;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the proxy with a price feed address
     * @param _priceFeed Address of the Chainlink price feed to forward calls to
     * @param _owner Address that will own this contract
     */
    function initialize(address _priceFeed, address _owner) public initializer {
        require(
            _priceFeed != address(0),
            "ChainlinkOracleProxy: price feed cannot be zero address"
        );
        require(
            _owner != address(0),
            "ChainlinkOracleProxy: owner cannot be zero address"
        );

        __Ownable_init();

        priceFeed = AggregatorV3Interface(_priceFeed);
        _transferOwnership(_owner);
    }

    // AggregatorV3Interface implementation - forwards all calls to the configured price feed

    function decimals() external view override returns (uint8) {
        return priceFeed.decimals();
    }

    function description() external view override returns (string memory) {
        return priceFeed.description();
    }

    function version() external view override returns (uint256) {
        return priceFeed.version();
    }

    function getRoundData(
        uint80 _roundId
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
        (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed
            .getRoundData(_roundId);
        _validateRoundData(roundId, answer, updatedAt, answeredInRound);
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
        (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed
            .latestRoundData();
        _validateRoundData(roundId, answer, updatedAt, answeredInRound);
    }

    function latestRound() external view override returns (uint256) {
        return priceFeed.latestRound();
    }

    /// @notice Validate the round data from Chainlink
    /// @param roundId The round ID to validate
    /// @param answer The price to validate
    /// @param updatedAt The timestamp when the round was updated
    /// @param answeredInRound The round ID in which the answer was computed
    function _validateRoundData(
        uint80 roundId,
        int256 answer,
        uint256 updatedAt,
        uint80 answeredInRound
    ) internal pure {
        require(answer > 0, "Chainlink price cannot be lower or equal to 0");
        require(updatedAt != 0, "Round is in incompleted state");
        require(answeredInRound >= roundId, "Stale price");
    }
}
