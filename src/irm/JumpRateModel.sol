// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import "./InterestRateModel.sol";
import "../SafeMath.sol";

/**
 * @title Moonwell's JumpRateModel Contract
 * @author Compound
 * @author Moonwell
 */
contract JumpRateModel is InterestRateModel {
    using SafeMath for uint;

    // 把初始化后的每秒参数和 kink 记录到链上日志，方便审计和前端读取历史配置
    event NewInterestParams(
        uint baseRatePerTimestamp,
        uint multiplierPerTimestamp,
        uint jumpMultiplierPerTimestamp,
        uint kink
    );

    /**
     * @notice The approximate number of timestamps per year that is assumed by the interest rate model
     */
    //  按“秒”估算一年
    uint public constant timestampsPerYear = 60 * 60 * 24 * 365;

    /**
     * @notice The multiplier of utilization rate that gives the slope of the interest rate
     */
    uint public multiplierPerTimestamp;

    /**
     * @notice The base interest rate which is the y-intercept when utilization rate is 0
     */
    uint public baseRatePerTimestamp;

    /**
     * @notice The multiplierPerTimestamp after hitting a specified utilization point
     */
    uint public jumpMultiplierPerTimestamp;

    /**
     * @notice The utilization point at which the jump multiplier is applied
     */
    uint public kink;

    /// @dev we know that we do not need to use safemath, however safemath is still used for safety
    /// and to not modify existing code.

    /**
     * @notice Construct an interest rate model
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
     * @param jumpMultiplierPerYear The multiplierPerTimestamp after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     */
    //  baseRatePerYear：基础年化借款利率（当利用率 (util=0) 时的起点），决定整条曲线在 y 轴上的起始高度
    //  multiplierPerYear：kink 之前的年化斜率（利用率每上升一点，利率增加多少），决定“正常区间”上涨快慢
    //  jumpMultiplierPerYear： 超过 kink 之后的年化斜率（跳升区间的更陡斜率）
    //  kink_： 拐点利用率阈值，决定从哪一刻开始切换到 jump 斜率
    constructor(
        uint baseRatePerYear,
        uint multiplierPerYear,
        uint jumpMultiplierPerYear,
        uint kink_
    ) {
        baseRatePerTimestamp = baseRatePerYear
            .mul(1e18)
            .div(timestampsPerYear)
            .div(1e18);
        multiplierPerTimestamp = multiplierPerYear
            .mul(1e18)
            .div(timestampsPerYear)
            .div(1e18);
        jumpMultiplierPerTimestamp = jumpMultiplierPerYear
            .mul(1e18)
            .div(timestampsPerYear)
            .div(1e18);
        kink = kink_;

        emit NewInterestParams(
            baseRatePerTimestamp,
            multiplierPerTimestamp,
            jumpMultiplierPerTimestamp,
            kink
        );
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market (currently unused)
     * @return The utilization rate as a mantissa between [0, 1e18]
     */
    //  计算资金利用率(市场里借出去的钱 占 可用总资金的比例)
    // 公式:  `borrows * 1e18 / (cash + borrows - reserves)`
    // reserves 是协议留存，不算可供借贷的有效流动性，所以要减掉

    // 直观理解：池子里的钱有多少比例被借走了。
    // 利用率 = 0%：没人借钱，资金全部闲置
    // 利用率 = 80%：池子里 80% 的钱都被借走了
    // 利用率 = 100%：资金被借空，新存款人无法提款（极危险）
    function utilizationRate(
        uint cash,
        uint borrows,
        uint reserves
    ) public pure returns (uint) {
        // Utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }

        return borrows.mul(1e18).div(cash.add(borrows).sub(reserves));
    }

    /**
     * @notice Calculates the current borrow rate per timestamp, with the error code expected by the market
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @return The borrow rate percentage per timestamp as a mantissa (scaled by 1e18)
     */
    function getBorrowRate(
        uint cash,
        uint borrows,
        uint reserves
    ) public view override returns (uint) {
        // q - 计算市场资金利用率？
        uint util = utilizationRate(cash, borrows, reserves);

        // 正常区间，使用较缓斜率
        if (util <= kink) {
            // 公式： 基础利率 + 利用率线性增长
            // 
            return
                util.mul(multiplierPerTimestamp).div(1e18).add(
                    baseRatePerTimestamp
                );
        } else {
            // 跳升区间
            // 先算拐点出正常利率： normalRate
            uint normalRate = kink.mul(multiplierPerTimestamp).div(1e18).add(
                baseRatePerTimestamp
            );
            // 超出拐点的部分
            uint excessUtil = util.sub(kink);
            // 最后计算总利率
            return
                excessUtil.mul(jumpMultiplierPerTimestamp).div(1e18).add(
                    normalRate
                );
        }
    }

    /**
     * @notice Calculates the current supply rate per timestamp
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @param reserveFactorMantissa The current reserve factor for the market
     * @return The supply rate percentage per timestamp as a mantissa (scaled by 1e18)
     */
    function getSupplyRate(
        uint cash,
        uint borrows,
        uint reserves,
        uint reserveFactorMantissa
    ) public view override returns (uint) {
        uint oneMinusReserveFactor = uint(1e18).sub(reserveFactorMantissa);
        uint borrowRate = getBorrowRate(cash, borrows, reserves);
        uint rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
        return
            utilizationRate(cash, borrows, reserves).mul(rateToPool).div(1e18);
    }
}
