// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {Configs} from "@proposals/Configs.sol";
import {BASE_FORK_ID, OPTIMISM_FORK_ID, MOONBEAM_FORK_ID} from "@utils/ChainIds.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {Networks} from "@proposals/utils/Networks.sol";

// this proposal should call Comptroller._setBorrowCapGuardian and Comptroller._setSupplyCapGuardian on both Moonbeam, Base and Optimism
contract x25 is HybridProposal, Configs, Networks {
    string public constant override name = "MIP-X25";

    constructor() {
        _setProposalDescription(
            bytes(vm.readFile("./proposals/mips/mip-x25/MIP-X25.md"))
        );
    }

    function primaryForkId() public pure override returns (uint256) {
        return MOONBEAM_FORK_ID;
    }

    function build(Addresses addresses) public override {
        for (uint256 i = 0; i < networks.length; i++) {
            vm.selectFork(networks[i].forkId);
            _pushAction(
                addresses.getAddress("UNITROLLER"),
                abi.encodeWithSignature(
                    "_setBorrowCapGuardian(address)",
                    addresses.getAddress("ANTHIAS_MULTISIG")
                ),
                string.concat("Set borrow cap guardian on ", networks[i].name)
            );

            // No supply cap guardian on Moonbeam
            if (networks[i].forkId != MOONBEAM_FORK_ID) {
                _pushAction(
                    addresses.getAddress("UNITROLLER"),
                    abi.encodeWithSignature(
                        "_setSupplyCapGuardian(address)",
                        addresses.getAddress("ANTHIAS_MULTISIG")
                    ),
                    string.concat(
                        "Set supply cap guardian on ",
                        networks[i].name
                    )
                );
            }
        }
    }

    function validate(Addresses addresses, address) public override {
        for (uint256 i = 0; i < networks.length; i++) {
            vm.selectFork(networks[i].forkId);

            address guardian = addresses.getAddress("ANTHIAS_MULTISIG");
            Comptroller unitroller = Comptroller(
                addresses.getAddress("UNITROLLER")
            );

            assertEq(
                unitroller.borrowCapGuardian(),
                guardian,
                string.concat(
                    "Borrow cap guardian on ",
                    networks[i].name,
                    " is not set"
                )
            );

            // No supply cap guardian on Moonbeam
            if (networks[i].forkId != MOONBEAM_FORK_ID) {
                assertEq(
                    unitroller.supplyCapGuardian(),
                    guardian,
                    string.concat(
                        "Supply cap guardian on ",
                        networks[i].name,
                        " is not set"
                    )
                );
            }
        }
    }
}
