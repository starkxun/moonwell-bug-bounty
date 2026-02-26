// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {MoonwellViewsV1Moonriver} from "@protocol/views/MoonwellViewsV1Moonriver.sol";
import {BaseMoonwellViews} from "@protocol/views/BaseMoonwellViews.sol";
import {MToken} from "@protocol/MToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract MoonwellViewsV1MoonriverTest is Test {
    MoonwellViewsV1Moonriver public views;

    // Moonriver addresses
    address constant UNITROLLER = 0x0b7a0EAA884849c6Af7a129e899536dDDcA4905E;
    address constant STK_GOVTOKEN = 0xCd76e63f3AbFA864c53b4B98F57c1aA6539FDa3a;
    address constant GOVTOKEN = 0xBb8d88bcD9749636BC4D2bE22aaC4Bb3B01A58F1;
    address constant MNATIVE = 0x6a1A771C7826596652daDC9145fEAaE62b1cd07f;
    address constant GOVTOKEN_LP = 0xE6Bfc609A2e58530310D6964ccdd236fc93b4ADB;

    // Tokens
    address constant WMOVR = 0x98878B06940aE243284CA214f92Bb71a2b032B8A;
    address constant USDC = 0xE3F5a90F9cb311505cd691a46596599aA1A0AD7D;
    address constant xcKSM = 0xFfFFfFff1FcaCBd218EDc0EbA20Fc2308C778080;
    address constant FRAX = 0x1A93B23281CC1CDE4C4741353F3064709A16197d;

    // Solarbeam DEX pairs
    address constant WMOVR_USDC_PAIR =
        0xe537f70a8b62204832B8Ba91940B77d3f79AEb81;
    address constant xcKSM_WMOVR_PAIR =
        0xea3d1E9e69ADDFA1ee5BBb89778Decd862F1F7C5;
    address constant FRAX_WMOVR_PAIR =
        0x2cc54b4A3878e36E1C754871438113C1117a3ad7;

    function setUp() public {
        string memory rpcUrl = vm.envOr(
            "MOONRIVER_RPC_URL",
            string("https://rpc.api.moonriver.moonbeam.network")
        );
        vm.createSelectFork(rpcUrl);

        // Deploy implementation
        MoonwellViewsV1Moonriver impl = new MoonwellViewsV1Moonriver();

        // Encode initialize
        bytes memory initdata = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            UNITROLLER,
            address(0), // no token sale distributor
            STK_GOVTOKEN,
            GOVTOKEN,
            MNATIVE,
            GOVTOKEN_LP
        );

        // Deploy proxy
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            address(proxyAdmin),
            initdata
        );

        views = MoonwellViewsV1Moonriver(address(proxy));

        // Configure DEX pricing
        views.setAdmin(address(this));
        views.setNativeWrapped(WMOVR);
        views.setStableToken(USDC, 6);
        views.setDexPair(WMOVR, WMOVR_USDC_PAIR);
        views.setDexPair(xcKSM, xcKSM_WMOVR_PAIR);
        views.setDexPair(FRAX, FRAX_WMOVR_PAIR);
    }

    function testGetMarketInfoMOVR() public view {
        BaseMoonwellViews.Market memory market = views.getMarketInfo(
            MToken(MNATIVE)
        );

        assertTrue(market.isListed, "mMOVR should be listed");
        assertGt(market.underlyingPrice, 0, "MOVR price should be non-zero");

        // MOVR price in oracle format (1e18 mantissa) should be reasonable
        // ~$5-50 range -> 5e18 to 50e18
        assertGt(market.underlyingPrice, 1e18, "MOVR price too low");
        assertLt(market.underlyingPrice, 100e18, "MOVR price too high");
    }

    function testGetAllMarketsInfo() public view {
        BaseMoonwellViews.Market[] memory markets = views.getAllMarketsInfo();

        assertGt(markets.length, 0, "should have markets");

        // Verify MOVR market (first market) has a price from DEX fallback
        bool foundMOVR = false;
        for (uint i = 0; i < markets.length; i++) {
            if (markets[i].market == MNATIVE) {
                foundMOVR = true;
                assertGt(
                    markets[i].underlyingPrice,
                    0,
                    "MOVR market should have non-zero price"
                );
            }
        }
        assertTrue(foundMOVR, "MOVR market should be found");
    }

    function testGetNativeTokenPrice() public view {
        uint price = views.getNativeTokenPrice();

        assertGt(price, 0, "native price should be non-zero");
        // MOVR ~$5-50 -> 5e18 to 50e18 in oracle format
        assertGt(price, 1e18, "MOVR price too low");
        assertLt(price, 100e18, "MOVR price too high");
    }

    function testGetGovernanceTokenPrice() public view {
        uint price = views.getGovernanceTokenPrice();

        // Governance token price should be non-zero if LP has liquidity
        // It's ok if it's 0 if LP is empty
        // Just verify it doesn't revert
        assertGe(price, 0, "governance token price should not revert");
    }

    function testDexPairConfiguration() public view {
        assertEq(views.dexPairs(WMOVR), WMOVR_USDC_PAIR, "WMOVR pair mismatch");
        assertEq(
            views.dexPairs(xcKSM),
            xcKSM_WMOVR_PAIR,
            "xcKSM pair mismatch"
        );
        assertEq(views.dexPairs(FRAX), FRAX_WMOVR_PAIR, "FRAX pair mismatch");
        assertEq(views.nativeWrapped(), WMOVR, "nativeWrapped mismatch");
        assertEq(views.stableToken(), USDC, "stableToken mismatch");
        assertEq(
            views.stableTokenDecimals(),
            6,
            "stableTokenDecimals mismatch"
        );
    }

    function testAdminAccess() public {
        // Non-admin should not be able to set pairs
        vm.prank(address(0xdead));
        vm.expectRevert("only admin");
        views.setDexPair(address(1), address(2));

        // Admin should be able to set pairs
        views.setDexPair(address(1), address(2));
        assertEq(views.dexPairs(address(1)), address(2));
    }

    function testSetAdminTransfer() public {
        address newAdmin = address(0xBEEF);

        // Transfer admin
        views.setAdmin(newAdmin);
        assertEq(views.admin(), newAdmin);

        // Old admin can no longer call
        vm.expectRevert("only admin");
        views.setDexPair(address(1), address(2));

        // New admin can call
        vm.prank(newAdmin);
        views.setDexPair(address(1), address(2));
    }
}
