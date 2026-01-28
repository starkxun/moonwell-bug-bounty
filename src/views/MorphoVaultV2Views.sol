// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {Comptroller} from "@protocol/Comptroller.sol";

/// @notice Interface for Morpho Vault V2 (adapter-based architecture)
interface IMorphoVaultV2 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function owner() external view returns (address);
    function curator() external view returns (address);
    function adapterRegistry() external view returns (address);
    function adaptersLength() external view returns (uint256);
    function adapters(uint256 index) external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

/// @notice Interface for Vault V2 Adapters
interface IVaultV2Adapter {
    function realAssets() external view returns (uint256);
    function morphoVaultV1() external view returns (address);
}

/// @notice Interface for MetaMorpho (underlying vault)
interface IMetaMorpho {
    function MORPHO() external view returns (address);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function fee() external view returns (uint96);
    function timelock() external view returns (uint256);
    function withdrawQueueLength() external view returns (uint256);
    function withdrawQueue(uint256 index) external view returns (bytes32);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/**
 * @title Moonwell Morpho Vault V2 Views Contract
 * @author Moonwell
 * @notice View contract for Morpho Vault V2 (adapter-based architecture)
 * @dev This contract provides read-only views for Vault V2 vaults that use adapters
 */
contract MorphoVaultV2Views is Initializable {
    /// @notice User balance in a Vault V2
    struct UserVaultBalance {
        address vault;
        uint256 shares;
        uint256 assets;
        uint256 assetValue; // USD value with 18 decimals
    }

    /// @notice Adapter information
    struct AdapterInfo {
        address adapter;
        uint256 realAssets;
        address underlyingVault; // MetaMorpho vault if MorphoVaultV1Adapter
        string underlyingVaultName;
        uint256 underlyingVaultTotalAssets;
        uint256 allocationPercentage; // Percentage of vault assets in this adapter (18 decimals)
    }

    /// @notice Complete Vault V2 information
    struct VaultV2Info {
        address vault;
        string name;
        string symbol;
        address asset;
        string assetName;
        string assetSymbol;
        uint8 assetDecimals;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 underlyingPrice; // USD price with 18 decimals
        address owner;
        address curator;
        address adapterRegistry;
        AdapterInfo[] adapters;
    }

    Comptroller public comptroller;

    /// @dev Initialize implementation to prevent initialization attacks
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _comptroller The comptroller address for price oracle access
    function initialize(address _comptroller) external initializer {
        require(
            Comptroller(_comptroller).isComptroller(),
            "Invalid comptroller"
        );
        comptroller = Comptroller(_comptroller);
    }

    /// @notice Get information for a single Vault V2
    /// @param _vault The Vault V2 address
    /// @return info Complete vault information
    function getVaultInfo(
        address _vault
    ) external view returns (VaultV2Info memory info) {
        IMorphoVaultV2 vault = IMorphoVaultV2(_vault);

        info.vault = _vault;
        info.name = vault.name();
        info.symbol = vault.symbol();
        info.asset = vault.asset();
        info.totalAssets = vault.totalAssets();
        info.totalSupply = vault.totalSupply();
        info.owner = vault.owner();
        info.curator = vault.curator();
        info.adapterRegistry = vault.adapterRegistry();

        // Get asset metadata
        IERC20Metadata asset = IERC20Metadata(info.asset);
        info.assetName = asset.name();
        info.assetSymbol = asset.symbol();
        info.assetDecimals = asset.decimals();

        // Get underlying price from Chainlink
        info.underlyingPrice = _getUnderlyingPrice(info.asset);

        // Get adapter information
        uint256 adaptersCount = vault.adaptersLength();
        info.adapters = new AdapterInfo[](adaptersCount);

        for (uint256 i = 0; i < adaptersCount; i++) {
            info.adapters[i] = _getAdapterInfo(
                vault.adapters(i),
                info.totalAssets
            );
        }

        return info;
    }

    /// @notice Get information for multiple Vault V2s
    /// @param _vaults Array of Vault V2 addresses
    /// @return infos Array of vault information
    function getVaultsInfo(
        address[] calldata _vaults
    ) external view returns (VaultV2Info[] memory infos) {
        infos = new VaultV2Info[](_vaults.length);

        for (uint256 i = 0; i < _vaults.length; i++) {
            infos[i] = this.getVaultInfo(_vaults[i]);
        }

        return infos;
    }

    /// @notice Get user balance in a Vault V2
    /// @param _vault The Vault V2 address
    /// @param _user The user address
    /// @return balance User balance information
    function getUserBalance(
        address _vault,
        address _user
    ) external view returns (UserVaultBalance memory balance) {
        IMorphoVaultV2 vault = IMorphoVaultV2(_vault);

        balance.vault = _vault;
        balance.shares = vault.balanceOf(_user);

        if (balance.shares > 0) {
            balance.assets = vault.convertToAssets(balance.shares);

            // Calculate USD value
            uint256 underlyingPrice = _getUnderlyingPrice(vault.asset());
            uint8 assetDecimals = IERC20Metadata(vault.asset()).decimals();

            // Normalize to 18 decimals: assets * price / 10^assetDecimals
            balance.assetValue =
                (balance.assets * underlyingPrice) /
                (10 ** assetDecimals);
        }

        return balance;
    }

    /// @notice Get user balances for multiple Vault V2s
    /// @param _vaults Array of Vault V2 addresses
    /// @param _user The user address
    /// @return balances Array of user balance information
    function getUserBalances(
        address[] calldata _vaults,
        address _user
    ) external view returns (UserVaultBalance[] memory balances) {
        balances = new UserVaultBalance[](_vaults.length);

        for (uint256 i = 0; i < _vaults.length; i++) {
            balances[i] = this.getUserBalance(_vaults[i], _user);
        }

        return balances;
    }

    /// @notice Get adapter information
    /// @param _adapter The adapter address
    /// @param _vaultTotalAssets Total assets of the parent vault (for percentage calculation)
    /// @return info Adapter information
    function _getAdapterInfo(
        address _adapter,
        uint256 _vaultTotalAssets
    ) internal view returns (AdapterInfo memory info) {
        IVaultV2Adapter adapter = IVaultV2Adapter(_adapter);

        info.adapter = _adapter;
        info.realAssets = adapter.realAssets();

        // Calculate allocation percentage (18 decimals)
        if (_vaultTotalAssets > 0) {
            info.allocationPercentage =
                (info.realAssets * 1e18) /
                _vaultTotalAssets;
        }

        // Try to get underlying MetaMorpho vault (if MorphoVaultV1Adapter)
        try adapter.morphoVaultV1() returns (address underlyingVault) {
            info.underlyingVault = underlyingVault;
            if (underlyingVault != address(0)) {
                IMetaMorpho metaMorpho = IMetaMorpho(underlyingVault);
                info.underlyingVaultName = metaMorpho.name();
                info.underlyingVaultTotalAssets = metaMorpho.totalAssets();
            }
        } catch {
            // Not a MorphoVaultV1Adapter or doesn't have this function
            info.underlyingVault = address(0);
        }

        return info;
    }

    /// @notice Get Chainlink price from a feed
    /// @param feed The Chainlink price feed
    /// @return price USD price with 18 decimals
    function _getChainlinkPrice(
        AggregatorV3Interface feed
    ) internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        require(answer > 0, "Chainlink price cannot be lower than 0");
        require(updatedAt != 0, "Round is in incompleted state");

        // Chainlink USD-denominated feeds store answers at 8 decimals
        uint256 decimalDelta = feed.decimals() > 18 ? 0 : 18 - feed.decimals();
        if (decimalDelta > 0) {
            return uint256(answer) * (10 ** decimalDelta);
        } else {
            return uint256(answer);
        }
    }

    /// @notice Get underlying asset price from Chainlink oracle
    /// @param _asset The asset address
    /// @return price USD price with 18 decimals
    function _getUnderlyingPrice(
        address _asset
    ) internal view returns (uint256 price) {
        try
            ChainlinkOracle(address(comptroller.oracle())).getFeed(
                IERC20Metadata(_asset).symbol()
            )
        returns (AggregatorV3Interface priceFeed) {
            if (address(priceFeed) != address(0)) {
                return _getChainlinkPrice(priceFeed);
            }
        } catch {}
        return 0;
    }

    /// @notice Get the underlying MetaMorpho vault info through an adapter
    /// @param _adapter The adapter address
    /// @return vault The underlying MetaMorpho vault address
    /// @return totalAssets Total assets in the MetaMorpho vault
    /// @return markets Number of markets in the MetaMorpho vault
    function getAdapterUnderlyingInfo(
        address _adapter
    )
        external
        view
        returns (address vault, uint256 totalAssets, uint256 markets)
    {
        try IVaultV2Adapter(_adapter).morphoVaultV1() returns (
            address underlyingVault
        ) {
            if (underlyingVault != address(0)) {
                IMetaMorpho metaMorpho = IMetaMorpho(underlyingVault);
                return (
                    underlyingVault,
                    metaMorpho.totalAssets(),
                    metaMorpho.withdrawQueueLength()
                );
            }
        } catch {}

        return (address(0), 0, 0);
    }
}
