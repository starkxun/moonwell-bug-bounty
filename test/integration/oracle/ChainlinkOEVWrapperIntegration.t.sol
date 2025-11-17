pragma solidity 0.8.19;

import "@forge-std/Test.sol";
import {IERC20Metadata as IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {MErc20} from "@protocol/MErc20.sol";
import {MToken} from "@protocol/MToken.sol";
import {MarketBase} from "@test/utils/MarketBase.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MErc20Delegator} from "@protocol/MErc20Delegator.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {ChainlinkOracleConfigs} from "@proposals/ChainlinkOracleConfigs.sol";
import {LiquidationData, Liquidations, LiquidationState} from "@test/utils/Liquidations.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";

contract ChainlinkOEVWrapperIntegrationTest is
    PostProposalCheck,
    ChainlinkOracleConfigs,
    Liquidations
{
    event FeeMultiplierChanged(
        uint16 oldFeeMultiplier,
        uint16 newFeeMultiplier
    );
    event PriceUpdatedEarlyAndLiquidated(
        address indexed borrower,
        uint256 repayAmount,
        address mTokenCollateral,
        address mTokenLoan,
        uint256 protocolFee,
        uint256 liquidatorFee
    );

    // Array of wrappers to test, resolved from oracle configs
    ChainlinkOEVWrapper[] public wrappers;
    Comptroller comptroller;
    MarketBase public marketBase;

    // Test actors
    address internal constant BORROWER =
        address(uint160(uint256(keccak256(abi.encodePacked("BORROWER")))));
    address internal constant LIQUIDATOR =
        address(uint160(uint256(keccak256(abi.encodePacked("LIQUIDATOR")))));

    function setUp() public override {
        uint256 primaryForkId = vm.envUint("PRIMARY_FORK_ID");

        super.setUp();
        vm.selectFork(primaryForkId);
        comptroller = Comptroller(addresses.getAddress("UNITROLLER"));
        marketBase = new MarketBase(comptroller);
        // Resolve wrappers from oracle configurations for the active chain
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );
        for (uint256 i = 0; i < oracleConfigs.length; i++) {
            string memory wrapperName = string(
                abi.encodePacked(oracleConfigs[i].oracleName, "_OEV_WRAPPER")
            );
            if (addresses.isAddressSet(wrapperName)) {
                ChainlinkOEVWrapper wrapper = ChainlinkOEVWrapper(
                    payable(addresses.getAddress(wrapperName))
                );
                wrappers.push(wrapper);

                // Make wrapper persistent so it survives fork rolls
                vm.makePersistent(address(wrapper));
            }
        }

        ChainlinkOracle oracle = ChainlinkOracle(address(comptroller.oracle()));
        vm.makePersistent(address(oracle));
    }

    function _perWrapperActor(
        string memory label,
        address wrapper
    ) internal pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(label, wrapper))))
            );
    }

    function _borrower(
        ChainlinkOEVWrapper wrapper
    ) internal pure returns (address) {
        return _perWrapperActor("BORROWER", address(wrapper));
    }

    function _liquidator(
        ChainlinkOEVWrapper wrapper
    ) internal pure returns (address) {
        return _perWrapperActor("LIQUIDATOR", address(wrapper));
    }

    function _mintMToken(
        address user,
        address mToken,
        uint256 amount
    ) internal {
        address underlying = MErc20(mToken).underlying();

        if (underlying == addresses.getAddress("WETH")) {
            vm.deal(addresses.getAddress("WETH"), amount);
        }
        deal(underlying, user, amount);
        vm.startPrank(user);

        IERC20(underlying).approve(mToken, amount);

        assertEq(
            MErc20Delegator(payable(mToken)).mint(amount),
            0,
            "Mint failed"
        );
        vm.stopPrank();
    }

    function testReturnPreviousRoundIfNoOneHasPaidForCurrentRoundAndNewRoundIsWithinMaxRoundDelay()
        public
    {
        int256 mockPrice = 3_3333e8; // chainlink oracle uses 8 decimals
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];

            uint256 latestRoundOnChain = wrapper.priceFeed().latestRound();

            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint256(latestRoundOnChain + 1),
                    mockPrice,
                    0,
                    block.timestamp,
                    uint256(latestRoundOnChain + 1)
                )
            );

            uint256 mockTimestamp = block.timestamp - 1;
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().getRoundData.selector,
                    uint80(latestRoundOnChain)
                ),
                abi.encode(
                    uint80(latestRoundOnChain),
                    mockPrice,
                    0,
                    mockTimestamp,
                    uint80(latestRoundOnChain)
                )
            );

            (uint256 roundId, int256 answer, , uint256 timestamp, ) = wrapper
                .latestRoundData();

            assertEq(
                roundId,
                latestRoundOnChain,
                "Round ID should be the same"
            );
            assertEq(mockPrice, answer, "Price should be the same as answer");
            assertEq(
                timestamp,
                mockTimestamp,
                "Timestamp should be the same as block.timestamp"
            );
        }
    }

    function testReturnLatestRoundIfBlockTimestampIsOlderThanBlockTImestampPlusMaxRoundDelay()
        public
    {
        int256 mockPrice = 3_000e8; // chainlink oracle uses 8 decimals
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            uint256 latestRoundOnChain = wrapper.priceFeed().latestRound();
            uint256 expectedTimestamp = block.timestamp;

            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint256(latestRoundOnChain + 1),
                    mockPrice,
                    0,
                    block.timestamp,
                    uint256(latestRoundOnChain + 1)
                )
            );

            vm.warp(block.timestamp + wrapper.maxRoundDelay());

            (uint256 roundID, int256 answer, , uint256 timestamp, ) = wrapper
                .latestRoundData();

            assertEq(
                roundID,
                latestRoundOnChain + 1,
                "Round ID should be the same"
            );
            assertEq(mockPrice, answer, "Price should be the same as answer");
            assertEq(
                timestamp,
                expectedTimestamp,
                "Timestamp should be the same as block.timestamp"
            );
        }
    }

    function testSetFeeMultiplier() public {
        uint16 newMultiplier = 100; // 1%
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            uint16 originalMultiplier = wrapper.feeMultiplier();
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            vm.expectEmit(address(wrapper));
            emit FeeMultiplierChanged(originalMultiplier, newMultiplier);
            wrapper.setFeeMultiplier(newMultiplier);
            assertEq(
                wrapper.feeMultiplier(),
                newMultiplier,
                "Fee multiplier not updated"
            );
        }
    }

    function testSetFeeMultiplierRevertNonOwner() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            vm.expectRevert("Ownable: caller is not the owner");
            wrapper.setFeeMultiplier(1);
        }
    }

    function testGetRoundData() public {
        uint80 roundId = 1;
        int256 mockPrice = 3_000e8;
        uint256 mockTimestamp = block.timestamp;
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            // Mock the original feed's getRoundData response
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().getRoundData.selector,
                    roundId
                ),
                abi.encode(
                    roundId,
                    mockPrice,
                    uint256(0),
                    mockTimestamp,
                    roundId
                )
            );

            (
                uint80 returnedRoundId,
                int256 answer,
                uint256 startedAt,
                uint256 updatedAt,
                uint80 answeredInRound
            ) = wrapper.getRoundData(roundId);

            assertEq(returnedRoundId, roundId, "Round ID should be the same");
            assertEq(answer, mockPrice, "Price should be the same");
            assertEq(startedAt, 0, "StartedAt should be 0");
            assertEq(
                updatedAt,
                mockTimestamp,
                "UpdatedAt should be the same as block.timestamp"
            );
            assertEq(
                answeredInRound,
                roundId,
                "AnsweredInRound should be the same as round ID"
            );
        }
    }

    function testAllChainlinkOraclesAreSet() public view {
        // Get all markets from the comptroller
        MToken[] memory allMarkets = comptroller.getAllMarkets();

        // Get the oracle from the comptroller
        ChainlinkOracle oracle = ChainlinkOracle(address(comptroller.oracle()));

        for (uint i = 0; i < allMarkets.length; i++) {
            // Skip LBTC market if configured in addresses (external Redstone requirements on some forks)
            if (addresses.isAddressSet("MOONWELL_LBTC")) {
                if (
                    address(allMarkets[i]) ==
                    addresses.getAddress("MOONWELL_LBTC")
                ) {
                    continue;
                }
            }
            address underlying = MErc20(address(allMarkets[i])).underlying();

            // Get token symbol
            string memory symbol = IERC20(underlying).symbol();

            // Try to get price - this will revert if oracle is not set
            uint price = oracle.getUnderlyingPrice(MToken(allMarkets[i]));

            // Price should not be 0
            assertTrue(
                price > 0,
                string(abi.encodePacked("Oracle not set for ", symbol))
            );
        }
    }

    function testLatestRoundDataRevertOnChainlinkPriceIsZero() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            uint256 timestampBefore = vm.getBlockTimestamp();
            vm.warp(timestampBefore + uint256(wrapper.maxRoundDelay()));

            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(1), // roundId
                    int256(0), // answer
                    uint256(0), // startedAt
                    uint256(timestampBefore), // updatedAt
                    uint80(1) // answeredInRound
                )
            );

            vm.expectRevert("Chainlink price cannot be lower or equal to 0");
            wrapper.latestRoundData();
        }
    }

    function testLatestRoundDataRevertOnIncompleteRoundState() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRound.selector
                ),
                abi.encode(uint256(1))
            );

            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(1), // roundId
                    int256(3_000e8), // answer
                    uint256(0), // startedAt
                    uint256(0), // updatedAt - set to 0 to simulate incomplete state
                    uint80(1) // answeredInRound
                )
            );

            vm.expectRevert("Round is in incompleted state");
            wrapper.latestRoundData();
        }
    }

    function testLatestRoundDataRevertOnStalePriceData() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            uint256 timestampBefore = vm.getBlockTimestamp();
            vm.warp(timestampBefore + uint256(wrapper.maxRoundDelay()));

            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(2), // roundId
                    int256(3_000e8), // answer
                    uint256(0), // startedAt
                    timestampBefore, // updatedAt
                    uint80(1) // answeredInRound - less than roundId to simulate stale price
                )
            );

            vm.expectRevert("Stale price");
            wrapper.latestRoundData();
        }
    }

    function testNoUpdateEarlyReturnsPreviousRound() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRound.selector
                ),
                abi.encode(uint256(2))
            );
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(2), // roundId
                    int256(3_000e8), // answer
                    uint256(0), // startedAt
                    uint256(block.timestamp), // updatedAt
                    uint80(3) // answeredInRound
                )
            );
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().getRoundData.selector
                ),
                abi.encode(
                    uint80(1),
                    int256(3_001e8),
                    uint256(0),
                    uint256(block.timestamp - 1),
                    uint80(2)
                )
            );
            // Call latestRoundData on the wrapper
            (
                uint80 roundId,
                int256 price,
                uint256 startedAt,
                uint256 updatedAt,
                uint80 answeredInRound
            ) = wrapper.latestRoundData();

            // Assert that the round data matches the previous round data
            assertEq(roundId, 1, "Round ID should be the previous round");
            assertEq(price, 3_001e8, "Price should be the previous price");
            assertEq(
                startedAt,
                0,
                "Started at timestamp should be the previous timestamp"
            );
            assertEq(
                updatedAt,
                block.timestamp - 1,
                "Updated at timestamp should be the previous timestamp"
            );
            assertEq(
                answeredInRound,
                2,
                "Answered in round should be the previous round"
            );
        }
    }

    function testMaxDecrementsLimit() public {
        // Mock the feed to return valid data for specific rounds
        uint256 latestRound = 100;
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];

            // Mock valid price data for round 100 (latest)
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(latestRound),
                    int256(1000),
                    uint256(block.timestamp),
                    uint256(block.timestamp),
                    uint80(latestRound)
                )
            );

            // Should return latest price since we can't find valid price within configured decrements when none mocked
            (
                uint80 roundId,
                int256 answer,
                ,
                ,
                uint80 answeredInRound
            ) = wrapper.latestRoundData();
            assertEq(
                answer,
                1000,
                "Should return latest price when valid price not found within maxDecrements"
            );
            assertEq(
                roundId,
                uint80(latestRound),
                "Should return latest round ID"
            );
            assertEq(
                answeredInRound,
                uint80(latestRound),
                "Should return latest answered round"
            );

            // Mock valid price data for round 95
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().getRoundData.selector,
                    uint80(latestRound - 5)
                ),
                abi.encode(
                    uint80(latestRound - 5),
                    int256(950),
                    uint256(block.timestamp - 1 hours),
                    uint256(block.timestamp - 1 hours),
                    uint80(latestRound - 5)
                )
            );

            // Should return price from round 95
            (roundId, answer, , , answeredInRound) = wrapper.latestRoundData();
            assertEq(
                answer,
                950,
                "Should return price from round 95 when maxDecrements allows reaching it"
            );
            assertEq(
                roundId,
                uint80(latestRound - 5),
                "Should return round 95 ID"
            );
            assertEq(
                answeredInRound,
                uint80(latestRound - 5),
                "Should return round 95 as answered round"
            );
        }
    }

    /** updatePriceEarlyAndLiquidate */

    function testUpdatePriceEarlyAndLiquidate_Succeeds() public {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );

        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];

            if (
                keccak256(abi.encodePacked(oracleConfigs[i].symbol)) ==
                keccak256(abi.encodePacked("cbETH"))
            ) {
                console2.log(
                    "Skipping cbETH wrapper due to borrow liquidity issues"
                );
                continue;
            }

            // Get the collateral mToken
            string memory mTokenKey = string(
                abi.encodePacked("MOONWELL_", oracleConfigs[i].symbol)
            );
            if (!addresses.isAddressSet(mTokenKey)) continue;

            address mTokenCollateralAddr = addresses.getAddress(mTokenKey);

            // Use USDC as borrow token
            if (
                !addresses.isAddressSet("MOONWELL_USDC") ||
                addresses.getAddress("MOONWELL_USDC") == mTokenCollateralAddr
            ) {
                continue;
            }
            address mTokenBorrowAddr = addresses.getAddress("MOONWELL_USDC");

            // Calculate amounts based on price and collateral factor
            uint256 collateralAmount;
            uint256 borrowAmount;
            {
                (, int256 currentPrice, , , ) = wrapper.latestRoundData();
                require(currentPrice > 0, "invalid price");

                address underlying = MErc20(mTokenCollateralAddr).underlying();
                (bool success, bytes memory data) = underlying.staticcall(
                    abi.encodeWithSignature("decimals()")
                );
                require(success && data.length >= 32, "decimals() call failed");
                uint8 decimals = abi.decode(data, (uint8));

                // Get the actual collateral factor for this market
                (bool isListed, uint256 collateralFactorMantissa) = comptroller
                    .markets(mTokenCollateralAddr);
                require(isListed, "market not listed");
                // collateralFactorMantissa is scaled by 1e18 (e.g., 0.65e18 = 65%)
                uint256 collateralFactorBps = (collateralFactorMantissa *
                    10000) / 1e18; // Convert to basis points

                // $10k worth of collateral
                collateralAmount =
                    (10_000 * 10 ** decimals * 1e8) /
                    uint256(currentPrice);

                // Borrow at 70% of the collateral factor (safe margin)
                // maxBorrow = $10k * CF, actualBorrow = maxBorrow * 0.8
                borrowAmount =
                    ((10_000 * collateralFactorBps * 70) / (10000 * 100)) *
                    1e6; // Result in USDC (6 decimals)
            }

            address borrower = _borrower(wrapper);

            // 1) Deposit collateral
            {
                MToken mToken = MToken(mTokenCollateralAddr);
                if (block.timestamp <= mToken.accrualBlockTimestamp()) {
                    vm.warp(mToken.accrualBlockTimestamp() + 1);
                }

                // Check and increase supply cap if needed
                uint256 supplyCap = comptroller.supplyCaps(
                    mTokenCollateralAddr
                );
                if (supplyCap != 0) {
                    uint256 totalSupply = mToken.totalSupply();
                    uint256 exchangeRate = mToken.exchangeRateStored();
                    uint256 totalUnderlyingSupply = (totalSupply *
                        exchangeRate) / 1e18;

                    if (totalUnderlyingSupply + collateralAmount >= supplyCap) {
                        vm.startPrank(
                            addresses.getAddress("TEMPORAL_GOVERNOR")
                        );
                        MToken[] memory mTokens = new MToken[](1);
                        mTokens[0] = mToken;
                        uint256[] memory newCaps = new uint256[](1);
                        newCaps[0] =
                            (totalUnderlyingSupply + collateralAmount) *
                            2;
                        comptroller._setMarketSupplyCaps(mTokens, newCaps);
                        vm.stopPrank();
                    }
                }

                _mintMToken(borrower, mTokenCollateralAddr, collateralAmount);

                address[] memory markets = new address[](2);
                markets[0] = mTokenCollateralAddr;
                markets[1] = mTokenBorrowAddr;
                vm.prank(borrower);
                comptroller.enterMarkets(markets);
            }

            // 2) Borrow USDC
            {
                MToken mToken = MToken(mTokenBorrowAddr);
                if (block.timestamp <= mToken.accrualBlockTimestamp()) {
                    vm.warp(mToken.accrualBlockTimestamp() + 1);
                }

                uint256 cap = comptroller.borrowCaps(mTokenBorrowAddr);
                uint256 total = mToken.totalBorrows();

                if (cap != 0 && total + borrowAmount >= cap) {
                    vm.startPrank(addresses.getAddress("TEMPORAL_GOVERNOR"));
                    MToken[] memory mTokens = new MToken[](1);
                    mTokens[0] = mToken;
                    uint256[] memory newCaps = new uint256[](1);
                    newCaps[0] = (total + borrowAmount) * 2;
                    comptroller._setMarketBorrowCaps(mTokens, newCaps);
                    vm.stopPrank();
                }

                vm.prank(borrower);
                assertEq(
                    MErc20Delegator(payable(mTokenBorrowAddr)).borrow(
                        borrowAmount
                    ),
                    0,
                    string(
                        abi.encodePacked(
                            "borrow failed for ",
                            oracleConfigs[i].symbol
                        )
                    )
                );
            }

            // 3) Crash price 60% to make position underwater
            {
                (, int256 price, , , ) = wrapper.latestRoundData();
                int256 crashedPrice = (price * 40) / 100;

                vm.mockCall(
                    address(wrapper.priceFeed()),
                    abi.encodeWithSelector(
                        wrapper.priceFeed().latestRoundData.selector
                    ),
                    abi.encode(
                        uint80(777),
                        crashedPrice,
                        uint256(0),
                        block.timestamp,
                        uint80(777)
                    )
                );

                (uint256 err, , uint256 shortfall) = comptroller
                    .getAccountLiquidity(borrower);
                require(err == 0 && shortfall > 0, "position not underwater");
            }

            // 4) Execute liquidation
            {
                address liquidator = _liquidator(wrapper);
                uint256 repayAmount = borrowAmount / 10;
                address borrowUnderlying = MErc20(mTokenBorrowAddr)
                    .underlying();
                deal(borrowUnderlying, liquidator, repayAmount);

                vm.startPrank(liquidator);
                IERC20(borrowUnderlying).approve(address(wrapper), repayAmount);

                uint256 borrowBefore = MErc20(mTokenBorrowAddr)
                    .borrowBalanceStored(borrower);
                uint256 collateralBefore = MErc20(mTokenCollateralAddr)
                    .balanceOf(borrower);
                uint256 reservesBefore = MErc20(mTokenCollateralAddr)
                    .totalReserves();

                if (
                    block.timestamp <=
                    MToken(mTokenBorrowAddr).accrualBlockTimestamp()
                ) {
                    vm.warp(
                        MToken(mTokenBorrowAddr).accrualBlockTimestamp() + 1
                    );
                }

                wrapper.updatePriceEarlyAndLiquidate(
                    borrower,
                    repayAmount,
                    mTokenCollateralAddr,
                    mTokenBorrowAddr
                );
                vm.stopPrank();

                // 5) Validate results
                assertEq(wrapper.cachedRoundId(), 777);
                assertLt(
                    MErc20(mTokenBorrowAddr).borrowBalanceStored(borrower),
                    borrowBefore
                );
                assertLt(
                    MErc20(mTokenCollateralAddr).balanceOf(borrower),
                    collateralBefore
                );

                address collateralUnderlying = MErc20(mTokenCollateralAddr)
                    .underlying();
                assertGt(IERC20(collateralUnderlying).balanceOf(liquidator), 0);
                // Protocol fee is now added to mToken reserves
                assertGt(
                    MErc20(mTokenCollateralAddr).totalReserves(),
                    reservesBefore
                );
            }
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertZeroRepay() public {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            string memory mTokenKeyCandidate = string(
                abi.encodePacked("MOONWELL_", oracleConfigs[i].symbol)
            );
            if (!addresses.isAddressSet(mTokenKeyCandidate)) {
                continue;
            }
            address mTokenAddr = addresses.getAddress(mTokenKeyCandidate);
            vm.expectRevert();
            wrapper.updatePriceEarlyAndLiquidate(
                address(0xBEEF),
                0,
                mTokenAddr,
                mTokenAddr
            );
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertZeroBorrower() public {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            string memory mTokenKeyCandidate = string(
                abi.encodePacked("MOONWELL_", oracleConfigs[i].symbol)
            );
            if (!addresses.isAddressSet(mTokenKeyCandidate)) {
                continue;
            }
            address mTokenAddr = addresses.getAddress(mTokenKeyCandidate);
            vm.expectRevert();
            wrapper.updatePriceEarlyAndLiquidate(
                address(0),
                1,
                mTokenAddr,
                mTokenAddr
            );
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertZeroMToken() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            vm.expectRevert();
            wrapper.updatePriceEarlyAndLiquidate(
                address(0xBEEF),
                1,
                address(0),
                address(0xBEEF)
            );
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertFeeZeroWhenMultiplierZero()
        public
    {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            string memory mTokenKeyCandidate = string(
                abi.encodePacked("MOONWELL_", oracleConfigs[i].symbol)
            );
            if (!addresses.isAddressSet(mTokenKeyCandidate)) {
                continue;
            }
            address mTokenAddr = addresses.getAddress(mTokenKeyCandidate);
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            wrapper.setFeeMultiplier(0);
            vm.expectRevert();
            wrapper.updatePriceEarlyAndLiquidate(
                address(0xBEEF),
                1,
                mTokenAddr,
                mTokenAddr
            );
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertInvalidPrice() public {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            string memory mTokenKeyCandidate = string(
                abi.encodePacked("MOONWELL_", oracleConfigs[i].symbol)
            );
            if (!addresses.isAddressSet(mTokenKeyCandidate)) {
                continue;
            }
            // answer <= 0
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(1),
                    int256(0),
                    uint256(0),
                    block.timestamp,
                    uint80(1)
                )
            );
            address mTokenAddr = addresses.getAddress(mTokenKeyCandidate);
            vm.expectRevert();
            wrapper.updatePriceEarlyAndLiquidate(
                address(0xBEEF),
                1,
                mTokenAddr,
                mTokenAddr
            );
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertIncompleteRound() public {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            string memory mTokenKeyCandidate = string(
                abi.encodePacked("MOONWELL_", oracleConfigs[i].symbol)
            );
            if (!addresses.isAddressSet(mTokenKeyCandidate)) {
                continue;
            }
            // updatedAt == 0
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(1),
                    int256(3_000e8),
                    uint256(0),
                    uint256(0),
                    uint80(1)
                )
            );
            address mTokenAddr = addresses.getAddress(mTokenKeyCandidate);
            vm.expectRevert();
            wrapper.updatePriceEarlyAndLiquidate(
                address(0xBEEF),
                1,
                mTokenAddr,
                mTokenAddr
            );
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertStalePrice() public {
        OracleConfig[] memory oracleConfigs = getOracleConfigurations(
            block.chainid
        );
        for (uint256 i = 0; i < wrappers.length; i++) {
            ChainlinkOEVWrapper wrapper = wrappers[i];
            string memory mTokenKeyCandidate = string(
                abi.encodePacked("MOONWELL_", oracleConfigs[i].symbol)
            );
            if (!addresses.isAddressSet(mTokenKeyCandidate)) {
                continue;
            }
            // answeredInRound < roundId
            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(2),
                    int256(3_000e8),
                    uint256(0),
                    block.timestamp,
                    uint80(1)
                )
            );
            address mTokenAddr = addresses.getAddress(mTokenKeyCandidate);
            vm.expectRevert();
            wrapper.updatePriceEarlyAndLiquidate(
                address(0xBEEF),
                1,
                mTokenAddr,
                mTokenAddr
            );
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertLiquidationFailed() public {
        // Use ETH/WETH for this test
        ChainlinkOEVWrapper wrapper = ChainlinkOEVWrapper(
            payable(addresses.getAddress("CHAINLINK_ETH_USD_OEV_WRAPPER"))
        );
        MToken mTokenCollateral = MToken(addresses.getAddress("MOONWELL_WETH"));
        MToken mTokenBorrow = MToken(addresses.getAddress("MOONWELL_USDC"));
        address borrower = _borrower(wrapper);
        uint256 borrowAmount;

        // 1) Deposit WETH as collateral
        {
            uint256 accrualTsPre = mTokenCollateral.accrualBlockTimestamp();
            if (block.timestamp <= accrualTsPre) {
                vm.warp(accrualTsPre + 1);
            }

            uint256 supplyAmount = 1 ether;
            _mintMToken(borrower, address(mTokenCollateral), supplyAmount);

            address[] memory markets = new address[](2);
            markets[0] = address(mTokenCollateral);
            markets[1] = address(mTokenBorrow);
            vm.prank(borrower);
            comptroller.enterMarkets(markets);

            assertTrue(
                comptroller.checkMembership(borrower, mTokenCollateral),
                "not in collateral market"
            );
        }

        // 2) Borrow USDC against WETH collateral (but stay healthy)
        {
            uint256 accrualTsPre = mTokenBorrow.accrualBlockTimestamp();
            if (block.timestamp <= accrualTsPre) {
                vm.warp(accrualTsPre + 1);
            }

            // Borrow only 1,000 USDC (well below 80% LTV, so position stays healthy)
            borrowAmount = 1_000 * 1e6;

            uint256 currentBorrowCap = comptroller.borrowCaps(
                address(mTokenBorrow)
            );
            uint256 totalBorrows = mTokenBorrow.totalBorrows();
            uint256 nextTotalBorrows = totalBorrows + borrowAmount;

            if (currentBorrowCap != 0 && nextTotalBorrows >= currentBorrowCap) {
                vm.startPrank(addresses.getAddress("TEMPORAL_GOVERNOR"));
                MToken[] memory mTokens = new MToken[](1);
                mTokens[0] = mTokenBorrow;
                uint256[] memory newBorrowCaps = new uint256[](1);
                newBorrowCaps[0] = nextTotalBorrows * 2;
                comptroller._setMarketBorrowCaps(mTokens, newBorrowCaps);
                vm.stopPrank();
            }

            vm.prank(borrower);
            assertEq(
                MErc20Delegator(payable(address(mTokenBorrow))).borrow(
                    borrowAmount
                ),
                0,
                "borrow failed"
            );
        }

        // 3) Verify position is healthy (has liquidity, no shortfall)
        {
            (uint256 err, uint256 liq, uint256 shortfall) = comptroller
                .getAccountLiquidity(borrower);
            assertEq(err, 0, "liquidity error");
            assertGt(liq, 0, "expected liquidity");
            assertEq(shortfall, 0, "should have no shortfall");
        }

        // 4) Try to liquidate a healthy position - should fail
        {
            address liquidator = _liquidator(wrapper);
            uint256 repayAmount = borrowAmount / 10; // Try to repay 100 USDC
            address borrowUnderlying = MErc20(address(mTokenBorrow))
                .underlying();
            deal(borrowUnderlying, liquidator, repayAmount);

            vm.startPrank(liquidator);
            IERC20(borrowUnderlying).approve(address(wrapper), repayAmount);

            if (block.timestamp <= mTokenBorrow.accrualBlockTimestamp()) {
                vm.warp(mTokenBorrow.accrualBlockTimestamp() + 1);
            }

            // Liquidation should fail because position is healthy (not underwater)
            vm.expectRevert(bytes("ChainlinkOEVWrapper: liquidation failed"));
            wrapper.updatePriceEarlyAndLiquidate(
                borrower,
                repayAmount,
                address(mTokenCollateral),
                address(mTokenBorrow)
            );
            vm.stopPrank();
        }
    }

    function testUpdatePriceEarlyAndLiquidate_RevertRedemptionFailed() public {
        // Use ETH/WETH for this test
        ChainlinkOEVWrapper wrapper = ChainlinkOEVWrapper(
            payable(addresses.getAddress("CHAINLINK_ETH_USD_OEV_WRAPPER"))
        );
        MToken mTokenCollateral = MToken(addresses.getAddress("MOONWELL_WETH"));
        MToken mTokenBorrow = MToken(addresses.getAddress("MOONWELL_USDC"));
        address borrower = _borrower(wrapper);
        uint256 borrowAmount;

        // 1) Deposit WETH as collateral
        {
            uint256 accrualTsPre = mTokenCollateral.accrualBlockTimestamp();
            if (block.timestamp <= accrualTsPre) {
                vm.warp(accrualTsPre + 1);
            }

            uint256 supplyAmount = 1 ether;
            _mintMToken(borrower, address(mTokenCollateral), supplyAmount);

            address[] memory markets = new address[](2);
            markets[0] = address(mTokenCollateral);
            markets[1] = address(mTokenBorrow);
            vm.prank(borrower);
            comptroller.enterMarkets(markets);

            assertTrue(
                comptroller.checkMembership(borrower, mTokenCollateral),
                "not in collateral market"
            );
        }

        // 2) Borrow USDC against WETH collateral
        {
            uint256 accrualTsPre = mTokenBorrow.accrualBlockTimestamp();
            if (block.timestamp <= accrualTsPre) {
                vm.warp(accrualTsPre + 1);
            }

            borrowAmount = 2_600 * 1e6; // 2,600 USDC

            uint256 currentBorrowCap = comptroller.borrowCaps(
                address(mTokenBorrow)
            );
            uint256 totalBorrows = mTokenBorrow.totalBorrows();
            uint256 nextTotalBorrows = totalBorrows + borrowAmount;

            if (currentBorrowCap != 0 && nextTotalBorrows >= currentBorrowCap) {
                vm.startPrank(addresses.getAddress("TEMPORAL_GOVERNOR"));
                MToken[] memory mTokens = new MToken[](1);
                mTokens[0] = mTokenBorrow;
                uint256[] memory newBorrowCaps = new uint256[](1);
                newBorrowCaps[0] = nextTotalBorrows * 2;
                comptroller._setMarketBorrowCaps(mTokens, newBorrowCaps);
                vm.stopPrank();
            }

            vm.prank(borrower);
            assertEq(
                MErc20Delegator(payable(address(mTokenBorrow))).borrow(
                    borrowAmount
                ),
                0,
                "borrow failed"
            );
        }

        // 3) Force position underwater by crashing ETH price to $2,000
        {
            int256 crashedPrice = 2_000 * 1e8;

            vm.mockCall(
                address(wrapper.priceFeed()),
                abi.encodeWithSelector(
                    wrapper.priceFeed().latestRoundData.selector
                ),
                abi.encode(
                    uint80(777),
                    crashedPrice,
                    uint256(0),
                    block.timestamp,
                    uint80(777)
                )
            );

            (uint256 err, uint256 liq, uint256 shortfall) = comptroller
                .getAccountLiquidity(borrower);
            assertEq(err, 0, "liquidity error");
            assertEq(liq, 0, "expected no liquidity");
            assertGt(shortfall, 0, "no shortfall created");
        }

        // 4) Mock redeem to fail, then attempt liquidation
        {
            address liquidator = _liquidator(wrapper);
            uint256 repayAmount = borrowAmount / 10; // 260 USDC
            address borrowUnderlying = MErc20(address(mTokenBorrow))
                .underlying();
            deal(borrowUnderlying, liquidator, repayAmount);

            vm.startPrank(liquidator);
            IERC20(borrowUnderlying).approve(address(wrapper), repayAmount);

            if (block.timestamp <= mTokenBorrow.accrualBlockTimestamp()) {
                vm.warp(mTokenBorrow.accrualBlockTimestamp() + 1);
            }

            // Mock redeem to fail (return error code 1)
            vm.mockCall(
                address(mTokenCollateral),
                abi.encodeWithSelector(
                    MErc20Delegator(payable(address(mTokenCollateral)))
                        .redeem
                        .selector
                ),
                abi.encode(uint256(1))
            );

            vm.expectRevert(bytes("ChainlinkOEVWrapper: redemption failed"));
            wrapper.updatePriceEarlyAndLiquidate(
                borrower,
                repayAmount,
                address(mTokenCollateral),
                address(mTokenBorrow)
            );
            vm.stopPrank();
        }
    }

    /// @notice Simulate some real liquidations from 10/10
    function testRealLiquidations() public {
        LiquidationData[] memory liquidations = getLiquidations();
        for (uint256 i = 0; i < liquidations.length; i++) {
            _testRealLiquidation(liquidations[i]);
        }
    }

    function _mockValidRound(
        ChainlinkOEVWrapper wrapper,
        uint80 roundId_,
        int256 price_
    ) internal {
        vm.mockCall(
            address(wrapper.priceFeed()),
            abi.encodeWithSelector(
                wrapper.priceFeed().latestRoundData.selector
            ),
            abi.encode(roundId_, price_, uint256(0), block.timestamp, roundId_)
        );
    }

    /// @notice Test liquidation using real liquidation data
    function _testRealLiquidation(LiquidationData memory liquidation) internal {
        (
            address mTokenCollateralAddr,
            address mTokenBorrowAddr,
            ChainlinkOEVWrapper wrapper
        ) = _setupLiquidation(liquidation);

        bool shouldContinue = _prepareLiquidation(
            liquidation,
            mTokenCollateralAddr,
            mTokenBorrowAddr,
            wrapper
        );
        if (!shouldContinue) {
            return; // Position doesn't exist, skip
        }

        LiquidationState memory state = _executeLiquidation(
            liquidation,
            wrapper,
            mTokenCollateralAddr,
            mTokenBorrowAddr
        );

        _verifyLiquidationResults(
            liquidation,
            state,
            mTokenCollateralAddr,
            mTokenBorrowAddr
        );
    }

    /// @notice Setup liquidation by getting addresses and finding wrapper
    function _setupLiquidation(
        LiquidationData memory liquidation
    )
        internal
        view
        returns (
            address mTokenCollateralAddr,
            address mTokenBorrowAddr,
            ChainlinkOEVWrapper wrapper
        )
    {
        string memory mTokenCollateralKey = string(
            abi.encodePacked("MOONWELL_", liquidation.collateralToken)
        );
        string memory mTokenBorrowKey = string(
            abi.encodePacked("MOONWELL_", liquidation.borrowedToken)
        );

        require(
            addresses.isAddressSet(mTokenCollateralKey),
            "Collateral mToken not found"
        );
        require(
            addresses.isAddressSet(mTokenBorrowKey),
            "Borrow mToken not found"
        );

        mTokenCollateralAddr = addresses.getAddress(mTokenCollateralKey);
        mTokenBorrowAddr = addresses.getAddress(mTokenBorrowKey);

        bool found;
        (wrapper, found) = _findWrapperForCollateral(
            liquidation.collateralToken
        );
        require(found, "Wrapper not found for collateral token");
    }

    /// @notice Prepare liquidation by warping time and validating position
    /// @return shouldContinue True if liquidation should proceed, false if position doesn't exist
    function _prepareLiquidation(
        LiquidationData memory liquidation,
        address mTokenCollateralAddr,
        address mTokenBorrowAddr,
        ChainlinkOEVWrapper wrapper
    ) internal returns (bool shouldContinue) {
        vm.rollFork(liquidation.blockNumber - 1); // ensure onchain state
        vm.warp(liquidation.timestamp - 1); // ensures mToken accrual timestamps

        // NOTE: doing this caused some liquidations to fail, but then its needed to get past some "delta" errors on others
        // uint256 targetTimestamp = liquidation.timestamp - 1;
        // vm.store(mTokenBorrowAddr, bytes32(uint256(9)), bytes32(targetTimestamp));
        // vm.store(mTokenCollateralAddr, bytes32(uint256(9)), bytes32(targetTimestamp));

        address borrower = liquidation.borrower;
        MToken mTokenBorrow = MToken(mTokenBorrowAddr);
        MToken mTokenCollateral = MToken(mTokenCollateralAddr);

        // NOTE: this seems to be needed to get past some "delta" errors
        // Explicitly accrue interest at the current timestamp to ensure accrual timestamps are set correctly
        mTokenBorrow.accrueInterest();
        mTokenCollateral.accrueInterest();

        uint256 borrowBalance = mTokenBorrow.borrowBalanceStored(borrower);
        if (borrowBalance == 0) {
            return false; // Position doesn't exist, skip
        }

        // Mock collateral price down to make position underwater
        AggregatorV3Interface priceFeed = wrapper.priceFeed();
        (uint80 feedRoundId, int256 price, , , ) = priceFeed.latestRoundData();
        int256 crashedPrice = (price * 75) / 100; // 25% price drop
        uint80 latestRoundId = feedRoundId;
        vm.mockCall(
            address(wrapper.priceFeed()),
            abi.encodeWithSelector(
                wrapper.priceFeed().latestRoundData.selector
            ),
            abi.encode(
                latestRoundId,
                crashedPrice,
                uint256(0),
                block.timestamp,
                latestRoundId
            )
        );

        // Mock getRoundData for previous rounds
        _mockPreviousRounds(
            wrapper,
            latestRoundId,
            crashedPrice,
            block.timestamp
        );

        // Verify position is now underwater after price crash
        (uint256 err, , uint256 shortfall) = comptroller.getAccountLiquidity(
            borrower
        );
        require(err == 0 && shortfall > 0, "Position not underwater");
        return true;
    }

    /// @notice Mock previous rounds for price feed to handle wrapper's round search logic
    function _mockPreviousRounds(
        ChainlinkOEVWrapper wrapper,
        uint80 latestRoundId,
        int256 crashedPrice,
        uint256 timestamp
    ) internal {
        uint256 maxDecrements = wrapper.maxDecrements();
        AggregatorV3Interface priceFeed = wrapper.priceFeed();

        uint80 startRound = latestRoundId > maxDecrements
            ? uint80(latestRoundId - maxDecrements)
            : 1;

        for (uint80 i = startRound; i < latestRoundId; i++) {
            uint256 roundTimestamp = timestamp -
                uint256(latestRoundId - i) *
                12;
            vm.mockCall(
                address(priceFeed),
                abi.encodeWithSelector(priceFeed.getRoundData.selector, i),
                abi.encode(i, crashedPrice, uint256(0), roundTimestamp, i)
            );
        }
    }

    /// @notice Execute the liquidation
    function _executeLiquidation(
        LiquidationData memory liquidation,
        ChainlinkOEVWrapper wrapper,
        address mTokenCollateralAddr,
        address mTokenBorrowAddr
    ) internal returns (LiquidationState memory state) {
        address borrower = liquidation.borrower;
        address liquidator = liquidation.liquidator;
        uint256 repayAmount = liquidation.repayAmount;

        address borrowUnderlying = MErc20(mTokenBorrowAddr).underlying();
        address collateralUnderlying = MErc20(mTokenCollateralAddr)
            .underlying();

        deal(borrowUnderlying, liquidator, repayAmount * 2);
        vm.warp(liquidation.timestamp);

        MToken mTokenBorrow = MToken(mTokenBorrowAddr);
        MToken mTokenCollateral = MToken(mTokenCollateralAddr);

        // Get balances before liquidation
        state.borrowerBorrowBefore = mTokenBorrow.borrowBalanceStored(borrower);
        state.borrowerCollateralBefore = mTokenCollateral.balanceOf(borrower);
        state.reservesBefore = mTokenCollateral.totalReserves();
        state.liquidatorCollateralBefore = IERC20(collateralUnderlying)
            .balanceOf(liquidator);

        // Execute liquidation
        vm.startPrank(liquidator);
        IERC20(borrowUnderlying).approve(address(wrapper), repayAmount);

        vm.recordLogs();
        wrapper.updatePriceEarlyAndLiquidate(
            borrower,
            repayAmount,
            mTokenCollateralAddr,
            mTokenBorrowAddr
        );
        vm.stopPrank();

        (
            state.protocolFee,
            state.liquidatorFeeReceived
        ) = _parseLiquidationEvent();

        // Get balances after liquidation
        state.borrowerBorrowAfter = mTokenBorrow.borrowBalanceStored(borrower);
        state.borrowerCollateralAfter = mTokenCollateral.balanceOf(borrower);
        state.reservesAfter = mTokenCollateral.totalReserves();
        state.liquidatorCollateralAfter = IERC20(collateralUnderlying)
            .balanceOf(liquidator);
    }

    /// @notice Parse liquidation event to extract fees
    function _parseLiquidationEvent()
        internal
        returns (uint256 protocolFee, uint256 liquidatorFee)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256(
            "PriceUpdatedEarlyAndLiquidated(address,uint256,address,address,uint256,uint256)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                (, , , uint256 _protocolFee, uint256 _liquidatorFee) = abi
                    .decode(
                        logs[i].data,
                        (uint256, address, address, uint256, uint256)
                    );

                protocolFee = _protocolFee;
                liquidatorFee = _liquidatorFee;
            }
        }
    }

    /// @notice Struct to hold price and decimal info
    struct PriceInfo {
        uint256 collateralPriceUSD;
        uint256 borrowPriceUSD;
        uint8 collateralDecimals;
        uint8 borrowDecimals;
    }

    /// @notice Verify liquidation results and log
    function _verifyLiquidationResults(
        LiquidationData memory liquidation,
        LiquidationState memory state,
        address mTokenCollateralAddr,
        address mTokenBorrowAddr
    ) internal view {
        PriceInfo memory priceInfo = _getPriceInfo(
            mTokenCollateralAddr,
            mTokenBorrowAddr
        );
        USDValues memory usdValues = _calculateUSDValues(
            liquidation,
            state,
            priceInfo
        );

        _logLiquidationResults(liquidation, state, usdValues);
        _assertLiquidationResults(state);
    }

    /// @notice Get price and decimal information
    function _getPriceInfo(
        address mTokenCollateralAddr,
        address mTokenBorrowAddr
    ) internal view returns (PriceInfo memory) {
        ChainlinkOracle chainlinkOracle = ChainlinkOracle(
            address(comptroller.oracle())
        );

        uint256 collateralPriceUSD = chainlinkOracle.getUnderlyingPrice(
            MToken(mTokenCollateralAddr)
        );
        uint256 borrowPriceUSD = chainlinkOracle.getUnderlyingPrice(
            MToken(mTokenBorrowAddr)
        );

        address collateralUnderlying = MErc20(mTokenCollateralAddr)
            .underlying();
        address borrowUnderlying = MErc20(mTokenBorrowAddr).underlying();
        uint8 collateralDecimals = IERC20(collateralUnderlying).decimals();
        uint8 borrowDecimals = IERC20(borrowUnderlying).decimals();

        return
            PriceInfo({
                collateralPriceUSD: collateralPriceUSD,
                borrowPriceUSD: borrowPriceUSD,
                collateralDecimals: collateralDecimals,
                borrowDecimals: borrowDecimals
            });
    }

    /// @notice Struct to hold USD values
    struct USDValues {
        uint256 protocolFeeUSD;
        uint256 liquidatorFeeUSD;
        uint256 repayAmountUSD;
    }

    /// @notice Calculate USD values from token amounts
    /// @dev getUnderlyingPrice returns prices scaled by 1e18 and already adjusted for token decimals
    /// So: USD = (amount * price) / 1e18
    function _calculateUSDValues(
        LiquidationData memory liquidation,
        LiquidationState memory state,
        PriceInfo memory priceInfo
    ) internal pure returns (USDValues memory) {
        uint256 repayAmount = liquidation.repayAmount;
        uint256 protocolFeeUSD = (state.protocolFee *
            priceInfo.collateralPriceUSD) / 1e18;
        uint256 liquidatorFeeUSD = (state.liquidatorFeeReceived *
            priceInfo.collateralPriceUSD) / 1e18;
        uint256 repayAmountUSD = (repayAmount * priceInfo.borrowPriceUSD) /
            1e18;

        return
            USDValues({
                protocolFeeUSD: protocolFeeUSD,
                liquidatorFeeUSD: liquidatorFeeUSD,
                repayAmountUSD: repayAmountUSD
            });
    }

    /// @notice Log liquidation results
    function _logLiquidationResults(
        LiquidationData memory liquidation,
        LiquidationState memory state,
        USDValues memory usdValues
    ) internal pure {
        console2.log("=== Liquidation Results ===");
        console2.log("Borrower:", liquidation.borrower);
        console2.log("Liquidator:", liquidation.liquidator);
        console2.log("Collateral Token:", liquidation.collateralToken);
        console2.log("Borrow Token:", liquidation.borrowedToken);
        console2.log("Repay Amount:", liquidation.repayAmount);
        console2.log("Repay Amount USD:", usdValues.repayAmountUSD);
        console2.log("Protocol Fee:", state.protocolFee);
        console2.log("Protocol Fee USD:", usdValues.protocolFeeUSD);
        console2.log("Liquidator Fee:", state.liquidatorFeeReceived);
        console2.log("Liquidator Fee USD:", usdValues.liquidatorFeeUSD);
        console2.log("Borrower Borrow Before:", state.borrowerBorrowBefore);
        console2.log("Borrower Borrow After:", state.borrowerBorrowAfter);
        console2.log(
            "Borrower Collateral Before:",
            state.borrowerCollateralBefore
        );
        console2.log(
            "Borrower Collateral After:",
            state.borrowerCollateralAfter
        );
    }

    /// @notice Assert liquidation results
    function _assertLiquidationResults(
        LiquidationState memory state
    ) internal pure {
        assertLt(
            state.borrowerBorrowAfter,
            state.borrowerBorrowBefore,
            "Borrow not reduced"
        );
        assertLt(
            state.borrowerCollateralAfter,
            state.borrowerCollateralBefore,
            "Collateral not seized"
        );
        assertGt(state.protocolFee, 0, "Protocol fee should be > 0");
        assertGt(
            state.liquidatorFeeReceived,
            0,
            "Liquidator fee should be > 0"
        );
        assertGt(
            state.reservesAfter,
            state.reservesBefore,
            "Reserves should increase"
        );
    }

    /// @notice Find the wrapper for a given collateral token symbol
    function _findWrapperForCollateral(
        string memory collateralSymbol
    ) internal view returns (ChainlinkOEVWrapper wrapper, bool found) {
        ChainlinkOracle chainlinkOracle = ChainlinkOracle(
            address(comptroller.oracle())
        );
        for (uint256 i = 0; i < wrappers.length; i++) {
            try chainlinkOracle.getFeed(collateralSymbol) returns (
                AggregatorV3Interface feed
            ) {
                if (address(feed) == address(wrappers[i])) {
                    return (wrappers[i], true);
                }
            } catch {
                continue;
            }
        }
        return (ChainlinkOEVWrapper(payable(address(0))), false);
    }
}
