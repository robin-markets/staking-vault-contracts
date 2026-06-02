// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { UUPSUpgradeable } from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import { AccessControlUpgradeable } from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import { ERC1155Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol';
import { ERC1155Holder } from '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import { DataTypes } from './types/DataTypes.sol';
import { AccountingMixin } from './mixins/AccountingMixin.sol';
import { PolymarketMixin } from './mixins/PolymarketMixin.sol';
import { YieldStrategyMixin } from './mixins/YieldStrategyMixin.sol';
import { SignaturesMixin } from './mixins/SignaturesMixin.sol';
import { PausableMixin } from './mixins/PausableMixin.sol';
import { StorageLib } from './libraries/StorageLib.sol';
import { ICollateralOnramp } from './interfaces/external/ICollateralOnramp.sol';
import { IRobinStakingVault } from './interfaces/IRobinStakingVault.sol';
import { DEFAULT_MANAGER_ROLE, FEE_HARVESTER_ROLE, TIMELOCKED_ROLE, PAUSER_ROLE, OPERATOR_ROLE } from './types/Roles.sol';

/// @title RobinStakingVault
/// @notice Singleton vault for Polymarket staking with multi-market support
/// @dev Combines all mixins with UUPS upgradeability. Admin functions are handled by
///      RobinStakingVaultExtension via the fallback() function to stay under the 24kb limit.
contract RobinStakingVault is
    UUPSUpgradeable,
    ReentrancyGuard,
    AccessControlUpgradeable,
    AccountingMixin,
    PolymarketMixin,
    YieldStrategyMixin,
    SignaturesMixin,
    PausableMixin
{
    // ============ ERC-7201 Extension Storage ============

    function _getExtensionStorage() private pure returns (StorageLib.ExtensionStorage storage) {
        return StorageLib.getExtensionStorage();
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    function initialize(DataTypes.InitParams calldata params) external initializer {
        if (params.owner == address(0)) revert ZeroAddress();

        __AccessControl_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, params.owner);
        _grantRole(DEFAULT_MANAGER_ROLE, params.owner);
        _grantRole(FEE_HARVESTER_ROLE, params.owner);
        _grantRole(PAUSER_ROLE, params.owner);
        _grantRole(OPERATOR_ROLE, params.owner);
        // Setup Timelock
        _grantRole(TIMELOCKED_ROLE, params.timelockController);

        // Make TIMELOCKED_ROLE self-administered
        // Only the timelock can grant/revoke TIMELOCKED_ROLE
        _setRoleAdmin(TIMELOCKED_ROLE, TIMELOCKED_ROLE);

        // Initialize mixins
        __AccountingMixin_init('https://api.robin.markets/v1/shares/{id}', params.protocolFeeBps, params.twapOracle);
        __PolymarketMixin_init(
            params.ctf, params.negRiskAdapter, params.negRiskCtfExchange, params.ctfExchange, params.underlyingUsdc, params.polymarketWcol
        );
        __YieldStrategyMixin_init(params.underlyingUsdc);
        __SignaturesMixin_init('RobinStakingVault', '1', params.ctfExchange);

        // Set extension address
        _getExtensionStorage().extension = params.extension;
    }

    // ============ Deposits ============

    function batchDeposit(
        bytes32[] calldata conditionIds,
        bytes32[] calldata questionIds,
        uint256[] calldata yesAmounts,
        uint256[] calldata noAmounts,
        uint256 nonZeroLength,
        uint256 referralCode
    ) external nonReentrant whenDepositsNotPaused {
        _batchDepositCore(msg.sender, bytes32(0), conditionIds, questionIds, yesAmounts, noAmounts, nonZeroLength, referralCode, false);
    }

    /// @notice Push-deposit entry, invoked from `onERC1155BatchReceived` for any unbracketed CTF
    ///         transfer to the vault.
    /// @dev SDK contract: the wallet calls
    ///      `ctf.safeBatchTransferFrom(wallet, vault, ids, values, data)` where
    ///      `data = abi.encode(bytes32[] conditionIds, bytes32[] questionIds, uint256[] yesAmounts,
    ///      uint256[] noAmounts, uint256 nonZeroLength, uint256 referralCode)`. The transferred
    ///      `(ids, values)` must match what `(conditionIds, yes/noAmounts, cached positionIds)`
    ///      would build — YES then NO per market, markets in ascending `conditionId` order, zero
    ///      amounts skipped. Mismatch (or any decode failure) reverts and undoes the CTF transfer.
    /// @dev Guarded by `nonReentrant` so the deposit pipeline can't be entered concurrently with
    ///      any other vault entry point (matters because the pipeline does multiple external calls
    ///      — CTF.mergePositions, Yearn deposit, etc.). Guarded by `whenDepositsNotPaused` so push
    ///      deposits can't sneak past a global deposit pause. The hook reverting here reverts the
    ///      whole CTF transfer atomically — tokens stay with the caller.
    function _runPushDeposit(
        address depositor,
        bytes32 receivedHash,
        bytes32[] memory conditionIds,
        bytes32[] memory questionIds,
        uint256[] memory yesAmounts,
        uint256[] memory noAmounts,
        uint256 nonZeroLength,
        uint256 referralCode
    ) internal override nonReentrant whenDepositsNotPaused {
        _batchDepositCore(depositor, receivedHash, conditionIds, questionIds, yesAmounts, noAmounts, nonZeroLength, referralCode, true);
    }

    /// @notice Core batch deposit logic shared by the pull path and the push path
    /// @dev Mints shares, acquires outcome tokens (pull or verify-already-pushed), pairs and merges,
    ///      and supplies USDC to external vaults. `conditionIds` MUST be sorted strictly ascending.
    /// @param receivedHash When `tokensPrePushed`, must equal `keccak256(abi.encode(ids, values))`
    ///        of the tokens actually delivered to the vault — the hook computes this from its own
    ///        `(ids, values)` arguments and passes it through
    /// @param tokensPrePushed When `true`, validates `receivedHash` matches what the declared
    ///        params imply. When `false`, pulls tokens via `_takeOutcomeTokens`.
    function _batchDepositCore(
        address depositor,
        bytes32 receivedHash,
        bytes32[] memory conditionIds,
        bytes32[] memory questionIds,
        uint256[] memory yesAmounts,
        uint256[] memory noAmounts,
        uint256 nonZeroLength,
        uint256 referralCode,
        bool tokensPrePushed
    ) internal {
        DataTypes.BatchDepositVars memory vars;

        vars.len = conditionIds.length;
        if (vars.len == 0) revert ZeroAmount();
        if (yesAmounts.length != vars.len || noAmounts.length != vars.len || questionIds.length != vars.len) revert LengthMismatch();
        if (nonZeroLength < vars.len) revert LengthMismatch(); //for each conditionId, either A or B has to be non-zero

        // Sync pool assets with actual vault value once before processing markets
        _updatePoolAssets(_getTotalUsdcValue());

        // Build arrays for batch transfer
        vars.ids = new uint256[](nonZeroLength);
        vars.amts = new uint256[](nonZeroLength);
        vars.yesShares = new uint256[](vars.len);
        vars.noShares = new uint256[](vars.len);

        // Process each market
        vars.nonZeroIndex = 0;
        for (uint256 i = 0; i < vars.len; i++) {
            if (i > 0 && conditionIds[i] <= conditionIds[i - 1]) revert UnsortedConditionIds();
            uint256 yesAmount = yesAmounts[i];
            uint256 noAmount = noAmounts[i];
            if (yesAmount == 0 && noAmount == 0) revert ZeroAmount();

            (vars.yesShares[i], vars.noShares[i]) =
                _prepareDepositMintShares(depositor, conditionIds[i], questionIds[i], yesAmount, noAmount, tokensPrePushed);

            DataTypes.PolymarketTokenInfo memory info = getPolymarketTokenInfo(conditionIds[i]);
            if (yesAmount > 0) {
                vars.ids[vars.nonZeroIndex] = info.yesPositionId;
                vars.amts[vars.nonZeroIndex] = yesAmount;
                vars.nonZeroIndex++;
            }
            if (noAmount > 0) {
                vars.ids[vars.nonZeroIndex] = info.noPositionId;
                vars.amts[vars.nonZeroIndex] = noAmount;
                vars.nonZeroIndex++;
            }
        }
        if (vars.nonZeroIndex != nonZeroLength) revert LengthMismatch();

        // Acquire the outcome tokens. Either pull from the user or verify the push transfer
        // that triggered this call delivered exactly the (ids, amts) by comparing the hashes
        if (tokensPrePushed) {
            if (keccak256(abi.encode(vars.ids, vars.amts)) != receivedHash) revert PushDepositMismatch();
        } else {
            _takeOutcomeTokens(vars.ids, vars.amts, depositor);
        }

        // Pair and supply for all markets
        for (uint256 i = 0; i < vars.len; i++) {
            uint256 paired = _pairAndMerge(conditionIds[i]);
            if (paired > 0) {
                _addToPool(conditionIds[i], paired);
                vars.totalPaired += paired;
            }
        }

        // Two-tier capacity check:
        // 1. Internal capacity (here): checks if all currently unpaired tokens COULD be paired without
        //    exceeding vault caps. This is a forward-looking check on the "worst case" USDC that would
        //    need to be deposited to vaults if all unpaired tokens were matched.
        // 2. External capacity (in _supplyToVaults): checks if the ACTUALLY paired USDC can fit in
        //    external vaults right now. This can fail if external vaults are full.
        // We separate these because external vault limits can change without this contract's knowledge.
        // The internal check can be disabled by an admin (see `setInternalCapacityCheckDisabled`);
        if (!_isInternalCapacityCheckDisabled()) {
            uint256 maximumAdditional = getMaximumAdditionalMatchedTokens();
            uint256 internalCapacity = _getTotalAvailableInternalCapacity();
            if (maximumAdditional > internalCapacity) {
                revert CapacityExceeded(maximumAdditional, internalCapacity);
            }
        }

        // Supply all paired Usdc to vaults
        if (vars.totalPaired > 0) {
            _supplyToVaults();
        }

        emit Deposited(depositor, referralCode, conditionIds, yesAmounts, noAmounts, vars.yesShares, vars.noShares);
    }

    // ============ Withdrawals ============

    function batchWithdraw(
        bytes32[] calldata conditionIds,
        uint256[] calldata yesShares,
        uint256[] calldata noShares,
        address yieldRecipient,
        uint256 nonZeroLength,
        uint256 referralCode,
        bool wrapYieldToPolyUsd
    ) external nonReentrant whenWithdrawalsNotPaused {
        _batchWithdraw(msg.sender, conditionIds, yesShares, noShares, yieldRecipient, nonZeroLength, referralCode, wrapYieldToPolyUsd);
    }

    /// @notice Internal batch withdrawal logic shared by single, batch, and signed withdrawal entry points
    /// @dev Burns shares, splits USDC into outcome tokens if needed, transfers tokens to user, and pays out yield.
    ///      `conditionIds` MUST be sorted strictly ascending;
    /// @param user Address of the user withdrawing
    /// @param conditionIds Array of market condition IDs, sorted strictly ascending
    /// @param yesSharesArr Array of YES shares to burn per market (same order as conditionIds)
    /// @param noSharesArr Array of NO shares to burn per market (same order as conditionIds)
    /// @param yieldRecipient Address to receive USDC yield (address(0) defaults to user)
    /// @param nonZeroLength Total count of non-zero share amounts for batch transfer array sizing
    /// @param referralCode Referral code for off-chain tracking (0 = no referral)
    /// @param wrapYieldToPolyUsd If true, USDC.e yield is wrapped into PolyUSD before being sent to yieldRecipient.
    ///        Reverts if the Polymarket onramp address has not been configured. If the onramp call itself
    ///        fails (e.g. asset paused on Polymarket's side), falls back to a plain USDC.e transfer.
    /// @return yesAssets Array of YES outcome token amounts returned per market
    /// @return noAssets Array of NO outcome token amounts returned per market
    function _batchWithdraw(
        address user,
        bytes32[] memory conditionIds,
        uint256[] memory yesSharesArr,
        uint256[] memory noSharesArr,
        address yieldRecipient,
        uint256 nonZeroLength,
        uint256 referralCode,
        bool wrapYieldToPolyUsd
    ) internal returns (uint256[] memory yesAssets, uint256[] memory noAssets) {
        DataTypes.BatchWithdrawVars memory vars;

        vars.len = conditionIds.length;
        if (vars.len == 0) revert ZeroAmount();
        if (yesSharesArr.length != vars.len || noSharesArr.length != vars.len) revert LengthMismatch();
        if (nonZeroLength < vars.len) revert LengthMismatch(); //for each conditionId, either A or B has to be non-zero

        // Sync pool assets with actual vault value once before processing markets
        _updatePoolAssets(_getTotalUsdcValue());

        yesAssets = new uint256[](vars.len);
        noAssets = new uint256[](vars.len);
        DataTypes.WithdrawBurnResult[] memory results = new DataTypes.WithdrawBurnResult[](vars.len);
        // Two-pass withdrawal: Pass 1 computes all accounting (burns shares, calculates USDC needs).
        // This must happen first so we know the total USDC to withdraw from external vaults.
        // Pass 2 then splits USDC into outcome tokens and builds the transfer arrays.
        for (uint256 i = 0; i < vars.len; i++) {
            if (i > 0 && conditionIds[i] <= conditionIds[i - 1]) revert UnsortedConditionIds();
            if (yesSharesArr[i] == 0 && noSharesArr[i] == 0) revert ZeroAmount();
            if (!isMarketInitialized(conditionIds[i])) revert MarketNotInitialized(conditionIds[i]);

            results[i] = _prepareWithdrawBurnShares(user, conditionIds[i], yesSharesArr[i], noSharesArr[i]);

            yesAssets[i] = results[i].yesAssets;
            noAssets[i] = results[i].noAssets;
            vars.totalUsdcNeeded += results[i].totalNeeded;
            vars.totalYield += results[i].yieldNeeded;
            if (yesSharesArr[i] > 0) vars.trueNonZeroLength++;
            if (noSharesArr[i] > 0) vars.trueNonZeroLength++;
        }
        if (nonZeroLength != vars.trueNonZeroLength) revert LengthMismatch();

        // Ensure we have enough Usdc (withdraws from vaults if needed, supplies excess idle after)
        // Must happen before _split which needs USDC to create outcome token pairs
        if (vars.totalUsdcNeeded > 0) {
            _ensureUsdcBalance(vars.totalUsdcNeeded);
        }

        // Second pass: splits, unpaired removal, and transfer array building
        vars.ids = new uint256[](nonZeroLength);
        vars.amts = new uint256[](nonZeroLength);

        for (uint256 i = 0; i < vars.len; i++) {
            if (results[i].splitNeeded > 0) _split(conditionIds[i], results[i].splitNeeded);

            // Update max potential (tokens not yet transferred out, so current is OLD state)
            (uint256 oldYes, uint256 oldNo) = getUnpairedTokens(conditionIds[i]);
            _updateMaxPotential(oldYes, oldNo, oldYes - results[i].yesAssets, oldNo - results[i].noAssets);

            DataTypes.PolymarketTokenInfo memory info = getPolymarketTokenInfo(conditionIds[i]);
            if (results[i].yesAssets > 0) {
                vars.ids[vars.nonZeroIndex] = info.yesPositionId;
                vars.amts[vars.nonZeroIndex] = results[i].yesAssets;
                vars.nonZeroIndex++;
            }
            if (results[i].noAssets > 0) {
                vars.ids[vars.nonZeroIndex] = info.noPositionId;
                vars.amts[vars.nonZeroIndex] = results[i].noAssets;
                vars.nonZeroIndex++;
            }
        }

        // Batch transfer all tokens to user
        _giveOutcomeTokens(vars.ids, vars.amts, user);

        // Handle payout, including protocol fee
        (uint256 yield, uint256 protocolFee) = _handleYieldPayout(user, yieldRecipient, vars.totalYield, wrapYieldToPolyUsd);

        emit Withdrawn(user, referralCode, conditionIds, yesSharesArr, noSharesArr, yesAssets, noAssets, yield, protocolFee);
    }

    // ============ Signed Withdrawal ============

    /// @dev The purpose of this is to enable limit orders. The user signs the withdrawal for Robin and to place the limit order on Polymarket.
    /// Our backend then monitors the price and executes the withdrawal if the price is close to the limit. Then places the order.
    /// This will be handled differently (Our contract placing the order directly) Once Polymarket enables ERC-1271 signatures.
    function executeSignedWithdrawal(DataTypes.SignedWithdrawal calldata signedWithdrawal) external nonReentrant whenWithdrawalsNotPaused {
        // Verify signature via the extension (routes through fallback)
        IRobinStakingVault(address(this)).verifySignedWithdrawal(signedWithdrawal);

        // Consume the nonce in the vault
        _consumeSignedWithdrawal(signedWithdrawal);

        // Execute withdrawal and check loss protection
        _executeSignedWithdrawalInternal(signedWithdrawal);

        emit SignedWithdrawalExecuted(
            signedWithdrawal.user,
            signedWithdrawal.conditionId,
            msg.sender,
            signedWithdrawal.yesShares,
            signedWithdrawal.noShares,
            signedWithdrawal.nonce
        );
    }

    /// @notice Execute the withdrawal from a signed withdrawal request and enforce loss protection
    /// @param sw The signed withdrawal parameters
    function _executeSignedWithdrawalInternal(DataTypes.SignedWithdrawal calldata sw) internal {
        (bytes32[] memory cids, uint256[] memory yams, uint256[] memory nams, uint256 nonZero) =
            _getActionParams(sw.conditionId, sw.yesShares, sw.noShares);

        (uint256[] memory yesAssets, uint256[] memory noAssets) =
            _batchWithdraw(sw.user, cids, yams, nams, sw.yieldRecipient, nonZero, sw.referralCode, sw.wrapYieldToPolyUsd);

        // Check for loss protection: if tokenAssets < expected tokens, there was a loss
        if (sw.protectAgainstLoss && (yesAssets[0] < sw.minYesTokens || noAssets[0] < sw.minNoTokens)) {
            revert WithdrawalWouldResultInLoss();
        }
    }

    function initializeMarket(bytes32 conditionId, bytes32 questionId) public {
        DataTypes.PolymarketTokenInfo memory info = _initializePolymarketInfo(conditionId, questionId);
        _initializeMarket(conditionId, info.yesPositionId, info.noPositionId, info.negRisk);
    }

    // ============ UUPS ============

    /// @notice Authorize a UUPS upgrade to a new implementation
    /// @dev Restricted to TIMELOCKED_ROLE to enforce governance delay on upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(TIMELOCKED_ROLE) { }

    // ============ ERC-165 ============

    /// @notice Override to resolve diamond inheritance conflict
    /// @dev ERC1155Upgradeable (from AccountingMixin) and ERC1155Holder (from PolymarketMixin)
    ///      both inherit from ERC165. AccessControlUpgradeable also inherits from ERC165Upgradeable.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable, ERC1155Upgradeable, ERC1155Holder) returns (bool) {
        return AccessControlUpgradeable.supportsInterface(interfaceId) || ERC1155Upgradeable.supportsInterface(interfaceId)
            || ERC1155Holder.supportsInterface(interfaceId);
    }

    // ============ Fallback Delegation ============

    /// @notice Routes unrecognized function calls to the extension contract via DELEGATECALL
    /// @dev Admin functions (vault management, fees, emergency, pause, URI) live on the extension
    ///      to keep this contract under the 24kb bytecode limit.
    fallback() external {
        address ext = _getExtensionStorage().extension;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ============ Internal Helpers ============

    /// @notice Deduct protocol fee from yield and transfer net yield to recipient.
    /// @dev If `wrapYieldToPolyUsd` is true, the user's yield is wrapped to PolyUSD via the
    ///      Polymarket CollateralOnramp before transfer. If the onramp call itself reverts
    ///      (asset paused or otherwise unavailable), the function falls back to a plain
    ///      USDC.e transfer.
    /// @param user The withdrawing user (fallback recipient if recipient is address(0))
    /// @param recipient Address to receive yield (address(0) defaults to user)
    /// @param totalYield Total USDC yield before protocol fee deduction
    /// @param wrapYieldToPolyUsd If true, attempt to wrap the net yield to PolyUSD
    /// @return yield Net yield transferred to recipient (after protocol fee, in USDC.e units)
    /// @return protocolFee Protocol fee deducted and accumulated
    function _handleYieldPayout(address user, address recipient, uint256 totalYield, bool wrapYieldToPolyUsd)
        internal
        returns (uint256 yield, uint256 protocolFee)
    {
        address yieldRecipient = recipient == address(0) ? user : recipient;
        if (totalYield > 0) {
            protocolFee = (totalYield * getProtocolFeeBps()) / DataTypes.BPS_DENOM;
            _addProtocolFee(protocolFee);
            yield = totalYield - protocolFee; // User gets net yield
            _payoutYield(yieldRecipient, yield, wrapYieldToPolyUsd);
        }
    }

    /// @notice Send `yield` USDC.e to `yieldRecipient`, wrapping to PolyUSD first if requested.
    /// @dev On wrap failure (e.g. onramp paused), revokes the just-granted USDC.e allowance and
    ///      falls back to a direct USDC.e transfer so the withdrawal still completes.
    function _payoutYield(address yieldRecipient, uint256 yield, bool wrapYieldToPolyUsd) internal {
        if (yield == 0) return;

        if (wrapYieldToPolyUsd) {
            address onramp = _getPolymarketOnramp();
            if (onramp == address(0)) revert PolymarketOnrampNotSet();
            address asset = getUnderlyingUsdc();

            SafeERC20.forceApprove(IERC20(asset), onramp, yield);
            try ICollateralOnramp(onramp).wrap(asset, yieldRecipient, yield) {
                return;
            } catch {
                // Onramp unavailable (paused asset, upgraded contract, etc.). Revoke the
                // outstanding allowance and fall back to a plain USDC.e transfer.
                SafeERC20.forceApprove(IERC20(asset), onramp, 0);
            }
        }

        _transferUsdc(yieldRecipient, yield);
    }

    /// @notice Wrap single-market parameters into arrays for batch processing
    /// @param conditionId Single market condition ID
    /// @param yesAmount YES amount or shares
    /// @param noAmount NO amount or shares
    /// @return conditionIds Single-element array of condition ID
    /// @return yesAmounts Single-element array of YES amount
    /// @return noAmounts Single-element array of NO amount
    /// @return nonZeroLength Count of non-zero amounts (1 or 2)
    function _getActionParams(bytes32 conditionId, uint256 yesAmount, uint256 noAmount)
        internal
        pure
        returns (bytes32[] memory conditionIds, uint256[] memory yesAmounts, uint256[] memory noAmounts, uint256 nonZeroLength)
    {
        conditionIds = new bytes32[](1);
        yesAmounts = new uint256[](1);
        noAmounts = new uint256[](1);
        conditionIds[0] = conditionId;
        yesAmounts[0] = yesAmount;
        noAmounts[0] = noAmount;
        nonZeroLength = (yesAmount > 0 ? 1 : 0) + (noAmount > 0 ? 1 : 0);
    }

    /// @notice Prepare deposit mint shares for a single market
    /// @dev Used to hold common logic for deposit and batch deposit
    /// @param depositor address to mint shares to
    /// @param conditionId Polymarket condition ID
    /// @param yesAmount Amount of YES outcome tokens to deposit
    /// @param noAmount Amount of NO outcome tokens to deposit
    /// @param tokensPrePushed Whether or not the new tokens are already held by the vault or not
    /// @return yesShares Amount of YES shares minted
    /// @return noShares Amount of NO shares minted
    function _prepareDepositMintShares(
        address depositor,
        bytes32 conditionId,
        bytes32 questionId,
        uint256 yesAmount,
        uint256 noAmount,
        bool tokensPrePushed
    ) internal returns (uint256 yesShares, uint256 noShares) {
        // Initialize market on first deposit using the supplied questionId. For already-initialized
        // markets the questionId is unused (cached classification wins).
        if (!isMarketInitialized(conditionId)) {
            initializeMarket(conditionId, questionId);
        }

        // Update max potential
        (uint256 currentYes, uint256 currentNo) = getUnpairedTokens(conditionId);
        if (tokensPrePushed) {
            // Push path: tokens already in balance, reconstruct pre-transfer state
            _updateMaxPotential(currentYes - yesAmount, currentNo - noAmount, currentYes, currentNo);
        } else {
            // Pull path: tokens not yet here, current IS the old state
            _updateMaxPotential(currentYes, currentNo, currentYes + yesAmount, currentNo + noAmount);
        }

        // Update indexes first to get accurate share price (once for both sides)
        _updateYieldIndexes(conditionId);
        // Mint shares to depositor
        if (yesAmount > 0) {
            yesShares = _mintShares(depositor, conditionId, DataTypes.Side.YES, yesAmount);
        }
        if (noAmount > 0) {
            noShares = _mintShares(depositor, conditionId, DataTypes.Side.NO, noAmount);
        }
    }

    /// @notice Prepare withdrawal by burning shares and computing USDC needs for a single market
    /// @dev Updates indexes, burns shares, calculates split/yield amounts, and removes from pool
    /// @param user Address of the user withdrawing
    /// @param conditionId Market condition ID
    /// @param yesShares YES shares to burn (0 if none)
    /// @param noShares NO shares to burn (0 if none)
    /// @return result Struct containing token assets, split needs, and yield amounts
    function _prepareWithdrawBurnShares(address user, bytes32 conditionId, uint256 yesShares, uint256 noShares)
        internal
        returns (DataTypes.WithdrawBurnResult memory result)
    {
        // Update indexes first to get accurate values (once for both sides)
        _updateYieldIndexes(conditionId);
        // Burn shares: get token assets (loss-adjusted) and yield (USDC) separately
        {
            uint256 sideYield;
            if (yesShares > 0) {
                (result.yesAssets, sideYield) = _burnShares(user, conditionId, DataTypes.Side.YES, yesShares);
                result.yieldNeeded = sideYield;
            }
            if (noShares > 0) {
                (result.noAssets, sideYield) = _burnShares(user, conditionId, DataTypes.Side.NO, noShares);
                result.yieldNeeded += sideYield;
            }
        }

        // Calculate USDC needed to split into outcome tokens to cover any shortfall.
        // Splitting X USDC produces exactly X YES + X NO tokens, so we need max(shortfall)
        // to cover the larger side. The smaller side gets excess tokens that remain unpaired.
        (uint256 yesUnpaired, uint256 noUnpaired) = getUnpairedTokens(conditionId);
        uint256 yesShortfall = result.yesAssets > yesUnpaired ? result.yesAssets - yesUnpaired : 0;
        uint256 noShortfall = result.noAssets > noUnpaired ? result.noAssets - noUnpaired : 0;
        result.splitNeeded = yesShortfall > noShortfall ? yesShortfall : noShortfall;

        result.totalNeeded = result.splitNeeded + result.yieldNeeded;

        if (result.totalNeeded > 0) {
            _removeFromPool(conditionId, result.totalNeeded);
        }
    }

    // ============ Override - Reserved Usdc ============

    /// @notice Get Usdc reserved for protocol fees (should not be supplied to vaults)
    /// @dev Overrides YieldStrategyMixin to reserve accumulated protocol fees
    function _getReservedUsdc() internal view override returns (uint256) {
        return getAccumulatedProtocolFees();
    }

    // ============ Override - Current Total Pool Assets ============

    /// @notice Get current total USDC value for accurate view function calculations
    /// @dev Overrides AccountingMixin to use current vault values instead of snapshot
    function _getTotalPoolAssetsCurrent() internal view override returns (uint256) {
        return _getTotalUsdcValue();
    }

    // ============ Override - ERC-1155 Transfer Hook ============

    /// @notice Override ERC-1155 update hook to check pause controls for transfers, transfer accounting and total supply updates
    /// @dev Checks pausedAll and pausedTransfers before allowing transfers
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal virtual override {
        // Check transfer pause (only for actual transfers, not mints/burns)
        bool isTransfer = from != address(0) && to != address(0);
        if (isTransfer) {
            _checkTransfersNotPaused();
        }

        // Capture receiver balances before super._update() applies all changes at once.
        // `accumulated[i]` tracks the sum of values[j] for all j < i where ids[j] == ids[i],
        // built incrementally via forward propagation.
        uint256[] memory receiverSharesBefore;
        uint256[] memory accumulated;
        if (isTransfer) {
            receiverSharesBefore = new uint256[](ids.length);
            accumulated = new uint256[](ids.length);
            for (uint256 i = 0; i < ids.length; i++) {
                if (values[i] > 0) {
                    receiverSharesBefore[i] = balanceOf(to, ids[i]);
                }
            }
        }

        // Call parent which handles accounting
        super._update(from, to, ids, values);

        // Handle transfer accounting (not for mints/burns)
        if (isTransfer) {
            for (uint256 i = 0; i < ids.length; i++) {
                if (values[i] > 0) {
                    // receiverShares = pre-transfer balance + amounts already processed for
                    // this token ID in earlier iterations of this batch
                    _handleTransferAccounting(from, to, ids[i], values[i], receiverSharesBefore[i] + accumulated[i]);
                    // Propagate this entry's value forward to future same-ID entries
                    for (uint256 j = i + 1; j < ids.length; j++) {
                        if (ids[j] == ids[i]) accumulated[j] += values[i];
                    }
                }
            }
        }
    }
}
