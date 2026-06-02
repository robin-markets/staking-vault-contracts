// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title ICollateralOfframp
/// @notice Minimal interface for Polymarket's CollateralOfframp.
/// @dev Used by `RobinStakingVault` to unwrap PolyUSD back to USDC.e after merging PolyUSD-backed
///      outcome tokens. The offramp pulls `_amount` of PolyUSD from `msg.sender` (the vault),
///      burns it via the CollateralToken, and sends `_amount` of `_asset` (USDC.e) to `_to`.
interface ICollateralOfframp {
    /// @notice Unwraps the collateral token back into a supported underlying asset
    /// @param _asset The underlying asset to receive (must be USDC or USDC.e)
    /// @param _to The address to receive the unwrapped asset
    /// @param _amount The amount of collateral token to unwrap
    function unwrap(address _asset, address _to, uint256 _amount) external;
}
