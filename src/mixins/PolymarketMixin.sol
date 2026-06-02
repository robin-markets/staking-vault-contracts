// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { ERC1155Holder } from '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { IRobinStakingVaultEvents } from '../interfaces/IRobinStakingVaultEvents.sol';
import { IRobinStakingVaultErrors } from '../interfaces/IRobinStakingVaultErrors.sol';

import { IConditionalTokens } from '../interfaces/external/IConditionalTokens.sol';
import { INegRiskAdapter } from '../interfaces/external/INegRiskAdapter.sol';
import { IRegistry } from '../interfaces/external/IRegistry.sol';

import { PolymarketLib } from '../libraries/PolymarketLib.sol';
import { StorageLib } from '../libraries/StorageLib.sol';

/// @title PolymarketMixin
/// @notice Polymarket CTF integration for multi-market singleton vault
/// @dev Uses ERC-7201 namespaced storage pattern for upgradeability.
///      Heavy logic delegated to PolymarketLib (external library) to reduce bytecode.
abstract contract PolymarketMixin is Initializable, ERC1155Holder, IRobinStakingVaultEvents, IRobinStakingVaultErrors {
    using SafeERC20 for IERC20;

    // ============ ERC-7201 Namespaced Storage ============

    function _getPolymarketStorage() private pure returns (StorageLib.PolymarketStorage storage) {
        return StorageLib.getPolymarketStorage();
    }

    // ============ Initialization ============

    /// @notice Initialize the Polymarket mixin
    /// forge-lint: disable-next-line(mixed-case-function)
    function __PolymarketMixin_init(
        address ctf_,
        address negRiskAdapter_,
        address negRiskCtfExchange_,
        address ctfExchange_,
        address underlyingUsdc_,
        address polymarketWcol_
    ) internal onlyInitializing {
        StorageLib.PolymarketStorage storage $ = _getPolymarketStorage();
        $.ctf = IConditionalTokens(ctf_);
        $.negRiskAdapter = INegRiskAdapter(negRiskAdapter_);
        $.negRiskCtfExchange = IRegistry(negRiskCtfExchange_);
        $.ctfExchange = IRegistry(ctfExchange_);
        $.underlyingUsdc = underlyingUsdc_;
        $.polymarketWcol = polymarketWcol_;

        // Approve CTF and NegRiskAdapter
        IERC20(polymarketWcol_).safeIncreaseAllowance(ctf_, type(uint256).max);
        IERC20(underlyingUsdc_).safeIncreaseAllowance(ctf_, type(uint256).max);
        IERC20(underlyingUsdc_).safeIncreaseAllowance(negRiskAdapter_, type(uint256).max);

        // Approve CTF for ERC-1155 transfers to NegRiskAdapter
        IConditionalTokens(ctf_).setApprovalForAll(negRiskAdapter_, true);
    }

    // ============ View Functions ============

    /// @notice Returns the Polymarket token info for a market
    function getPolymarketTokenInfo(bytes32 conditionId) public view returns (DataTypes.PolymarketTokenInfo memory) {
        return _getPolymarketStorage().tokenInfo[conditionId];
    }

    /// @notice Returns the unpaired YES and NO token balances for a market
    function getUnpairedTokens(bytes32 conditionId) public view returns (uint256 yesAmount, uint256 noAmount) {
        return PolymarketLib.getUnpairedTokens(conditionId);
    }

    /// @notice Returns the address of the underlying USDC token
    function getUnderlyingUsdc() public view virtual returns (address) {
        return _getPolymarketStorage().underlyingUsdc;
    }

    /// @notice Returns the maximum additional matched tokens that could be paired
    function getMaximumAdditionalMatchedTokens() public view returns (uint256) {
        return _getPolymarketStorage().maximumAdditionalMatchedTokens;
    }

    // ============ Internal Functions (delegated to PolymarketLib) ============

    /// @notice Initialize market token info on first deposit
    function _initializePolymarketInfo(bytes32 conditionId, bytes32 questionId) internal returns (DataTypes.PolymarketTokenInfo memory info) {
        return PolymarketLib.initializePolymarketInfo(conditionId, questionId);
    }

    /// @notice Append a Polymarket oracle / collateral pair to the recognised list (delegated to PolymarketLib)
    function _addPolymarketOracle(address oracle, address collateral) internal {
        PolymarketLib.addPolymarketOracle(oracle, collateral);
    }

    /// @notice Remove a Polymarket oracle from the recognised list (delegated to PolymarketLib)
    function _removePolymarketOracle(address oracle) internal {
        PolymarketLib.removePolymarketOracle(oracle);
    }

    /// @notice Swap the priority of two Polymarket oracles (delegated to PolymarketLib)
    function _swapPolymarketOracleOrder(address oracle1, address oracle2) internal {
        PolymarketLib.swapPolymarketOracleOrder(oracle1, oracle2);
    }

    /// @notice Update the Polymarket CollateralOnramp address (delegated to PolymarketLib)
    function _setPolymarketOnramp(address newOnramp) internal {
        PolymarketLib.setPolymarketOnramp(newOnramp);
    }

    /// @notice Read the configured Polymarket CollateralOnramp address (zero if unset)
    function _getPolymarketOnramp() internal view returns (address) {
        return _getPolymarketStorage().polymarketOnramp;
    }

    /// @notice Update the Polymarket CollateralOfframp address (delegated to PolymarketLib)
    function _setPolymarketOfframp(address newOfframp) internal {
        PolymarketLib.setPolymarketOfframp(newOfframp);
    }

    /// @notice Read the configured Polymarket CollateralOfframp address (zero if unset)
    function _getPolymarketOfframp() internal view returns (address) {
        return _getPolymarketStorage().polymarketOfframp;
    }

    /// @notice Pull outcome tokens from a user via CTF batch transfer
    function _takeOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address from) internal {
        PolymarketLib.takeOutcomeTokens(ids, amts, from);
    }

    /// @notice Send outcome tokens to a user via CTF batch transfer
    function _giveOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address to) internal {
        PolymarketLib.giveOutcomeTokens(ids, amts, to);
    }

    /// @notice Pair unpaired tokens and merge to Usdc
    function _pairAndMerge(bytes32 conditionId) internal returns (uint256 pairedAmount) {
        return PolymarketLib.pairAndMerge(conditionId);
    }

    /// @notice Split Usdc into YES+NO token pairs
    function _split(bytes32 conditionId, uint256 usdcAmount) internal {
        PolymarketLib.split(conditionId, usdcAmount);
    }

    /// @notice Update maximum potential matched tokens
    function _updateMaxPotential(uint256 oldYes, uint256 oldNo, uint256 newYes, uint256 newNo) internal {
        PolymarketLib.updateMaxPotential(oldYes, oldNo, newYes, newNo);
    }

    // ============ ERC-1155 Receiver Overrides (Donation Block) ============

    /// @dev Single-token receive hook. Behaves identically to `onERC1155BatchReceived` — the
    ///      single (id, value) is wrapped into length-1 arrays and dispatched through the same
    ///      `_executePushDepositFromHook` path. `data` must still encode the full batch payload
    ///      (length-1 conditionIds / questionIds / amount arrays).
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes memory data)
        public
        virtual
        override
        returns (bytes4)
    {
        bytes32 slot = PolymarketLib.RECEIVE_ALLOWED_SLOT;
        bool ok;
        assembly {
            ok := tload(slot)
        }
        if (ok) return super.onERC1155Received(operator, from, id, value, data);

        if (msg.sender != address(_getPolymarketStorage().ctf)) revert UnsolicitedTransfer();

        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = id;
        values[0] = value;
        _executePushDepositFromHook(from, ids, values, data);
        return super.onERC1155Received(operator, from, id, value, data);
    }

    /// @dev Reject any inbound ERC-1155 transfer that the vault did not itself initiate.
    ///      `PolymarketLib.takeOutcomeTokens` and `PolymarketLib.split` set the transient
    ///      receive-allowed flag right before the CTF call that triggers this hook, and clear
    ///      it immediately after. Any other path — direct donations, callback-time injections
    ///      during `_giveOutcomeTokens`, accidental returns of Robin shares to the vault
    ///      address — finds the flag at zero and reverts.
    ///
    ///      Also handles the **push-deposit entry**: when the call originates from the CTF and
    ///      is not part of one of our own bracketed flows (`_receiveAllowed` unset), `data` is
    ///      decoded as the deposit payload `(conditionIds, questionIds, yesAmounts, noAmounts,
    ///      nonZeroLength, referralCode)` and the full deposit pipeline runs inside this same
    ///      call via `_runPushDeposit`.
    function onERC1155BatchReceived(address operator, address from, uint256[] memory ids, uint256[] memory values, bytes memory data)
        public
        virtual
        override
        returns (bytes4)
    {
        // Bracketed pull / split paths from our own library code — flag is set right before the CTF
        // call and cleared right after. Accept without trying to decode.
        bytes32 slot = PolymarketLib.RECEIVE_ALLOWED_SLOT;
        bool ok;
        assembly {
            ok := tload(slot)
        }
        if (ok) return super.onERC1155BatchReceived(operator, from, ids, values, data);

        // Otherwise the only legitimate inbound source is the CTF — any other ERC-1155 contract is
        // either a Robin-share return (msg.sender == this) or an unrelated token; both should revert.
        if (msg.sender != address(_getPolymarketStorage().ctf)) revert UnsolicitedTransfer();

        _executePushDepositFromHook(from, ids, values, data);
        return super.onERC1155BatchReceived(operator, from, ids, values, data);
    }

    /// @dev Decode the deposit payload, hash the actually-transferred `(ids, values)`, and dispatch into the vault's deposit pipeline.
    function _executePushDepositFromHook(address from, uint256[] memory ids, uint256[] memory values, bytes memory data) private {
        (
            bytes32[] memory conditionIds,
            bytes32[] memory questionIds,
            uint256[] memory yesAmounts,
            uint256[] memory noAmounts,
            uint256 nonZeroLength,
            uint256 referralCode
        ) = abi.decode(data, (bytes32[], bytes32[], uint256[], uint256[], uint256, uint256));

        bytes32 receivedHash = keccak256(abi.encode(ids, values));
        _runPushDeposit(from, receivedHash, conditionIds, questionIds, yesAmounts, noAmounts, nonZeroLength, referralCode);
    }

    /// @notice Run the deposit pipeline for tokens that have just been push-transferred to the vault.
    /// @dev The main vault overrides this with `_batchDepositCore(..., tokensPrePushed = true)`
    function _runPushDeposit(
        address, /* depositor */
        bytes32, /* receivedHash */
        bytes32[] memory, /* conditionIds */
        bytes32[] memory, /* questionIds */
        uint256[] memory, /* yesAmounts */
        uint256[] memory, /* noAmounts */
        uint256, /* nonZeroLength */
        uint256 /* referralCode */
    )
        internal
        virtual
    {
        revert UnsolicitedTransfer();
    }
}
