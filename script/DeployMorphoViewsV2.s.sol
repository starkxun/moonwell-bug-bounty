// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {console} from "@forge-std/console.sol";
import {Script} from "@forge-std/Script.sol";
import {Test} from "@forge-std/Test.sol";

import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MorphoViewsV2} from "@protocol/views/MorphoViewsV2.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/*
to run:
forge script script/DeployMorphoViewsV2.s.sol:DeployMorphoViewsV2 -vvvv --rpc-url {rpc} --broadcast --etherscan-api-key {key}

Example for Base mainnet:
forge script script/DeployMorphoViewsV2.s.sol:DeployMorphoViewsV2 -vvvv --rpc-url https://mainnet.base.org --broadcast --verify --etherscan-api-key {BASESCAN_API_KEY}

*/

contract DeployMorphoViewsV2 is Script, Test {
    uint256 public PRIVATE_KEY;

    Addresses public addresses;

    function setUp() public {
        addresses = new Addresses();

        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "MOONWELL_DEPLOY_PK",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        vm.startBroadcast(PRIVATE_KEY);

        address unitroller = addresses.getAddress("UNITROLLER");
        // Morpho Blue on Base mainnet
        address morpho = addresses.getAddress("MORPHO_BLUE");

        MorphoViewsV2 viewsContract = new MorphoViewsV2();

        bytes memory initdata = abi.encodeWithSignature(
            "initialize(address,address)",
            unitroller,
            morpho
        );

        ProxyAdmin proxyAdmin = new ProxyAdmin();

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(viewsContract),
            address(proxyAdmin),
            initdata
        );

        console.log("MorphoViewsV2 Implementation:", address(viewsContract));
        console.log("MorphoViewsV2 Proxy:", address(proxy));
        console.log("ProxyAdmin:", address(proxyAdmin));

        vm.stopBroadcast();
    }
}
