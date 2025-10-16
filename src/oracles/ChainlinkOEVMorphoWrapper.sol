// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "./AggregatorV3Interface.sol";
import {EIP20Interface} from "../EIP20Interface.sol";
import {IMorphoBlue} from "../morpho/IMorphoBlue.sol";
import {MarketParams} from "../morpho/IMetaMorpho.sol";
/**
 * @title ChainlinkOEVMorphoWrapper
 * @notice A wrapper for Chainlink price feeds that allows early updates for liquidation
 * @dev This contract implements the AggregatorV3Interface and adds OEV (Oracle Extractable Value) functionality
 */
contract ChainlinkOEVMorphoWrapper is
    Initializable,
    OwnableUpgradeable,
    AggregatorV3Interface
{
    /// @notice The maximum basis points for the fee multiplier
    uint16 public constant MAX_BPS = 10000;

    /// @notice The Chainlink price feed this proxy forwards to
    AggregatorV3Interface public priceFeed;

    /// @notice The address that will receive the OEV fees
    address public feeRecipient;

    /// @notice The fee multiplier for the OEV fees
    /// @dev Represented as a percentage
    uint16 public feeMultiplier;

    /// @notice The last cached round id
    uint256 public cachedRoundId;

    /// @notice The max round delay
    uint256 public maxRoundDelay;

    /// @notice The max decrements
    uint256 public maxDecrements;

    /// @notice The Morpho Blue contract address
    IMorphoBlue public morphoBlue;

    /// @notice Emitted when the fee recipient is changed
    event FeeRecipientChanged(address oldFeeRecipient, address newFeeRecipient);

    /// @notice Emitted when the fee multiplier is changed
    event FeeMultiplierChanged(
        uint16 oldFeeMultiplier,
        uint16 newFeeMultiplier
    );

    /// @notice Emitted when the price is updated early and liquidated
    event PriceUpdatedEarlyAndLiquidated(
        address indexed sender,
        address indexed borrower,
        uint256 seizedAssets,
        uint256 repaidAssets,
        uint256 fee
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the proxy with a price feed address
     * @param _priceFeed Address of the Chainlink price feed to forward calls to
     * @param _owner Address that will own this contract
     * @param _feeRecipient Address that will receive the OEV fees
     * @param _feeMultiplier The fee multiplier for the OEV fees
     * @param _maxRoundDelay The max round delay
     * @param _maxDecrements The max decrements
     * @param _morphoBlue Address of the Morpho Blue contract
     */
    function initialize(
        address _priceFeed,
        address _owner,
        address _feeRecipient,
        uint16 _feeMultiplier,
        uint256 _maxRoundDelay,
        uint256 _maxDecrements,
        address _morphoBlue
    ) public initializer {
        require(
            _priceFeed != address(0),
            "ChainlinkOEVMorphoWrapper: price feed cannot be zero address"
        );
        require(
            _owner != address(0),
            "ChainlinkOEVMorphoWrapper: owner cannot be zero address"
        );
        require(
            _feeRecipient != address(0),
            "ChainlinkOEVMorphoWrapper: fee recipient cannot be zero address"
        );
        require(
            _feeMultiplier <= MAX_BPS,
            "ChainlinkOEVMorphoWrapper: fee multiplier cannot be greater than MAX_BPS"
        );
        require(
            _maxRoundDelay > 0,
            "ChainlinkOEVMorphoWrapper: max round delay cannot be zero"
        );
        require(
            _maxDecrements > 0,
            "ChainlinkOEVMorphoWrapper: max decrements cannot be zero"
        );
        require(
            _morphoBlue != address(0),
            "ChainlinkOEVMorphoWrapper: morpho blue cannot be zero address"
        );
        __Ownable_init();

        priceFeed = AggregatorV3Interface(_priceFeed);
        cachedRoundId = priceFeed.latestRound();
        maxRoundDelay = _maxRoundDelay;
        maxDecrements = _maxDecrements;
        morphoBlue = IMorphoBlue(_morphoBlue);

        _transferOwnership(_owner);
    }

    /**
     * @notice Returns the number of decimals in the price feed
     * @return The number of decimals
     */
    function decimals() external view override returns (uint8) {
        return priceFeed.decimals();
    }

    /**
     * @notice Returns a description of the price feed
     * @return The description string
     */
    function description() external view override returns (string memory) {
        return priceFeed.description();
    }

    /**
     * @notice Returns the version number of the price feed
     * @return The version number
     */
    function version() external view override returns (uint256) {
        return priceFeed.version();
    }

    /**
     * @notice Returns data for a specific round
     * @param _roundId The round ID to retrieve data for
     * @return roundId The round ID
     * @return answer The price reported in this round
     * @return startedAt The timestamp when the round started
     * @return updatedAt The timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     */
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

    /**
     * @notice Returns data from the latest round, with OEV protection mechanism
     * @dev If the latest round hasn't been paid for (via updatePriceEarlyAndLiquidate) and is recent,
     *      this function will return data from a previous round instead
     * @return roundId The round ID
     * @return answer The latest price
     * @return startedAt The timestamp when the round started
     * @return updatedAt The timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     */
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

        // The default behavior is to delay the price update unless someone has paid for the current round.
        // If the current round is not too old (maxRoundDelay seconds) and hasn't been paid for,
        // attempt to find the most recent valid round by checking previous rounds
        if (
            roundId != cachedRoundId &&
            block.timestamp < updatedAt + maxRoundDelay
        ) {
            // start from the previous round
            uint256 currentRoundId = roundId - 1;

            for (uint256 i = 0; i < maxDecrements && currentRoundId > 0; i++) {
                try priceFeed.getRoundData(uint80(currentRoundId)) returns (
                    uint80 r,
                    int256 a,
                    uint256 s,
                    uint256 u,
                    uint80 ar
                ) {
                    // previous round data found, update the round data
                    roundId = r;
                    answer = a;
                    startedAt = s;
                    updatedAt = u;
                    answeredInRound = ar;
                    break;
                } catch {
                    // previous round data not found, continue to the next decrement
                    currentRoundId--;
                }
            }
        }
        _validateRoundData(roundId, answer, updatedAt, answeredInRound);
    }

    /**
     * @notice Returns the latest round ID
     * @dev Falls back to extracting round ID from latestRoundData if latestRound() is not supported
     * @return The latest round ID
     */
    function latestRound() external view override returns (uint256) {
        try priceFeed.latestRound() returns (uint256 round) {
            return round;
        } catch {
            // Fallback: extract round ID from latestRoundData
            (uint80 roundId, , , , ) = priceFeed.latestRoundData();
            return uint256(roundId);
        }
    }

    /**
     * @notice Sets the fee recipient address
     * @param _feeRecipient The new fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(
            _feeRecipient != address(0),
            "ChainlinkOEVMorphoWrapper: fee recipient cannot be zero address"
        );

        address oldFeeRecipient = feeRecipient;
        feeRecipient = _feeRecipient;

        emit FeeRecipientChanged(oldFeeRecipient, _feeRecipient);
    }

    /**
     * @notice Sets the fee multiplier for OEV fees
     * @param _feeMultiplier The new fee multiplier in basis points (must be <= MAX_BPS)
     */
    function setFeeMultiplier(uint16 _feeMultiplier) external onlyOwner {
        require(
            _feeMultiplier <= MAX_BPS,
            "ChainlinkOEVMorphoWrapper: fee multiplier cannot be greater than MAX_BPS"
        );
        uint16 oldFeeMultiplier = feeMultiplier;
        feeMultiplier = _feeMultiplier;
        emit FeeMultiplierChanged(oldFeeMultiplier, _feeMultiplier);
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

    /**
     * @notice Updates the cached round ID to allow early access to the latest price and executes a liquidation
     * @dev This function collects a fee from the caller, updates the cached price, and performs the liquidation on Morpho Blue
     * @dev The actual repayment amount is calculated by Morpho based on seizedAssets, oracle price, and liquidation incentive
     * @param marketParams The Morpho market parameters identifying the market
     * @param borrower The address of the borrower to liquidate
     * @param seizedAssets The amount of collateral assets to seize from the borrower
     * @param maxRepayAmount The maximum amount of loan tokens the liquidator is willing to repay (slippage protection)
     */
    function updatePriceEarlyAndLiquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 maxRepayAmount
    ) external {
        // ensure the borrower is not the zero address
        require(
            borrower != address(0),
            "ChainlinkOEVMorphoWrapper: borrower cannot be zero address"
        );

        // ensure the seized assets is greater than zero
        require(
            seizedAssets > 0,
            "ChainlinkOEVMorphoWrapper: seized assets cannot be zero"
        );

        // ensure max repay amount is greater than zero
        require(
            maxRepayAmount > 0,
            "ChainlinkOEVMorphoWrapper: max repay amount cannot be zero"
        );

        // get the loan token from market params
        EIP20Interface loanToken = EIP20Interface(marketParams.loanToken);

        // get the collateral token from market params
        EIP20Interface collateralToken = EIP20Interface(
            marketParams.collateralToken
        );

        // get the latest round data
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // validate the round data
        _validateRoundData(roundId, answer, updatedAt, answeredInRound);

        // update the cached round id
        cachedRoundId = roundId;

        // transfer max repay amount from liquidator to this contract
        // Morpho will pull the actual amount needed, and we'll return any excess
        loanToken.transferFrom(msg.sender, address(this), maxRepayAmount);

        // approve Morpho Blue to spend the loan tokens
        loanToken.approve(address(morphoBlue), maxRepayAmount);

        // liquidate the borrower on Morpho Blue
        // Morpho will: 1) Transfer seized collateral to this contract, 2) Pull loan tokens from this contract
        // seizedAssets: amount of collateral to seize
        // repaidShares: 0 (means we specify collateral amount, Morpho calculates debt repayment)
        (uint256 actualSeizedAssets, uint256 actualRepaidAssets) = morphoBlue
            .liquidate(marketParams, borrower, seizedAssets, 0, "");

        // ensure actual repaid amount doesn't exceed liquidator's maximum
        require(
            actualRepaidAssets <= maxRepayAmount,
            "ChainlinkOEVMorphoWrapper: repaid amount exceeds maximum"
        );

        // return any excess loan tokens to the liquidator
        uint256 excessLoanTokens = maxRepayAmount - actualRepaidAssets;
        if (excessLoanTokens > 0) {
            loanToken.transfer(msg.sender, excessLoanTokens);
        }

        // calculate the protocol fee based on the seized collateral
        uint256 fee = (actualSeizedAssets * uint256(feeMultiplier)) / MAX_BPS;

        // ensure the fee is greater than zero
        require(fee > 0, "ChainlinkOEVMorphoWrapper: fee cannot be zero");

        // if the fee recipient is not set, use the owner as the recipient
        address recipient = feeRecipient == address(0) ? owner() : feeRecipient;

        // transfer the protocol fee (in collateral tokens) to the recipient
        collateralToken.transfer(recipient, fee);

        // transfer the remaining collateral tokens to the liquidator (caller)
        collateralToken.transfer(msg.sender, actualSeizedAssets - fee);

        emit PriceUpdatedEarlyAndLiquidated(
            msg.sender,
            borrower,
            actualSeizedAssets,
            actualRepaidAssets,
            fee
        );
    }
}
