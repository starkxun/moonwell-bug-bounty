//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {BASE_FORK_ID} from "@utils/ChainIds.sol";
import {MarketUpdateTemplate} from "@proposals/templates/MarketUpdate.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

/// @notice MIP-X42: Anthias Labs Monthly Recommendations + Warden Allocator Removal
/// DO_VALIDATE=true DO_PRINT=true DO_BUILD=true DO_RUN=true forge script
/// proposals/mips/mip-x42/mip-x42.sol:mipx42
contract mipx42 is MarketUpdateTemplate {
    /// @notice Old allocator address (BlockAnalitica) to be removed
    address public constant OLD_ALLOCATOR =
        0x76E21F76cdD96AE6678a4383d2cc6cF61f925564;

    function name() external pure override returns (string memory) {
        return "MIP-X42";
    }

    function build(Addresses addresses) public override {
        /// First, call parent to build market update actions
        super.build(addresses);

        /// Then add allocator removal actions on Base
        vm.selectFork(BASE_FORK_ID);

        address publicAllocator = addresses.getAddress(
            "MORPHO_PUBLIC_ALLOCATOR"
        );
        address newAdmin = addresses.getAddress("ANTHIAS_EOA");

        /// Vault addresses
        address usdcVault = addresses.getAddress("USDC_METAMORPHO_VAULT");
        address wethVault = addresses.getAddress("WETH_METAMORPHO_VAULT");
        address eurcVault = addresses.getAddress("EURC_METAMORPHO_VAULT");
        address cbbtcVault = addresses.getAddress("cbBTC_METAMORPHO_VAULT");

        /// ============================================
        /// 1. Disable OLD_ALLOCATOR as allocator on all vaults
        /// ============================================

        _pushAction(
            usdcVault,
            abi.encodeWithSignature(
                "setIsAllocator(address,bool)",
                OLD_ALLOCATOR,
                false
            ),
            "Disable Warden as allocator on USDC vault"
        );

        _pushAction(
            wethVault,
            abi.encodeWithSignature(
                "setIsAllocator(address,bool)",
                OLD_ALLOCATOR,
                false
            ),
            "Disable Warden as allocator on WETH vault"
        );

        _pushAction(
            eurcVault,
            abi.encodeWithSignature(
                "setIsAllocator(address,bool)",
                OLD_ALLOCATOR,
                false
            ),
            "Disable Warden as allocator on EURC vault"
        );

        _pushAction(
            cbbtcVault,
            abi.encodeWithSignature(
                "setIsAllocator(address,bool)",
                OLD_ALLOCATOR,
                false
            ),
            "Disable Warden as allocator on cbBTC vault"
        );

        /// ============================================
        /// 2. Change Public Allocator admin for all vaults
        /// ============================================

        _pushAction(
            publicAllocator,
            abi.encodeWithSignature(
                "setAdmin(address,address)",
                usdcVault,
                newAdmin
            ),
            "Set Anthias as Public Allocator admin for USDC vault"
        );

        _pushAction(
            publicAllocator,
            abi.encodeWithSignature(
                "setAdmin(address,address)",
                wethVault,
                newAdmin
            ),
            "Set Anthias as Public Allocator admin for WETH vault"
        );

        _pushAction(
            publicAllocator,
            abi.encodeWithSignature(
                "setAdmin(address,address)",
                eurcVault,
                newAdmin
            ),
            "Set Anthias as Public Allocator admin for EURC vault"
        );

        _pushAction(
            publicAllocator,
            abi.encodeWithSignature(
                "setAdmin(address,address)",
                cbbtcVault,
                newAdmin
            ),
            "Set Anthias as Public Allocator admin for cbBTC vault"
        );
    }

    function validate(Addresses addresses, address deployer) public override {
        /// First, validate parent market updates
        super.validate(addresses, deployer);

        /// Then validate allocator changes on Base
        vm.selectFork(BASE_FORK_ID);

        address publicAllocator = addresses.getAddress(
            "MORPHO_PUBLIC_ALLOCATOR"
        );
        address newAdmin = addresses.getAddress("ANTHIAS_EOA");

        address usdcVault = addresses.getAddress("USDC_METAMORPHO_VAULT");
        address wethVault = addresses.getAddress("WETH_METAMORPHO_VAULT");
        address eurcVault = addresses.getAddress("EURC_METAMORPHO_VAULT");
        address cbbtcVault = addresses.getAddress("cbBTC_METAMORPHO_VAULT");

        /// Validate OLD_ALLOCATOR is no longer allocator on any vault
        assertFalse(
            _isAllocator(usdcVault, OLD_ALLOCATOR),
            "Warden should not be allocator on USDC vault"
        );
        assertFalse(
            _isAllocator(wethVault, OLD_ALLOCATOR),
            "Warden should not be allocator on WETH vault"
        );
        assertFalse(
            _isAllocator(eurcVault, OLD_ALLOCATOR),
            "Warden should not be allocator on EURC vault"
        );
        assertFalse(
            _isAllocator(cbbtcVault, OLD_ALLOCATOR),
            "Warden should not be allocator on cbBTC vault"
        );

        /// Validate new admin is set on public allocator for each vault
        assertEq(
            _getPublicAllocatorAdmin(publicAllocator, usdcVault),
            newAdmin,
            "Anthias should be Public Allocator admin for USDC vault"
        );
        assertEq(
            _getPublicAllocatorAdmin(publicAllocator, wethVault),
            newAdmin,
            "Anthias should be Public Allocator admin for WETH vault"
        );
        assertEq(
            _getPublicAllocatorAdmin(publicAllocator, eurcVault),
            newAdmin,
            "Anthias should be Public Allocator admin for EURC vault"
        );
        assertEq(
            _getPublicAllocatorAdmin(publicAllocator, cbbtcVault),
            newAdmin,
            "Anthias should be Public Allocator admin for cbBTC vault"
        );
    }

    function _isAllocator(
        address vault,
        address allocator
    ) internal view returns (bool) {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("isAllocator(address)", allocator)
        );
        require(success, "isAllocator call failed");
        return abi.decode(data, (bool));
    }

    function _getPublicAllocatorAdmin(
        address publicAllocator,
        address vault
    ) internal view returns (address) {
        (bool success, bytes memory data) = publicAllocator.staticcall(
            abi.encodeWithSignature("admin(address)", vault)
        );
        require(success, "admin call failed");
        return abi.decode(data, (address));
    }
}
