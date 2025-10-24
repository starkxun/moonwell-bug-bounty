pragma solidity 0.8.19;

import {xWELLRouter} from "@protocol/xWELL/xWELLRouter.sol";
import {ProposalAction} from "@proposals/proposalTypes/IProposal.sol";

/// @title BridgeValidationHook
/// @notice Hook to validate bridgeToRecipient calls in proposals
/// @dev Ensures that the native value sent with bridge calls is between 5x and 10x
///      the actual bridge cost returned by router.bridgeCost(destinationChain)
contract BridgeValidationHook {
    /// @notice Function selector for bridgeToRecipient(address,uint256,uint16)
    bytes4 private constant BRIDGE_TO_RECIPIENT_SELECTOR =
        xWELLRouter.bridgeToRecipient.selector;

    /// @notice Minimum multiplier for bridge cost (5x)
    uint256 private constant MIN_BRIDGE_COST_MULTIPLIER = 5;

    /// @notice Maximum multiplier for bridge cost (10x)
    uint256 private constant MAX_BRIDGE_COST_MULTIPLIER = 10;

    /// @notice Verify bridge-related proposal actions before execution
    /// @dev This function should be called from _verifyActionsPreRun in derived contracts
    /// @param proposal Array of proposal actions to validate
    function _verifyBridgeActions(
        ProposalAction[] memory proposal
    ) internal view {
        uint256 proposalLength = proposal.length;

        for (uint256 i = 0; i < proposalLength; i++) {
            bytes4 selector = bytesToBytes4(proposal[i].data);

            // Check if this action is a bridgeToRecipient call
            if (selector == BRIDGE_TO_RECIPIENT_SELECTOR) {
                address router = proposal[i].target;
                uint256 actionValue = proposal[i].value;

                // Validate router is a contract
                _validateRouterIsContract(router);

                // Extract wormholeChainId from calldata
                // Calldata structure:
                // 0-3: function selector
                // 4-35: address to (32 bytes)
                // 36-67: uint256 amount (32 bytes)
                // 68-99: uint16 wormholeChainId (32 bytes, right-padded)
                uint16 wormholeChainId = extractUint16FromCalldata(
                    proposal[i].data
                );

                // Get the actual bridge cost from the router with validation
                uint256 bridgeCost = _getBridgeCost(router, wormholeChainId);

                // Validate that action value is between 5x and 10x the bridge cost
                uint256 minValue = bridgeCost * MIN_BRIDGE_COST_MULTIPLIER;
                uint256 maxValue = bridgeCost * MAX_BRIDGE_COST_MULTIPLIER;

                require(
                    actionValue >= minValue,
                    string.concat(
                        "BridgeValidationHook: bridge value too low. Expected >= ",
                        _toString(minValue),
                        ", got ",
                        _toString(actionValue)
                    )
                );

                require(
                    actionValue <= maxValue,
                    string.concat(
                        "BridgeValidationHook: bridge value too high. Expected <= ",
                        _toString(maxValue),
                        ", got ",
                        _toString(actionValue)
                    )
                );
            }
        }
    }

    /// @notice Validates that the router address is a contract
    /// @param router The router address to validate
    function _validateRouterIsContract(address router) private view {
        require(
            router.code.length > 0,
            "BridgeValidationHook: router must be a contract"
        );
    }

    /// @notice Gets bridge cost from router and validates it's non-zero
    /// @param router The router contract address
    /// @param wormholeChainId The destination chain ID
    /// @return bridgeCost The validated bridge cost
    function _getBridgeCost(
        address router,
        uint16 wormholeChainId
    ) private view returns (uint256 bridgeCost) {
        bridgeCost = xWELLRouter(router).bridgeCost(wormholeChainId);

        require(
            bridgeCost > 0,
            "BridgeValidationHook: bridge cost must be greater than zero"
        );
    }

    /// @notice Extract uint16 value from calldata at the third parameter position
    /// @param input The calldata to extract from
    /// @return result The extracted uint16 value
    function extractUint16FromCalldata(
        bytes memory input
    ) public pure returns (uint16 result) {
        require(
            input.length >= 100,
            "BridgeValidationHook: invalid calldata length"
        );

        // The uint16 wormholeChainId is the third parameter, starting at byte 68
        // It's stored in the last 2 bytes of a 32-byte word
        bytes32 rawBytes;
        assembly {
            // Skip 32 bytes (array length) + 4 bytes (selector) + 64 bytes (first two params)
            // = 100 bytes total, so we load from position 68 after the length prefix
            let dataPointer := add(add(input, 0x20), 0x44) // 0x20 (32) + 0x44 (68) = 100
            rawBytes := mload(dataPointer) // Load 32 bytes
        }

        // Extract the uint16 from the rightmost 2 bytes
        result = uint16(uint256(rawBytes));
    }

    /// @notice Extract the first 4 bytes (function selector) from calldata
    /// @dev This function is declared as virtual to allow inheritance from MarketCreationHook
    /// @param toSlice The bytes to extract from
    /// @return functionSignature The extracted function selector
    function bytesToBytes4(
        bytes memory toSlice
    ) public pure virtual returns (bytes4 functionSignature) {
        if (toSlice.length < 4) {
            return bytes4(0);
        }

        assembly {
            functionSignature := mload(add(toSlice, 0x20))
        }
    }

    /// @notice Convert uint256 to string
    /// @param value The uint256 value to convert
    /// @return str The string representation
    function _toString(
        uint256 value
    ) internal pure returns (string memory str) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;

        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);

        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
