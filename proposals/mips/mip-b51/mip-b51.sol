//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {Configs} from "@proposals/Configs.sol";
import {BASE_FORK_ID} from "@utils/ChainIds.sol";
import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {IMetaMorphoBase} from "@protocol/morpho/IMetaMorpho.sol";
import {ParameterValidation} from "@proposals/utils/ParameterValidation.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";

/// DO_VALIDATE=true DO_PRINT=true DO_BUILD=true DO_RUN=true forge script
/// proposals/mips/mip-b51/mip-b51.sol:mipb51
contract mipb51 is HybridProposal, Configs, ParameterValidation {
    string public constant override name = "MIP-B51";

    uint256 public constant NEW_TIMELOCK = 3 days;

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b51/MIP-B51.md")
        );

        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function deploy(Addresses addresses, address) public override {}

    function build(Addresses addresses) public override {
        _pushAction(
            addresses.getAddress("meUSDC_METAMORPHO_VAULT"),
            abi.encodeWithSignature("submitTimelock(uint256)", NEW_TIMELOCK),
            "Set the timelock for the meUSDC Metamorpho Vault to 3 days"
        );
    }

    function teardown(Addresses addresses, address) public pure override {}

    /// @notice assert that the new timelock is set correctly
    function validate(Addresses addresses, address) public view override {
        assertEq(
            IMetaMorphoBase(addresses.getAddress("meUSDC_METAMORPHO_VAULT"))
                .timelock(),
            NEW_TIMELOCK,
            "meUSDC Metamorpho Vault timelock incorrect"
        );
    }
}
