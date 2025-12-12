// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import {Test} from "@forge-std/Test.sol";
import {OEVProtocolFeeRedeemer} from "@protocol/OEVProtocolFeeRedeemer.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {MockWeth} from "@test/mock/MockWeth.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";

contract OEVProtocolFeeRedeemerUnitTest is Test {
    OEVProtocolFeeRedeemer public redeemer;

    // Mock contracts
    MockWeth public weth;
    MockERC20 public usdc;

    // mToken contracts
    MErc20Immutable public mWETH;
    MErc20Immutable public mUSDC;

    // Protocol contracts
    Comptroller public comptroller;
    SimplePriceOracle public priceOracle;
    InterestRateModel public interestRateModel;

    // Test addresses
    address public owner = address(0x1);
    address public user = address(0x2);
    address public nonOwner = address(0x3);

    // Constants
    uint256 public constant INITIAL_EXCHANGE_RATE = 2e17; // 0.2
    uint256 public constant MINT_AMOUNT = 100 ether;

    // Events
    event ReservesAddedFromOEV(address indexed mToken, uint256 amount);
    event MarketWhitelisted(address indexed market, bool whitelisted);

    function setUp() public {
        // Deploy mock tokens
        weth = new MockWeth();
        usdc = new MockERC20();

        // Deploy comptroller and oracle
        comptroller = new Comptroller();
        priceOracle = new SimplePriceOracle();

        // Set up comptroller
        comptroller._setPriceOracle(priceOracle);
        comptroller._setCloseFactor(0.5e18);
        comptroller._setLiquidationIncentive(1.08e18);

        // Deploy interest rate model (2.5% base rate, 20% slope)
        interestRateModel = new WhitePaperInterestRateModel(0.025e18, 0.2e18);

        // Deploy mTokens
        mWETH = new MErc20Immutable(
            address(weth),
            comptroller,
            interestRateModel,
            INITIAL_EXCHANGE_RATE,
            "Moonwell WETH",
            "mWETH",
            8,
            payable(owner)
        );

        mUSDC = new MErc20Immutable(
            address(usdc),
            comptroller,
            interestRateModel,
            INITIAL_EXCHANGE_RATE,
            "Moonwell USDC",
            "mUSDC",
            8,
            payable(owner)
        );

        // Support markets (comptroller admin is address(this) by default)
        comptroller._supportMarket(mWETH);
        comptroller._supportMarket(mUSDC);

        // Set oracle prices (1 ETH = 2000 USD, 1 USDC = 1 USD)
        priceOracle.setUnderlyingPrice(mWETH, 2000e18);
        priceOracle.setUnderlyingPrice(mUSDC, 1e18);

        // Deploy OEVProtocolFeeRedeemer
        vm.prank(owner);
        redeemer = new OEVProtocolFeeRedeemer(address(mWETH));

        // Fund the redeemer with ETH for testing
        vm.deal(address(redeemer), 10 ether);
    }

    function testConstructor() public view {
        assertEq(
            redeemer.MOONWELL_WETH(),
            address(mWETH),
            "MOONWELL_WETH should be set"
        );
        assertEq(redeemer.owner(), owner, "Owner should be set");
        assertTrue(
            redeemer.whitelistedMarkets(address(mWETH)),
            "mWETH should be whitelisted"
        );
    }

    function testConstructorWhitelistsWETH() public view {
        assertTrue(
            redeemer.whitelistedMarkets(address(mWETH)),
            "mWETH should be automatically whitelisted"
        );
        assertFalse(
            redeemer.whitelistedMarkets(address(mUSDC)),
            "mUSDC should not be whitelisted initially"
        );
    }

    function testWhitelistMarket() public {
        assertFalse(
            redeemer.whitelistedMarkets(address(mUSDC)),
            "mUSDC should not be whitelisted"
        );

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MarketWhitelisted(address(mUSDC), true);
        redeemer.whitelistMarket(address(mUSDC), true);

        assertTrue(
            redeemer.whitelistedMarkets(address(mUSDC)),
            "mUSDC should be whitelisted"
        );
    }

    function testUnwhitelistMarket() public {
        vm.startPrank(owner);

        vm.expectEmit(true, false, false, true);
        emit MarketWhitelisted(address(mUSDC), true);
        redeemer.whitelistMarket(address(mUSDC), true);
        assertTrue(redeemer.whitelistedMarkets(address(mUSDC)));

        vm.expectEmit(true, false, false, true);
        emit MarketWhitelisted(address(mUSDC), false);
        redeemer.whitelistMarket(address(mUSDC), false);
        assertFalse(redeemer.whitelistedMarkets(address(mUSDC)));

        vm.stopPrank();
    }

    function testCannotUseUnwhitelistedMarket() public {
        vm.startPrank(owner);
        redeemer.whitelistMarket(address(mUSDC), true);
        vm.stopPrank();

        usdc.mint(address(redeemer), 1000e18);

        vm.prank(owner);
        redeemer.whitelistMarket(address(mUSDC), false);

        vm.expectRevert("OEVProtocolFeeRedeemer: not whitelisted market");
        redeemer.addReserves(address(mUSDC));
    }

    function testWhitelistMarketOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        redeemer.whitelistMarket(address(mUSDC), true);
    }

    function testCannotCallRedeemAndAddReservesWithNonWhitelistedMarket()
        public
    {
        vm.expectRevert("OEVProtocolFeeRedeemer: not whitelisted market");
        redeemer.redeemAndAddReserves(address(mUSDC));
    }

    function testCannotCallAddReservesWithNonWhitelistedMarket() public {
        vm.expectRevert("OEVProtocolFeeRedeemer: not whitelisted market");
        redeemer.addReserves(address(mUSDC));
    }

    function testRedeemAndAddReserves() public {
        // Setup: Ensure mWETH has enough cash by having someone else mint first
        weth.mint(owner, MINT_AMOUNT * 10);
        vm.startPrank(owner);
        weth.approve(address(mWETH), MINT_AMOUNT * 10);
        mWETH.mint(MINT_AMOUNT * 10);
        vm.stopPrank();

        // Give redeemer some mWETH tokens
        weth.mint(user, MINT_AMOUNT);

        vm.startPrank(user);
        weth.approve(address(mWETH), MINT_AMOUNT);
        require(mWETH.mint(MINT_AMOUNT) == 0, "mint failed");

        // Transfer mWETH to redeemer
        uint256 mTokenAmount = mWETH.balanceOf(user);
        mWETH.transfer(address(redeemer), mTokenAmount);
        vm.stopPrank();

        // Record state before
        uint256 reservesBefore = mWETH.totalReserves();
        uint256 redeemerMTokenBalance = mWETH.balanceOf(address(redeemer));

        assertGt(redeemerMTokenBalance, 0, "Redeemer should have mTokens");

        // Calculate expected underlying amount
        uint256 exchangeRate = mWETH.exchangeRateStored();
        uint256 expectedUnderlying = (redeemerMTokenBalance * exchangeRate) /
            1e18;

        // Execute redeem and add reserves
        vm.expectEmit(true, true, true, true);
        emit ReservesAddedFromOEV(address(mWETH), expectedUnderlying);

        redeemer.redeemAndAddReserves(address(mWETH));

        // Verify results
        assertEq(
            mWETH.balanceOf(address(redeemer)),
            0,
            "Redeemer should have no mTokens left"
        );
        assertGt(
            mWETH.totalReserves(),
            reservesBefore,
            "Reserves should have increased"
        );
    }

    function testRedeemAndAddReservesWithMTokenBalance() public {
        // Ensure mWETH has enough cash
        weth.mint(owner, MINT_AMOUNT * 10);
        vm.startPrank(owner);
        weth.approve(address(mWETH), MINT_AMOUNT * 10);
        mWETH.mint(MINT_AMOUNT * 10);
        vm.stopPrank();

        // Give redeemer some mWETH
        weth.mint(address(this), MINT_AMOUNT);
        weth.approve(address(mWETH), MINT_AMOUNT);
        require(mWETH.mint(MINT_AMOUNT) == 0, "mint failed");

        uint256 mTokenBalance = mWETH.balanceOf(address(this));
        mWETH.transfer(address(redeemer), mTokenBalance);

        uint256 reservesBefore = mWETH.totalReserves();

        redeemer.redeemAndAddReserves(address(mWETH));

        assertGt(
            mWETH.totalReserves(),
            reservesBefore,
            "Reserves should increase"
        );
        assertEq(
            mWETH.balanceOf(address(redeemer)),
            0,
            "All mTokens should be redeemed"
        );
    }

    function testRedeemAndAddReservesRevertsOnInvalidMToken() public {
        vm.prank(owner);
        redeemer.whitelistMarket(address(weth), true);

        // When calling isMToken() on a contract that doesn't implement it, we get a revert
        vm.expectRevert();
        redeemer.redeemAndAddReserves(address(weth));
    }

    function testRedeemAndAddReservesRevertsWhenAddReservesFails() public {
        // Setup: Give mWETH enough cash
        weth.mint(owner, MINT_AMOUNT * 10);
        vm.startPrank(owner);
        weth.approve(address(mWETH), MINT_AMOUNT * 10);
        mWETH.mint(MINT_AMOUNT * 10);
        vm.stopPrank();

        // Give redeemer some mWETH
        uint256 mTokenAmount = 50e8; // 50 mWETH tokens (8 decimals)
        vm.prank(owner);
        mWETH.transfer(address(redeemer), mTokenAmount);

        uint256 underlyingAmount = (mTokenAmount * mWETH.exchangeRateStored()) /
            1e18;

        vm.mockCall(
            address(mWETH),
            abi.encodeWithSelector(
                mWETH._addReserves.selector,
                underlyingAmount
            ),
            abi.encode(1)
        );

        vm.expectRevert("OEVProtocolFeeRedeemer: add reserves failed");
        redeemer.redeemAndAddReserves(address(mWETH));
        vm.clearMockedCalls();
    }

    function testAddReserves() public {
        vm.prank(owner);
        redeemer.whitelistMarket(address(mUSDC), true);

        // Give redeemer some USDC
        uint256 usdcAmount = 1000e18;
        usdc.mint(address(redeemer), usdcAmount);

        uint256 reservesBefore = mUSDC.totalReserves();
        uint256 redeemerBalance = usdc.balanceOf(address(redeemer));

        assertEq(redeemerBalance, usdcAmount, "Redeemer should have USDC");

        // Execute add reserves
        vm.expectEmit(true, true, true, true);
        emit ReservesAddedFromOEV(address(mUSDC), usdcAmount);

        redeemer.addReserves(address(mUSDC));

        // Verify results
        assertEq(
            usdc.balanceOf(address(redeemer)),
            0,
            "Redeemer should have no USDC left"
        );
        assertEq(
            mUSDC.totalReserves(),
            reservesBefore + usdcAmount,
            "Reserves should increase by exact amount"
        );
    }

    function testAddReservesRevertsWithZeroBalance() public {
        vm.prank(owner);
        redeemer.whitelistMarket(address(mUSDC), true);

        vm.expectRevert("OEVProtocolFeeRedeemer: no underlying balance");
        redeemer.addReserves(address(mUSDC));
    }

    function testAddReservesRevertsWhenAddReservesFails() public {
        vm.prank(owner);
        redeemer.whitelistMarket(address(mUSDC), true);

        // Give redeemer some USDC
        uint256 amount = 1000e18;
        usdc.mint(address(redeemer), amount);

        vm.mockCall(
            address(mUSDC),
            abi.encodeWithSelector(mUSDC._addReserves.selector, amount),
            abi.encode(1)
        );

        vm.expectRevert("OEVProtocolFeeRedeemer: add reserves failed");
        redeemer.addReserves(address(mUSDC));
        vm.clearMockedCalls();
    }

    function testAddReservesRevertsOnInvalidMToken() public {
        vm.prank(owner);
        redeemer.whitelistMarket(address(usdc), true);

        // Give the redeemer some USDC so it doesn't fail on the balance check first
        usdc.mint(address(redeemer), 1000e18);

        // When calling isMToken() on a contract that doesn't implement it, we get a revert
        vm.expectRevert();
        redeemer.addReserves(address(usdc));
    }

    function testAddReservesNative() public {
        uint256 nativeAmount = 5 ether;
        vm.deal(address(redeemer), nativeAmount);

        uint256 reservesBefore = mWETH.totalReserves();
        uint256 nativeBalance = address(redeemer).balance;

        assertEq(
            nativeBalance,
            nativeAmount,
            "Redeemer should have native balance"
        );

        // Execute add reserves native
        vm.expectEmit(true, true, true, true);
        emit ReservesAddedFromOEV(address(mWETH), nativeAmount);

        redeemer.addReservesNative();

        // Verify results
        assertEq(
            address(redeemer).balance,
            0,
            "Redeemer should have no native balance left"
        );
        assertEq(
            mWETH.totalReserves(),
            reservesBefore + nativeAmount,
            "Reserves should increase by native amount"
        );
    }

    function testAddReservesNativeRevertsWithZeroBalance() public {
        // Drain native balance
        vm.deal(address(redeemer), 0);

        vm.expectRevert("OEVProtocolFeeRedeemer: no native balance");
        redeemer.addReservesNative();
    }

    function testAddReservesNativeRevertsWhenAddReservesFails() public {
        uint256 nativeAmount = 5 ether;
        vm.deal(address(redeemer), nativeAmount);

        vm.mockCall(
            address(mWETH),
            abi.encodeWithSelector(mWETH._addReserves.selector, nativeAmount),
            abi.encode(1)
        );

        vm.expectRevert("OEVProtocolFeeRedeemer: add reserves failed");
        redeemer.addReservesNative();
        vm.clearMockedCalls();
    }

    function testAddReservesNativeWrapsETHToWETH() public {
        uint256 nativeAmount = 3 ether;
        vm.deal(address(redeemer), nativeAmount);

        uint256 wethBalanceBefore = weth.balanceOf(address(mWETH));

        redeemer.addReservesNative();

        // Verify WETH was created and transferred
        assertEq(address(redeemer).balance, 0, "Native ETH should be consumed");
        assertGt(
            weth.balanceOf(address(mWETH)),
            wethBalanceBefore,
            "WETH balance of mWETH should increase"
        );
    }

    function testMultipleOperationsInSequence() public {
        vm.prank(owner);
        redeemer.whitelistMarket(address(mUSDC), true);

        // 1. Add reserves from native
        uint256 nativeAmount = 2 ether;
        vm.deal(address(redeemer), nativeAmount);
        redeemer.addReservesNative();

        uint256 reservesAfterNative = mWETH.totalReserves();
        assertGt(
            reservesAfterNative,
            0,
            "Reserves should increase after native"
        );

        // 2. Add reserves from underlying token
        uint256 usdcAmount = 500e18;
        usdc.mint(address(redeemer), usdcAmount);
        redeemer.addReserves(address(mUSDC));

        assertEq(
            mUSDC.totalReserves(),
            usdcAmount,
            "USDC reserves should match"
        );

        // 3. Redeem and add reserves
        // First ensure mWETH has enough cash
        weth.mint(owner, MINT_AMOUNT * 10);
        vm.startPrank(owner);
        weth.approve(address(mWETH), MINT_AMOUNT * 10);
        mWETH.mint(MINT_AMOUNT * 10);
        vm.stopPrank();

        weth.mint(address(this), MINT_AMOUNT);
        weth.approve(address(mWETH), MINT_AMOUNT);
        require(mWETH.mint(MINT_AMOUNT) == 0, "mint failed");
        mWETH.transfer(address(redeemer), mWETH.balanceOf(address(this)));

        uint256 reservesBeforeRedeem = mWETH.totalReserves();
        redeemer.redeemAndAddReserves(address(mWETH));

        assertGt(
            mWETH.totalReserves(),
            reservesBeforeRedeem,
            "Reserves should increase after redeem"
        );
    }

    function testReceiveETHDirectly() public {
        uint256 amount = 1 ether;
        uint256 initialBalance = address(redeemer).balance;

        // Send ETH directly to redeemer
        (bool success, ) = address(redeemer).call{value: amount}("");
        assertTrue(success, "Should be able to receive ETH");
        assertEq(
            address(redeemer).balance,
            initialBalance + amount,
            "Balance should match sent amount"
        );
    }

    function testPermissionlessExecution() public {
        // Setup: Give redeemer some native balance
        vm.deal(address(redeemer), 5 ether);

        // Any address should be able to call these functions
        vm.prank(user);
        redeemer.addReservesNative();

        vm.deal(address(redeemer), 5 ether);
        vm.prank(nonOwner);
        redeemer.addReservesNative();
    }

    function testWhitelistMultipleMarkets() public {
        address[] memory markets = new address[](2);
        markets[0] = address(mUSDC);
        markets[1] = address(0x123);

        vm.startPrank(owner);
        for (uint256 i = 0; i < markets.length; i++) {
            redeemer.whitelistMarket(markets[i], true);
            assertTrue(
                redeemer.whitelistedMarkets(markets[i]),
                "Market should be whitelisted"
            );
        }
        vm.stopPrank();
    }

    function testRedeemAndAddReservesWithZeroMTokenBalance() public {
        // Ensure mWETH has enough cash
        weth.mint(owner, MINT_AMOUNT);
        vm.startPrank(owner);
        weth.approve(address(mWETH), MINT_AMOUNT);
        mWETH.mint(MINT_AMOUNT);
        vm.stopPrank();

        // Redeemer has no mTokens
        assertEq(
            mWETH.balanceOf(address(redeemer)),
            0,
            "Should start with 0 mTokens"
        );

        uint256 reservesBefore = mWETH.totalReserves();

        // Should not revert, but also should not change reserves
        redeemer.redeemAndAddReserves(address(mWETH));

        assertEq(
            mWETH.totalReserves(),
            reservesBefore,
            "Reserves should not change"
        );
    }

    function testAddReservesAfterWhitelistingLater() public {
        usdc.mint(address(redeemer), 1000e18);

        vm.expectRevert("OEVProtocolFeeRedeemer: not whitelisted market");
        redeemer.addReserves(address(mUSDC));

        vm.prank(owner);
        redeemer.whitelistMarket(address(mUSDC), true);

        // Now it should work
        redeemer.addReserves(address(mUSDC));
        assertGt(mUSDC.totalReserves(), 0, "Reserves should be added");
    }

    function testLargeAmounts() public {
        uint256 largeAmount = 1000000 ether;

        // Test with large native amount
        vm.deal(address(redeemer), largeAmount);
        redeemer.addReservesNative();

        assertEq(address(redeemer).balance, 0, "Should consume all native ETH");
        assertGt(mWETH.totalReserves(), 0, "Should add large reserves");
    }

    receive() external payable {}
}
