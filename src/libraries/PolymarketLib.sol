// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { IRobinStakingVaultEvents } from '../interfaces/IRobinStakingVaultEvents.sol';
import { IRobinStakingVaultErrors } from '../interfaces/IRobinStakingVaultErrors.sol';
import { IConditionalTokens } from '../interfaces/external/IConditionalTokens.sol';
import { ICollateralOnramp } from '../interfaces/external/ICollateralOnramp.sol';
import { ICollateralOfframp } from '../interfaces/external/ICollateralOfframp.sol';
import { StorageLib } from './StorageLib.sol';

/// @title PolymarketLib
/// @notice Externally-deployed library for Polymarket CTF integration operations
/// @dev Deployed as a separate contract and called via DELEGATECALL to reduce vault bytecode.
///      Accesses PolymarketMixin's ERC-7201 namespaced storage directly via the same slot constant.
library PolymarketLib {
    using SafeERC20 for IERC20;

    /// @notice Transient-storage slot that gates ERC-1155 inbound transfers to the vault.
    bytes32 internal constant RECEIVE_ALLOWED_SLOT = keccak256('robin.transient.receiveAllowed');

    function _getStorage() private pure returns (StorageLib.PolymarketStorage storage $) {
        return StorageLib.getPolymarketStorage();
    }

    /// @notice Brackets a CTF call that legitimately moves outcome tokens to the vault.
    function _setReceiveAllowed(bool allow) private {
        bytes32 slot = RECEIVE_ALLOWED_SLOT;
        assembly {
            tstore(slot, allow)
        }
    }

    // ============ Market Initialization ============

    /// @notice Initialize market token info on first deposit
    /// @dev The caller must supply the original Polymarket `questionId` so the contract can
    ///      verify the negRisk classification by reconstructing the conditionId itself
    ///      (`keccak256(oracle, questionId, 2)`). This replaces the previous reliance on
    ///      Polymarket's `getConditionId` / `getComplement` registry views, which the new
    ///      Polymarket exchanges no longer expose.
    function initializePolymarketInfo(bytes32 conditionId, bytes32 questionId) external returns (DataTypes.PolymarketTokenInfo memory info) {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        IConditionalTokens ctf = $.ctf;

        // Validate binary market
        uint256 outcomeSlotCount = ctf.getOutcomeSlotCount(conditionId);
        if (outcomeSlotCount != 2) revert IRobinStakingVaultErrors.InvalidOutcomeSlotCount(conditionId, outcomeSlotCount);

        // Compute collections
        bytes32 yesColl = ctf.getCollectionId(DataTypes.PARENT_COLLECTION_ID, conditionId, DataTypes.YES_INDEX_SET);
        bytes32 noColl = ctf.getCollectionId(DataTypes.PARENT_COLLECTION_ID, conditionId, DataTypes.NO_INDEX_SET);

        // Verify market type via oracle hash check. `_decideVaultMode` returns the canonical
        // collateral for the matched oracle (USDC.e for legacy markets, PolyUSD for admin-tagged
        // PolyUSD oracles, WCOL for NegRisk).
        (bool negRisk, address collateral) = _decideVaultMode($, conditionId, questionId);

        // Compute position IDs
        info.yesPositionId = ctf.getPositionId(collateral, yesColl);
        info.noPositionId = ctf.getPositionId(collateral, noColl);
        info.negRisk = negRisk;
        info.collateral = collateral;

        // Store info
        $.tokenInfo[conditionId] = info;

        emit IRobinStakingVaultEvents.MarketInitialized(conditionId, info.yesPositionId, info.noPositionId, negRisk);
    }

    // ============ Token Transfers ============

    /// @notice Pull outcome tokens from a user via CTF batch transfer
    /// @dev Requires the user to have approved this contract on the CTF
    /// @param ids Array of CTF position IDs to transfer
    /// @param amts Array of amounts to transfer per position
    /// @param from Address to transfer tokens from
    function takeOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address from) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        IConditionalTokens ctf = $.ctf;

        if (!ctf.isApprovedForAll(from, address(this))) revert IRobinStakingVaultErrors.CTFApprovalRequired();

        // Bracket the CTF transfer with the receive-allowed flag so the vault's
        // onERC1155Received hook accepts these specific tokens (and only these).
        _setReceiveAllowed(true);
        if (ids.length == 1) {
            ctf.safeTransferFrom(from, address(this), ids[0], amts[0], '');
        } else {
            ctf.safeBatchTransferFrom(from, address(this), ids, amts, '');
        }
        _setReceiveAllowed(false);
    }

    /// @notice Send outcome tokens to a user via CTF batch transfer
    /// @param ids Array of CTF position IDs to transfer
    /// @param amts Array of amounts to transfer per position
    /// @param to Address to transfer tokens to
    function giveOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address to) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        IConditionalTokens ctf = $.ctf;

        if (ids.length == 1) {
            ctf.safeTransferFrom(address(this), to, ids[0], amts[0], '');
        } else {
            ctf.safeBatchTransferFrom(address(this), to, ids, amts, '');
        }
    }

    // ============ Merge / Split ============

    /// @notice Split USDC.e into YES+NO token pairs.
    /// @dev Three classification paths:
    ///        - NegRisk: split via the NegRiskAdapter (USDC.e in, WCOL-flavoured positions out).
    ///        - Regular USDC.e: direct `ctf.splitPosition` with USDC.e.
    ///        - Regular PolyUSD: wrap USDC.e → PolyUSD via the onramp first, then `ctf.splitPosition`
    ///          with PolyUSD. The wrap leaves `usdcAmount` PolyUSD in the vault, which is the
    ///          collateral the CTF will pull for the split.
    function split(bytes32 conditionId, uint256 usdcAmount) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        DataTypes.PolymarketTokenInfo storage info = $.tokenInfo[conditionId];

        uint256[] memory partition = new uint256[](2);
        partition[0] = DataTypes.YES_INDEX_SET;
        partition[1] = DataTypes.NO_INDEX_SET;

        // Bracket the splitPosition call so the vault's onERC1155Received hook accepts
        // the freshly minted YES/NO tokens (vault is the recipient of the mint).
        _setReceiveAllowed(true);
        if (info.negRisk) {
            $.negRiskAdapter.splitPosition($.underlyingUsdc, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, usdcAmount);
        } else if (info.collateral == $.underlyingUsdc) {
            $.ctf.splitPosition(info.collateral, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, usdcAmount);
        } else {
            // PolyUSD-backed regular market: wrap USDC.e → PolyUSD, then split with PolyUSD.
            address onramp = $.polymarketOnramp;
            address underlyingUsdc = $.underlyingUsdc;
            address collateral = info.collateral;
            IConditionalTokens ctf = $.ctf;
            if (onramp == address(0)) revert IRobinStakingVaultErrors.PolymarketOnrampNotSet();
            IERC20(underlyingUsdc).forceApprove(onramp, usdcAmount);
            ICollateralOnramp(onramp).wrap(underlyingUsdc, address(this), usdcAmount);
            // CTF needs allowance on the PolyUSD we just minted to itself before split.
            IERC20(collateral).forceApprove(address(ctf), usdcAmount);
            ctf.splitPosition(collateral, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, usdcAmount);
        }
        _setReceiveAllowed(false);

        // Update max potential (tokens already added by split, so current is NEW state)
        (uint256 newYes, uint256 newNo) = getUnpairedTokens(conditionId);
        _updateMaxPotential($, newYes - usdcAmount, newNo - usdcAmount, newYes, newNo);

        emit IRobinStakingVaultEvents.TokensSplit(conditionId, usdcAmount, usdcAmount);
    }

    /// @notice Pair unpaired tokens and merge to Usdc
    /// @param conditionId Market condition ID
    /// @return pairedAmount Amount of Usdc created from pairing
    function pairAndMerge(bytes32 conditionId) external returns (uint256 pairedAmount) {
        StorageLib.PolymarketStorage storage $ = _getStorage();

        // Get current unpaired balances
        (uint256 yesBalance, uint256 noBalance) = getUnpairedTokens(conditionId);

        // Pair the minimum of both
        uint256 pairs = yesBalance < noBalance ? yesBalance : noBalance;

        if (pairs > 0) {
            pairedAmount = _merge($, conditionId, pairs);
        }
    }

    // ============ Max Potential Tracking ============

    /// @notice Update maximum potential matched tokens
    function updateMaxPotential(uint256 oldYes, uint256 oldNo, uint256 newYes, uint256 newNo) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        _updateMaxPotential($, oldYes, oldNo, newYes, newNo);
    }

    // ============ Private Functions ============

    /// @notice Decide whether a market is NegRisk and return the collateral token it is prepared
    ///         against on the CTF, by reconstructing the conditionId from the supplied questionId.
    /// @dev Polymarket's `conditionId = keccak256(oracle, questionId, outcomeSlotCount)`. We verify:
    ///      1. NegRisk: oracle = $.negRiskAdapter → collateral is WCOL.
    ///      2. Regular: oracle ∈ $.polymarketOracles (admin-managed list, in priority order).
    ///         The matched entry's `collateral` is returned — typically USDC.e, but PolyUSD for
    ///         oracles that the admin has tagged as PolyUSD-backed.
    ///      The first match wins; if neither branch reproduces the conditionId, the caller is
    ///      either lying about the questionId or the market is on an oracle we don't recognise —
    ///      either way we revert rather than guess (a wrong guess would brick the market).
    function _decideVaultMode(StorageLib.PolymarketStorage storage $, bytes32 conditionId, bytes32 questionId)
        private
        view
        returns (bool isNegRisk, address collateral)
    {
        if (_computeConditionId(address($.negRiskAdapter), questionId) == conditionId) {
            return (true, $.polymarketWcol);
        }

        DataTypes.PolymarketOracle[] storage oracles = $.polymarketOracles;
        uint256 len = oracles.length;
        for (uint256 i = 0; i < len; i++) {
            if (_computeConditionId(oracles[i].oracle, questionId) == conditionId) {
                return (false, oracles[i].collateral);
            }
        }

        revert IRobinStakingVaultErrors.UnlistedCondition(conditionId);
    }

    /// @notice Compute the canonical CTF conditionId for a binary market locally.
    /// @dev Equivalent to `IConditionalTokens.getConditionId(oracle, questionId, 2)` but pure —
    ///      avoids an external call
    function _computeConditionId(address oracle, bytes32 questionId) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, questionId, uint256(2)));
    }

    // ============ Regular Oracle Management ============

    /// @notice Append a Polymarket oracle to the priority list, paired with the collateral that
    ///         markets prepared by this oracle use on the CTF (USDC.e or PolyUSD).
    /// @dev New entry is added at the end; use `swapPolymarketOracleOrder` to promote it.
    function addPolymarketOracle(address oracle, address collateral) external {
        if (oracle == address(0) || collateral == address(0)) revert IRobinStakingVaultErrors.ZeroAddress();
        StorageLib.PolymarketStorage storage $ = _getStorage();
        DataTypes.PolymarketOracle[] storage oracles = $.polymarketOracles;
        uint256 len = oracles.length;
        for (uint256 i = 0; i < len; i++) {
            if (oracles[i].oracle == oracle) revert IRobinStakingVaultErrors.PolymarketOracleAlreadyExists(oracle);
        }
        oracles.push(DataTypes.PolymarketOracle({ oracle: oracle, collateral: collateral }));
        emit IRobinStakingVaultEvents.PolymarketOracleAdded(oracle, collateral, len);
    }

    /// @notice Remove a Polymarket oracle from the priority list
    /// @dev Preserves the relative order of remaining entries (uses shift, not swap-with-last).
    ///      Existing initialized markets are unaffected — their classification is cached in
    ///      `info.collateral` at init time and is not re-evaluated.
    function removePolymarketOracle(address oracle) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        DataTypes.PolymarketOracle[] storage oracles = $.polymarketOracles;
        uint256 len = oracles.length;
        for (uint256 i = 0; i < len; i++) {
            if (oracles[i].oracle == oracle) {
                for (uint256 j = i; j + 1 < len; j++) {
                    oracles[j] = oracles[j + 1];
                }
                oracles.pop();
                emit IRobinStakingVaultEvents.PolymarketOracleRemoved(oracle);
                return;
            }
        }
        revert IRobinStakingVaultErrors.PolymarketOracleNotFound(oracle);
    }

    /// @notice Swap the priority order of two Polymarket oracles
    /// @dev Use this to promote a more common oracle to the front so `_decideVaultMode`
    ///      iterates as little as possible.
    function swapPolymarketOracleOrder(address oracle1, address oracle2) external {
        if (oracle1 == oracle2) return;
        StorageLib.PolymarketStorage storage $ = _getStorage();
        DataTypes.PolymarketOracle[] storage oracles = $.polymarketOracles;
        uint256 len = oracles.length;
        uint256 idx1 = type(uint256).max;
        uint256 idx2 = type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            if (oracles[i].oracle == oracle1) idx1 = i;
            else if (oracles[i].oracle == oracle2) idx2 = i;
        }
        if (idx1 == type(uint256).max) revert IRobinStakingVaultErrors.PolymarketOracleNotFound(oracle1);
        if (idx2 == type(uint256).max) revert IRobinStakingVaultErrors.PolymarketOracleNotFound(oracle2);
        DataTypes.PolymarketOracle memory tmp = oracles[idx1];
        oracles[idx1] = oracles[idx2];
        oracles[idx2] = tmp;
        emit IRobinStakingVaultEvents.PolymarketOraclesSwapped(oracle1, oracle2, idx1, idx2);
    }

    /// @notice View the current ordered list of Polymarket oracles (oracle/collateral pairs)
    function getPolymarketOracles() external view returns (DataTypes.PolymarketOracle[] memory) {
        return _getStorage().polymarketOracles;
    }

    // ============ Polymarket Collateral On-/Offramp ============

    /// @notice Update the Polymarket CollateralOnramp address
    /// @dev The new onramp must accept USDC.e via its `wrap(asset, to, amount)` flow.
    function setPolymarketOnramp(address newOnramp) external {
        if (newOnramp == address(0)) revert IRobinStakingVaultErrors.ZeroAddress();
        StorageLib.PolymarketStorage storage $ = _getStorage();
        address oldOnramp = $.polymarketOnramp;
        if (newOnramp == oldOnramp) return;
        $.polymarketOnramp = newOnramp;
        emit IRobinStakingVaultEvents.PolymarketOnrampUpdated(oldOnramp, newOnramp);
    }

    /// @notice Update the Polymarket CollateralOfframp address.
    function setPolymarketOfframp(address newOfframp) external {
        if (newOfframp == address(0)) revert IRobinStakingVaultErrors.ZeroAddress();
        StorageLib.PolymarketStorage storage $ = _getStorage();
        address oldOfframp = $.polymarketOfframp;
        if (newOfframp == oldOfframp) return;
        $.polymarketOfframp = newOfframp;
        emit IRobinStakingVaultEvents.PolymarketOfframpUpdated(oldOfframp, newOfframp);
    }

    /// @notice Merge paired YES+NO tokens into Usdc
    /// @param conditionId Market condition ID
    /// @param pairs Amount of pairs to merge
    /// @return usdcReceived Amount of Usdc received
    function _merge(StorageLib.PolymarketStorage storage $, bytes32 conditionId, uint256 pairs) private returns (uint256 usdcReceived) {
        DataTypes.PolymarketTokenInfo storage info = $.tokenInfo[conditionId];

        address underlyingUsdc = $.underlyingUsdc;

        uint256 beforeBal = IERC20(underlyingUsdc).balanceOf(address(this));

        uint256[] memory partition = new uint256[](2);
        partition[0] = DataTypes.YES_INDEX_SET;
        partition[1] = DataTypes.NO_INDEX_SET;

        if (info.negRisk) {
            $.negRiskAdapter.mergePositions(underlyingUsdc, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, pairs);
        } else if (info.collateral == underlyingUsdc) {
            $.ctf.mergePositions(info.collateral, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, pairs);
        } else {
            // PolyUSD-backed regular market: merge gives us PolyUSD, unwrap to USDC.e via the offramp.
            address offramp = $.polymarketOfframp;
            if (offramp == address(0)) revert IRobinStakingVaultErrors.PolymarketOfframpNotSet();
            $.ctf.mergePositions(info.collateral, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, pairs);
            // Now vault holds `pairs` PolyUSD. Approve the offramp and unwrap into USDC.e.
            IERC20(info.collateral).forceApprove(offramp, pairs);
            ICollateralOfframp(offramp).unwrap(underlyingUsdc, address(this), pairs);
        }

        uint256 afterBal = IERC20(underlyingUsdc).balanceOf(address(this));
        usdcReceived = afterBal - beforeBal;

        // Update max potential (tokens already merged/burned, so current is NEW state)
        // get unpaired tokens
        (uint256 newYes, uint256 newNo) = getUnpairedTokens(conditionId);
        _updateMaxPotential($, newYes + pairs, newNo + pairs, newYes, newNo);

        emit IRobinStakingVaultEvents.TokensPaired(conditionId, pairs, usdcReceived);
    }

    /// @notice Internal helper to update max potential matched tokens
    /// @dev Tracks how much additional USDC would enter the pool if all unpaired tokens across all
    ///      markets were optimally matched. For a single market, the "potential" is max(YES, NO) because
    ///      that's the maximum number of pairs that could exist. This is used for capacity checks:
    ///      even if tokens aren't paired yet, we want to ensure the vault can absorb the USDC when they are.
    ///      Otherwise, one side could keep depositing tokens and dilute the yield, while the other side can not catch up because it would exceed the limit.
    /// @dev The reduction branch saturates at zero so that outcome-token donations sent directly to
    ///      the vault (which bypass the deposit accounting and therefore never increment the counter)
    ///      cannot trigger an arithmetic underflow on the subsequent pair-and-merge.
    function _updateMaxPotential(StorageLib.PolymarketStorage storage $, uint256 oldYes, uint256 oldNo, uint256 newYes, uint256 newNo) private {
        uint256 oldMax = Math.max(oldYes, oldNo);
        uint256 newMax = Math.max(newYes, newNo);

        if (newMax > oldMax) {
            $.maximumAdditionalMatchedTokens += newMax - oldMax;
        } else if (oldMax > newMax) {
            uint256 reduction = oldMax - newMax;
            uint256 current = $.maximumAdditionalMatchedTokens;
            $.maximumAdditionalMatchedTokens = reduction >= current ? 0 : current - reduction;
        }
    }

    /// @notice Returns the unpaired YES and NO token balances for a market
    function getUnpairedTokens(bytes32 conditionId) public view returns (uint256 yesAmount, uint256 noAmount) {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        DataTypes.PolymarketTokenInfo storage info = $.tokenInfo[conditionId];
        yesAmount = $.ctf.balanceOf(address(this), info.yesPositionId);
        noAmount = $.ctf.balanceOf(address(this), info.noPositionId);
    }
}
