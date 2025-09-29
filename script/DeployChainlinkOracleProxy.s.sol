// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Script} from "@forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {ChainlinkOracleProxy} from "@protocol/oracles/ChainlinkOracleProxy.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

contract DeployChainlinkOracleProxy is Script {
    function deploy(
        Addresses addresses
    ) public returns (TransparentUpgradeableProxy, ChainlinkOracleProxy) {
        vm.startBroadcast();

        // Deploy the implementation contract
        ChainlinkOracleProxy implementation = new ChainlinkOracleProxy();

        // Get the ProxyAdmin address
        address proxyAdmin = addresses.getAddress("MRD_PROXY_ADMIN");

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            ChainlinkOracleProxy.initialize.selector,
            addresses.getAddress("CHAINLINK_WELL_USD"), // Price feed address
            msg.sender // Owner address
        );

        // Deploy the TransparentUpgradeableProxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initData
        );

        vm.stopBroadcast();

        // Record deployed contracts
        addresses.addAddress(
            "CHAINLINK_ORACLE_PROXY_IMPL",
            address(implementation)
        );
        addresses.addAddress("CHAINLINK_ORACLE_PROXY", address(proxy));

        return (proxy, implementation);
    }

    function run()
        public
        returns (TransparentUpgradeableProxy, ChainlinkOracleProxy)
    {
        Addresses addresses = new Addresses();
        return deploy(addresses);
    }
}
