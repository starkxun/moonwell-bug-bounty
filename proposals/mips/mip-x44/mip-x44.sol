// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {console} from "forge-std/console.sol";
import {HybridProposal} from "@proposals/proposalTypes/HybridProposal.sol";
import {ChainlinkOracleConfigs} from "@proposals/ChainlinkOracleConfigs.sol";
import {BASE_FORK_ID, OPTIMISM_FORK_ID, BASE_CHAIN_ID, OPTIMISM_CHAIN_ID, ChainIds} from "@utils/ChainIds.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {Networks} from "@proposals/utils/Networks.sol";
import {ERC20} from "@openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {IChainlinkOracle} from "@protocol/interfaces/IChainlinkOracle.sol";
import {ChainlinkOEVWrapper} from "@protocol/oracles/ChainlinkOEVWrapper.sol";
import {ChainlinkOEVMorphoWrapper} from "@protocol/oracles/ChainlinkOEVMorphoWrapper.sol";
import {AggregatorV3Interface} from "@protocol/oracles/AggregatorV3Interface.sol";
import {validateProxy} from "@proposals/utils/ProxyUtils.sol";
import {OEVProtocolFeeRedeemer} from "@protocol/OEVProtocolFeeRedeemer.sol";

/// @notice MIP-X44: Revert the configured oracle for cbETH market on Base from the OEV wrapper to CHAINLINK_ETH_USD
contract mipx44 is HybridProposal, ChainlinkOracleConfigs, Networks {
    using ChainIds for uint256;
    string public constant override name = "MIP-X44";

    constructor() {
        _setProposalDescription(
            bytes(vm.readFile("./proposals/mips/mip-x44/x44.md"))
        );
    }

    function primaryForkId() public pure override returns (uint256) {
        return BASE_FORK_ID;
    }

    function build(Addresses addresses) public override {
        address chainlinkOracle = addresses.getAddress("CHAINLINK_ORACLE");
        string memory symbol = "cbETH";

        _pushAction(
            chainlinkOracle,
            abi.encodeWithSignature(
                "setFeed(string,address)",
                symbol,
                addresses.getAddress("CHAINLINK_ETH_USD")
            ),
            string.concat("Set feed to CHAINLINK_ETH_USD for ", symbol)
        );
    }

    function validate(Addresses addresses, address) public view override {
        address configured = address(
            ChainlinkOracle(addresses.getAddress("CHAINLINK_ORACLE")).getFeed(
                "cbETH"
            )
        );
        address expected = addresses.getAddress("CHAINLINK_ETH_USD");
        assertEq(
            configured,
            expected,
            "cbETH feed not reverted to CHAINLINK_ETH_USD"
        );

        address otherConfigured = address(
            ChainlinkOracle(addresses.getAddress("CHAINLINK_ORACLE")).getFeed(
                "WETH"
            )
        );

        (, int256 price, , , ) = AggregatorV3Interface(configured)
            .latestRoundData();
        (, int256 otherPrice, , , ) = AggregatorV3Interface(otherConfigured)
            .latestRoundData();
        assertEq(
            uint256(price),
            uint256(otherPrice),
            "cbETH and WETH prices are not the same"
        );
    }
}
