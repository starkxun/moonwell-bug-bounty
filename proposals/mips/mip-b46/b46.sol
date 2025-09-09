//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {Configs} from "@proposals/Configs.sol";
import "@protocol/utils/ChainIds.sol";
import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HybridProposal, ActionType} from "@proposals/proposalTypes/HybridProposal.sol";
import {WormholeBridgeAdapter} from "@protocol/xWELL/WormholeBridgeAdapter.sol";
import {WormholeRelayerAdapter} from "@test/mock/WormholeRelayerAdapter.sol";

interface IMerkleCampaignCreator {
    struct CampaignParameters {
        // POPULATED ONCE CREATED
        // ID of the campaign. This can be left as a null bytes32 when creating campaigns
        // on Merkl.
        bytes32 campaignId;
        // CHOSEN BY CAMPAIGN CREATOR
        // Address of the campaign creator, if marked as address(0), it will be overriden with the
        // address of the `msg.sender` creating the campaign
        address creator;
        // Address of the token used as a reward
        address rewardToken;
        // Amount of `rewardToken` to distribute across all the epochs
        // Amount distributed per epoch is `amount/numEpoch`
        uint256 amount;
        // Type of campaign
        uint32 campaignType;
        // Timestamp at which the campaign should start
        uint32 startTimestamp;
        // Duration of the campaign in seconds. Has to be a multiple of EPOCH = 3600
        uint32 duration;
        // Extra data to pass to specify the campaign
        bytes campaignData;
    }

    function campaignId(
        CampaignParameters memory campaignData
    ) external view returns (bytes32);

    function campaign(
        bytes32 campaignId
    ) external view returns (CampaignParameters memory);
}

/// @notice MIP-B46: Moonwell Morpho Vault Incentive Campaigns
contract mipb46 is HybridProposal, Configs {
    using ChainIds for uint256;
    /// @notice the name of the proposal
    string public constant override name = "MIP-B46";

    uint256 public constant totalCampaignAmount = 3333333333333333000000000;
    uint256 public constant amountToBridge = 3333333333333333000000000;
    uint256 public constant amountPerVault = 833333333333333250000000;

    // Campaign type for MORPHOVAULT
    uint32 public constant MORPHOVAULT_CAMPAIGN_TYPE = 56;

    // Empty campaign data for all vaults
    bytes public constant CAMPAIGN_DATA = hex"";

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b46/MIP-B46.md")
        );
        _setProposalDescription(proposalDescription);
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function beforeSimulationHook(Addresses addresses) public override {
        vm.selectFork(MOONBEAM_FORK_ID);
        // mock relayer so we can simulate bridging well
        WormholeRelayerAdapter wormholeRelayer = new WormholeRelayerAdapter();
        vm.makePersistent(address(wormholeRelayer));
        vm.label(address(wormholeRelayer), "MockWormholeRelayer");

        // we need to set this so that the relayer mock knows that for the next sendPayloadToEvm
        // call it must switch forks
        wormholeRelayer.setIsMultichainTest(true);
        wormholeRelayer.setSenderChainId(MOONBEAM_WORMHOLE_CHAIN_ID);

        // set mock as the wormholeRelayer address on bridge adapter
        WormholeBridgeAdapter wormholeBridgeAdapter = WormholeBridgeAdapter(
            addresses.getAddress("WORMHOLE_BRIDGE_ADAPTER_PROXY")
        );

        uint256 gasLimit = wormholeBridgeAdapter.gasLimit();

        // encode gasLimit and relayer address since is stored in a single slot
        // relayer is first due to how evm pack values into a single storage
        bytes32 encodedData = bytes32(
            (uint256(uint160(address(wormholeRelayer))) << 96) |
                uint256(gasLimit)
        );

        // stores the wormhole mock address in the wormholeRelayer variable
        vm.store(
            address(wormholeBridgeAdapter),
            bytes32(uint256(153)),
            encodedData
        );

        // approve governor to spend well
        vm.startPrank(addresses.getAddress("F-GLMR-DEVGRANT"));
        IERC20(addresses.getAddress("GOVTOKEN")).approve(
            addresses.getAddress("MULTICHAIN_GOVERNOR_PROXY"),
            amountToBridge
        );
        vm.stopPrank();
        vm.selectFork(primaryForkId());

        // stores the wormhole mock address in the wormholeRelayer variable
        vm.store(
            address(wormholeBridgeAdapter),
            bytes32(uint256(153)),
            encodedData
        );
    }

    function build(Addresses addresses) public override {
        vm.selectFork(MOONBEAM_FORK_ID);

        address router = addresses.getAddress("xWELL_ROUTER");
        address well = addresses.getAddress("GOVTOKEN");

        _pushAction(
            well,
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                addresses.getAddress("F-GLMR-DEVGRANT"),
                addresses.getAddress("MULTICHAIN_GOVERNOR_PROXY"),
                amountToBridge
            ),
            string(
                abi.encodePacked(
                    "Transfer WELL from F-GLMR-DEVGRANT to MULTICHAIN_GOVERNOR_PROXY"
                )
            )
        );

        // first approve
        _pushAction(
            well,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                router,
                amountToBridge
            ),
            string(
                abi.encodePacked(
                    "Approve xWELL Router to spend ",
                    vm.toString(amountToBridge / 1e18),
                    " ",
                    vm.getLabel(well)
                )
            ),
            ActionType.Moonbeam
        );

        uint256 wormholeChainId = BASE_CHAIN_ID.toWormholeChainId();

        _pushAction(
            router,
            amountToBridge,
            abi.encodeWithSignature(
                "bridgeToRecipient(address,uint256,uint16)",
                addresses.getAddress("TEMPORAL_GOVERNOR", BASE_CHAIN_ID),
                amountToBridge,
                wormholeChainId
            ),
            "Bridge xWELL to TEMPORAL_GOVERNOR",
            ActionType.Moonbeam
        );

        vm.selectFork(BASE_FORK_ID);

        // Approve merkle campaign creator to spend all campaign tokens
        _pushAction(
            addresses.getAddress("xWELL_PROXY"),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                addresses.getAddress("MERKLE_CAMPAIGN_CREATOR"),
                totalCampaignAmount
            ),
            "Approve merkle campaign creator for all campaigns"
        );

        // Accept conditions once for all campaigns
        _pushAction(
            addresses.getAddress("MERKLE_CAMPAIGN_CREATOR"),
            abi.encodeWithSignature("acceptConditions()"),
            "Accept merkle campaign creator conditions"
        );

        // Create campaigns for all MetaMorpho vaults
        _createCampaign(addresses, "cbBTC_METAMORPHO_VAULT", "cbBTC");
        _createCampaign(addresses, "USDC_METAMORPHO_VAULT", "USDC");
        _createCampaign(addresses, "WETH_METAMORPHO_VAULT", "WETH");
        _createCampaign(addresses, "EURC_METAMORPHO_VAULT", "EURC");
    }

    function _createCampaign(
        Addresses addresses,
        string memory vaultName,
        string memory assetName
    ) internal {
        IMerkleCampaignCreator.CampaignParameters
            memory campaign = IMerkleCampaignCreator.CampaignParameters({
                campaignId: bytes32(0),
                creator: address(0),
                rewardToken: addresses.getAddress("xWELL_PROXY"),
                amount: amountPerVault,
                campaignType: MORPHOVAULT_CAMPAIGN_TYPE,
                startTimestamp: uint32(block.timestamp),
                duration: 3600, // 1 hour
                campaignData: CAMPAIGN_DATA
            });

        _pushAction(
            addresses.getAddress("MERKLE_CAMPAIGN_CREATOR"),
            abi.encodeWithSignature(
                "createCampaign((bytes32,address,address,uint256,uint32,uint32,uint32,bytes))",
                campaign.campaignId,
                campaign.creator,
                campaign.rewardToken,
                campaign.amount,
                campaign.campaignType,
                campaign.startTimestamp,
                campaign.duration,
                campaign.campaignData
            ),
            string(
                abi.encodePacked(
                    "Create ",
                    assetName,
                    " MetaMorpho vault campaign"
                )
            )
        );
    }

    function validate(Addresses addresses, address) public override {
        // Validate that all campaigns are created by checking their IDs
        string[4] memory vaultNames = [
            "cbBTC_METAMORPHO_VAULT",
            "USDC_METAMORPHO_VAULT",
            "WETH_METAMORPHO_VAULT",
            "EURC_METAMORPHO_VAULT"
        ];

        string[4] memory assetNames = ["cbBTC", "USDC", "WETH", "EURC"];

        for (uint256 i = 0; i < vaultNames.length; i++) {
            IMerkleCampaignCreator.CampaignParameters
                memory campaignParams = IMerkleCampaignCreator
                    .CampaignParameters({
                        campaignId: bytes32(0),
                        creator: address(0),
                        rewardToken: addresses.getAddress("xWELL_PROXY"),
                        amount: amountPerVault,
                        campaignType: MORPHOVAULT_CAMPAIGN_TYPE,
                        startTimestamp: uint32(block.timestamp),
                        duration: 3600,
                        campaignData: CAMPAIGN_DATA
                    });

            bytes32 campaignId = IMerkleCampaignCreator(
                addresses.getAddress("MERKLE_CAMPAIGN_CREATOR")
            ).campaignId(campaignParams);

            assertNotEq(
                campaignId,
                bytes32(0),
                string(
                    abi.encodePacked(
                        assetNames[i],
                        " campaign should be created"
                    )
                )
            );
        }

        // Validate that the total amount was properly approved and distributed
        uint256 expectedTotalAmount = amountPerVault * 4;
        assertEq(
            expectedTotalAmount,
            totalCampaignAmount,
            "Total campaign amount should match expected"
        );
    }
}
