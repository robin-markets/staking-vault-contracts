// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';

/// @title IRobinLens
/// @notice Read-only aggregation contract for batch queries against RobinStakingVault
interface IRobinLens {
    // ============ Batch Queries ============

    /// @notice Batch query user's shares across multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @return yesShares Array of YES share balances
    /// @return noShares Array of NO share balances
    function batchGetUserShares(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesShares, uint256[] memory noShares);

    /// @notice Batch query user's current assets (loss-adjusted) across multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @return yesAssets Array of YES asset values (loss-adjusted)
    /// @return noAssets Array of NO asset values (loss-adjusted)
    function batchGetUserAssets(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesAssets, uint256[] memory noAssets);

    /// @notice Batch query user's pending yield across multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @param twapPricesYes Array of Average YES TWAP price since last updates per market (> PRICE_SCALE to use stored)
    /// @return yesYield Array of pending YES side yield in USDC
    /// @return noYield Array of pending NO side yield in USDC
    function batchGetUserYield(address user, bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (uint256[] memory yesYield, uint256[] memory noYield);

    /// @notice Comprehensive batch query for user portfolio data
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @param twapPricesYes Array of Average YES TWAP price since last updates per market (> PRICE_SCALE to use stored)
    /// @return yesShares Array of YES share balances
    /// @return noShares Array of NO share balances
    /// @return yesAssets Array of YES token values (loss-adjusted)
    /// @return noAssets Array of NO token values (loss-adjusted)
    /// @return yesYield Array of pending YES side USDC yield
    /// @return noYield Array of pending NO side USDC yield
    function batchGetUserPortfolio(address user, bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (
            uint256[] memory yesShares,
            uint256[] memory noShares,
            uint256[] memory yesAssets,
            uint256[] memory noAssets,
            uint256[] memory yesYield,
            uint256[] memory noYield
        );

    /// @notice Batch query user's shares + loss-adjusted assets across multiple markets
    /// @dev Same as `batchGetUserPortfolio` but excludes the yield columns; cheaper to call when
    ///      yield isn't needed and avoids the per-market `twapPricesYes` argument.
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @return yesShares Array of YES share balances
    /// @return noShares Array of NO share balances
    /// @return yesAssets Array of YES token values (loss-adjusted)
    /// @return noAssets Array of NO token values (loss-adjusted)
    function batchGetUserSharesAndAssets(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesShares, uint256[] memory noShares, uint256[] memory yesAssets, uint256[] memory noAssets);

    /// @notice Batch preview deposits across multiple markets and sides
    /// @param conditionIds Array of market condition IDs
    /// @param sides Array of sides (YES or NO) per market
    /// @param amounts Array of token amounts to deposit per market
    /// @return shares Array of shares that would be minted per market
    function batchPreviewDeposit(bytes32[] calldata conditionIds, DataTypes.Side[] calldata sides, uint256[] calldata amounts)
        external
        view
        returns (uint256[] memory shares);

    /// @notice Batch preview withdrawals for multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @param sides Array of sides (YES or NO) for each market
    /// @param sharesToBurn Array of share amounts to burn for each market
    /// @param twapPricesYes Array of Average YES TWAP price since last updates per market (> PRICE_SCALE to use stored)
    /// @return tokenAssets Array of token assets that would be received (loss-adjusted)
    /// @return yieldUsdc Array of USDC yield that would be received
    function batchPreviewWithdraw(
        address user,
        bytes32[] calldata conditionIds,
        DataTypes.Side[] calldata sides,
        uint256[] calldata sharesToBurn,
        uint256[] calldata twapPricesYes
    ) external view returns (uint256[] memory tokenAssets, uint256[] memory yieldUsdc);

    // ============ Market State ============

    /// @notice Batch query full market state across multiple markets
    /// @param conditionIds Array of market condition IDs
    /// @return states Array of market states (indexes, pool shares, timestamps, etc.)
    function batchGetMarketState(bytes32[] calldata conditionIds) external view returns (DataTypes.MarketState[] memory states);

    /// @notice Batch query computed market indexes across multiple markets
    /// @dev Simulates pending yield since last update when twapPriceYes <= PRICE_SCALE
    /// @param conditionIds Array of market condition IDs
    /// @param twapPricesYes Array of average YES TWAP price since last update per market (> PRICE_SCALE to use stored)
    /// @return results Array of computed index results (loss indexes, yield per share, reduction factor, market value)
    function batchGetMarketIndexes(bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (DataTypes.IndexResult[] memory results);

    // ============ Capacity ============

    /// @notice Vault-wide deposit headroom, evaluated exactly as a real deposit would be
    /// @dev All fields use `type(uint256).max` to mean "uncapped". The internal tier is admin-disableable
    ///      (`isInternalCapacityCheckDisabled`); when disabled it never blocks a deposit, so
    ///      `internalRemaining` reports uncapped and drops out of `remainingUsdc`.
    struct VaultCapacity {
        /// @dev USDC the vault can still absorb now; min of the enforced tiers
        uint256 remainingUsdc;
        /// @dev Whether the internal (forward-looking worst-case pairing) guard is enforced
        bool internalCheckEnabled;
        /// @dev Headroom for additional worst-case matched tokens before the internal guard trips
        uint256 internalRemaining;
        /// @dev Live headroom the actually-paired USDC must fit into (external ERC-4626 vaults)
        uint256 externalRemaining;
    }

    /// @notice Which side of a market pairs against the pool's current unmatched surplus
    enum MatchingSide {
        YES,
        NO,
        NONE
    }

    /// @notice Result of simulating a batch deposit: whether it fits, how far each tier overshoots,
    ///         where each market's tokens land, plus the vault's headroom
    struct DepositCapacity {
        /// @dev Whether a deposit of the given batch would succeed (honors the internal-guard flag)
        bool fits;
        /// @dev USDC the batch overshoots the internal (unmatched-surplus) tier by; 0 when not binding
        uint256 internalShortfall;
        /// @dev USDC the batch overshoots the external (matched / ERC-4626) tier by; 0 when not binding
        uint256 externalShortfall;
        /// @dev Per market: USDC that pairs against the pool now; consumes external (matched) capacity
        uint256[] matchedUsdc;
        /// @dev Per market: USDC this deposit adds to the pool's unmatched surplus; consumes internal capacity (0 when it reduces the surplus)
        uint256[] unmatchedUsdc;
        /// @dev Per market: the side that pairs against the pool's current surplus (NONE when balanced)
        MatchingSide[] matchingSide;
        /// @dev The vault's current headroom; identical to `getCapacity()`
        VaultCapacity capacity;
    }

    /// @notice The vault's current deposit headroom; no batch needed
    /// @dev Reads the live state of every attached ERC-4626 vault (its own `maxDeposit` and the admin
    ///      cap) plus the internal-guard flag. Use this for a "how full is the vault" gauge.
    /// @return capacity Per-tier and overall remaining headroom
    function getCapacity() external view returns (VaultCapacity memory capacity);

    /// @notice Simulate a batch deposit: whether it fits, per-tier shortfalls, and where each market's tokens land
    /// @dev Mirrors the vault's deposit-time checks, including skipping the internal tier when
    ///      `isInternalCapacityCheckDisabled()` is set. Capacity is vault-wide, so pass the WHOLE
    ///      prospective batch; per-market checks do not compose.
    /// @param conditionIds Array of condition IDs
    /// @param yesAmounts Array of YES amounts (aligned with conditionIds)
    /// @param noAmounts Array of NO amounts (aligned with conditionIds)
    /// @return result `fits`, the per-tier shortfalls, per-market matched/unmatched USDC, and the vault's headroom
    function getDepositCapacity(bytes32[] memory conditionIds, uint256[] memory yesAmounts, uint256[] memory noAmounts)
        external
        view
        returns (DepositCapacity memory result);

    // ============ Vault Reference ============

    /// @notice Get the address of the RobinStakingVault this lens reads from
    /// @return The vault address
    function vault() external view returns (address);
}
