// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { ShareMath } from './ShareMath.sol';
import { TwapMath } from './TwapMath.sol';

/// @title IndexCalcLib
/// @notice Externally-deployed library for yield/loss index calculations
/// @dev Deployed as a separate contract and called via DELEGATECALL to reduce vault bytecode.
///      All functions are pure — storage reads are performed by the caller and passed as parameters.
library IndexCalcLib {
    using Math for uint256;

    /// @notice Internal helper to calculate loss indexes and yield-per-share with specific pool assets value
    /// @dev For GAINS: only yieldPerShare increases (TWAP-weighted split). lossIndex unchanged.
    ///      For LOSSES: the paired-backed portion of the loss (min(delta, pairableTokens)) is
    ///      applied equally to both lossIndexes; any excess past pairable backing is absorbed by
    ///      yieldReductionFactor instead. yieldPerShare unchanged.
    /// @param market Market state snapshot (copied from storage by the caller)
    /// @param input Calculation parameters (pool state, TWAP data, timestamp)
    /// @return result Computed index result with loss indexes, yield per share, and reduction factor
    function calculateIndexes(DataTypes.MarketState memory market, DataTypes.IndexCalcInput memory input)
        external
        pure
        returns (DataTypes.IndexResult memory result)
    {
        // Start with current stored values
        result.lossIndexYes = market.lossIndexYes;
        result.lossIndexNo = market.lossIndexNo;
        result.yieldPerShareYes = market.yieldPerShareYes;
        result.yieldPerShareNo = market.yieldPerShareNo;
        result.yieldReductionFactor = market.yieldReductionFactor;

        // Skip if market has no pool shares
        if (market.marketPoolShares == 0 || input.totalPoolShares == 0) {
            return result;
        }

        // Get market's actual value from global pool
        result.marketValue = ShareMath.sharesToAssets(market.marketPoolShares, input.totalPoolAssets, input.totalPoolShares, false);

        // Calculate yield/loss vs principal contributed to pool
        if (result.marketValue == market.principalContributed) {
            return result;
        }

        DataTypes.YieldCalcLocals memory vars;

        // Local caching
        vars.principalContributed = market.principalContributed;
        vars.totalSharesYes = market.totalSharesYes;
        vars.totalSharesNo = market.totalSharesNo;

        vars.isGain = result.marketValue > vars.principalContributed;
        vars.delta = vars.isGain ? result.marketValue - vars.principalContributed : vars.principalContributed - result.marketValue;

        if (vars.isGain) {
            // For GAINS: Split by TWAP weighting, only update yieldPerShare
            vars.yesBaseline = ShareMath.sharesToAssetsWithIndex(vars.totalSharesYes, result.lossIndexYes);
            vars.noBaseline = ShareMath.sharesToAssetsWithIndex(vars.totalSharesNo, result.lossIndexNo);

            if (input.twapPriceYes <= DataTypes.PRICE_SCALE && input.currentTimestamp > input.lastTwapUpdate) {
                // View-function path: simulate what the accumulator WOULD be if a TWAP update happened now
                // at the given price. This gives callers an up-to-date yield estimate without requiring a tx.
                uint256 simulatedAccumulator = input.twapAccumulatorYes + input.twapPriceYes * (input.currentTimestamp - input.lastTwapUpdate);
                vars.twapAccumulatorYesDelta = simulatedAccumulator - market.lastYieldTwapCheckpointYes;
                vars.timeDelta = input.currentTimestamp - market.lastYieldTimestamp;
            } else {
                // Mutating path (PRICE_SCALE + 1 sentinel): use stored accumulators as-is.
                // TWAP was already applied to storage before calling this.
                vars.twapAccumulatorYesDelta = input.twapAccumulatorYes - market.lastYieldTwapCheckpointYes;
                vars.timeDelta = input.lastTwapUpdate - market.lastYieldTimestamp;

                // Fallback to last twap when no fresh TWAP has been submitted since the last yield update
                // This can happen during the GRACE_PERIOD
                if (vars.timeDelta == 0) {
                    vars.timeDelta = 1;
                    vars.twapAccumulatorYesDelta = uint256(market.lastTwapPriceYes);
                }
            }

            (vars.yesDelta, vars.noDelta) =
                TwapMath.splitYieldWeighted(vars.delta, vars.twapAccumulatorYesDelta, vars.timeDelta, vars.yesBaseline, vars.noBaseline);

            // Increase yieldPerShare (USDC yield per share)
            if (vars.totalSharesYes > 0 && vars.yesDelta > 0) {
                result.yieldPerShareYes += vars.yesDelta.mulDiv(DataTypes.INDEX_SCALE, vars.totalSharesYes, Math.Rounding.Floor);
            }
            if (vars.totalSharesNo > 0 && vars.noDelta > 0) {
                result.yieldPerShareNo += vars.noDelta.mulDiv(DataTypes.INDEX_SCALE, vars.totalSharesNo, Math.Rounding.Floor);
            }
        } else {
            // For LOSSES: the paired-backed portion of the loss is applied equally to both
            // sides' lossIndexes. The vault holds USDC from merged token pairs (1 USDC = 1 YES + 1 NO),
            // When X USDC is lost, the vault can produce X fewer YES tokens AND X fewer NO tokens
            // on withdrawal (since splitting X USDC creates X YES + X NO simultaneously).

            // Calculate token assets before loss (needed to detect if loss exceeds pairable backing)
            uint256 yesTokenAssets =
                vars.totalSharesYes > 0 ? vars.totalSharesYes.mulDiv(result.lossIndexYes, DataTypes.INDEX_SCALE, Math.Rounding.Floor) : 0;
            uint256 noTokenAssets =
                vars.totalSharesNo > 0 ? vars.totalSharesNo.mulDiv(result.lossIndexNo, DataTypes.INDEX_SCALE, Math.Rounding.Floor) : 0;

            uint256 pairableTokens = yesTokenAssets < noTokenAssets ? yesTokenAssets : noTokenAssets;
            uint256 lossToIndex = vars.delta < pairableTokens ? vars.delta : pairableTokens;
            vars.yesDelta = lossToIndex;
            vars.noDelta = lossToIndex;

            // Decrease lossIndex (token value reduction), allow reaching 0
            if (vars.totalSharesYes > 0 && vars.yesDelta > 0) {
                vars.yesChange = vars.yesDelta.mulDiv(DataTypes.INDEX_SCALE, vars.totalSharesYes, Math.Rounding.Floor);
                result.lossIndexYes = result.lossIndexYes > vars.yesChange ? result.lossIndexYes - vars.yesChange : 0;
            }
            if (vars.totalSharesNo > 0 && vars.noDelta > 0) {
                vars.noChange = vars.noDelta.mulDiv(DataTypes.INDEX_SCALE, vars.totalSharesNo, Math.Rounding.Floor);
                result.lossIndexNo = result.lossIndexNo > vars.noChange ? result.lossIndexNo - vars.noChange : 0;
            }

            // If loss exceeds token pair backing, excess eats into yield via reduction factor.
            _applyExcessLossReduction(result, market, vars.delta, yesTokenAssets, noTokenAssets, vars.totalSharesYes, vars.totalSharesNo);
        }
    }

    /// @notice Apply yield reduction when loss exceeds pairable token backing
    /// @dev When USDC loss occurs, it reduces the outcome tokens that can be merged (since merging
    ///      requires equal amounts of YES and NO). If loss > min(YES, NO) tokens, the excess
    ///      cannot be absorbed by lossIndex alone (which may already be at 0). To maintain solvency,
    ///      the excess must reduce outstanding yield claims via the yieldReductionFactor.
    ///      totalWeightedSnapshot = Σ(shares_i × snapshot_i) across all users, enabling O(1) computation
    ///      of total outstanding yield without iterating over all users.
    function _applyExcessLossReduction(
        DataTypes.IndexResult memory result,
        DataTypes.MarketState memory market,
        uint256 delta,
        uint256 yesTokenAssets,
        uint256 noTokenAssets,
        uint256 totalSharesYes,
        uint256 totalSharesNo
    ) private pure {
        uint256 pairableTokens = yesTokenAssets < noTokenAssets ? yesTokenAssets : noTokenAssets;
        if (delta <= pairableTokens) return;

        uint256 excessUsdc = delta - pairableTokens;
        uint256 rf = result.yieldReductionFactor;

        // Compute true outstanding yield across all users in O(1):
        //   rawYield = yieldPerShare × totalShares - totalWeightedSnapshot
        // This works because totalWeightedSnapshot tracks Σ(shares_i × snapshot_i) globally,
        // so (yieldPerShare × totalShares - totalWeightedSnapshot) = Σ(shares_i × (yieldPerShare - snapshot_i))
        // which is exactly the sum of all users' unclaimed yield (before reduction factor).
        uint256 yesRaw = result.yieldPerShareYes * totalSharesYes;
        uint256 noRaw = result.yieldPerShareNo * totalSharesNo;
        uint256 claimableRaw = (yesRaw > market.totalWeightedSnapshotYes ? yesRaw - market.totalWeightedSnapshotYes : 0)
            + (noRaw > market.totalWeightedSnapshotNo ? noRaw - market.totalWeightedSnapshotNo : 0);
        uint256 trueTotalYield = (claimableRaw / DataTypes.INDEX_SCALE).mulDiv(rf, DataTypes.INDEX_SCALE, Math.Rounding.Floor);

        // Scale down yieldReductionFactor so that: reducedYield = trueTotalYield - excessUsdc.
        // If excess >= total yield, all yield is wiped out (factor = 0).
        // The factor compounds with the existing rf: new_rf = old_rf × ((total - excess) / total).
        if (trueTotalYield > 0) {
            if (excessUsdc >= trueTotalYield) {
                result.yieldReductionFactor = 0;
            } else {
                uint256 factor = (trueTotalYield - excessUsdc).mulDiv(DataTypes.INDEX_SCALE, trueTotalYield, Math.Rounding.Floor);
                result.yieldReductionFactor = rf.mulDiv(factor, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            }
        }
    }
}
