// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Ownable} from "@openzeppelin-contracts/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import {MErc20Storage, MTokenInterface, MErc20Interface} from "../MTokenInterfaces.sol";
import {MErc20} from "../MErc20.sol";
import {MToken} from "../MToken.sol";
import {EIP20Interface} from "../EIP20Interface.sol";
import {IChainlinkOracle} from "../interfaces/IChainlinkOracle.sol";

import {console} from "forge-std/console.sol";

/**
 * @title ChainlinkOEVWrapper
 * @notice A wrapper for Chainlink price feeds that allows early updates for liquidation
 * @dev This contract implements the AggregatorV3Interface and adds OEV (Oracle Extractable Value) functionality
 */
contract ChainlinkOEVWrapper is Ownable, AggregatorV3Interface {
    /// @notice The maximum basis points for the fee multiplier
    uint16 public constant MAX_BPS = 10000;

    /// @notice The ChainlinkOracle contract
    IChainlinkOracle public immutable chainlinkOracle;

    /// @notice The Chainlink price feed this proxy forwards to
    AggregatorV3Interface public priceFeed;

    /// @notice The fee multiplier for the OEV fees
    /// @dev Represented as a percentage
    uint16 public feeMultiplier;

    /// @notice The last cached round id
    uint256 public cachedRoundId;

    /// @notice The max round delay
    uint256 public maxRoundDelay;

    /// @notice The max decrements
    uint256 public maxDecrements;

    /// @notice Emitted when the fee multiplier is changed
    event FeeMultiplierChanged(
        uint16 oldFeeMultiplier,
        uint16 newFeeMultiplier
    );

    /// @notice Emitted when the max round delay is changed
    event MaxRoundDelayChanged(
        uint256 oldMaxRoundDelay,
        uint256 newMaxRoundDelay
    );

    /// @notice Emitted when the max decrements is changed
    event MaxDecrementsChanged(
        uint256 oldMaxDecrements,
        uint256 newMaxDecrements
    );

    /// @notice Emitted when the price is updated early and liquidated
    event PriceUpdatedEarlyAndLiquidated(
        address indexed borrower,
        uint256 repayAmount,
        address mTokenCollateral,
        address mTokenLoan,
        uint256 protocolFee,
        uint256 liquidatorFee
    );

    /**
     * @notice Contract constructor
     * @param _priceFeed Address of the Chainlink price feed to forward calls to
     * @param _owner Address that will own this contract
     * @param _feeMultiplier The fee multiplier for the OEV fees
     * @param _maxRoundDelay The max round delay
     * @param _maxDecrements The max decrements
     */
    constructor(
        address _priceFeed,
        address _owner,
        address _chainlinkOracle,
        uint16 _feeMultiplier,
        uint256 _maxRoundDelay,
        uint256 _maxDecrements
    ) {
        require(
            _priceFeed != address(0),
            "ChainlinkOEVWrapper: price feed cannot be zero address"
        );
        require(
            _owner != address(0),
            "ChainlinkOEVWrapper: owner cannot be zero address"
        );
        require(
            _feeMultiplier <= MAX_BPS,
            "ChainlinkOEVWrapper: fee multiplier cannot be greater than MAX_BPS"
        );
        require(
            _maxRoundDelay > 0,
            "ChainlinkOEVWrapper: max round delay cannot be zero"
        );
        require(
            _maxDecrements > 0,
            "ChainlinkOEVWrapper: max decrements cannot be zero"
        );
        require(
            _chainlinkOracle != address(0),
            "ChainlinkOEVWrapper: chainlink oracle cannot be zero address"
        );

        priceFeed = AggregatorV3Interface(_priceFeed);
        feeMultiplier = _feeMultiplier;
        cachedRoundId = priceFeed.latestRound();
        maxRoundDelay = _maxRoundDelay;
        maxDecrements = _maxDecrements;
        chainlinkOracle = IChainlinkOracle(_chainlinkOracle);

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
     * @notice Sets the fee multiplier for OEV fees
     * @param _feeMultiplier The new fee multiplier in basis points (must be <= MAX_BPS)
     */
    function setFeeMultiplier(uint16 _feeMultiplier) external onlyOwner {
        require(
            _feeMultiplier <= MAX_BPS,
            "ChainlinkOEVWrapper: fee multiplier cannot be greater than MAX_BPS"
        );
        uint16 oldFeeMultiplier = feeMultiplier;
        feeMultiplier = _feeMultiplier;
        emit FeeMultiplierChanged(oldFeeMultiplier, _feeMultiplier);
    }

    /**
     * @notice Sets the max round delay in seconds
     * @param _maxRoundDelay The new max round delay (must be > 0)
     */
    function setMaxRoundDelay(uint256 _maxRoundDelay) external onlyOwner {
        require(
            _maxRoundDelay > 0,
            "ChainlinkOEVWrapper: max round delay cannot be zero"
        );
        uint256 oldMaxRoundDelay = maxRoundDelay;
        maxRoundDelay = _maxRoundDelay;
        emit MaxRoundDelayChanged(oldMaxRoundDelay, _maxRoundDelay);
    }

    /**
     * @notice Sets the max number of decrements to search previous rounds
     * @param _maxDecrements The new max decrements (must be > 0)
     */
    function setMaxDecrements(uint256 _maxDecrements) external onlyOwner {
        require(
            _maxDecrements > 0,
            "ChainlinkOEVWrapper: max decrements cannot be zero"
        );
        uint256 oldMaxDecrements = maxDecrements;
        maxDecrements = _maxDecrements;
        emit MaxDecrementsChanged(oldMaxDecrements, _maxDecrements);
    }

    /**
     * @notice Allows the contract to receive ETH (needed for mWETH redemption which unwraps to ETH)
     */
    receive() external payable {}

    /**
     * @notice Updates the cached round ID to allow early access to the latest price and executes a liquidation
     * @dev This function collects a fee from the caller, updates the cached price, and performs the liquidation
     * @param borrower The address of the borrower to liquidate
     * @param repayAmount The amount to repay on behalf of the borrower
     * @param mTokenCollateral The mToken market for the collateral token
     * @param mTokenLoan The mToken market for the loan token, against which to liquidate
     */
    function updatePriceEarlyAndLiquidate(
        address borrower,
        uint256 repayAmount,
        address mTokenCollateral,
        address mTokenLoan
    ) external {
        // ensure the repay amount is greater than zero
        require(
            repayAmount > 0,
            "ChainlinkOEVWrapper: repay amount cannot be zero"
        );

        // ensure the borrower is not the zero address
        require(
            borrower != address(0),
            "ChainlinkOEVWrapper: borrower cannot be zero address"
        );

        // ensure the mToken is not the zero address
        require(
            mTokenCollateral != address(0),
            "ChainlinkOEVWrapper: mToken collateral cannot be zero address"
        );

        // ensure the mToken loan is not the zero address
        require(
            mTokenLoan != address(0),
            "ChainlinkOEVWrapper: mToken loan cannot be zero address"
        );

        // get the loan underlying token (the token being repaid)
        EIP20Interface underlyingLoan = EIP20Interface(
            MErc20Storage(mTokenLoan).underlying()
        );

        // get the collateral underlying token (the token being seized)
        EIP20Interface underlyingCollateral = EIP20Interface(
            MErc20Storage(mTokenCollateral).underlying()
        );

        require(
            address(chainlinkOracle.getFeed(underlyingCollateral.symbol())) ==
                address(this),
            "ChainlinkOEVWrapper: chainlink oracle feed does not match"
        );

        // transfer the loan token (to repay the borrow) from the liquidator to this contract
        underlyingLoan.transferFrom(msg.sender, address(this), repayAmount);

        // get the latest round data and update cached round id
        int256 collateralAnswer;
        {
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
            collateralAnswer = answer;
        }

        // execute liquidation and redeem collateral
        uint256 collateralReceived = _executeLiquidationAndRedeem(
            borrower,
            repayAmount,
            mTokenCollateral,
            mTokenLoan,
            underlyingLoan,
            underlyingCollateral
        );

        console.log("collateralReceived", collateralReceived);

        // Calculate the split of collateral between liquidator and protocol
        (
            uint256 liquidatorFee,
            uint256 protocolFee
        ) = _calculateCollateralSplit(
                repayAmount,
                collateralAnswer,
                collateralReceived,
                mTokenLoan,
                underlyingCollateral
            );

        // transfer the liquidator's payment (repayment + bonus) to the liquidator
        underlyingCollateral.transfer(msg.sender, liquidatorFee);

        // transfer the remainder to the protocol
        underlyingCollateral.approve(mTokenCollateral, protocolFee);
        MErc20(mTokenCollateral)._addReserves(protocolFee);

        emit PriceUpdatedEarlyAndLiquidated(
            borrower,
            repayAmount,
            mTokenCollateral,
            mTokenLoan,
            protocolFee,
            liquidatorFee
        );
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

    /// @notice Calculate the fully adjusted collateral token price
    /// @dev Scales Chainlink feed decimals to 18, then adjusts for token decimals
    /// @param collateralAnswer The raw price from Chainlink
    /// @param underlyingCollateral The collateral token interface
    /// @return The price scaled to 1e18 and adjusted for token decimals
    function _getCollateralTokenPrice(
        int256 collateralAnswer,
        EIP20Interface underlyingCollateral
    ) private view returns (uint256) {
        uint256 decimalDelta = uint256(18) - uint256(priceFeed.decimals());
        uint256 collateralPricePerUnit = uint256(collateralAnswer);
        if (decimalDelta > 0) {
            collateralPricePerUnit =
                collateralPricePerUnit *
                (10 ** decimalDelta);
        }

        // Adjust for token decimals (same logic as ChainlinkOracle)
        uint256 collateralDecimalDelta = uint256(18) -
            uint256(underlyingCollateral.decimals());
        if (collateralDecimalDelta > 0) {
            return collateralPricePerUnit * (10 ** collateralDecimalDelta);
        }
        return collateralPricePerUnit;
    }

    /// @notice Execute liquidation and redeem collateral
    /// @param borrower The address of the borrower to liquidate
    /// @param repayAmount The amount to repay on behalf of the borrower
    /// @param mTokenCollateral The mToken market for the collateral token
    /// @param mTokenLoan The mToken market for the loan token
    /// @param underlyingLoan The underlying loan token interface
    /// @param underlyingCollateral The underlying collateral token interface
    /// @return collateralReceived The amount of underlying collateral received
    function _executeLiquidationAndRedeem(
        address borrower,
        uint256 repayAmount,
        address mTokenCollateral,
        address mTokenLoan,
        EIP20Interface underlyingLoan,
        EIP20Interface underlyingCollateral
    ) internal returns (uint256 collateralReceived) {
        uint256 collateralBefore = underlyingCollateral.balanceOf(
            address(this)
        );
        uint256 nativeBalanceBefore = address(this).balance;

        // approve the mToken loan market to spend the loan tokens for liquidation
        underlyingLoan.approve(mTokenLoan, repayAmount);

        // liquidate the borrower's position: repay their loan and seize their collateral
        uint256 mTokenCollateralBalanceBefore = MTokenInterface(
            mTokenCollateral
        ).balanceOf(address(this));
        require(
            MErc20Interface(mTokenLoan).liquidateBorrow(
                borrower,
                repayAmount,
                MTokenInterface(mTokenCollateral)
            ) == 0,
            "ChainlinkOEVWrapper: liquidation failed"
        );

        // get the amount of mToken collateral received from liquidation
        uint256 mTokenBalanceDelta = MTokenInterface(mTokenCollateral)
            .balanceOf(address(this)) - mTokenCollateralBalanceBefore;

        // redeem all the mToken collateral to get the underlying collateral tokens
        // Note: mWETH will unwrap to native ETH via WETH_UNWRAPPER
        require(
            MErc20Interface(mTokenCollateral).redeem(mTokenBalanceDelta) == 0,
            "ChainlinkOEVWrapper: redemption failed"
        );

        // If we received native ETH (from mWETH), wrap it back to WETH
        uint256 nativeDelta = address(this).balance - nativeBalanceBefore;
        if (nativeDelta > 0) {
            (bool success, ) = address(underlyingCollateral).call{
                value: nativeDelta
            }(abi.encodeWithSignature("deposit()"));
            require(success, "ChainlinkOEVWrapper: WETH deposit failed");
        }

        console.log(
            "underlyingCollateral.balanceOf(address(this))",
            underlyingCollateral.balanceOf(address(this))
        );
        console.log("collateralBefore", collateralBefore);

        collateralReceived =
            underlyingCollateral.balanceOf(address(this)) -
            collateralBefore;
    }

    /// @notice Calculate the split of seized collateral between liquidator and fee recipient
    /// @param repayAmount The amount of loan tokens being repaid
    /// @param collateralReceived The amount of collateral tokens seized
    /// @param mTokenLoan The mToken for the loan being repaid
    /// @param underlyingCollateral The underlying collateral token interface
    /// @return liquidatorFee The amount of collateral to send to the liquidator (repayment + bonus)
    /// @return protocolFee The amount of collateral to send to the fee recipient (remainder)
    function _calculateCollateralSplit(
        uint256 repayAmount,
        int256 collateralAnswer,
        uint256 collateralReceived,
        address mTokenLoan,
        EIP20Interface underlyingCollateral
    ) internal view returns (uint256 liquidatorFee, uint256 protocolFee) {
        uint256 loanTokenPrice = chainlinkOracle.getUnderlyingPrice(
            MToken(mTokenLoan)
        );

        // Get the fully adjusted collateral token price
        uint256 collateralTokenPrice = _getCollateralTokenPrice(
            collateralAnswer,
            underlyingCollateral
        );

        // Calculate USD value of the repay amount
        uint256 repayValueUSD = (repayAmount * loanTokenPrice);
        uint256 collateralValueUSD = (collateralReceived *
            collateralTokenPrice);

        // Liquidator receives: collateral worth repay amount + bonus (remainder * feeMultiplier)
        uint256 liquidatorPaymentUSD = repayValueUSD +
            ((collateralValueUSD - repayValueUSD) * uint256(feeMultiplier)) /
            MAX_BPS;

        // Convert USD value back to collateral token amount
        // Both prices from oracle are already scaled for token decimals, so simple division works
        liquidatorFee = liquidatorPaymentUSD / collateralTokenPrice;

        // Protocol gets the remainder
        protocolFee = collateralReceived - liquidatorFee;
    }
}
