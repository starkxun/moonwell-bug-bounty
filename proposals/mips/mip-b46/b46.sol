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

import {xWELLRouter} from "@protocol/xWELL/xWELLRouter.sol";

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

    uint256 public constant totalCampaignAmount = 3333333333333333000000000; // 3.33M WELL tokens
    uint32 public constant campaignDuration = 26 days;

    // Proportional distribution based on flagship vault allocations
    uint256 public constant USDC_AMOUNT = 1666666666500000000000000; // ~1.67M WELL (50%)
    uint256 public constant WETH_AMOUNT = 799999999920000000000000; // ~800K WELL (24%)
    uint256 public constant EURC_AMOUNT = 433333333290000000000000; // ~433K WELL (13%)
    uint256 public constant cbBTC_AMOUNT = 433333333290000000000000; // ~433K WELL (13%)

    // Hardcoded bridge cost from onchain transaction
    uint256 public constant BRIDGE_COST = 14059583765471401896;

    // Campaign type for MORPHOVAULT
    uint32 public constant MORPHOVAULT_CAMPAIGN_TYPE = 56;

    // Empty campaign data for all vaults
    bytes public constant CAMPAIGN_DATA_EURC =
        hex"000000000000000000000000f24608e0ccb972b0b0f4a6446a0bbf58c701a0260000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes public constant CAMPAIGN_DATA_CBBTC =
        hex"000000000000000000000000543257ef2161176d7c8cd90ba65c2d4caef5a7960000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes public constant CAMPAIGN_DATA_ETH =
        hex"000000000000000000000000a0e430870c4604ccfc7b38ca7845b1ff653d0ff10000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes public constant CAMPAIGN_DATA_USDC =
        hex"000000000000000000000000c1256ae5ff1cf2719d4937adb3bbccab2e00a2ca0000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

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
        WormholeRelayerAdapter wormholeRelayer = new WormholeRelayerAdapter(
            new uint16[](0),
            new uint256[](0)
        );
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
            totalCampaignAmount
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
                totalCampaignAmount
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
                totalCampaignAmount
            ),
            string(
                abi.encodePacked(
                    "Approve xWELL Router to spend ",
                    vm.toString(totalCampaignAmount / 1e18),
                    " ",
                    vm.getLabel(well)
                )
            ),
            ActionType.Moonbeam
        );

        uint16 wormholeChainId = BASE_CHAIN_ID.toWormholeChainId();

        // find bridge cost from xWELLRouter
        //uint256 bridgeCost = xWELLRouter(router).bridgeCost(wormholeChainId);
        uint256 bridgeCost = BRIDGE_COST;

        _pushAction(
            router,
            bridgeCost,
            abi.encodeWithSignature(
                "bridgeToRecipient(address,uint256,uint16)",
                addresses.getAddress("TEMPORAL_GOVERNOR", BASE_CHAIN_ID),
                totalCampaignAmount,
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

        // Create campaigns for all MetaMorpho vaults with proportional distribution
        _createCampaign(addresses, "cbBTC", cbBTC_AMOUNT, CAMPAIGN_DATA_CBBTC);
        _createCampaign(addresses, "USDC", USDC_AMOUNT, CAMPAIGN_DATA_USDC);
        _createCampaign(addresses, "WETH", WETH_AMOUNT, CAMPAIGN_DATA_ETH);
        _createCampaign(addresses, "EURC", EURC_AMOUNT, CAMPAIGN_DATA_EURC);
    }

    function _createCampaign(
        Addresses addresses,
        string memory assetName,
        uint256 campaignAmount,
        bytes memory campaignData
    ) internal {
        IMerkleCampaignCreator.CampaignParameters
            memory campaign = IMerkleCampaignCreator.CampaignParameters({
                campaignId: bytes32(0),
                creator: address(0),
                rewardToken: addresses.getAddress("xWELL_PROXY"),
                amount: campaignAmount,
                campaignType: MORPHOVAULT_CAMPAIGN_TYPE,
                startTimestamp: 1757975452, // 2025-09-15
                duration: campaignDuration,
                campaignData: campaignData
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
        uint256[4] memory vaultAmounts = [
            cbBTC_AMOUNT,
            USDC_AMOUNT,
            WETH_AMOUNT,
            EURC_AMOUNT
        ];

        bytes[4] memory campaignDatas = [
            CAMPAIGN_DATA_CBBTC,
            CAMPAIGN_DATA_USDC,
            CAMPAIGN_DATA_ETH,
            CAMPAIGN_DATA_EURC
        ];

        for (uint256 i = 0; i < vaultNames.length; i++) {
            IMerkleCampaignCreator.CampaignParameters
                memory campaignParams = IMerkleCampaignCreator
                    .CampaignParameters({
                        campaignId: bytes32(0),
                        creator: addresses.getAddress("TEMPORAL_GOVERNOR"),
                        rewardToken: addresses.getAddress("xWELL_PROXY"),
                        amount: vaultAmounts[i],
                        campaignType: MORPHOVAULT_CAMPAIGN_TYPE,
                        startTimestamp: 1757975452,
                        duration: campaignDuration,
                        campaignData: campaignDatas[i]
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

            // Validate that the campaign data is correct
            IMerkleCampaignCreator.CampaignParameters
                memory returnedCampaignParams = IMerkleCampaignCreator(
                    addresses.getAddress("MERKLE_CAMPAIGN_CREATOR")
                ).campaign(campaignId);
            assertEq(
                returnedCampaignParams.creator,
                campaignParams.creator,
                "Creator should be correct"
            );
            assertEq(
                returnedCampaignParams.rewardToken,
                campaignParams.rewardToken,
                "Reward token should be correct"
            );
            assertApproxEqRel(
                returnedCampaignParams.amount,
                campaignParams.amount - ((campaignParams.amount * 1) / 100),
                1e16,
                "Amount should be correct"
            ); // // reduce the 1% fee
            assertEq(
                returnedCampaignParams.campaignType,
                campaignParams.campaignType,
                "Campaign type should be correct"
            );
            assertEq(
                returnedCampaignParams.startTimestamp,
                campaignParams.startTimestamp,
                "Start timestamp should be correct"
            );
            assertEq(
                returnedCampaignParams.duration,
                campaignParams.duration,
                "Duration should be correct"
            );
            assertEq(
                returnedCampaignParams.campaignData,
                campaignDatas[i],
                "Campaign data should be correct"
            );
        }
    }
}
