// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Script} from "@forge-std/Script.sol";

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
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
            addresses.getAddress("MRD_PROXY_ADMIN") // Owner address
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

    function validate(
        Addresses addresses,
        TransparentUpgradeableProxy proxy,
        ChainlinkOracleProxy implementation
    ) public view {
        // Get proxy admin contract
        ProxyAdmin proxyAdmin = ProxyAdmin(
            addresses.getAddress("MRD_PROXY_ADMIN")
        );

        // Validate proxy configuration
        address actualImplementation = proxyAdmin.getProxyImplementation(
            ITransparentUpgradeableProxy(address(proxy))
        );
        address actualProxyAdmin = proxyAdmin.getProxyAdmin(
            ITransparentUpgradeableProxy(address(proxy))
        );

        require(
            actualImplementation == address(implementation),
            "DeployChainlinkOracleProxy: proxy implementation mismatch"
        );

        require(
            actualProxyAdmin == address(proxyAdmin),
            "DeployChainlinkOracleProxy: proxy admin mismatch"
        );

        // Validate implementation configuration
        ChainlinkOracleProxy proxyInstance = ChainlinkOracleProxy(
            address(proxy)
        );

        require(
            proxyInstance.owner() == addresses.getAddress("MRD_PROXY_ADMIN"),
            "DeployChainlinkOracleProxy: implementation owner mismatch"
        );

        require(
            address(proxyInstance.priceFeed()) ==
                addresses.getAddress("CHAINLINK_WELL_USD"),
            "DeployChainlinkOracleProxy: price feed address mismatch"
        );
    }

    function run()
        public
        returns (TransparentUpgradeableProxy, ChainlinkOracleProxy)
    {
        Addresses addresses = new Addresses();
        (
            TransparentUpgradeableProxy proxy,
            ChainlinkOracleProxy implementation
        ) = deploy(addresses);
        validate(addresses, proxy, implementation);
        return (proxy, implementation);
    }
}
