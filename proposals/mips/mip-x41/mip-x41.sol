//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {MOONBEAM_FORK_ID, BASE_FORK_ID, OPTIMISM_FORK_ID, ChainIds} from "@utils/ChainIds.sol";
import {ProposalActions} from "@proposals/utils/ProposalActions.sol";

/// @title MIP-X41: Upgrade StakedWell contracts on Base, OP, and Moonbeam
/// @author Moonwell Contributors
/// @notice Proposal to:
///         1. Upgrade stkWELL on Moonbeam to switch snapshot logic to use timestamps instead of block numbers
///         2. Upgrade stkWELL on Base/OP to remove faulty configureAssets function
///         3. Call setNewStakedWell on the MultichainGovernor on moonbeam with the same stkwell contract and toUseTimestamps=true
contract mipx41 is HybridProposal {
    using ProposalActions for *;
    using ChainIds for uint256;

    string public constant override name = "MIP-X41";

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-x41/x41.md")
        );
        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return MOONBEAM_FORK_ID;
    }

    function run() public override {
        primaryForkId().createForksAndSelect();

        Addresses addresses = new Addresses();
        vm.makePersistent(address(addresses));

        initProposal(addresses);

        (, address deployerAddress, ) = vm.readCallers();

        if (DO_DEPLOY) deploy(addresses, deployerAddress);
        if (DO_AFTER_DEPLOY) afterDeploy(addresses, deployerAddress);

        if (DO_BUILD) build(addresses);
        if (DO_RUN) run(addresses, deployerAddress);
        if (DO_TEARDOWN) teardown(addresses, deployerAddress);
        if (DO_VALIDATE) {
            validate(addresses, deployerAddress);
            console.log("Validation completed for proposal ", this.name());
        }
        if (DO_PRINT) {
            printProposalActionSteps();

            addresses.removeAllRestrictions();
            printCalldata(addresses);

            _printAddressesChanges(addresses);
        }
    }

    function deploy(
        Addresses addresses,
        address deployerAddress
    ) public override {
        // Moonbeam
        if (!addresses.isAddressSet("STK_GOVTOKEN_IMPL_V2")) {
            vm.startBroadcast();
            address implementation = deployCode(
                "artifacts/foundry/StakedWellMoonbeam.sol/StakedWellMoonbeam.json"
            );

            require(
                implementation != address(0),
                "MIP-X41: failed to deploy STK_GOVTOKEN_IMPL_V2"
            );

            // Save new implementation
            addresses.addAddress("STK_GOVTOKEN_IMPL_V2", implementation);
            vm.stopBroadcast();
        }

        // Base
        vm.selectFork(BASE_FORK_ID);
        if (!addresses.isAddressSet("STK_GOVTOKEN_IMPL_V2")) {
            vm.startBroadcast();
            address implementation = deployCode(
                "artifacts/foundry/StakedWell.sol/StakedWell.json"
            );

            require(
                implementation != address(0),
                "MIP-X41: failed to deploy STK_GOVTOKEN_IMPL_V2"
            );

            // Save new implementation
            addresses.addAddress("STK_GOVTOKEN_IMPL_V2", implementation);
            vm.stopBroadcast();
        }

        // OP
        vm.selectFork(OPTIMISM_FORK_ID);
        if (!addresses.isAddressSet("STK_GOVTOKEN_IMPL_V2")) {
            vm.startBroadcast();
            address implementation = deployCode(
                "artifacts/foundry/StakedWell.sol/StakedWell.json"
            );

            require(
                implementation != address(0),
                "MIP-X41: failed to deploy STK_GOVTOKEN_IMPL_V2"
            );

            // Save new implementation
            addresses.addAddress("STK_GOVTOKEN_IMPL_V2", implementation);
            vm.stopBroadcast();
        }

        // Switch back to Moonbeam
        vm.selectFork(primaryForkId());
    }

    function build(Addresses addresses) public override {
        // Moonbeam: upgrade stkWELL proxy with initializeV2
        _pushAction(
            addresses.getAddress("MOONBEAM_PROXY_ADMIN"),
            abi.encodeWithSignature(
                "upgradeAndCall(address,address,bytes)",
                addresses.getAddress("STK_GOVTOKEN_PROXY"),
                addresses.getAddress("STK_GOVTOKEN_IMPL_V2"),
                abi.encodeWithSignature("initializeV2()")
            ),
            "Upgrade stkWELL on Moonbeam via upgradeAndCall (with initializeV2)"
        );

        // Moonbeam: call setNewStakedWell on MultichainGovernor to enable timestamp mode
        _pushAction(
            addresses.getAddress("MULTICHAIN_GOVERNOR_PROXY"),
            abi.encodeWithSignature(
                "setNewStakedWell(address,bool)",
                addresses.getAddress("STK_GOVTOKEN_PROXY"),
                true // toUseTimestamps
            ),
            "Enable timestamp mode on MultichainGovernor for stkWELL"
        );

        // Base: upgrade stkWELL proxy (no initializeV2 needed)
        vm.selectFork(BASE_FORK_ID);
        _pushAction(
            addresses.getAddress("MRD_PROXY_ADMIN"),
            abi.encodeWithSignature(
                "upgrade(address,address)",
                addresses.getAddress("STK_GOVTOKEN_PROXY"),
                addresses.getAddress("STK_GOVTOKEN_IMPL_V2")
            ),
            "Upgrade stkWELL on Base"
        );

        // Optimism: upgrade stkWELL proxy (no initializeV2 needed)
        vm.selectFork(OPTIMISM_FORK_ID);
        _pushAction(
            addresses.getAddress("MRD_PROXY_ADMIN"),
            abi.encodeWithSignature(
                "upgrade(address,address)",
                addresses.getAddress("STK_GOVTOKEN_PROXY"),
                addresses.getAddress("STK_GOVTOKEN_IMPL_V2")
            ),
            "Upgrade stkWELL on Optimism"
        );

        // Switch back to Moonbeam
        vm.selectFork(primaryForkId());
    }

    function teardown(Addresses addresses, address) public pure override {}

    function validate(Addresses addresses, address) public override {
        // Validate Moonbeam
        vm.selectFork(primaryForkId());
        _validateMoonbeamUpgrade(addresses);

        // Validate Base
        vm.selectFork(BASE_FORK_ID);
        _validateBaseUpgrade(addresses);

        // Validate Optimism
        vm.selectFork(OPTIMISM_FORK_ID);
        _validateOptimismUpgrade(addresses);

        // Switch back to Moonbeam
        vm.selectFork(primaryForkId());
    }

    function _validateMoonbeamUpgrade(Addresses addresses) internal view {
        address proxyAdmin = addresses.getAddress("MOONBEAM_PROXY_ADMIN");
        address proxy = addresses.getAddress("STK_GOVTOKEN_PROXY");
        address expectedImpl = addresses.getAddress("STK_GOVTOKEN_IMPL_V2");

        // Validate proxy points to new implementation
        address actualImpl = _getProxyImplementation(proxyAdmin, proxy);
        assertEq(
            actualImpl,
            expectedImpl,
            "Moonbeam stkWELL implementation not upgraded"
        );

        // Validate initializeV2 was called by checking defaultSnapshotTimestamp
        (bool success, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("defaultSnapshotTimestamp()")
        );
        require(success, "Failed to read defaultSnapshotTimestamp");
        uint256 defaultSnapshotTimestamp = abi.decode(data, (uint256));
        assertGt(
            defaultSnapshotTimestamp,
            0,
            "initializeV2 not called - defaultSnapshotTimestamp is 0"
        );

        // Validate MultichainGovernor useTimestamps is true
        address governor = addresses.getAddress("MULTICHAIN_GOVERNOR_PROXY");
        (bool timestampSuccess, bytes memory timestampData) = governor
            .staticcall(abi.encodeWithSignature("useTimestamps()"));
        require(timestampSuccess, "Failed to read useTimestamps");
        bool useTimestamps = abi.decode(timestampData, (bool));
        assertTrue(
            useTimestamps,
            "MultichainGovernor useTimestamps not enabled"
        );

        // TODO: validate an address that had voting power thru stkwell, and voting power remained the same after the upgrade
    }

    function _validateBaseUpgrade(Addresses addresses) internal view {
        address proxyAdmin = addresses.getAddress("MRD_PROXY_ADMIN");
        address proxy = addresses.getAddress("STK_GOVTOKEN_PROXY");
        address expectedImpl = addresses.getAddress("STK_GOVTOKEN_IMPL_V2");

        // Validate proxy points to new implementation
        address actualImpl = _getProxyImplementation(proxyAdmin, proxy);
        assertEq(
            actualImpl,
            expectedImpl,
            "Base stkWELL implementation not upgraded"
        );
    }

    function _validateOptimismUpgrade(Addresses addresses) internal view {
        address proxyAdmin = addresses.getAddress("MRD_PROXY_ADMIN");
        address proxy = addresses.getAddress("STK_GOVTOKEN_PROXY");
        address expectedImpl = addresses.getAddress("STK_GOVTOKEN_IMPL_V2");

        // Validate proxy points to new implementation
        address actualImpl = _getProxyImplementation(proxyAdmin, proxy);
        assertEq(
            actualImpl,
            expectedImpl,
            "Optimism stkWELL implementation not upgraded"
        );
    }

    function _getProxyImplementation(
        address proxyAdmin,
        address proxy
    ) internal view returns (address) {
        (bool success, bytes memory data) = proxyAdmin.staticcall(
            abi.encodeWithSignature("getProxyImplementation(address)", proxy)
        );
        require(success, "Failed to get proxy implementation");
        return abi.decode(data, (address));
    }
}
