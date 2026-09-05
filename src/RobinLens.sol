// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from './types/DataTypes.sol';
import { IRobinLens } from './interfaces/IRobinLens.sol';
import { IRobinStakingVault } from './interfaces/IRobinStakingVault.sol';

/// @title RobinLens
/// @notice Read-only aggregation contract for batch queries against RobinStakingVault
/// @dev Deployed separately from the vault to reduce vault contract size.
///      All functions are view-only and delegate to the vault's public view functions.
contract RobinLens is IRobinLens {
    using Math for uint256;

    /// @inheritdoc IRobinLens
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    // ============ Batch Queries ============

    /// @inheritdoc IRobinLens
    function batchGetUserShares(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesShares, uint256[] memory noShares)
    {
        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        yesShares = new uint256[](len);
        noShares = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesShares[i], noShares[i]) = v.getUserShares(user, conditionIds[i]);
        }
    }

    /// @inheritdoc IRobinLens
    function batchGetUserAssets(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesAssets, uint256[] memory noAssets)
    {
        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        yesAssets = new uint256[](len);
        noAssets = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesAssets[i], noAssets[i]) = v.getUserAssets(user, conditionIds[i]);
        }
    }

    /// @inheritdoc IRobinLens
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
        )
    {
        if (conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        yesShares = new uint256[](len);
        noShares = new uint256[](len);
        yesAssets = new uint256[](len);
        noAssets = new uint256[](len);
        yesYield = new uint256[](len);
        noYield = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesShares[i], noShares[i]) = v.getUserShares(user, conditionIds[i]);
            (yesAssets[i], noAssets[i]) = v.getUserAssets(user, conditionIds[i]);
            (yesYield[i], noYield[i]) = v.getUserYield(user, conditionIds[i], twapPricesYes[i]);
        }
    }

    /// @inheritdoc IRobinLens
    function batchGetUserSharesAndAssets(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesShares, uint256[] memory noShares, uint256[] memory yesAssets, uint256[] memory noAssets)
    {
        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        yesShares = new uint256[](len);
        noShares = new uint256[](len);
        yesAssets = new uint256[](len);
        noAssets = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesShares[i], noShares[i]) = v.getUserShares(user, conditionIds[i]);
            (yesAssets[i], noAssets[i]) = v.getUserAssets(user, conditionIds[i]);
        }
    }

    /// @inheritdoc IRobinLens
    function batchGetUserYield(address user, bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (uint256[] memory yesYield, uint256[] memory noYield)
    {
        if (conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        yesYield = new uint256[](len);
        noYield = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesYield[i], noYield[i]) = v.getUserYield(user, conditionIds[i], twapPricesYes[i]);
        }
    }

    /// @inheritdoc IRobinLens
    function batchPreviewDeposit(bytes32[] calldata conditionIds, DataTypes.Side[] calldata sides, uint256[] calldata amounts)
        external
        view
        returns (uint256[] memory shares)
    {
        if (conditionIds.length != sides.length || conditionIds.length != amounts.length) revert LengthMismatch();

        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        if (len != sides.length || len != amounts.length) revert LengthMismatch();
        shares = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            shares[i] = v.previewDeposit(conditionIds[i], sides[i], amounts[i]);
        }
    }

    /// @inheritdoc IRobinLens
    function batchPreviewWithdraw(
        address user,
        bytes32[] calldata conditionIds,
        DataTypes.Side[] calldata sides,
        uint256[] calldata sharesToBurn,
        uint256[] calldata twapPricesYes
    ) external view returns (uint256[] memory tokenAssets, uint256[] memory yieldUsdc) {
        if (conditionIds.length != sides.length || conditionIds.length != sharesToBurn.length || conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        if (len != sides.length || len != sharesToBurn.length || len != twapPricesYes.length) revert LengthMismatch();

        tokenAssets = new uint256[](len);
        yieldUsdc = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (tokenAssets[i], yieldUsdc[i]) = v.previewWithdraw(user, conditionIds[i], sides[i], sharesToBurn[i], twapPricesYes[i]);
        }
    }

    // ============ Market State ============

    /// @inheritdoc IRobinLens
    function batchGetMarketState(bytes32[] calldata conditionIds) external view returns (DataTypes.MarketState[] memory states) {
        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        states = new DataTypes.MarketState[](len);

        for (uint256 i = 0; i < len; i++) {
            states[i] = v.getMarketState(conditionIds[i]);
        }
    }

    /// @inheritdoc IRobinLens
    function batchGetMarketIndexes(bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (DataTypes.IndexResult[] memory results)
    {
        if (conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 len = conditionIds.length;
        results = new DataTypes.IndexResult[](len);

        for (uint256 i = 0; i < len; i++) {
            results[i] = v.getMarketIndexes(conditionIds[i], twapPricesYes[i]);
        }
    }

    // ============ Capacity ============

    /// @inheritdoc IRobinLens
    function getCapacity() external view returns (VaultCapacity memory capacity) {
        (capacity,,) = _capacity(IRobinStakingVault(vault));
    }

    /// @inheritdoc IRobinLens
    function getDepositCapacity(bytes32[] memory conditionIds, uint256[] memory yesAmounts, uint256[] memory noAmounts)
        external
        view
        returns (DepositCapacity memory result)
    {
        uint256 len = conditionIds.length;
        if (len != yesAmounts.length || len != noAmounts.length) revert LengthMismatch();

        IRobinStakingVault v = IRobinStakingVault(vault);
        uint256 internalCapacity;
        uint256 newMaxPotential;
        (result.capacity, internalCapacity, newMaxPotential) = _capacity(v);
        result.matchedUsdc = new uint256[](len);
        result.unmatchedUsdc = new uint256[](len);
        result.matchingSide = new MatchingSide[](len);

        // ---- Simulate the batch (mirrors _addUnpaired + _pairAndMerge), one market at a time ----
        uint256 totalPairedUsdc;
        for (uint256 i = 0; i < len; i++) {
            (uint256 unpairedYes, uint256 unpairedNo) = v.getUnpairedTokens(conditionIds[i]);
            uint256 pairs;
            (newMaxPotential, pairs, result.unmatchedUsdc[i], result.matchingSide[i]) =
                _simulateMarket(unpairedYes, unpairedNo, yesAmounts[i], noAmounts[i], newMaxPotential);
            result.matchedUsdc[i] = pairs;
            totalPairedUsdc += pairs;
        }

        // ---- Tier checks, gated exactly like the vault's batch-deposit path ----
        // Internal (forward-looking): only enforced while the admin guard is on. The vault runs it after
        // merging, when the batch's own paired USDC is still idle in the contract, so that USDC has
        // already been subtracted from the internal capacity the vault compares against.
        if (result.capacity.internalCheckEnabled && internalCapacity != type(uint256).max) {
            uint256 internalAtCheck = internalCapacity > totalPairedUsdc ? internalCapacity - totalPairedUsdc : 0;
            if (newMaxPotential > internalAtCheck) {
                result.internalShortfall = newMaxPotential - internalAtCheck;
            }
        }
        // External (live ERC-4626 headroom for the paired USDC): always enforced.
        if (result.capacity.externalRemaining != type(uint256).max && totalPairedUsdc > result.capacity.externalRemaining) {
            result.externalShortfall = totalPairedUsdc - result.capacity.externalRemaining;
        }
        result.fits = result.internalShortfall == 0 && result.externalShortfall == 0;
    }

    /// @dev One market's share of the simulation: advances the global max potential the way
    ///      _addUnpaired + _pairAndMerge would, and reports where this deposit's tokens land.
    function _simulateMarket(uint256 unpairedYes, uint256 unpairedNo, uint256 yesAmount, uint256 noAmount, uint256 maxPotential)
        private
        pure
        returns (uint256 updatedMaxPotential, uint256 pairs, uint256 unmatchedAdded, MatchingSide side)
    {
        side = unpairedYes > unpairedNo ? MatchingSide.NO : unpairedNo > unpairedYes ? MatchingSide.YES : MatchingSide.NONE;

        uint256 newYes = unpairedYes + yesAmount;
        uint256 newNo = unpairedNo + noAmount;
        uint256 currentMax = Math.max(unpairedYes, unpairedNo);
        uint256 newMax = Math.max(newYes, newNo);

        // Update max potential (simulates _addUnpaired)
        updatedMaxPotential = maxPotential;
        if (newMax > currentMax) {
            updatedMaxPotential += newMax - currentMax;
        }

        // Simulate pairing (simulates _pairAndMerge)
        pairs = newYes < newNo ? newYes : newNo;
        uint256 maxAfterPair = newMax;
        if (pairs > 0) {
            maxAfterPair = Math.max(newYes - pairs, newNo - pairs);
            updatedMaxPotential = (newMax - maxAfterPair) <= updatedMaxPotential ? updatedMaxPotential - (newMax - maxAfterPair) : 0;
        }

        // Pairs consume the external (matched) tier. The internal tier charges the growth of the
        // market's worst-case pairing exposure: every token on the side that is larger after the
        // deposit, net of pool surplus it pairs against. Pairing doesn't reduce that charge; the
        // merged USDC is idle at check time and fills the cap just the same.
        unmatchedAdded = newMax - currentMax;
    }

    /// @dev Shared headroom read behind both public views. Also returns the raw internal cap and the
    ///      current max potential the batch simulation compares against, so the vault is read once.
    function _capacity(IRobinStakingVault v)
        private
        view
        returns (VaultCapacity memory capacity, uint256 internalCapacity, uint256 currentMaxPotential)
    {
        internalCapacity = v.getTotalAvailableInternalCapacity();
        currentMaxPotential = v.getMaximumAdditionalMatchedTokens();
        capacity.internalCheckEnabled = !v.isInternalCapacityCheckDisabled();
        // External: the live ERC-4626 headroom the vault getter already computes (min of each attached
        // vault's own maxDeposit and the admin cap, minus idle USDC). Always enforced.
        capacity.externalRemaining = v.getTotalAvailableCapacity();
        // Internal: room left for additional worst-case matched tokens. A disabled guard never blocks,
        // so it reports uncapped and drops out of the overall minimum.
        if (!capacity.internalCheckEnabled || internalCapacity == type(uint256).max) {
            capacity.internalRemaining = type(uint256).max;
        } else {
            capacity.internalRemaining = internalCapacity > currentMaxPotential ? internalCapacity - currentMaxPotential : 0;
        }
        capacity.remainingUsdc = Math.min(capacity.internalRemaining, capacity.externalRemaining);
    }

    // ============ Errors ============

    /// @notice Thrown when array lengths don't match
    error LengthMismatch();
}
