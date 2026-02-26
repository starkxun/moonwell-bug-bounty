// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {console} from "@forge-std/console.sol";
import {Script} from "@forge-std/Script.sol";

import "@forge-std/Test.sol";

import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MoonwellViewsV1Moonriver} from "@protocol/views/MoonwellViewsV1Moonriver.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/*
to run:
forge script script/DeployMoonwellViewsV1Moonriver.s.sol:DeployMoonwellViewsV1Moonriver -vvvv --rpc-url moonriver --broadcast
*/

contract DeployMoonwellViewsV1Moonriver is Script, Test {
    // Moonriver token addresses
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

    Addresses public addresses;

    function setUp() public {
        addresses = new Addresses();
    }

    function run() public {
        vm.startBroadcast();

        address unitroller = addresses.getAddress("UNITROLLER");
        address safetyModule = addresses.getAddress("STK_GOVTOKEN_PROXY");
        address governanceToken = addresses.getAddress("GOVTOKEN");
        address nativeMarket = addresses.getAddress("MNATIVE");
        address governanceTokenLP = addresses.getAddress("GOVTOKEN_LP");

        // 1. Deploy implementation
        MoonwellViewsV1Moonriver viewsImpl = new MoonwellViewsV1Moonriver();

        // 2. Encode initialize calldata
        bytes memory initdata = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            unitroller,
            address(0), // tokenSaleDistributor - not used on Moonriver
            safetyModule,
            governanceToken,
            nativeMarket,
            governanceTokenLP
        );

        // 3. Deploy proxy
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(viewsImpl),
            address(proxyAdmin),
            initdata
        );

        MoonwellViewsV1Moonriver views = MoonwellViewsV1Moonriver(
            address(proxy)
        );

        // 4. Configure DEX pricing
        views.setAdmin(msg.sender);
        views.setNativeWrapped(WMOVR);
        views.setStableToken(USDC, 6);
        views.setDexPair(WMOVR, WMOVR_USDC_PAIR);
        views.setDexPair(xcKSM, xcKSM_WMOVR_PAIR);
        views.setDexPair(FRAX, FRAX_WMOVR_PAIR);

        console.log("Implementation:", address(viewsImpl));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("Proxy:", address(proxy));

        vm.stopBroadcast();
    }
}
