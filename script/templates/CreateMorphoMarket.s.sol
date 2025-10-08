// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/Test.sol";
import {stdJson} from "@forge-std/StdJson.sol";

import "@protocol/utils/ChainIds.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {IMetaMorpho, MarketParams, IMetaMorphoStaticTyping} from "@protocol/morpho/IMetaMorpho.sol";
import {IMorphoBlue} from "@protocol/morpho/IMorphoBlue.sol";
import {IMorphoChainlinkOracleV2Factory} from "@protocol/morpho/IMorphoChainlinkOracleFactory.sol";
import {IMorphoChainlinkOracleV2} from "@protocol/morpho/IMorphoChainlinkOracleV2.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "@forge-std/console.sol";
import {IERC4626} from "@forge-std/interfaces/IERC4626.sol";

/// @notice Template script: Create a Morpho Blue market and configure a vault cap/supply queue based on JSON
contract CreateMorphoMarket is Script, Test {
    using ChainIds for uint256;
    using stdJson for string;

    struct MarketConfig {
        string vaultAddressName; // vault registry name to configure caps/queues
        string loanTokenName; // name key for loan token (Addresses)
        string collateralTokenName; // name key for collateral token (Addresses)
        string irmName; // name key for IRM (Addresses)
        uint256 lltv; // loan-to-value mantissa
        uint256 supplyCap; // cap in loan token units
        bool setSupplyQueue; // if true, update supply queue to only this market
        bool autoDeposit; // if true, perform deposit/supply/borrow demo actions
        uint256 vaultDepositAssets; // amount of assets to deposit into the vault
        uint256 collateralAmount; // amount of collateral to supply to Morpho
        uint256 borrowAssets; // amount of assets to borrow
        // Optional oracle deployment block: presence triggers deployment if missing
        bool oracleConfigPresent;
        OracleConfig oracle;
    }

    struct OracleConfig {
        string addressName; // name key for oracle (Addresses)
        string baseFeedName; // e.g. CHAINLINK_WELL_USD
        uint8 baseFeedDecimals; // e.g. 18
        string quoteFeedName; // e.g. CHAINLINK_USDC_USD
        uint8 quoteFeedDecimals; // e.g. 6
    }

    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    function run() external {
        // Setup fork for Base chain
        BASE_FORK_ID.createForksAndSelect();

        string memory json = vm.readFile(vm.envString("NEW_MARKET_PATH"));
        MarketConfig memory cfg = _parseConfig(json);

        Addresses addresses = new Addresses();

        // Enforcing an immediate borrow and deposit: https://docs.morpho.org/curate/tutorials-market-v1/creating-market/#fill-all-attributes
        assertGt(cfg.vaultDepositAssets, 0, "config.vaultDepositAssets must be greater than 0");
        assertGt(cfg.collateralAmount, 0, "config.collateralAmount must be greater than 0");
        assertGt(cfg.borrowAssets, 0, "config.borrowAssets must be greater than 0");

        vm.startBroadcast();

        // Ensure oracle is deployed or deploy it
        _ensureOracle(addresses, cfg.oracleConfigPresent, cfg.oracle);

        MarketParams memory market = _buildMarketParams(addresses, cfg);
        bytes32 marketId = _computeMarketId(market);
        address morphoBlue = addresses.getAddress("MORPHO_BLUE");

        _createMarket(morphoBlue, market, marketId, cfg);

        _validate(addresses, market, cfg, marketId, morphoBlue);

        // TODO: is this ever optional?
        if (bytes(cfg.vaultAddressName).length != 0 && cfg.supplyCap > 0) {
            _configureVault(addresses, cfg.vaultAddressName, cfg.supplyCap, cfg.setSupplyQueue, marketId, market);
        }

        _supplyAndBorrow(addresses, cfg.vaultAddressName, morphoBlue, market, cfg.vaultDepositAssets, cfg.collateralAmount, cfg.borrowAssets);

        vm.stopBroadcast();
    }

    function _parseConfig(
        string memory json
    ) internal pure returns (MarketConfig memory cfg) {
        cfg = _parseCore(json);
        cfg = _parseOptionals(json, cfg);
        (bool hasOracle, OracleConfig memory ocfg) = _maybeParseOracle(json);
        if (hasOracle) {
            cfg.oracleConfigPresent = true;
            cfg.oracle = ocfg;
        }
    }

    function _parseCore(
        string memory json
    ) internal pure returns (MarketConfig memory cfg) {
        cfg.vaultAddressName = json.readString(".vaultAddressName");
        cfg.loanTokenName = json.readString(".loanTokenName");
        cfg.collateralTokenName = json.readString(".collateralTokenName");
        cfg.irmName = json.readString(".irmName");
        cfg.lltv = json.readUint(".lltv");
        cfg.supplyCap = json.readUint(".supplyCap");
    }

    function _parseOptionals(
        string memory json,
        MarketConfig memory cfg
    ) internal pure returns (MarketConfig memory) {
        if (json.parseRaw(".setSupplyQueue").length != 0) {
            cfg.setSupplyQueue = json.readBool(".setSupplyQueue");
        }
        if (json.parseRaw(".autoDeposit").length != 0) {
            cfg.autoDeposit = json.readBool(".autoDeposit");
        }
        if (json.parseRaw(".vaultDepositAssets").length != 0) {
            cfg.vaultDepositAssets = json.readUint(".vaultDepositAssets");
        }
        if (json.parseRaw(".collateralAmount").length != 0) {
            cfg.collateralAmount = json.readUint(".collateralAmount");
        }
        if (json.parseRaw(".borrowAssets").length != 0) {
            cfg.borrowAssets = json.readUint(".borrowAssets");
        }
        return cfg;
    }

    function _maybeParseOracle(
        string memory json
    ) internal pure returns (bool present, OracleConfig memory ocfg) {
        bytes memory oracleRaw = json.parseRaw(".oracle");
        if (oracleRaw.length == 0) {
            return (false, ocfg);
        }
        present = true;
        ocfg.baseFeedName = json.readString(".oracle.baseFeedName");
        ocfg.baseFeedDecimals = uint8(json.readUint(".oracle.baseFeedDecimals"));
        ocfg.quoteFeedName = json.readString(".oracle.quoteFeedName");
        ocfg.quoteFeedDecimals = uint8(
            json.readUint(".oracle.quoteFeedDecimals")
        );
        ocfg.addressName = json.readString(".oracle.addressName");
    }

    function _computeMarketId(
        MarketParams memory params
    ) internal pure returns (bytes32 marketParamsId) {
        assembly ("memory-safe") {
            marketParamsId := keccak256(params, MARKET_PARAMS_BYTES_LENGTH)
        }
    }

    function _ensureOracle(
        Addresses addresses,
        bool oracleConfigPresent,
        OracleConfig memory ocfg
    ) internal {
        if (oracleConfigPresent && !addresses.isAddressSet(ocfg.addressName)) {
            _deployAndRegisterOracle(addresses, ocfg);
        } else {
            require(addresses.isAddressSet(ocfg.addressName), "Oracle not found");
        }
    }

    function _buildMarketParams(
        Addresses addresses,
        MarketConfig memory cfg
    ) internal view returns (MarketParams memory) {
        return
            MarketParams({
                loanToken: addresses.getAddress(cfg.loanTokenName),
                collateralToken: addresses.getAddress(cfg.collateralTokenName),
                oracle: addresses.getAddress(cfg.oracle.addressName),
                irm: addresses.getAddress(cfg.irmName),
                lltv: cfg.lltv
            });
    }

    function _createMarket(
        address morphoBlue,
        MarketParams memory market,
        bytes32 marketId,
        MarketConfig memory cfg
    ) internal {
        console.log(
            "Creating market on Morpho Blue with parameters:"
        );
        console.log("Loan token (%s): %s", cfg.loanTokenName, market.loanToken);
        console.log("Collateral token (%s): %s", cfg.collateralTokenName, market.collateralToken);
        console.log("Oracle (%s): %s", cfg.oracle.addressName, market.oracle);
        console.log("IRM (%s): %s", cfg.irmName, market.irm);
        console.log("LLTV: %s", market.lltv);

        IMorphoBlue(morphoBlue).createMarket(market);

        console.log("Market created:");
        console.logBytes32(marketId);
    }

    function _validate(
        Addresses addresses,
        MarketParams memory market,
        MarketConfig memory cfg,
        bytes32 marketId,
        address morphoBlue
    ) internal view {
        // Market params match config
        assertEq(
            market.loanToken,
            addresses.getAddress(cfg.loanTokenName),
            "Market loan token mismatch"
        );
        assertEq(
            market.collateralToken,
            addresses.getAddress(cfg.collateralTokenName),
            "Market collateral token mismatch"
        );
        assertEq(
            market.oracle,
            addresses.getAddress(cfg.oracle.addressName),
            "Market oracle mismatch"
        );
        assertEq(
            market.irm,
            addresses.getAddress(cfg.irmName),
            "Market IRM mismatch"
        );
        assertEq(market.lltv, cfg.lltv, "Market LLTV mismatch");

        // If a vault is configured, validate cap status
        if (bytes(cfg.vaultAddressName).length != 0 && cfg.supplyCap > 0) {
            IMetaMorpho vault = IMetaMorpho(
                addresses.getAddress(cfg.vaultAddressName)
            );
            (uint184 cap, bool accepted, uint64 removableAt) = IMetaMorphoStaticTyping(
                address(vault)
            ).config(marketId);
            assertEq(cap, cfg.supplyCap, "Market cap mismatch");
            assertEq(accepted, true, "Market cap should be accepted");
            assertEq(removableAt, 0, "Market cap should not be removable");
        }

        console.log("Validation completed successfully");
        console.log("Market loan token:", market.loanToken);
        console.log("Market collateral token:", market.collateralToken);
        console.log("Market oracle:", market.oracle);
        console.log("Market IRM:", market.irm);
        console.log("Market LLTV:", market.lltv);
        console.log("Market id:");
        console.logBytes32(marketId);
    }

    function _configureVault(
        Addresses addresses,
        string memory vaultAddressName,
        uint256 supplyCap,
        bool setSupplyQueue,
        bytes32 marketId,
        MarketParams memory market
    ) internal {
        IMetaMorpho vault = IMetaMorpho(addresses.getAddress(vaultAddressName));
        vault.submitCap(market, supplyCap);
        vault.acceptCap(market);

        if (setSupplyQueue) {
            bytes32[] memory queue = new bytes32[](1);
            queue[0] = marketId;
            vault.setSupplyQueue(queue);
        }

        (uint184 cap, bool accepted, ) = IMetaMorphoStaticTyping(address(vault))
            .config(marketId);
        require(cap == supplyCap && accepted, "cap not set/accepted");
    }

    function _supplyAndBorrow(
        Addresses addresses,
        string memory vaultAddressName,
        address morphoBlue,
        MarketParams memory market,
        uint256 vaultDepositAssets,
        uint256 collateralAmount,
        uint256 borrowAssets
    ) internal {
        console.log("=== Step 1: Depositing into Vault ===");

        IMetaMorpho vault = IMetaMorpho(addresses.getAddress(vaultAddressName));

        IERC20(market.loanToken).approve(address(vault), vaultDepositAssets);
        uint256 sharesMinted = vault.deposit(vaultDepositAssets, msg.sender);
        console.log("Deposited loan asset into vault:", vaultDepositAssets);
        console.log("Shares minted:", sharesMinted);

        console.log("=== Step 2: Supplying Collateral to Morpho ===");
        IERC20(market.collateralToken).approve(morphoBlue, collateralAmount);
        IMorphoBlue(morphoBlue).supplyCollateral(
            market,
            collateralAmount,
            msg.sender,
            ""
        );
        console.log("Supplied collateral:", collateralAmount);

        console.log("=== Step 3: Borrowing Loan Asset ===");
        (uint256 assetsBorrowed, uint256 sharesBorrowed) = IMorphoBlue(
            morphoBlue
        ).borrow(market, borrowAssets, 0, msg.sender, msg.sender);
        console.log("Borrowed:", assetsBorrowed);
        console.log("Borrow shares:", sharesBorrowed);

        uint256 collateralBal = IERC20(market.collateralToken).balanceOf(
            msg.sender
        );
        uint256 loanBal = IERC20(market.loanToken).balanceOf(msg.sender);
        console.log("=== Final Balances ===");
        console.log("Collateral token:", collateralBal);
        console.log("Loan token:", loanBal);
    }

    function _deployAndRegisterOracle(
        Addresses addresses,
        CreateMorphoMarket.OracleConfig memory ocfg
    ) internal {
        IMorphoChainlinkOracleV2Factory oracleFactory = IMorphoChainlinkOracleV2Factory(
            addresses.getAddress("MORPHO_CHAINLINK_ORACLE_FACTORY")
        );
        (AggregatorV3Interface baseFeed, AggregatorV3Interface quoteFeed) = _getFeeds(
            addresses,
            ocfg
        );
        IMorphoChainlinkOracleV2 oracle = _createOracle(
            oracleFactory,
            baseFeed, // TODO: deploy the new proxy contract to wrap the base feed
            quoteFeed, // TODO: not wrapping this!!!
            ocfg.baseFeedDecimals,
            ocfg.quoteFeedDecimals
        );
        addresses.addAddress(ocfg.addressName, address(oracle));
    }

    function _getFeeds(
        Addresses addresses,
        CreateMorphoMarket.OracleConfig memory ocfg
    ) internal view returns (AggregatorV3Interface, AggregatorV3Interface) {
        AggregatorV3Interface baseFeed = AggregatorV3Interface(
            addresses.getAddress(ocfg.baseFeedName)
        );
        AggregatorV3Interface quoteFeed = AggregatorV3Interface(
            addresses.getAddress(ocfg.quoteFeedName)
        );
        return (baseFeed, quoteFeed);
    }

    function _createOracle(
        IMorphoChainlinkOracleV2Factory oracleFactory,
        AggregatorV3Interface baseFeed,
        AggregatorV3Interface quoteFeed,
        uint8 baseFeedDecimals,
        uint8 quoteFeedDecimals
    ) internal returns (IMorphoChainlinkOracleV2) {
        IMorphoChainlinkOracleV2 oracle = oracleFactory
            .createMorphoChainlinkOracleV2(
                IERC4626(address(0)), // no base vault
                1, // no conversion sample
                baseFeed,
                AggregatorV3Interface(address(0)),
                baseFeedDecimals,
                IERC4626(address(0)), // no quote vault
                1, // no conversion sample
                quoteFeed,
                AggregatorV3Interface(address(0)), // no second quote feed
                quoteFeedDecimals,
                bytes32(0) // no salt
            );
        return oracle;
    }
}
