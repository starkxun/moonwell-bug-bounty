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
/// proposals/mips/mip-b47/mip-b47.sol:mipb47
contract mipb47 is HybridProposal, Configs, ParameterValidation {
    string public constant override name = "MIP-B47";

    uint256 public constant CURATOR_TIMELOCK = 4 days;

    string public constant VAULT_NAME = "Moonwell Ecosystem USDC Vault";
    string public constant VAULT_SYMBOL = "meUSDC";
    bytes32 public constant SALT =
        keccak256(abi.encodePacked("meUSDC_ECOSYSTEM"));
    string public constant VAULT_ADDRESS_NAME = "meUSDC_METAMORPHO_VAULT";

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b47/MIP-B47.md")
        );

        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function deploy(Addresses addresses, address) public override {
        // Deploy the new MetaMorpho vault with msg.sender as initial owner
        address vaultAddress = createVault(
            addresses,
            msg.sender,
            addresses.getAddress("USDC"),
            0,
            VAULT_NAME,
            VAULT_SYMBOL,
            SALT
        );

        // Transfer ownership to temporal governor
        IMetaMorpho(vaultAddress).transferOwnership(
            addresses.getAddress("TEMPORAL_GOVERNOR")
        );
    }

    function build(Addresses addresses) public override {
        // Accept ownership of the Moonwell Ecosystem USDC Vault
        _pushAction(
            addresses.getAddress(VAULT_ADDRESS_NAME),
            abi.encodeWithSignature("acceptOwnership()"),
            "Accept ownership of the Moonwell Ecosystem USDC Vault"
        );

        // Set curator as Anthias Labs
        _pushAction(
            addresses.getAddress(VAULT_ADDRESS_NAME),
            abi.encodeWithSignature(
                "setCurator(address)",
                addresses.getAddress("ANTHIAS_MULTISIG")
            ),
            "Set curator as Anthias Labs"
        );

        // Set guardian as Security Council
        _pushAction(
            addresses.getAddress(VAULT_ADDRESS_NAME),
            abi.encodeWithSignature(
                "submitGuardian(address)",
                addresses.getAddress("SECURITY_COUNCIL")
            ),
            "Set guardian as Security Council"
        );
    }

    function teardown(Addresses addresses, address) public pure override {}

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

        // Validate curator should be Anthias Labs
        assertEq(
            IMetaMorphoBase(vaultAddress).curator(),
            addresses.getAddress("ANTHIAS_MULTISIG"),
            "USDC Ecosystem Vault curator incorrect"
        );

        address guardianOnChain = IMetaMorpho(vaultAddress).guardian();
        // Validate guardian should be Security Council
        assertEq(
            guardianOnChain,
            addresses.getAddress("SECURITY_COUNCIL"),
            "Pending guardian should be Security Council"
        );
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
            vaultSymbol,
            "_METAMORPHO_VAULT"
        );

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
        if (addresses.isAddressSet(vaultAddressName)) {
            addresses.changeAddress(vaultAddressName, vaultAddress, true);
        } else {
            addresses.addAddress(vaultAddressName, vaultAddress);
        }

        return vaultAddress;
    }
}
