// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title ICollateralOnramp
/// @notice Minimal interface for Polymarket's CollateralOnramp.
/// @dev Used by `RobinStakingVault` to wrap USDC.e yield into PolyUSD when the user opts in
///      via `wrapYieldToPolyUsd` on withdrawal. The onramp pulls `_amount` of `_asset` from
///      `msg.sender` (the vault) and mints PolyUSD to `_to`.
interface ICollateralOnramp {
    /// @notice Wraps a supported asset into the collateral token (PolyUSD)
    /// @param _asset The asset to wrap (must be USDC or USDC.e)
    /// @param _to The address to receive the minted collateral tokens
    /// @param _amount The amount of asset to wrap
    function wrap(address _asset, address _to, uint256 _amount) external;
}
