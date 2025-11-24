// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {MTokenInterface} from "@protocol/MTokenInterfaces.sol";
import {MWethOwnerWrapper} from "@protocol/MWethOwnerWrapper.sol";

import {HybridProposal, ActionType} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {BASE_FORK_ID} from "@utils/ChainIds.sol";
import {ProposalActions} from "@proposals/utils/ProposalActions.sol";

import {DeployMWethOwnerWrapper} from "@script/DeployMWethOwnerWrapper.s.sol";

/// @title MIP-B53: WETH Market Ownership Wrapper
/// @notice Proposal to deploy and migrate WETH market admin to a wrapper contract
///         that can reliably receive native ETH, enabling reserve reductions.
/// @dev This proposal:
///      1. Deploys MWethOwnerWrapper implementation and proxy
///      2. Transfers WETH market admin from TEMPORAL_GOVERNOR to the wrapper
///      3. Wrapper is owned by TEMPORAL_GOVERNOR, maintaining governance control
///      4. Enables future WETH reserve reductions via the wrapper
contract mipb53 is HybridProposal {
    using ProposalActions for *;

    string public constant override name = "MIP-B53";

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b53/b53.md")
        );
        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function deploy(Addresses addresses, address) public override {
        vm.selectFork(BASE_FORK_ID);

        // Deploy the MWethOwnerWrapper implementation and proxy
        DeployMWethOwnerWrapper deployer = new DeployMWethOwnerWrapper();
        (TransparentUpgradeableProxy proxy, ) = deployer.deploy(addresses);

        console.log("MWethOwnerWrapper deployed at:", address(proxy));
    }

    function build(Addresses addresses) public override {
        vm.selectFork(BASE_FORK_ID);

        address wrapperProxy = addresses.getAddress("MWETH_OWNER_WRAPPER");
        address moonwellWeth = addresses.getAddress("MOONWELL_WETH");

        // Step 1: Set the wrapper as pending admin of the WETH market
        _pushAction(
            moonwellWeth,
            abi.encodeWithSignature(
                "_setPendingAdmin(address)",
                payable(wrapperProxy)
            ),
            "Set MWethOwnerWrapper as pending admin of MOONWELL_WETH",
            ActionType.Base
        );

        // Step 2: Accept admin role from the wrapper
        _pushAction(
            wrapperProxy,
            abi.encodeWithSignature("_acceptAdmin()"),
            "MWethOwnerWrapper accepts admin role for MOONWELL_WETH",
            ActionType.Base
        );
    }

    function validate(Addresses addresses, address) public override {
        vm.selectFork(BASE_FORK_ID);

        address wrapperProxy = addresses.getAddress("MWETH_OWNER_WRAPPER");
        address moonwellWeth = addresses.getAddress("MOONWELL_WETH");
        address temporalGovernor = addresses.getAddress("TEMPORAL_GOVERNOR");
        address weth = addresses.getAddress("WETH");

        // Validate wrapper configuration
        MWethOwnerWrapper wrapper = MWethOwnerWrapper(payable(wrapperProxy));

        assertEq(
            wrapper.owner(),
            temporalGovernor,
            "Wrapper owner should be TEMPORAL_GOVERNOR"
        );

        assertEq(
            address(wrapper.mToken()),
            moonwellWeth,
            "Wrapper mToken should be MOONWELL_WETH"
        );

        assertEq(
            address(wrapper.weth()),
            weth,
            "Wrapper WETH address should be correct"
        );

        // Validate admin transfer
        MTokenInterface mToken = MTokenInterface(moonwellWeth);

        assertEq(
            mToken.admin(),
            wrapperProxy,
            "MOONWELL_WETH admin should be the wrapper"
        );

        assertEq(
            mToken.pendingAdmin(),
            address(0),
            "MOONWELL_WETH pendingAdmin should be zero after accepting"
        );
    }
}
