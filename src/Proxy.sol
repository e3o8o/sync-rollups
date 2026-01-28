// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Proxy
/// @notice Proxy contract that delegates all calls to an implementation
/// @dev Stores L2Proxy-specific parameters in storage slots 0-3
contract Proxy {
    /// @notice The implementation contract address (slot 0)
    address internal _implementation;

    /// @notice The Rollups contract address (slot 1)
    address internal _rollups;

    /// @notice The original address this proxy represents (slot 2)
    address internal _originalAddress;

    /// @notice The original rollup ID (slot 3)
    uint256 internal _originalRollupId;

    /// @param implementation_ The address of the implementation contract
    /// @param rollups_ The address of the Rollups contract
    /// @param originalAddress_ The original address this proxy represents
    /// @param originalRollupId_ The original rollup ID
    constructor(address implementation_, address rollups_, address originalAddress_, uint256 originalRollupId_) {
        _implementation = implementation_;
        _rollups = rollups_;
        _originalAddress = originalAddress_;
        _originalRollupId = originalRollupId_;
    }

    /// @notice Fallback function that delegates all calls to the implementation
    fallback() external payable {
        address impl = _implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
