pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {MorphoViewsV2, IMetaMorphoV2} from "@protocol/views/MorphoViewsV2.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import "@utils/ChainIds.sol";

contract MorphoViewsV2Test is PostProposalCheck {
    using ChainIds for uint256;

    MorphoViewsV2 public viewsContract;

    address public proxyAdmin = address(1337);

    function setUp() public override {
        super.setUp();

        // Switch to Base fork for testing
        vm.selectFork(BASE_FORK_ID);

        address comptroller = addresses.getAddress("UNITROLLER");
        address morpho = addresses.getAddress("MORPHO_BLUE");

        MorphoViewsV2 implementation = new MorphoViewsV2();

        bytes memory initdata = abi.encodeWithSignature(
            "initialize(address,address)",
            comptroller,
            morpho
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initdata
        );

        viewsContract = MorphoViewsV2(address(proxy));
    }

    function testVaultsProtocolInfoV2() public view {
        address[] memory morphoVaults = new address[](2);
        morphoVaults[0] = addresses.getAddress("WETH_METAMORPHO_VAULT");
        morphoVaults[1] = addresses.getAddress("USDC_METAMORPHO_VAULT");

        MorphoViewsV2.MorphoVault[] memory vaultsInfo = viewsContract
            .getVaultsInfo(morphoVaults);

        assertEq(vaultsInfo.length, 2);

        for (uint index = 0; index < vaultsInfo.length; index++) {
            MorphoViewsV2.MorphoVault memory vault = vaultsInfo[index];
            assertEq(vault.vault, morphoVaults[index]);
            assertGt(vault.totalSupply, 0);
        }
    }

    function testMorphoMarketsInfoV2() public view {
        bytes32[] memory markets = new bytes32[](1);
        // cbETH/USDC market on Base
        markets[0] = bytes32(
            0xdba352d93a64b17c71104cbddc6aef85cd432322a1446b5b65163cbbc615cd0c
        );

        MorphoViewsV2.MorphoBlueMarket[] memory marketInfo = viewsContract
            .getMorphoBlueMarketsInfo(markets);

        assertEq(marketInfo.length, 1);

        MorphoViewsV2.MorphoBlueMarket memory market = marketInfo[0];
        assertEq(market.marketId, markets[0]);
        assertGt(market.lltv, 0);
    }

    function testUserBalancesV2() public view {
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = bytes32(
            0xdba352d93a64b17c71104cbddc6aef85cd432322a1446b5b65163cbbc615cd0c
        );

        // Use a known user address from the Addresses contract or a test address
        address user = addresses.getAddress("TEMPORAL_GOVERNOR");

        MorphoViewsV2.UserMarketBalance[] memory balances = viewsContract
            .getMorphoBlueUserBalances(markets, user);

        assertEq(balances.length, 1);
        assertEq(balances[0].marketId, markets[0]);
    }

    function testNewV2Vaults() public view {
        address[] memory morphoVaults = new address[](2);
        morphoVaults[0] = addresses.getAddress("llUSDC_METAMORPHO_VAULT");
        morphoVaults[1] = addresses.getAddress("meUSDC_METAMORPHO_VAULT");

        MorphoViewsV2.MorphoVault[] memory vaultsInfo = viewsContract
            .getVaultsInfo(morphoVaults);

        assertEq(vaultsInfo.length, 2);

        for (uint index = 0; index < vaultsInfo.length; index++) {
            MorphoViewsV2.MorphoVault memory vault = vaultsInfo[index];
            assertEq(vault.vault, morphoVaults[index]);
        }
    }

    function testGetSingleVaultInfo() public view {
        address vaultAddress = addresses.getAddress("USDC_METAMORPHO_VAULT");

        MorphoViewsV2.MorphoVault memory vault = viewsContract.getVaultInfo(
            IMetaMorphoV2(vaultAddress)
        );

        assertEq(vault.vault, vaultAddress);
        assertGe(vault.markets.length, 0);
    }

    function testGetSingleMarketInfo() public view {
        bytes32 marketId = bytes32(
            0xdba352d93a64b17c71104cbddc6aef85cd432322a1446b5b65163cbbc615cd0c
        );

        MorphoViewsV2.MorphoBlueMarket memory market = viewsContract
            .getMorphoBlueMarketInfo(marketId);

        assertEq(market.marketId, marketId);
        assertGt(market.lltv, 0);
    }
}
