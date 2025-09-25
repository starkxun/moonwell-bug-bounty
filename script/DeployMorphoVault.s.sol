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
import {console} from "@forge-std/console.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {IERC4626} from "@forge-std/interfaces/IERC4626.sol";

/// @notice Script to create a new MetaMorpho vault using the Morpho factory
contract DeployMorphoVault is Script, Test {
    using ChainIds for uint256;

    /// @notice The created MetaMorpho vault address
    IMetaMorpho public usdcVault;

    /// @notice The created market parameters
    MarketParams public market;

    uint256 public constant SUPPLY_CAP = 100_000_000e6; // 100M USDC

    uint256 public constant LLTV = 625_000_000_000_000_000; // 62.5%

    string public constant VAULT_NAME = "Lunar Labs Treasury USDC Vault"; // TODO verify

    string public constant VAULT_SYMBOL = "llUSDC"; // TODO verify

    bytes32 public constant SALT = keccak256(abi.encodePacked("llUSDC")); // TODO change

    uint256 public constant USDC_VAULT_DEPOSIT = 1e6;

    uint256 public constant WELL_COLLATERAL = 100e18;

    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    string public constant ADDRESS_NAME = "llUSDC_METAMORPHO_VAULT";

    function run() public {
        // Setup fork for Base chain
        BASE_FORK_ID.createForksAndSelect();

        // Initialize addresses
        Addresses addresses = new Addresses();

        // Hardcoded vault parameters
        address initialOwner = msg.sender;
        uint256 initialTimelock = 0;
        address asset = addresses.getAddress("USDC");
        IMorphoChainlinkOracleV2 oracle;
        if (!addresses.isAddressSet("MORPHO_CHAINLINK_WELL_USD_ORACLE")) {
            oracle = deployOracle(addresses);
        } else {
            oracle = IMorphoChainlinkOracleV2(
                addresses.getAddress("MORPHO_CHAINLINK_WELL_USD_ORACLE")
            );
        }

        // Market parameters for USDC/WELL market
        market = MarketParams({
            loanToken: asset,
            collateralToken: addresses.getAddress("xWELL_PROXY"),
            oracle: address(oracle),
            irm: addresses.getAddress("MORPHO_ADAPTIVE_CURVE_IRM"),
            lltv: LLTV
        });

        bytes32 marketId = computeMarketId();

        console.log("market id:");
        console.logBytes32(marketId);

        address vaultAddress = createVault(
            addresses,
            initialOwner,
            asset,
            initialTimelock,
            VAULT_NAME,
            VAULT_SYMBOL,
            SALT
        );

        usdcVault = IMetaMorpho(vaultAddress);

        console.log("MetaMorpho vault created at:", vaultAddress);

        // Add the created vault to the addresses registry
        addresses.addAddress(ADDRESS_NAME, vaultAddress);

        vm.startBroadcast();

        // Set msg.sender as curator role for now
        usdcVault.setCurator(initialOwner);

        // Then submit the supply cap to the market
        submitAndAcceptCap(addresses);

        bytes32[] memory newSupplyQueue = new bytes32[](1);
        newSupplyQueue[0] = marketId;

        usdcVault.setSupplyQueue(newSupplyQueue);

        usdcVault.setCurator(addresses.getAddress("LUKE_EOA"));

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
        IMetaMorpho vault = IMetaMorpho(addresses.getAddress(ADDRESS_NAME));

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
            addresses.getAddress("MORPHO_CHAINLINK_WELL_USD_ORACLE"),
            "Market oracle should match"
        );
        assertEq(
            market.irm,
            addresses.getAddress("MORPHO_ADAPTIVE_CURVE_IRM"),
            "Market IRM should match"
        );
        assertEq(market.lltv, LLTV, "Market LLTV should be 86%");

        assertEq(
            usdcVault.curator(),
            addresses.getAddress("LUKE_EOA"),
            "Curator should match"
        );

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

        console.log("Deposited USDC into vault:", USDC_VAULT_DEPOSIT);
        console.log("Shares minted:", sharesMinted);
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
                1e6,
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
                AggregatorV3Interface(
                    addresses.getAddress("CHAINLINK_WELL_USD")
                ),
                AggregatorV3Interface(address(0)), // no second base feed,
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

        addresses.addAddress(
            "MORPHO_CHAINLINK_WELL_USD_ORACLE",
            address(oracle)
        );

        return oracle;
    }

    function createVault(
        Addresses addresses,
        address initialOwner,
        address asset,
        uint256 initialTimelock,
        string memory vaultName,
        string memory vaultSymbol,
        bytes32 salt
    ) public returns (address) {
        string memory vaultAddressName = string.concat(
            vaultName,
            "_METAMORPHO_VAULT"
        );
        vm.startBroadcast();

        // Then create the MetaMorpho vault
        address vaultAddress = IMetaMorphoFactory(
            addresses.getAddress("MORPHO_FACTORY_V1_1")
        ).createMetaMorpho(
                initialOwner,
                initialTimelock,
                asset,
                vaultName,
                vaultSymbol,
                salt
            );

        vm.stopBroadcast();

        addresses.addAddress(vaultAddressName, vaultAddress);

        return vaultAddress;
    }
}
