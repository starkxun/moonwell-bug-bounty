// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";
import "@forge-std/Script.sol";

import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {IMetaMorphoFactory} from "@protocol/morpho/IMetaMorphoFactory.sol";
import {IMetaMorpho, MarketParams, IMetaMorphoStaticTyping} from "@protocol/morpho/IMetaMorpho.sol";
import {IMorphoBlue} from "@protocol/morpho/IMorphoBlue.sol";
import "@protocol/utils/ChainIds.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IMorphoChainlinkOracleV2Factory} from "@protocol/morpho/IMorphoChainlinkOracleFactory.sol";
import {IMorphoChainlinkOracleV2} from "@protocol/morpho/IMorphoChainlinkOracleV2.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {IERC4626} from "@forge-std/interfaces/IERC4626.sol";

/// @notice Script to create a new MetaMorpho vault using the Morpho factory
contract CreateMetaMorphoVault is Script, Test {
    using ChainIds for uint256;

    /// @notice The created MetaMorpho vault address
    IMetaMorpho public usdcVault;

    /// @notice The created market parameters
    MarketParams public market;

    uint256 public constant SUPPLY_CAP = 10e18; // TODO change
    // TODO add anthias address as the curator

    uint256 public constant LLTV = 625_000_000_000_000_000;

    string public constant VAULT_NAME = "Moonwell Growth/Underperform USDC"; // TODO verify

    string public constant VAULT_SYMBOL = "USDC"; // TODO verify

    bytes32 public constant SALT = keccak256(abi.encodePacked("test_3")); // TODO change

    uint256 public constant USDC_VAULT_DEPOSIT = 1e6;

    uint256 public constant WELL_COLLATERAL = 42e18; // arround 1$

    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

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
        address asset = addresses.getAddress("USDC");

        IMorphoChainlinkOracleV2 oracle = deployOracle(addresses);

        // Market parameters for USDC/WELL market
        market = MarketParams({
            loanToken: asset,
            collateralToken: addresses.getAddress("xWELL_PROXY"),
            oracle: address(oracle),
            irm: addresses.getAddress("MORPHO_ADAPTIVE_CURVE_IRM"),
            lltv: LLTV
        });

        vm.startBroadcast();

        // First create the USDC/WELL market on Morpho Blue
        //createMarket(addresses);

        // Then create the MetaMorpho vault
        address vaultAddress = factory.createMetaMorpho(
            initialOwner,
            initialTimelock,
            asset,
            VAULT_NAME,
            VAULT_SYMBOL,
            SALT
        );

        vm.stopBroadcast();

        usdcVault = IMetaMorpho(vaultAddress);

        console.log("MetaMorpho vault created at:", vaultAddress);

        // Add the created vault to the addresses registry
        string memory addressName = string(
            abi.encodePacked(VAULT_SYMBOL, "_METAMORPHO_VAULT_TEST")
        );
        addresses.addAddress(addressName, vaultAddress);

        vm.startBroadcast();

        // Set msg.sender as curator role for now
        usdcVault.setCurator(initialOwner);

        // Then submit the supply cap to the market
        submitAndAcceptCap(addresses);

        bytes32[] memory newSupplyQueue = new bytes32[](1);
        newSupplyQueue[0] = computeMarketId();

        usdcVault.setSupplyQueue(newSupplyQueue);

        vm.stopBroadcast();

        // Validate the created vault and market
        validate(addresses);

        vm.startBroadcast();

        // Deposit into the vault
        depositIntoVault(addresses.getAddress("USDC"), vaultAddress);

        // Supply collateral to the market
        supplyCollateralToMorpho(
            addresses.getAddress("xWELL_PROXY"),
            addresses.getAddress("MORPHO_BLUE")
        );

        // Borrow from the market
        borrowFromMorpho(addresses.getAddress("MORPHO_BLUE"));

        // Display final balances
        displayFinalBalances(
            addresses.getAddress("xWELL_PROXY"),
            addresses.getAddress("USDC")
        );

        vm.stopBroadcast();

        // Print addresses
        addresses.printAddresses();
    }

    function createMarket(Addresses addresses) internal {
        // Get Morpho Blue contract
        IMorphoBlue morphoBlue = IMorphoBlue(
            addresses.getAddress("MORPHO_BLUE")
        );
        console.log(
            "Creating USDC/WELL market on Morpho Blue with parameters:"
        );
        console.log("Loan token (USDC):", market.loanToken);
        console.log("Collateral token (WELL):", market.collateralToken);
        console.log("Oracle:", market.oracle);
        console.log("IRM:", market.irm);
        console.log("LLTV:", market.lltv);

        // Create the market
        morphoBlue.createMarket(market);

        console.log("USDC/WELL market created on Morpho Blue");
    }

    function submitAndAcceptCap(Addresses addresses) internal {
        // Get Morpho Blue contract
        IMetaMorpho vault = IMetaMorpho(
            addresses.getAddress("USDC_METAMORPHO_VAULT_TEST")
        );

        vault.submitCap(market, SUPPLY_CAP);
        vault.acceptCap(market);
    }

    function validate(Addresses addresses) internal view {
        // Validate vault creation
        assertTrue(
            address(usdcVault) != address(0),
            "MetaMorpho vault should be created"
        );

        // Get addresses for validation
        address expectedAsset = addresses.getAddress("USDC");

        // Verify the vault parameters
        assertEq(
            usdcVault.owner(),
            msg.sender,
            "Vault owner should match msg.sender"
        );
        assertEq(
            usdcVault.asset(),
            expectedAsset,
            "Vault asset should match USDC"
        );
        assertEq(
            usdcVault.name(),
            VAULT_NAME,
            "Vault name should match specified name"
        );
        assertEq(
            usdcVault.symbol(),
            VAULT_SYMBOL,
            "Vault symbol should match specified symbol"
        );

        // Validate market creation
        assertEq(
            market.loanToken,
            addresses.getAddress("USDC"),
            "Market loan token should be USDC"
        );
        assertEq(
            market.collateralToken,
            addresses.getAddress("xWELL_PROXY"),
            "Market collateral should be WELL"
        );
        assertEq(
            market.oracle,
            addresses.getAddress("CHAINLINK_USDC_WELL_ORACLE"),
            "Market oracle should match"
        );
        assertEq(
            market.irm,
            addresses.getAddress("MORPHO_ADAPTIVE_CURVE_IRM"),
            "Market IRM should match"
        );
        assertEq(market.lltv, LLTV, "Market LLTV should be 86%");

        assertEq(usdcVault.curator(), msg.sender, "Curator should match");

        (
            uint184 cap,
            bool accepted,
            uint64 removableAt
        ) = IMetaMorphoStaticTyping(address(usdcVault)).config(
                computeMarketId()
            );
        assertEq(cap, SUPPLY_CAP, "Market cap should match");
        assertEq(accepted, true, "Market cap should be accepted");
        assertEq(removableAt, 0, "Market cap should not be removable");

        console.log("Validation completed successfully");
        console.log("Vault owner:", usdcVault.owner());
        console.log("Vault asset:", usdcVault.asset());
        console.log("Vault name:", usdcVault.name());
        console.log("Vault symbol:", usdcVault.symbol());
        console.log("Market loan token:", market.loanToken);
        console.log("Market collateral token:", market.collateralToken);
        console.log("Market oracle:", market.oracle);
        console.log("Market IRM:", market.irm);
        console.log("Market LLTV:", market.lltv);
    }

    function depositIntoVault(address usdcToken, address vault) internal {
        console.log("=== Step 1: Depositing into Vault ===");

        // Approve vault to spend WELL tokens
        IERC20(usdcToken).approve(vault, USDC_VAULT_DEPOSIT);

        // Deposit into the vault
        IMetaMorpho metaMorphoVault = IMetaMorpho(vault);
        uint256 sharesMinted = metaMorphoVault.deposit(
            USDC_VAULT_DEPOSIT,
            msg.sender
        );

        console.log("Deposited USDC into vault:", USDC_VAULT_DEPOSIT / 1e18);
        console.log("Shares minted:", sharesMinted / 1e18);
    }

    function supplyCollateralToMorpho(
        address wellToken,
        address morphoBlue
    ) internal {
        console.log("=== Step 2: Supplying Collateral to Morpho ===");

        // Approve Morpho Blue to spend WELL tokens
        IERC20(wellToken).approve(morphoBlue, WELL_COLLATERAL);

        // Supply WELL as collateral
        IMorphoBlue(morphoBlue).supplyCollateral(
            market,
            WELL_COLLATERAL,
            msg.sender,
            ""
        );

        console.log("Supplied WELL as collateral:", WELL_COLLATERAL / 1e18);
    }

    function borrowFromMorpho(address morphoBlue) internal {
        console.log("=== Step 3: Borrowing USDC ===");

        // Borrow USDC against WELL collateral
        (uint256 assetsBorrowed, uint256 sharesBorrowed) = IMorphoBlue(
            morphoBlue
        ).borrow(
                market,
                0.09e6, // TODO borrow 1$
                0, // shares = 0 means we want to borrow exact assets
                msg.sender,
                msg.sender
            );

        console.log("Borrowed USDC:", assetsBorrowed / 1e6);
        console.log("Borrow shares:", sharesBorrowed);
    }

    function displayFinalBalances(
        address wellToken,
        address usdcToken
    ) internal view {
        uint256 wellBalanceAfter = IERC20(wellToken).balanceOf(msg.sender);
        uint256 usdcBalanceAfter = IERC20(usdcToken).balanceOf(msg.sender);

        console.log("=== Final Balances ===");
        console.log("WELL:", wellBalanceAfter);
        console.log("USDC:", usdcBalanceAfter);
    }

    function computeMarketId() internal view returns (bytes32 marketParamsId) {
        MarketParams memory marketParams = market;
        assembly ("memory-safe") {
            marketParamsId := keccak256(
                marketParams,
                MARKET_PARAMS_BYTES_LENGTH
            )
        }
    }

    function deployOracle(
        Addresses addresses
    ) internal returns (IMorphoChainlinkOracleV2) {
        // Get Morpho Chainlink Oracle Factory contract
        IMorphoChainlinkOracleV2Factory oracleFactory = IMorphoChainlinkOracleV2Factory(
                addresses.getAddress("MORPHO_CHAINLINK_ORACLE_FACTORY")
            );

        vm.startBroadcast();

        IMorphoChainlinkOracleV2 oracle = oracleFactory
            .createMorphoChainlinkOracleV2(
                IERC4626(address(0)), // no base vault
                1, // no conversion sample
                AggregatorV3Interface(address(0)),
                AggregatorV3Interface(
                    addresses.getAddress("CHAINLINK_WELL_USD")
                ), // no second base feed,
                18,
                IERC4626(address(0)), // no quote vault
                1, // no conversion sample,
                AggregatorV3Interface(
                    addresses.getAddress("CHAINLINK_USDC_USD")
                ),
                AggregatorV3Interface(address(0)), // no second quote feed,
                6,
                bytes32(0) // no salt
            );
        vm.stopBroadcast();

        addresses.addAddress("CHAINLINK_USDC_WELL_ORACLE", address(oracle));

        return oracle;
    }
}
