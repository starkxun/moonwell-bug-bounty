// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Script} from "@forge-std/Script.sol";

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

/// @dev deprecated, no longer compatible with new wrapper
contract DeployChainlinkOEVWrapper is Script {
    function deploy(
        Addresses // addresses
    ) public pure returns (TransparentUpgradeableProxy, ChainlinkOEVWrapper) {
        // no longer compatible with new wrapper
        return (
            TransparentUpgradeableProxy(payable(address(0))),
            ChainlinkOEVWrapper(payable(address(0)))
        );
    }

    function validate(
        Addresses addresses,
        TransparentUpgradeableProxy proxy,
        ChainlinkOEVWrapper implementation
    ) public view {
        // no longer compatible with new wrapper
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
