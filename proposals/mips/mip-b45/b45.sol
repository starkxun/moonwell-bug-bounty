//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {Configs} from "@proposals/Configs.sol";
import "@protocol/utils/ChainIds.sol";
import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStakedWell} from "@protocol/IStakedWell.sol";
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

/// @notice MIP-B45: Moonwell Base Safety Module Pre Bug Airdrop
contract mipb45 is HybridProposal, Configs {
    using ChainIds for uint256;
    /// @notice the name of the proposal
    string public constant override name = "MIP-B45";

    uint256 public constant totalAirdropAmount = 18519532835036764465073938;
    uint256 public constant amountToBridge = 148657655578374265073938;

    bytes public constant campaignData =
        hex"000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000004068747470733a2f2f73746f726167652e676f6f676c65617069732e636f6d2f61697264726f70732f343237373438343530303132353536343139312e6a736f6e000000000000000000000000000000000000000000000000000000000000002952656d6564696174696f6e206f66204261736520536166657479204d6f64756c652052657761726473000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    constructor() {
        bytes memory proposalDescription = abi.encodePacked(
            vm.readFile("./proposals/mips/mip-b45/MIP-B45.md")
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

        address safetyModule = addresses.getAddress("STK_GOVTOKEN_PROXY");
        uint128[] memory emissionPerSecond = new uint128[](1);
        emissionPerSecond[0] = 0;
        uint256[] memory totalStaked = new uint256[](1);
        totalStaked[0] = 0;
        address[] memory underlyingAsset = new address[](1);
        underlyingAsset[0] = safetyModule;

        // TODO add bridge to base call
        _pushAction(
            safetyModule,
            abi.encodeWithSignature(
                "configureAssets(uint128[],uint256[],address[])",
                emissionPerSecond,
                totalStaked,
                underlyingAsset
            ),
            "Configure safety module assets"
        );

        _pushAction(
            addresses.getAddress("xWELL_PROXY"),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                addresses.getAddress("MERKLE_CAMPAIGN_CREATOR"),
                totalAirdropAmount
            ),
            "Approve merkle campaign creator"
        );

        _pushAction(
            addresses.getAddress("MERKLE_CAMPAIGN_CREATOR"),
            abi.encodeWithSignature("acceptConditions()"),
            "Accept merkle campaign creator conditions"
        );

        IMerkleCampaignCreator.CampaignParameters
            memory campaign = IMerkleCampaignCreator.CampaignParameters({
                campaignId: bytes32(0),
                creator: address(0),
                rewardToken: addresses.getAddress("xWELL_PROXY"),
                amount: totalAirdropAmount,
                campaignType: 4, // 4 is airdrop
                startTimestamp: uint32(block.timestamp),
                duration: 3600, // 1 hour
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
            "Create merkle campaign"
        );
    }

    function validate(Addresses addresses, address) public override {
        address safetyModule = addresses.getAddress("STK_GOVTOKEN_PROXY");

        address user = 0xFDd96AcCea44F2c4B71C792220781c9420E5Cb0e;

        uint256 userBalance = IERC20(safetyModule).balanceOf(user);
        uint256 userWellBalance = IERC20(addresses.getAddress("xWELL_PROXY"))
            .balanceOf(user);
        assertGt(userBalance, 0, "User should have balance");

        // user can call coldown and unstake
        vm.startPrank(user);
        IStakedWell(safetyModule).cooldown();

        vm.warp(block.timestamp + 7 days + 1);
        IStakedWell(safetyModule).redeem(user, userBalance);

        vm.stopPrank();

        uint256 userWellBalanceAfter = IERC20(
            addresses.getAddress("xWELL_PROXY")
        ).balanceOf(user);

        assertGt(
            userWellBalanceAfter,
            userWellBalance,
            "User should have more well balance after unstake"
        );

        uint256 userBalanceAfter = IERC20(safetyModule).balanceOf(user);
        assertEq(
            userBalanceAfter,
            0,
            "User should have no balance after unstake"
        );

        IMerkleCampaignCreator.CampaignParameters
            memory campaignParamaters = IMerkleCampaignCreator
                .CampaignParameters({
                    campaignId: bytes32(0),
                    creator: address(0),
                    rewardToken: addresses.getAddress("xWELL_PROXY"),
                    amount: totalAirdropAmount,
                    campaignType: 4, // 4 is airdrop
                    startTimestamp: uint32(block.timestamp),
                    duration: 3600, // 1 hour
                    campaignData: campaignData
                });

        // check if the campaign is created
        bytes32 campaignId = IMerkleCampaignCreator(
            addresses.getAddress("MERKLE_CAMPAIGN_CREATOR")
        ).campaignId(campaignParamaters);
        assertNotEq(campaignId, bytes32(0), "Campaign should be created");
    }
}
