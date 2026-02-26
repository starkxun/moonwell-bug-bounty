// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MoonwellViewsV1} from "@protocol/views/MoonwellViewsV1.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {Well} from "@protocol/governance/Well.sol";
import {MToken} from "@protocol/MToken.sol";
import {MErc20Interface} from "@protocol/MTokenInterfaces.sol";
import {SafetyModuleInterfaceV1} from "@protocol/views/SafetyModuleInterfaceV1.sol";
import {UniswapV2PairInterface} from "@protocol/views/UniswapV2PairInterface.sol";

/**
 * @title Moonwell Views Contract for Moonriver
 * @author Moonwell
 * @notice Extends MoonwellViewsV1 with DEX-based price fallbacks for markets
 *         whose Chainlink oracle feeds are dead (e.g., MOVR/USD).
 *         Uses Solarbeam DEX pairs to compute prices when oracle reverts.
 */
contract MoonwellViewsV1Moonriver is MoonwellViewsV1 {
    struct InitParams {
        address comptroller;
        address safetyModule;
        address governanceToken;
        address nativeMarket;
        address governanceTokenLP;
        address admin;
        address nativeWrapped;
        address stableToken;
        uint8 stableDecimals;
        address[] tokens;
        address[] pairs;
    }

    /// @notice Token address to Solarbeam DEX pair mapping
    mapping(address => address) public dexPairs;

    /// @notice Wrapped native token address (WMOVR)
    address public nativeWrapped;

    /// @notice USD stablecoin reference token (USDC)
    address public stableToken;

    /// @notice Decimals of the stable token
    uint8 public stableTokenDecimals;

    /// @notice Admin address for configuration
    address public admin;

    /// @notice Governance token LP pair (stored here because base field is private)
    UniswapV2PairInterface public governanceTokenLP;

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin");
        _;
    }

    /// @notice Initialize all state: protocol config + DEX pricing
    function initialize(InitParams calldata params) external initializer {
        // Base protocol config
        require(
            params.comptroller != address(0),
            "Comptroller cant be the 0 address!"
        );
        comptroller = Comptroller(payable(params.comptroller));
        require(
            comptroller.isComptroller(),
            "Cant bind to something thats not a comptroller!"
        );

        safetyModule = SafetyModuleInterfaceV1(params.safetyModule);
        governanceToken = Well(params.governanceToken);
        _nativeMarket = params.nativeMarket;
        governanceTokenLP = UniswapV2PairInterface(params.governanceTokenLP);

        // DEX pricing config
        require(params.admin != address(0), "zero address");
        require(params.tokens.length == params.pairs.length, "length mismatch");

        admin = params.admin;
        nativeWrapped = params.nativeWrapped;
        stableToken = params.stableToken;
        stableTokenDecimals = params.stableDecimals;

        for (uint i = 0; i < params.tokens.length; i++) {
            dexPairs[params.tokens[i]] = params.pairs[i];
        }
    }

    /// @notice Set the admin address. First call is unrestricted (bootstrapping).
    function setAdmin(address _admin) external {
        require(admin == address(0) || msg.sender == admin, "only admin");
        require(_admin != address(0), "zero address");
        admin = _admin;
    }

    /// @notice Set DEX pair for a token
    function setDexPair(address token, address pair) external onlyAdmin {
        dexPairs[token] = pair;
    }

    /// @notice Set the wrapped native token address
    function setNativeWrapped(address token) external onlyAdmin {
        nativeWrapped = token;
    }

    /// @notice Set the USD stablecoin reference
    function setStableToken(address token, uint8 decimals) external onlyAdmin {
        stableToken = token;
        stableTokenDecimals = decimals;
    }

    /// @notice Get native token price from DEX (WMOVR/USDC pair)
    /// @return price in oracle format (1e18 mantissa for 18-decimal token)
    function _getNativeTokenPriceFromDex() internal view returns (uint) {
        address pair = dexPairs[nativeWrapped];
        if (pair == address(0) || stableToken == address(0)) return 0;

        (uint112 r0, uint112 r1, ) = UniswapV2PairInterface(pair).getReserves();
        address token0 = UniswapV2PairInterface(pair).token0();

        uint stableReserve = token0 == nativeWrapped ? uint(r1) : uint(r0);
        uint nativeReserve = token0 == nativeWrapped ? uint(r0) : uint(r1);

        if (nativeReserve == 0) return 0;

        // nativePrice = stableReserve * 10^(36 - stableDecimals) / nativeReserve
        return
            (stableReserve * (10 ** (36 - stableTokenDecimals))) /
            nativeReserve;
    }

    /// @notice Get token price from DEX via token/WMOVR pair + MOVR/USD
    /// @return price in oracle format (10^(36 - tokenDecimals) mantissa)
    function _getTokenPriceFromDex(address token) internal view returns (uint) {
        if (token == nativeWrapped) return _getNativeTokenPriceFromDex();

        address pair = dexPairs[token];
        if (pair == address(0)) return 0;

        (uint112 r0, uint112 r1, ) = UniswapV2PairInterface(pair).getReserves();
        address token0 = UniswapV2PairInterface(pair).token0();

        uint nativeReserve = token0 == token ? uint(r1) : uint(r0);
        uint tokenReserve = token0 == token ? uint(r0) : uint(r1);

        if (tokenReserve == 0) return 0;

        uint nativePrice = getNativeTokenPrice();
        // tokenPrice = nativeReserve * nativePrice / tokenReserve
        // This formula is decimal-independent (works for any token decimals)
        return (nativeReserve * nativePrice) / tokenReserve;
    }

    /// @notice Override getMarketInfo to wrap oracle price call in try/catch with DEX fallback
    function getMarketInfo(
        MToken _mToken
    ) external view virtual override returns (Market memory) {
        Market memory _result;

        (bool _isListed, uint _collateralFactor) = comptroller.markets(
            address(_mToken)
        );

        if (_isListed) {
            _result.market = address(_mToken);
            _result.borrowCap = comptroller.borrowCaps(address(_mToken));
            _result.supplyCap = _getSupplyCaps(address(_mToken));
            _result.collateralFactor = _collateralFactor;
            _result.isListed = _isListed;

            _result.mintPaused = comptroller.mintGuardianPaused(
                address(_mToken)
            );
            _result.borrowPaused = comptroller.borrowGuardianPaused(
                address(_mToken)
            );

            // Try oracle first, fallback to DEX pricing
            try comptroller.oracle().getUnderlyingPrice(_mToken) returns (
                uint price
            ) {
                _result.underlyingPrice = price;
            } catch {
                // Determine underlying token for DEX lookup
                address underlying;
                try MErc20Interface(address(_mToken)).underlying() returns (
                    address token
                ) {
                    underlying = token;
                } catch {
                    // Native market (no underlying() function)
                    underlying = nativeWrapped;
                }
                _result.underlyingPrice = _getTokenPriceFromDex(underlying);
            }

            _result.totalSupply = _mToken.totalSupply();
            _result.totalBorrows = _mToken.totalBorrows();
            _result.totalReserves = _mToken.totalReserves();
            _result.cash = _mToken.getCash();
            _result.exchangeRate = _mToken.exchangeRateStored();
            _result.borrowIndex = _mToken.borrowIndex();
            _result.reserveFactor = _mToken.reserveFactorMantissa();
            _result.borrowRate = _mToken.borrowRatePerTimestamp();
            _result.supplyRate = _mToken.supplyRatePerTimestamp();
            _result.incentives = getMarketIncentives(_mToken);
        }

        return _result;
    }

    /// @notice Override getGovernanceTokenPrice using our own LP field + DEX native price
    function getGovernanceTokenPrice()
        public
        view
        virtual
        override
        returns (uint _result)
    {
        if (
            address(governanceTokenLP) != address(0) &&
            _nativeMarket != address(0)
        ) {
            (uint reserves0, uint reserves1, ) = governanceTokenLP
                .getReserves();
            address token0 = governanceTokenLP.token0();

            uint _nativeReserve = token0 == address(governanceToken)
                ? reserves1
                : reserves0;
            uint _tokenReserve = token0 == address(governanceToken)
                ? reserves0
                : reserves1;

            if (_tokenReserve > 0) {
                _result =
                    (_nativeReserve * getNativeTokenPrice()) /
                    _tokenReserve;
            }
        }
    }

    /// @notice Override getNativeTokenPrice with oracle try/catch + DEX fallback
    function getNativeTokenPrice()
        public
        view
        virtual
        override
        returns (uint _result)
    {
        // Try oracle first if native market is configured
        if (_nativeMarket != address(0)) {
            try
                comptroller.oracle().getUnderlyingPrice(MToken(_nativeMarket))
            returns (uint price) {
                return price;
            } catch {}
        }
        // Fallback to DEX
        _result = _getNativeTokenPriceFromDex();
    }
}
