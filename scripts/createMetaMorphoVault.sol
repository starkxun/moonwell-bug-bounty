// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";
import "@forge-std/Script.sol";

import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {IMetaMorphoFactory} from "@protocol/morpho/IMetaMorphoFactory.sol";
import {IMetaMorpho, MarketParams} from "@protocol/morpho/IMetaMorpho.sol";
import {IMorphoBlue} from "@protocol/morpho/IMorphoBlue.sol";
import "@protocol/utils/ChainIds.sol";

/// @notice Script to create a new MetaMorpho vault using the Morpho factory
contract CreateMetaMorphoVault is Script, Test {
    using ChainIds for uint256;

    /// @notice The created MetaMorpho vault address
    IMetaMorpho public createdVault;

    /// @notice The created market parameters
    MarketParams public createdMarket;

    function run() public {
        // Setup fork for Base chain
        BASE_FORK_ID.createForksAndSelect();

        // Initialize addresses
        Addresses addresses = new Addresses();

        // Get the Morpho factory address from the chain configuration
        address factoryAddress = addresses.getAddress("MORPHO_FACTORY_V1_1");
        IMetaMorphoFactory factory = IMetaMorphoFactory(factoryAddress);

        // Hardcoded vault parameters
        address initialOwner = msg.sender;
        uint256 initialTimelock = 0;
        address asset = addresses.getAddress("xWELL_PROXY");
        string memory vaultName = "Moonwell Growth/Outperform USDC";
        string memory vaultSymbol = "vWELL";
        bytes32 salt = keccak256(abi.encodePacked("test"));

        console.log("Creating MetaMorpho vault with the following parameters:");
        console.log("Factory address:", factoryAddress);
        console.log("Initial owner:", initialOwner);
        console.log("Initial timelock:", initialTimelock);
        console.log("Asset:", asset);
        console.log("Vault name:", vaultName);
        console.log("Vault symbol:", vaultSymbol);
        console.log("Salt:");
        console.logBytes32(salt);

        vm.startBroadcast();

        // First create the USDC/WELL market on Morpho Blue
        createMarket(addresses);

        // Then create the MetaMorpho vault
        address vaultAddress = factory.createMetaMorpho(
            initialOwner,
            initialTimelock,
            asset,
            vaultName,
            vaultSymbol,
            salt
        );

        vm.stopBroadcast();

        createdVault = IMetaMorpho(vaultAddress);

        console.log("MetaMorpho vault created at:", vaultAddress);

        // Add the created vault to the addresses registry
        string memory addressName = string(
            abi.encodePacked(vaultSymbol, "_METAMORPHO_VAULT")
        );
        addresses.addAddress(addressName, vaultAddress);

        console.log(
            "Added vault to addresses registry with name:",
            addressName
        );

        // Validate the created vault
        validate();
    }

    function createMarket(Addresses addresses) internal {
        // Get Morpho Blue contract
        IMorphoBlue morphoBlue = IMorphoBlue(
            addresses.getAddress("MORPHO_BLUE")
        );

        // Market parameters for USDC/WELL market
        MarketParams memory marketParams = MarketParams({
            loanToken: addresses.getAddress("USDC"),
            collateralToken: addresses.getAddress("xWELL_PROXY"),
            oracle: addresses.getAddress("CHAINLINK_WELL_USD_OEV_WRAPPER"),
            irm: addresses.getAddress("MORPHO_ADAPTIVE_CURVE_IRM"),
            lltv: 860000000000000000 // 86% LLTV (Loan to Loan-Token Value)
        });

        createdMarket = marketParams;

        console.log(
            "Creating USDC/WELL market on Morpho Blue with parameters:"
        );
        console.log("Loan token (USDC):", marketParams.loanToken);
        console.log("Collateral token (WELL):", marketParams.collateralToken);
        console.log("Oracle:", marketParams.oracle);
        console.log("IRM:", marketParams.irm);
        console.log("LLTV:", marketParams.lltv);

        // Create the market
        morphoBlue.createMarket(marketParams);

        console.log("USDC/WELL market created on Morpho Blue");
    }

    function validate() internal {
        // Validate vault creation
        assertTrue(
            address(createdVault) != address(0),
            "MetaMorpho vault should be created"
        );

        // Get addresses for validation
        Addresses addresses = new Addresses();
        address expectedAsset = addresses.getAddress("xWELL_PROXY");

        // Verify the vault parameters
        assertEq(
            createdVault.owner(),
            msg.sender,
            "Vault owner should match msg.sender"
        );
        assertEq(
            createdVault.asset(),
            expectedAsset,
            "Vault asset should match xWELL_PROXY"
        );
        assertEq(
            createdVault.name(),
            "Moonwell Growth/Outperform USDC",
            "Vault name should match specified name"
        );
        assertEq(
            createdVault.symbol(),
            "vWELL",
            "Vault symbol should match specified symbol"
        );

        // Validate market creation
        assertEq(
            createdMarket.loanToken,
            addresses.getAddress("USDC"),
            "Market loan token should be USDC"
        );
        assertEq(
            createdMarket.collateralToken,
            addresses.getAddress("xWELL_PROXY"),
            "Market collateral should be WELL"
        );
        assertEq(
            createdMarket.oracle,
            addresses.getAddress("CHAINLINK_WELL_USD_OEV_WRAPPER"),
            "Market oracle should match"
        );
        assertEq(
            createdMarket.irm,
            addresses.getAddress("MORPHO_ADAPTIVE_CURVE_IRM"),
            "Market IRM should match"
        );
        assertEq(createdMarket.lltv, 0.86e18, "Market LLTV should be 86%");

        console.log("Validation completed successfully");
        console.log("Created vault address:", address(createdVault));
        console.log("Vault owner:", createdVault.owner());
        console.log("Vault asset:", createdVault.asset());
        console.log("Vault name:", createdVault.name());
        console.log("Vault symbol:", createdVault.symbol());
        console.log("Market loan token:", createdMarket.loanToken);
        console.log("Market collateral token:", createdMarket.collateralToken);
        console.log("Market oracle:", createdMarket.oracle);
        console.log("Market IRM:", createdMarket.irm);
        console.log("Market LLTV:", createdMarket.lltv);
    }
}
