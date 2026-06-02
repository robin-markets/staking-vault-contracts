// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from '../types/DataTypes.sol';

/// @title ShareMath
/// @notice Share/asset conversion math for ERC-4626-like accounting
/// @dev Uses virtual offset of 1 to prevent share inflation attacks
library ShareMath {
    using Math for uint256;

    /// @notice Virtual offset to prevent first depositor inflation attack
    /// @dev By adding 1 to both numerator and denominator, we ensure:
    ///      1. Division by zero is impossible
    ///      2. First depositor cannot manipulate share price
    uint256 internal constant VIRTUAL_OFFSET = 1;

    /// @notice Convert assets to shares
    /// @param assets Amount of assets to convert
    /// @param totalAssets Total assets in the pool
    /// @param totalShares Total shares outstanding
    /// @param roundUp Whether to round up (true for minting on deposit)
    /// @return shares Number of shares
    function assetsToShares(uint256 assets, uint256 totalAssets, uint256 totalShares, bool roundUp) internal pure returns (uint256 shares) {
        // Virtual offset prevents inflation attacks
        uint256 virtualAssets = totalAssets + VIRTUAL_OFFSET;
        uint256 virtualShares = totalShares + VIRTUAL_OFFSET;

        if (roundUp) {
            shares = assets.mulDiv(virtualShares, virtualAssets, Math.Rounding.Ceil);
        } else {
            shares = assets.mulDiv(virtualShares, virtualAssets, Math.Rounding.Floor);
        }
    }

    /// @notice Convert shares to assets
    /// @param shares Number of shares to convert
    /// @param totalAssets Total assets in the pool
    /// @param totalShares Total shares outstanding
    /// @param roundUp Whether to round up (false for burning on withdrawal)
    /// @return assets Amount of assets
    function sharesToAssets(uint256 shares, uint256 totalAssets, uint256 totalShares, bool roundUp) internal pure returns (uint256 assets) {
        // Virtual offset prevents inflation attacks
        uint256 virtualAssets = totalAssets + VIRTUAL_OFFSET;
        uint256 virtualShares = totalShares + VIRTUAL_OFFSET;

        if (roundUp) {
            assets = shares.mulDiv(virtualAssets, virtualShares, Math.Rounding.Ceil);
        } else {
            assets = shares.mulDiv(virtualAssets, virtualShares, Math.Rounding.Floor);
        }
    }

    // ============ Yield Index Functions ============

    /// @notice Convert shares to assets using yield index
    /// @param shares Number of shares to convert
    /// @param yieldIndex Current yield index (scaled by INDEX_SCALE)
    /// @return assets Amount of assets
    function sharesToAssetsWithIndex(uint256 shares, uint256 yieldIndex) internal pure returns (uint256 assets) {
        assets = shares.mulDiv(yieldIndex, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
    }

    /// @notice Convert assets to shares using yield index
    /// @param assets Amount of assets to convert
    /// @param yieldIndex Current yield index (scaled by INDEX_SCALE)
    /// @return shares Number of shares
    function assetsToSharesWithIndex(uint256 assets, uint256 yieldIndex) internal pure returns (uint256 shares) {
        shares = assets.mulDiv(DataTypes.INDEX_SCALE, yieldIndex, Math.Rounding.Floor);
    }
}
