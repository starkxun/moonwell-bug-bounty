//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {Configs} from "@proposals/Configs.sol";
import "@protocol/utils/ChainIds.sol";
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

/// @notice MIP-B50: Moonwell Morpho Vault and stkWELL Incentive Campaigns
contract mipb50 is HybridProposal, Configs {
    using ChainIds for uint256;
    /// @notice the name of the proposal
    string public constant override name = "MIP-B50";

    uint256 public constant totalCampaignAmount = 11108152230220094109600000; // 11,108,152.230220094109600000 WELL tokens (total for all campaigns)
    uint256 public constant bridgeAmount = 3973076920000000000000000; // 3,973,076.92 WELL tokens (amount to bridge, excluding stkWELL)
    uint32 public constant campaignDuration = 2419200; // 28 days
    uint32 public constant campaignStartTimestamp = 1760103018;

    // Proportional distribution for MetaMorpho vaults
    uint256 public constant USDC_AMOUNT = 1500000000000000000000000; // 1.5M WELL
    uint256 public constant WETH_AMOUNT = 750000000000000000000000; // 750K WELL
    uint256 public constant EURC_AMOUNT = 400000000000000000000000; // 400K WELL
    uint256 public constant cbBTC_AMOUNT = 400000000000000000000000; // 400K WELL
    uint256 public constant meUSDC_AMOUNT = 923076920000000000000000; // 923,076.92 WELL
    uint256 public constant STKWELL_AMOUNT = 7135075310220094109600000; // 7,135,075.310220094109600000 WELL

    // Campaign type for MORPHOVAULT
    uint32 public constant MORPHOVAULT_CAMPAIGN_TYPE = 56;
    // Campaign type for Token Holding (stkWELL)
    uint32 public constant TOKEN_HOLDING_CAMPAIGN_TYPE = 18;

    // Campaign data for MetaMorpho vaults
    bytes public constant CAMPAIGN_DATA_EURC =
        hex"000000000000000000000000f24608e0ccb972b0b0f4a6446a0bbf58c701a0260000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes public constant CAMPAIGN_DATA_CBBTC =
        hex"000000000000000000000000543257ef2161176d7c8cd90ba65c2d4caef5a7960000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes public constant CAMPAIGN_DATA_ETH =
        hex"000000000000000000000000a0e430870c4604ccfc7b38ca7845b1ff653d0ff10000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes public constant CAMPAIGN_DATA_USDC =
        hex"000000000000000000000000c1256ae5ff1cf2719d4937adb3bbccab2e00a2ca0000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes public constant CAMPAIGN_DATA_MEUSDC =
        hex"000000000000000000000000e1ba476304255353aef290e6474a417d06e7b7730000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    // Campaign data for stkWELL - Token Holding Campaign with xWELL as reward token
    bytes public constant CAMPAIGN_DATA_STKWELL =
        hex"000000000000000000000000e66e3a37c3274ac24fe8590f7d84a2427194dc1700000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b50/MIP-B50.md")
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

        // approve governor to spend well (only amount to bridge, stkWELL already on Base)
        vm.startPrank(addresses.getAddress("F-GLMR-DEVGRANT"));
        IERC20(addresses.getAddress("GOVTOKEN")).approve(
            addresses.getAddress("MULTICHAIN_GOVERNOR_PROXY"),
            bridgeAmount
        );
        vm.stopPrank();
        vm.selectFork(primaryForkId());

        // stores the wormhole mock address in the wormholeRelayer variable
        vm.store(
            address(wormholeBridgeAdapter),
            bytes32(uint256(153)),
            encodedData
        );

        // Deal xWELL tokens to Temporal Governor for stkWELL campaign (funds not bridged yet)
        deal(
            addresses.getAddress("xWELL_PROXY"),
            addresses.getAddress("TEMPORAL_GOVERNOR"),
            STKWELL_AMOUNT
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
                bridgeAmount
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
                bridgeAmount
            ),
            string(
                abi.encodePacked(
                    "Approve xWELL Router to spend ",
                    vm.toString(bridgeAmount / 1e18),
                    " ",
                    vm.getLabel(well)
                )
            ),
            ActionType.Moonbeam
        );

        uint16 wormholeChainId = BASE_CHAIN_ID.toWormholeChainId();

        // find bridge cost from xWELLRouter
        uint256 bridgeCost = xWELLRouter(router).bridgeCost(wormholeChainId);

        _pushAction(
            router,
            bridgeCost,
            abi.encodeWithSignature(
                "bridgeToRecipient(address,uint256,uint16)",
                addresses.getAddress("TEMPORAL_GOVERNOR", BASE_CHAIN_ID),
                bridgeAmount,
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
        _createCampaign(
            addresses,
            "cbBTC",
            cbBTC_AMOUNT,
            CAMPAIGN_DATA_CBBTC,
            MORPHOVAULT_CAMPAIGN_TYPE
        );
        _createCampaign(
            addresses,
            "USDC",
            USDC_AMOUNT,
            CAMPAIGN_DATA_USDC,
            MORPHOVAULT_CAMPAIGN_TYPE
        );
        _createCampaign(
            addresses,
            "WETH",
            WETH_AMOUNT,
            CAMPAIGN_DATA_ETH,
            MORPHOVAULT_CAMPAIGN_TYPE
        );
        _createCampaign(
            addresses,
            "EURC",
            EURC_AMOUNT,
            CAMPAIGN_DATA_EURC,
            MORPHOVAULT_CAMPAIGN_TYPE
        );
        _createCampaign(
            addresses,
            "meUSDC",
            meUSDC_AMOUNT,
            CAMPAIGN_DATA_MEUSDC,
            MORPHOVAULT_CAMPAIGN_TYPE
        );

        // Create stkWELL campaign
        _createStkWellCampaign(addresses);
    }

    function _createCampaign(
        Addresses addresses,
        string memory assetName,
        uint256 campaignAmount,
        bytes memory campaignData,
        uint32 campaignType
    ) internal {
        IMerkleCampaignCreator.CampaignParameters
            memory campaign = IMerkleCampaignCreator.CampaignParameters({
                campaignId: bytes32(0),
                creator: address(0),
                rewardToken: addresses.getAddress("xWELL_PROXY"),
                amount: campaignAmount,
                campaignType: campaignType,
                startTimestamp: campaignStartTimestamp,
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

    function _createStkWellCampaign(Addresses addresses) internal {
        IMerkleCampaignCreator.CampaignParameters
            memory campaign = IMerkleCampaignCreator.CampaignParameters({
                campaignId: bytes32(0),
                creator: address(0),
                rewardToken: addresses.getAddress("xWELL_PROXY"),
                amount: STKWELL_AMOUNT,
                campaignType: TOKEN_HOLDING_CAMPAIGN_TYPE,
                startTimestamp: campaignStartTimestamp,
                duration: campaignDuration,
                campaignData: CAMPAIGN_DATA_STKWELL
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
            "Create stkWELL safety module campaign"
        );
    }

    function validate(Addresses addresses, address) public override {
        // Validate that all MetaMorpho vault campaigns are created
        string[5] memory vaultNames = [
            "cbBTC_METAMORPHO_VAULT",
            "USDC_METAMORPHO_VAULT",
            "WETH_METAMORPHO_VAULT",
            "EURC_METAMORPHO_VAULT",
            "meUSDC_METAMORPHO_VAULT"
        ];

        string[5] memory assetNames = [
            "cbBTC",
            "USDC",
            "WETH",
            "EURC",
            "meUSDC"
        ];
        uint256[5] memory vaultAmounts = [
            cbBTC_AMOUNT,
            USDC_AMOUNT,
            WETH_AMOUNT,
            EURC_AMOUNT,
            meUSDC_AMOUNT
        ];

        bytes[5] memory campaignDatas = [
            CAMPAIGN_DATA_CBBTC,
            CAMPAIGN_DATA_USDC,
            CAMPAIGN_DATA_ETH,
            CAMPAIGN_DATA_EURC,
            CAMPAIGN_DATA_MEUSDC
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
                        startTimestamp: campaignStartTimestamp,
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
        }

        // Validate stkWELL campaign
        IMerkleCampaignCreator.CampaignParameters
            memory stkWellCampaignParams = IMerkleCampaignCreator
                .CampaignParameters({
                    campaignId: bytes32(0),
                    creator: addresses.getAddress("TEMPORAL_GOVERNOR"),
                    rewardToken: addresses.getAddress("xWELL_PROXY"),
                    amount: STKWELL_AMOUNT,
                    campaignType: TOKEN_HOLDING_CAMPAIGN_TYPE,
                    startTimestamp: campaignStartTimestamp,
                    duration: campaignDuration,
                    campaignData: CAMPAIGN_DATA_STKWELL
                });

        bytes32 stkWellCampaignId = IMerkleCampaignCreator(
            addresses.getAddress("MERKLE_CAMPAIGN_CREATOR")
        ).campaignId(stkWellCampaignParams);

        assertNotEq(
            stkWellCampaignId,
            bytes32(0),
            "stkWELL campaign should be created"
        );
    }
}
