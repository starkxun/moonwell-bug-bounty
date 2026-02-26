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

        // Token addresses
        address wmovr = addresses.getAddress("WMOVR");
        address usdc = addresses.getAddress("USDC");
        address xcKSM = addresses.getAddress("xcKSM");
        address frax = addresses.getAddress("FRAX");

        // Solarbeam DEX pairs
        address wmovrUsdcPair = addresses.getAddress("WMOVR_USDC_PAIR");
        address xcKsmWmovrPair = addresses.getAddress("xcKSM_WMOVR_PAIR");
        address fraxWmovrPair = addresses.getAddress("FRAX_WMOVR_PAIR");

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
        views.setNativeWrapped(wmovr);
        views.setStableToken(usdc, 6);
        views.setDexPair(wmovr, wmovrUsdcPair);
        views.setDexPair(xcKSM, xcKsmWmovrPair);
        views.setDexPair(frax, fraxWmovrPair);

        console.log("Implementation:", address(viewsImpl));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("Proxy:", address(proxy));

        vm.stopBroadcast();
    }
}
