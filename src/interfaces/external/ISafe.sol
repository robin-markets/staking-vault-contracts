// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @notice Minimal Gnosis/Safe interface — only the read methods needed to verify that a
///         Safe is still 1-of-1 with a given signer as a current owner.
interface ISafe {
    function getThreshold() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
}
