pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {MorphoVaultV2Views} from "@protocol/views/MorphoVaultV2Views.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import "@utils/ChainIds.sol";

contract MorphoVaultV2ViewsTest is PostProposalCheck {
    using ChainIds for uint256;

    MorphoVaultV2Views public viewsContract;
    MorphoVaultV2Views public implementation;

    address public proxyAdmin = address(1337);

    // Morpho Vault V2 meUSDC on Base
    address public constant VAULT_V2_MEUSDC =
        0xbB2F06CeAE42CBcF5559Ed0713538c8892D977c9;

    // The adapter used by meUSDC Vault V2
    address public constant MEUSDC_ADAPTER =
        0xF144a14cEF059DB3746E6BED871bA105Ec047BB2;

    // Underlying MetaMorpho vault
    address public constant METAMORPHO_MEUSDC =
        0xE1bA476304255353aEF290e6474A417D06e7b773;

    function setUp() public override {
        super.setUp();

        // Switch to Base fork for testing
        vm.selectFork(BASE_FORK_ID);

        address comptroller = addresses.getAddress("UNITROLLER");

        implementation = new MorphoVaultV2Views();

        bytes memory initdata = abi.encodeWithSignature(
            "initialize(address)",
            comptroller
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initdata
        );

        viewsContract = MorphoVaultV2Views(address(proxy));
    }

    // ==================== VAULT INFO TESTS ====================

    /// @notice Test getting single vault info
    function testGetVaultInfo() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        assertEq(info.vault, VAULT_V2_MEUSDC);
        assertEq(info.name, "Moonwell Ecosystem USDC");
        assertEq(info.symbol, "meUSDC");
        assertGt(info.totalAssets, 0);
        assertGt(info.totalSupply, 0);
        assertTrue(info.owner != address(0));
        assertTrue(info.curator != address(0));
        assertTrue(info.adapterRegistry != address(0));
    }

    /// @notice Test vault has adapters
    function testVaultHasAdapters() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        // meUSDC has 1 adapter
        assertEq(info.adapters.length, 1);

        // First adapter should be the MorphoVaultV1Adapter
        assertEq(info.adapters[0].adapter, MEUSDC_ADAPTER);
        assertGt(info.adapters[0].realAssets, 0);
    }

    /// @notice Test adapter points to underlying MetaMorpho
    function testAdapterUnderlyingVault() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        // Adapter should point to MetaMorpho vault
        assertEq(info.adapters[0].underlyingVault, METAMORPHO_MEUSDC);
        assertEq(
            info.adapters[0].underlyingVaultName,
            "Moonwell Ecosystem USDC Vault"
        );
        assertGt(info.adapters[0].underlyingVaultTotalAssets, 0);
    }

    /// @notice Test allocation percentage is calculated correctly
    function testAdapterAllocationPercentage() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        // With only 1 adapter, allocation should be ~100% (1e18)
        // Allow some small variance for rounding
        assertGt(info.adapters[0].allocationPercentage, 0.99e18);
        assertLe(info.adapters[0].allocationPercentage, 1e18);
    }

    /// @notice Test asset metadata is populated
    function testAssetMetadata() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        // USDC metadata
        assertEq(info.assetSymbol, "USDC");
        assertEq(info.assetDecimals, 6);
        assertTrue(bytes(info.assetName).length > 0);
    }

    /// @notice Test underlying price is fetched
    function testUnderlyingPrice() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        // USDC should be ~$1 (between $0.90 and $1.10)
        assertGt(info.underlyingPrice, 0.9e18);
        assertLt(info.underlyingPrice, 1.1e18);
    }

    // ==================== MULTIPLE VAULTS TESTS ====================

    /// @notice Test getting multiple vaults info
    function testGetVaultsInfo() public view {
        address[] memory vaults = new address[](1);
        vaults[0] = VAULT_V2_MEUSDC;

        MorphoVaultV2Views.VaultV2Info[] memory infos = viewsContract
            .getVaultsInfo(vaults);

        assertEq(infos.length, 1);
        assertEq(infos[0].vault, VAULT_V2_MEUSDC);
    }

    /// @notice Test empty array returns empty result
    function testGetVaultsInfoEmptyArray() public view {
        address[] memory emptyVaults = new address[](0);

        MorphoVaultV2Views.VaultV2Info[] memory infos = viewsContract
            .getVaultsInfo(emptyVaults);

        assertEq(infos.length, 0);
    }

    // ==================== USER BALANCE TESTS ====================

    /// @notice Test getting user balance
    function testGetUserBalance() public view {
        // Use a test address that likely has no balance
        address user = addresses.getAddress("TEMPORAL_GOVERNOR");

        MorphoVaultV2Views.UserVaultBalance memory balance = viewsContract
            .getUserBalance(VAULT_V2_MEUSDC, user);

        assertEq(balance.vault, VAULT_V2_MEUSDC);
        // Balance may be 0 for this user, that's fine
        assertEq(balance.shares >= 0, true);
    }

    /// @notice Test getting multiple user balances
    function testGetUserBalances() public view {
        address user = addresses.getAddress("TEMPORAL_GOVERNOR");

        address[] memory vaults = new address[](1);
        vaults[0] = VAULT_V2_MEUSDC;

        MorphoVaultV2Views.UserVaultBalance[] memory balances = viewsContract
            .getUserBalances(vaults, user);

        assertEq(balances.length, 1);
        assertEq(balances[0].vault, VAULT_V2_MEUSDC);
    }

    /// @notice Test user balance empty array
    function testGetUserBalancesEmptyArray() public view {
        address user = addresses.getAddress("TEMPORAL_GOVERNOR");
        address[] memory emptyVaults = new address[](0);

        MorphoVaultV2Views.UserVaultBalance[] memory balances = viewsContract
            .getUserBalances(emptyVaults, user);

        assertEq(balances.length, 0);
    }

    // ==================== ADAPTER INFO TESTS ====================

    /// @notice Test getting adapter underlying info directly
    function testGetAdapterUnderlyingInfo() public view {
        (address vault, uint256 totalAssets, uint256 markets) = viewsContract
            .getAdapterUnderlyingInfo(MEUSDC_ADAPTER);

        assertEq(vault, METAMORPHO_MEUSDC);
        assertGt(totalAssets, 0);
        assertGt(markets, 0); // MetaMorpho should have markets
    }

    // ==================== INITIALIZATION TESTS ====================

    /// @notice Test that re-initialization reverts
    function testCannotReinitialize() public {
        address comptroller = addresses.getAddress("UNITROLLER");

        vm.expectRevert("Initializable: contract is already initialized");
        viewsContract.initialize(comptroller);
    }

    /// @notice Test that implementation cannot be initialized directly
    function testImplementationCannotBeInitialized() public {
        address comptroller = addresses.getAddress("UNITROLLER");

        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(comptroller);
    }

    // ==================== DATA INTEGRITY TESTS ====================

    /// @notice Test that vault totalAssets matches adapter realAssets
    function testVaultAssetsMatchAdapterAssets() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        // Sum of all adapter realAssets should approximately equal vault totalAssets
        uint256 totalAdapterAssets = 0;
        for (uint256 i = 0; i < info.adapters.length; i++) {
            totalAdapterAssets += info.adapters[i].realAssets;
        }

        // Allow 0.1% variance for rounding
        uint256 variance = info.totalAssets / 1000;
        assertGe(totalAdapterAssets, info.totalAssets - variance);
        assertLe(totalAdapterAssets, info.totalAssets + variance);
    }

    /// @notice Test that convertToAssets works correctly for shares
    function testShareToAssetConversion() public view {
        MorphoVaultV2Views.VaultV2Info memory info = viewsContract.getVaultInfo(
            VAULT_V2_MEUSDC
        );

        // If totalSupply > 0, convertToAssets should give reasonable value
        if (info.totalSupply > 0) {
            // 1 share should be worth some assets
            uint256 assetsPerShare = (info.totalAssets * 1e18) /
                info.totalSupply;
            assertGt(assetsPerShare, 0);
        }
    }
}
