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
import {ChainlinkOracleProxy} from "@protocol/oracles/ChainlinkOracleProxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
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

        vm.startBroadcast();

        // Ensure oracle is deployed or deploy it
        _ensureOracle(addresses, cfg.oracleConfigPresent, cfg.oracle);

        MarketParams memory market = _buildMarketParams(addresses, cfg);
        bytes32 marketId = _computeMarketId(market);
        address morphoBlue = addresses.getAddress("MORPHO_BLUE");

        _createMarket(morphoBlue, market, marketId, cfg);

        _validate(addresses, market, cfg, marketId);

        vm.stopBroadcast();
    }

    function _parseConfig(
        string memory json
    ) internal pure returns (MarketConfig memory cfg) {
        cfg = _parseCore(json);
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
        ocfg.baseFeedDecimals = uint8(
            json.readUint(".oracle.baseFeedDecimals")
        );
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
            require(
                addresses.isAddressSet(ocfg.addressName),
                "Oracle not found"
            );
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
        console.log("Creating market on Morpho Blue with parameters:");
        console.log("Loan token (%s): %s", cfg.loanTokenName, market.loanToken);
        console.log(
            "Collateral token (%s): %s",
            cfg.collateralTokenName,
            market.collateralToken
        );
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
        bytes32 marketId
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

        console.log("Validation completed successfully");
        console.log("Market loan token:", market.loanToken);
        console.log("Market collateral token:", market.collateralToken);
        console.log("Market oracle:", market.oracle);
        console.log("Market IRM:", market.irm);
        console.log("Market LLTV:", market.lltv);
        console.log("Market id:");
        console.logBytes32(marketId);
    }

    function _deployAndRegisterOracle(
        Addresses addresses,
        CreateMorphoMarket.OracleConfig memory ocfg
    ) internal {
        IMorphoChainlinkOracleV2Factory oracleFactory = IMorphoChainlinkOracleV2Factory(
                addresses.getAddress("MORPHO_CHAINLINK_ORACLE_FACTORY")
            );
        AggregatorV3Interface baseFeed = _getOrDeployBaseFeed(addresses, ocfg);
        IMorphoChainlinkOracleV2 oracle = _createOracle(
            oracleFactory,
            baseFeed, // TODO: deploy the new proxy contract to wrap the base feed
            AggregatorV3Interface(addresses.getAddress(ocfg.quoteFeedName)), // assuming we don't deploy quote feeds (ie USDC)
            ocfg.baseFeedDecimals,
            ocfg.quoteFeedDecimals
        );
        addresses.addAddress(ocfg.addressName, address(oracle));
    }

    function _getOrDeployBaseFeed(
        Addresses addresses,
        CreateMorphoMarket.OracleConfig memory ocfg
    ) internal returns (AggregatorV3Interface) {
        if (addresses.isAddressSet(ocfg.addressName)) {
            return
                AggregatorV3Interface(addresses.getAddress(ocfg.addressName));
        }

        ChainlinkOracleProxy logic = new ChainlinkOracleProxy();
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(logic),
            address(proxyAdmin),
            ""
        );

        ChainlinkOracleProxy(address(proxy)).initialize(
            addresses.getAddress(ocfg.baseFeedName),
            msg.sender
        );

        return AggregatorV3Interface(address(proxy));
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

/// @notice Follow-up script to set cap and queue on an existing vault for a given market
contract ConfigureMorphoMarketCaps is Script, Test {
    using ChainIds for uint256;
    using stdJson for string;

    struct CapsConfig {
        string vaultAddressName;
        string loanTokenName;
        string collateralTokenName;
        string irmName;
        uint256 lltv;
        uint256 supplyCap;
        bool setSupplyQueue;
        CreateMorphoMarket.OracleConfig oracle;
    }

    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    function run() external {
        BASE_FORK_ID.createForksAndSelect();

        string memory json = vm.readFile(vm.envString("NEW_MARKET_PATH"));
        CapsConfig memory cfg = _parse(json);

        Addresses addresses = new Addresses();

        // TODO: need to prank anthias for dry run; remove this line before merging
        vm.startBroadcast(addresses.getAddress("ANTHIAS_MULTISIG"));

        MarketParams memory market = MarketParams({
            loanToken: addresses.getAddress(cfg.loanTokenName),
            collateralToken: addresses.getAddress(cfg.collateralTokenName),
            oracle: addresses.getAddress(cfg.oracle.addressName),
            irm: addresses.getAddress(cfg.irmName),
            lltv: cfg.lltv
        });

        bytes32 marketId = _computeMarketId(market);
        IMetaMorpho vault = IMetaMorpho(
            addresses.getAddress(cfg.vaultAddressName)
        );

        vault.submitCap(market, cfg.supplyCap);
        vault.acceptCap(market);
        if (cfg.setSupplyQueue) {
            bytes32[] memory queue = new bytes32[](1);
            queue[0] = marketId;
            vault.setSupplyQueue(queue);
        }
        vm.stopPrank();
        (
            uint184 cap,
            bool accepted,
            uint64 removableAt
        ) = IMetaMorphoStaticTyping(address(vault)).config(marketId);
        assertEq(cap, cfg.supplyCap, "cap mismatch");
        assertEq(accepted, true, "cap not accepted");
        assertEq(removableAt, 0, "cap should not be removable");

        console.log("Configured cap/queue for market:");
        console.logBytes32(marketId);
    }

    function _parse(
        string memory json
    ) internal pure returns (CapsConfig memory cfg) {
        cfg.vaultAddressName = json.readString(".vaultAddressName");
        cfg.loanTokenName = json.readString(".loanTokenName");
        cfg.collateralTokenName = json.readString(".collateralTokenName");
        cfg.irmName = json.readString(".irmName");
        cfg.lltv = json.readUint(".lltv");
        cfg.supplyCap = json.readUint(".supplyCap");
        if (json.parseRaw(".setSupplyQueue").length != 0) {
            cfg.setSupplyQueue = json.readBool(".setSupplyQueue");
        }
        // oracle nested
        cfg.oracle.addressName = json.readString(".oracle.addressName");
    }

    function _computeMarketId(
        MarketParams memory params
    ) internal pure returns (bytes32 marketParamsId) {
        assembly ("memory-safe") {
            marketParamsId := keccak256(params, MARKET_PARAMS_BYTES_LENGTH)
        }
    }
}

/// @notice Follow-up script to deposit to vault, supply collateral and borrow on a market
contract MorphoSupplyBorrow is Script, Test {
    using ChainIds for uint256;
    using stdJson for string;

    struct SBConfig {
        string vaultAddressName;
        string loanTokenName;
        string collateralTokenName;
        string irmName;
        uint256 lltv;
        uint256 vaultDepositAssets;
        uint256 collateralAmount;
        uint256 borrowAssets;
        CreateMorphoMarket.OracleConfig oracle;
    }

    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    function run() external {
        BASE_FORK_ID.createForksAndSelect();

        string memory json = vm.readFile(vm.envString("NEW_MARKET_PATH"));
        SBConfig memory cfg = _parse(json);

        Addresses addresses = new Addresses();

        // Enforcing an immediate borrow and deposit: https://docs.morpho.org/curate/tutorials-market-v1/creating-market/#fill-all-attributes
        assertGt(
            cfg.vaultDepositAssets,
            0,
            "config.vaultDepositAssets must be greater than 0"
        );
        assertGt(
            cfg.collateralAmount,
            0,
            "config.collateralAmount must be greater than 0"
        );
        assertGt(
            cfg.borrowAssets,
            0,
            "config.borrowAssets must be greater than 0"
        );

        MarketParams memory market = MarketParams({
            loanToken: addresses.getAddress(cfg.loanTokenName),
            collateralToken: addresses.getAddress(cfg.collateralTokenName),
            oracle: addresses.getAddress(cfg.oracle.addressName),
            irm: addresses.getAddress(cfg.irmName),
            lltv: cfg.lltv
        });

        address morphoBlue = addresses.getAddress("MORPHO_BLUE");
        IMetaMorpho vault = IMetaMorpho(
            addresses.getAddress(cfg.vaultAddressName)
        );

        // Scale human-readable amounts by oracle decimals
        uint256 depositAmount = _scaleByDecimals(
            cfg.vaultDepositAssets,
            cfg.oracle.quoteFeedDecimals
        );
        uint256 supplyAmount = _scaleByDecimals(
            cfg.collateralAmount,
            cfg.oracle.baseFeedDecimals
        );
        uint256 borrowAmount = cfg.borrowAssets;
        vm.startBroadcast();

        IERC20(market.loanToken).approve(address(vault), depositAmount);
        uint256 sharesMinted = vault.deposit(depositAmount, msg.sender);
        console.log("Deposited loan asset into vault:", depositAmount);
        console.log("Shares minted:", sharesMinted);

        IERC20(market.collateralToken).approve(morphoBlue, supplyAmount);
        IMorphoBlue(morphoBlue).supplyCollateral(
            market,
            supplyAmount,
            msg.sender,
            ""
        );
        console.log("Supplied collateral:", supplyAmount);

        (uint256 assetsBorrowed, uint256 sharesBorrowed) = IMorphoBlue(
            morphoBlue
        ).borrow(market, borrowAmount, 0, msg.sender, msg.sender);
        vm.stopBroadcast();

        console.log("Borrowed:", assetsBorrowed);
        console.log("Borrow shares:", sharesBorrowed);
        console.log(
            "Loan token balance:",
            IERC20(market.loanToken).balanceOf(msg.sender)
        );
        console.log(
            "Collateral token balance:",
            IERC20(market.collateralToken).balanceOf(msg.sender)
        );
    }

    function _parse(
        string memory json
    ) internal pure returns (SBConfig memory cfg) {
        cfg.vaultAddressName = json.readString(".vaultAddressName");
        cfg.loanTokenName = json.readString(".loanTokenName");
        cfg.collateralTokenName = json.readString(".collateralTokenName");
        cfg.irmName = json.readString(".irmName");
        cfg.lltv = json.readUint(".lltv");
        cfg.vaultDepositAssets = json.readUint(".vaultDepositAssets");
        cfg.collateralAmount = json.readUint(".collateralAmount");
        cfg.borrowAssets = json.readUint(".borrowAssets");
        // oracle nested
        cfg.oracle.addressName = json.readString(".oracle.addressName");
        cfg.oracle.baseFeedDecimals = uint8(
            json.readUint(".oracle.baseFeedDecimals")
        );
        cfg.oracle.quoteFeedDecimals = uint8(
            json.readUint(".oracle.quoteFeedDecimals")
        );
    }

    function _scaleByDecimals(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        return amount * (10 ** uint256(decimals));
    }
}
