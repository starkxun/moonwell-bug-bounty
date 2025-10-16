// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Script} from "@forge-std/Script.sol";

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

// TODO: update for new ChainlinkOEVWrapper
contract DeployChainlinkOEVWrapper is Script {
    function deploy(
        Addresses addresses
    ) public returns (TransparentUpgradeableProxy, ChainlinkOEVWrapper) {
        vm.startBroadcast();

        // Deploy the implementation contract
        ChainlinkOEVWrapper implementation = new ChainlinkOEVWrapper();

        // Get the ProxyAdmin address
        address proxyAdmin = addresses.getAddress("MRD_PROXY_ADMIN");

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            ChainlinkOEVWrapper.initialize.selector,
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
        ChainlinkOEVWrapper implementation
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
            "DeployChainlinkOEVWrapper: proxy implementation mismatch"
        );

        require(
            actualProxyAdmin == address(proxyAdmin),
            "DeployChainlinkOEVWrapper: proxy admin mismatch"
        );

        // Validate implementation configuration
        ChainlinkOEVWrapper proxyInstance = ChainlinkOEVWrapper(
            address(proxy)
        );

        require(
            proxyInstance.owner() == addresses.getAddress("MRD_PROXY_ADMIN"),
            "DeployChainlinkOEVWrapper: implementation owner mismatch"
        );

        require(
            address(proxyInstance.priceFeed()) ==
                addresses.getAddress("CHAINLINK_WELL_USD"),
            "DeployChainlinkOEVWrapper: price feed address mismatch"
        );
    }

    function run()
        public
        returns (TransparentUpgradeableProxy, ChainlinkOEVWrapper)
    {
        Addresses addresses = new Addresses();
        (
            TransparentUpgradeableProxy proxy,
            ChainlinkOEVWrapper implementation
        ) = deploy(addresses);
        validate(addresses, proxy, implementation);
        return (proxy, implementation);
    }
}
