//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {Ownable2StepUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";

import "@forge-std/Test.sol";

import {Configs} from "@proposals/Configs.sol";
import {BASE_FORK_ID} from "@utils/ChainIds.sol";
import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {IMetaMorphoBase, IMetaMorpho, IMetaMorphoStaticTyping} from "@protocol/morpho/IMetaMorpho.sol";
import {IMetaMorphoFactory} from "@protocol/morpho/IMetaMorphoFactory.sol";
import {ParameterValidation} from "@proposals/utils/ParameterValidation.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

/// DO_VALIDATE=true DO_PRINT=true DO_BUILD=true DO_RUN=true forge script
/// proposals/mips/mip-b49/mip-b49.sol:mipb49
contract mipb49 is HybridProposal, Configs, ParameterValidation {
    string public constant override name = "MIP-B49";

    string public constant VAULT_NAME = "Moonwell Ecosystem USDC Vault";
    string public constant VAULT_SYMBOL = "meUSDC";
    bytes32 public constant SALT =
        keccak256(abi.encodePacked("meUSDC_ECOSYSTEM"));
    string public constant VAULT_ADDRESS_NAME = "meUSDC_METAMORPHO_VAULT";

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b49/MIP-B49.md")
        );

        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function build(Addresses addresses) public override {
        // Set allocator as Anthias Labs (EOA)
        _pushAction(
            addresses.getAddress(VAULT_ADDRESS_NAME),
            abi.encodeWithSignature(
                "setIsAllocator(address,bool)",
                addresses.getAddress("ANTHIAS_EOA"),
                true
            ),
            "Set allocator as Anthias Labs (EOA)"
        );
    }

    function validate(Addresses addresses, address) public view override {
        // Validate that vault was created and added to addresses
        assertTrue(
            addresses.isAddressSet(VAULT_ADDRESS_NAME),
            "USDC Ecosystem Vault address should be set"
        );

        address vaultAddress = addresses.getAddress(VAULT_ADDRESS_NAME);

        // Validate vault basic properties
        IMetaMorpho vault = IMetaMorpho(vaultAddress);
        assertEq(vault.name(), VAULT_NAME, "Vault name incorrect");
        assertEq(vault.symbol(), VAULT_SYMBOL, "Vault symbol incorrect");
        assertEq(
            vault.asset(),
            addresses.getAddress("USDC"),
            "Vault asset incorrect"
        );

        // Validate ownership
        assertEq(
            Ownable2StepUpgradeable(vaultAddress).owner(),
            addresses.getAddress("TEMPORAL_GOVERNOR"),
            "USDC Ecosystem Vault ownership incorrect"
        );

        // Validate pending owner should be cleared
        assertEq(
            Ownable2StepUpgradeable(vaultAddress).pendingOwner(),
            address(0),
            "USDC Ecosystem Vault pending owner should be cleared"
        );

        // Validate allocator should be Anthias Labs
        assertTrue(
            IMetaMorphoBase(vaultAddress).isAllocator(
                addresses.getAddress("ANTHIAS_EOA")
            ),
            "USDC Ecosystem Vault allocator incorrect"
        );
    }
}
