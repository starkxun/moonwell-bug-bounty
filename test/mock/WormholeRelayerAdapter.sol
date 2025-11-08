pragma solidity 0.8.19;

import "@protocol/utils/ChainIds.sol";
import {console} from "@forge-std/console.sol";
import {Vm} from "@forge-std/Vm.sol";
import {IWormhole} from "@protocol/wormhole/IWormhole.sol";
import {IWormholeRelayer} from "@protocol/wormhole/IWormholeRelayer.sol";
import {IWormholeReceiver} from "@protocol/wormhole/IWormholeReceiver.sol";

/// @notice Wormhole Token Relayer Adapter
contract WormholeRelayerAdapter {
    using ChainIds for *;

    Vm private constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public nonce;

    uint16 public senderChainId;

    /// @notice we need this flag because there are tests where the target is
    /// in the same chain and we need to skip the fork selection
    bool public isMultichainTest;

    // @notice some tests need to silence the failure while others expect it to revert
    // e.g of silence failure: check for refunds
    bool public silenceFailure;

    /// @notice Mapping of wormhole chain ID to native price quote
    mapping(uint16 => uint256) public nativePriceQuotes;

    /// @notice Default price quote for backwards compatibility (used when no specific price is set)
    uint256 public constant DEFAULT_NATIVE_PRICE_QUOTE = 0.1 ether;

    uint256 public callCounter;

    /// @notice Constructor - accepts empty arrays for backwards compatibility
    /// @param chainIds Array of wormhole chain IDs (can be empty for default behavior)
    /// @param prices Array of native prices for each chain (can be empty for default behavior)
    constructor(uint16[] memory chainIds, uint256[] memory prices) {
        require(
            chainIds.length == prices.length,
            "WormholeRelayerAdapter: array length mismatch"
        );
        for (uint256 i = 0; i < chainIds.length; i++) {
            nativePriceQuotes[chainIds[i]] = prices[i];
        }
    }

    /// @notice Get the default native price quote (for backwards compatibility)
    function nativePriceQuote() public pure returns (uint256) {
        return DEFAULT_NATIVE_PRICE_QUOTE;
    }

    event MockWormholeRelayerError(string reason);

    mapping(uint256 chainId => bool shouldRevert) public shouldRevertAtChain;

    mapping(uint16 chainId => bool shouldRevert)
        public shouldRevertQuoteAtChain;

    function setShouldRevertQuoteAtChain(
        uint16[] memory chainIds,
        bool shouldRevert
    ) external {
        for (uint16 i = 0; i < chainIds.length; i++) {
            shouldRevertQuoteAtChain[chainIds[i]] = shouldRevert;
        }
    }

    function setShouldRevertAtChain(
        uint16[] memory chainIds,
        bool _shouldRevert
    ) external {
        for (uint16 i = 0; i < chainIds.length; i++) {
            shouldRevertAtChain[chainIds[i]] = _shouldRevert;
        }
    }

    function setSilenceFailure(bool _silenceFailure) external {
        silenceFailure = _silenceFailure;
    }

    function setSenderChainId(uint16 _senderChainId) external {
        senderChainId = _senderChainId;
    }

    function setIsMultichainTest(bool _isMultichainTest) external {
        isMultichainTest = _isMultichainTest;
    }

    /// @notice Publishes an instruction for the default delivery provider
    /// to relay a payload to the address `targetAddress`
    /// `targetAddress` must implement the IWormholeReceiver interface
    ///
    /// @param targetAddress address to call on targetChain (that implements IWormholeReceiver)
    /// @param payload arbitrary bytes to pass in as parameter in call to `targetAddress`
    /// @return sequence sequence number of published VAA containing delivery instructions
    function sendPayloadToEvm(
        uint16 chainId,
        address targetAddress,
        bytes memory payload,
        uint256, /// shhh
        uint256 /// shhh
    ) external payable returns (uint64) {
        if (shouldRevertAtChain[chainId]) {
            revert("WormholeBridgeAdapter: sendPayloadToEvm revert");
        }

        uint256 expectedValue = nativePriceQuotes[chainId];
        if (expectedValue == 0) {
            expectedValue = DEFAULT_NATIVE_PRICE_QUOTE;
        }
        require(msg.value == expectedValue, "incorrect value");

        uint256 initialFork;

        uint256 timestamp = block.timestamp;
        if (isMultichainTest) {
            initialFork = vm.activeFork();

            vm.selectFork(chainId.toChainId().toForkId());

            vm.warp(timestamp);
        }

        // TODO naming;
        require(senderChainId != 0, "senderChainId not set");

        if (silenceFailure) {
            /// immediately call the target
            try
                IWormholeReceiver(targetAddress).receiveWormholeMessages(
                    payload,
                    new bytes[](0),
                    bytes32(uint256(uint160(msg.sender))),
                    senderChainId, // chain not the target chain
                    bytes32(++nonce)
                )
            {
                // success
            } catch Error(string memory reason) {
                emit MockWormholeRelayerError(reason);
            }
        } else {
            IWormholeReceiver(targetAddress).receiveWormholeMessages(
                payload,
                new bytes[](0),
                bytes32(uint256(uint160(msg.sender))),
                senderChainId, // chain not the target chain
                bytes32(++nonce)
            );
        }

        if (isMultichainTest) {
            vm.selectFork(initialFork);
            vm.warp(timestamp);
        }

        return uint64(nonce);
    }

    /// @notice Retrieve the price for relaying messages to another chain
    /// Returns the price stored in nativePriceQuotes mapping for the target chain, or default if not set
    function quoteEVMDeliveryPrice(
        uint16 targetChain,
        uint256,
        uint256
    )
        public
        view
        returns (uint256 nativePrice, uint256 targetChainRefundPerGasUnused)
    {
        if (shouldRevertQuoteAtChain[targetChain]) {
            revert("WormholeBridgeAdapter: quoteEVMDeliveryPrice revert");
        }

        nativePrice = nativePriceQuotes[targetChain];
        if (nativePrice == 0) {
            nativePrice = DEFAULT_NATIVE_PRICE_QUOTE;
        }
        targetChainRefundPerGasUnused = 0;
    }
}
