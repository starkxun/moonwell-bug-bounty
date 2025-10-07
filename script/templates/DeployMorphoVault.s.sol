// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/Test.sol";
import {stdJson} from "@forge-std/StdJson.sol";

import "@protocol/utils/ChainIds.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {IMetaMorphoFactory} from "@protocol/morpho/IMetaMorphoFactory.sol";
import {IMetaMorpho} from "@protocol/morpho/IMetaMorpho.sol";

/// @notice Template script: Deploy a MetaMorpho vaultAddress from JSON config
contract DeployMorphoVault is Script, Test {
    using ChainIds for uint256;
    using stdJson for string;

    struct VaultConfig {
        string addressName; // key used in Addresses registry, e.g. "llUSDC_METAMORPHO_VAULT"
        string vaultName; // ERC4626 name
        string vaultSymbol; // ERC4626 symbol
        string assetName; // name key to resolve via Addresses.getAddress(), e.g. "USDC"
        string saltString; // arbitrary string to hash into a salt, e.g. "llUSDC"
        uint256 initialTimelock; // initial timelock duration
        string curatorName; // optional: name key for initial curator to set
    }

    function run() external {
        // TODO: BASE_FORK_ID.createForksAndSelect fails
        // Setup fork for Base chain
        BASE_FORK_ID.createForksAndSelect();
        // vm.createSelectFork("base");

        string memory configPath = vm.envString("NEW_VAULT_PATH");
        string memory json = vm.readFile(configPath);

        VaultConfig memory cfg = _parseConfig(json);

        Addresses addresses = new Addresses();

        // If already registered, skip
        if (addresses.isAddressSet(cfg.addressName)) {
            console.log("Vault already exists for name:", cfg.addressName);
            console.log("Address:", addresses.getAddress(cfg.addressName));
            return;
        }

        address asset = addresses.getAddress(cfg.assetName);

        address initialOwner = msg.sender;
        bytes32 salt = keccak256(abi.encodePacked(cfg.saltString));

        vm.startBroadcast();
        address vaultAddress = IMetaMorphoFactory(
            addresses.getAddress("MORPHO_FACTORY_V1_1")
        ).createMetaMorpho(
            initialOwner,
            cfg.initialTimelock,
            asset,
            cfg.vaultName,
            cfg.vaultSymbol,
            salt
        );

        addresses.addAddress(cfg.addressName, vaultAddress);

        // Set msg.sender as curator role as default
        IMetaMorpho(vaultAddress).setCurator(initialOwner);

        // Optionally set initial curator on the vaultAddress
        if (bytes(cfg.curatorName).length != 0) {
            address curator = addresses.getAddress(cfg.curatorName);
            IMetaMorpho(vaultAddress).setCurator(curator);
        }

        vm.stopBroadcast();

        console.log("Deployed MetaMorpho vault:", vaultAddress);
        console.log("Registered as:", cfg.addressName);
        addresses.printAddresses();
    }

    function _parseConfig(
        string memory json
    ) internal pure returns (VaultConfig memory cfg) {
        cfg.addressName = json.readString(".addressName");
        cfg.vaultName = json.readString(".vaultName");
        cfg.vaultSymbol = json.readString(".vaultSymbol");
        cfg.assetName = json.readString(".assetName");
        // optional fields
        if (json.parseRaw(".saltString").length != 0) {
            cfg.saltString = json.readString(".saltString");
        }
        if (json.parseRaw(".initialTimelock").length != 0) {
            cfg.initialTimelock = json.readUint(".initialTimelock");
        }
        if (json.parseRaw(".curatorName").length != 0) {
            cfg.curatorName = json.readString(".curatorName");
        }
    }
}
