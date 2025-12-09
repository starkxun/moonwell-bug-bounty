// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Script} from "@forge-std/Script.sol";

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {MWethOwnerWrapper} from "@protocol/MWethOwnerWrapper.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

/*
How to use:
forge script script/DeployMWethOwnerWrapper.s.sol:DeployMWethOwnerWrapper \
    -vvvv \
    --rpc-url base \
    --broadcast

Remove --broadcast if you want to try locally first, without paying any gas.
*/

contract DeployMWethOwnerWrapper is Script {
    function deploy(
        Addresses addresses
    ) public returns (TransparentUpgradeableProxy, MWethOwnerWrapper) {
        // Skip deployment if already deployed (check both addresses)
        if (
            addresses.isAddressSet("MWETH_OWNER_WRAPPER_IMPL") ||
            addresses.isAddressSet("MWETH_OWNER_WRAPPER")
        ) {
            return (
                TransparentUpgradeableProxy(
                    payable(addresses.getAddress("MWETH_OWNER_WRAPPER"))
                ),
                MWethOwnerWrapper(
                    payable(addresses.getAddress("MWETH_OWNER_WRAPPER_IMPL"))
                )
            );
        }

        vm.startBroadcast();

        // Deploy the implementation contract
        MWethOwnerWrapper implementation = new MWethOwnerWrapper();

        // Get required addresses
        address proxyAdmin = addresses.getAddress("MRD_PROXY_ADMIN");
        address mToken = addresses.getAddress("MOONWELL_WETH");
        address weth = addresses.getAddress("WETH");
        address temporalGovernor = addresses.getAddress("TEMPORAL_GOVERNOR");

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            MWethOwnerWrapper.initialize.selector,
            mToken,
            weth,
            temporalGovernor
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
            "MWETH_OWNER_WRAPPER_IMPL",
            address(implementation)
        );
        addresses.addAddress("MWETH_OWNER_WRAPPER", address(proxy));

        return (proxy, implementation);
    }

    function validate(
        Addresses addresses,
        TransparentUpgradeableProxy proxy,
        MWethOwnerWrapper implementation
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
            "DeployMWethOwnerWrapper: proxy implementation mismatch"
        );

        require(
            actualProxyAdmin == address(proxyAdmin),
            "DeployMWethOwnerWrapper: proxy admin mismatch"
        );

        // Validate wrapper configuration
        MWethOwnerWrapper wrapperInstance = MWethOwnerWrapper(
            payable(address(proxy))
        );

        require(
            wrapperInstance.owner() ==
                addresses.getAddress("TEMPORAL_GOVERNOR"),
            "DeployMWethOwnerWrapper: owner mismatch"
        );

        require(
            address(wrapperInstance.mToken()) ==
                addresses.getAddress("MOONWELL_WETH"),
            "DeployMWethOwnerWrapper: mToken address mismatch"
        );

        require(
            address(wrapperInstance.weth()) == addresses.getAddress("WETH"),
            "DeployMWethOwnerWrapper: weth address mismatch"
        );
    }

    function run()
        public
        returns (TransparentUpgradeableProxy, MWethOwnerWrapper)
    {
        Addresses addresses = new Addresses();
        (
            TransparentUpgradeableProxy proxy,
            MWethOwnerWrapper implementation
        ) = deploy(addresses);
        validate(addresses, proxy, implementation);
        return (proxy, implementation);
    }
}
