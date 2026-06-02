// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { AccessControlUpgradeable } from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import { ERC1155Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol';
import { ERC1155Holder } from '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';

import { DataTypes } from './types/DataTypes.sol';
import { IRobinStakingVaultErrors } from './interfaces/IRobinStakingVaultErrors.sol';
import { IRobinStakingVaultEvents } from './interfaces/IRobinStakingVaultEvents.sol';
import { AccountingMixin } from './mixins/AccountingMixin.sol';
import { PolymarketMixin } from './mixins/PolymarketMixin.sol';
import { YieldStrategyMixin } from './mixins/YieldStrategyMixin.sol';
import { SignaturesMixin } from './mixins/SignaturesMixin.sol';
import { PausableMixin } from './mixins/PausableMixin.sol';
import { PolymarketLib } from './libraries/PolymarketLib.sol';
import { StorageLib } from './libraries/StorageLib.sol';
import {
    DEFAULT_MANAGER_ROLE as _DEFAULT_MANAGER_ROLE,
    FEE_HARVESTER_ROLE as _FEE_HARVESTER_ROLE,
    TIMELOCKED_ROLE as _TIMELOCKED_ROLE,
    PAUSER_ROLE as _PAUSER_ROLE,
    OPERATOR_ROLE as _OPERATOR_ROLE
} from './types/Roles.sol';

/// @title RobinStakingVaultExtension
/// @notice Extension contract for admin functions, reached via fallback delegation from RobinStakingVault
/// @dev This contract is NOT proxied directly. It is DELEGATECALLed from the main vault implementation
///      via its fallback() function. Shares the same ERC-7201 namespaced storage as the main contract.
contract RobinStakingVaultExtension is
    AccessControlUpgradeable,
    AccountingMixin,
    PolymarketMixin,
    YieldStrategyMixin,
    SignaturesMixin,
    PausableMixin
{
    // ============ Roles (sourced from Roles.sol) ============

    bytes32 public constant DEFAULT_MANAGER_ROLE = _DEFAULT_MANAGER_ROLE;
    bytes32 public constant FEE_HARVESTER_ROLE = _FEE_HARVESTER_ROLE;
    bytes32 public constant TIMELOCKED_ROLE = _TIMELOCKED_ROLE;
    bytes32 public constant PAUSER_ROLE = _PAUSER_ROLE;
    bytes32 public constant OPERATOR_ROLE = _OPERATOR_ROLE;

    // ============ ERC-7201 Extension Storage ============

    function _getExtensionStorage() private pure returns (StorageLib.ExtensionStorage storage) {
        return StorageLib.getExtensionStorage();
    }

    // ============ Admin Functions - Extension Address ============

    /// @notice Set the extension contract address (for upgrades to the extension)
    /// @param newExtension Address of the new extension contract
    /// @dev Reverts if `newExtension` has no contract code. The vault's fallback DELEGATECALLs into
    ///      this address; pointing at an EOA or self-destructed contract would silently succeed
    ///      with empty returndata for every admin call, masking misconfigurations.
    function setExtensionAddress(address newExtension) external onlyRole(TIMELOCKED_ROLE) {
        StorageLib.ExtensionStorage storage $ = _getExtensionStorage();
        if (newExtension == address(0)) revert IRobinStakingVaultErrors.ZeroAddress();
        if (newExtension.code.length == 0) revert IRobinStakingVaultErrors.NotAContract(newExtension);
        address oldExtension = $.extension;
        $.extension = newExtension;
        emit IRobinStakingVaultEvents.ExtensionAddressUpdated(oldExtension, newExtension);
    }

    // ============ Admin Functions - Vault Management ============

    /// @dev Timelocked because adding a vault hands custody of USDC to a new ERC-4626 contract.
    function addVault(address vault, uint256 cap) external onlyRole(TIMELOCKED_ROLE) {
        _addVault(vault, cap);
    }

    function removeVault(address vault) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _removeVault(vault);
    }

    function setVaultCap(address vault, uint256 cap) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _setVaultCap(vault, cap);
    }

    function setVaultActive(address vault, bool active) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _setVaultActive(vault, active);
    }

    /// @dev vault order matters - vaults are processed in array order for deposits.
    ///      Place higher-APY or preferred vaults first.
    function swapVaultOrder(address vault1, address vault2) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _swapVaultOrder(vault1, vault2);
    }

    /// @notice Permissionless: pushes idle USDC.e to the admin-approved external vaults.
    /// @dev Anyone may trigger this; the destinations are admin-controlled and bounded by
    ///      per-vault caps. Net effect is always positive (idle funds start earning yield).
    function supplyIdleToVaults() external nonReentrant returns (uint256 remaining) {
        return _trySupplyIdleToVaults();
    }

    // ============ Admin Functions - Protocol Fees ============

    function setProtocolFeeBps(uint256 newFeeBps) external onlyRole(TIMELOCKED_ROLE) {
        _setProtocolFeeBps(newFeeBps);
    }

    /// @dev Withdraws from vaults if contract doesn't have enough Usdc
    function harvestProtocolFee(address to) external onlyRole(FEE_HARVESTER_ROLE) {
        if (to == address(0)) revert IRobinStakingVaultErrors.ZeroAddress();
        uint256 amount = _harvestProtocolFees();

        // Ensure we have enough Usdc (withdraw from vaults if needed)
        // after harvest, _getReserveUsdc() returns 0, so _getIdleUsdc() = full contract balance
        uint256 contractBalance = _getContractUsdcBalance();
        if (contractBalance < amount) {
            _withdrawFromVaults(amount - contractBalance);
        }

        _transferUsdc(to, amount);
        emit IRobinStakingVaultEvents.ProtocolFeeHarvested(to, amount);
    }

    // ============ Admin Functions - Twap ============

    /// @dev Bounded by `MAX_TWAP_GRACE_PERIOD` (240s); operational tuning.
    function setTwapGracePeriod(uint256 gracePeriod) external onlyRole(OPERATOR_ROLE) {
        _setTwapGracePeriod(gracePeriod);
    }

    // ============ Admin Functions - Polymarket Oracle List ============

    /// @notice Append a Polymarket oracle to the recognition list, paired with the collateral
    ///         that markets prepared by this oracle use on the CTF (USDC.e or PolyUSD).
    function addPolymarketOracle(address oracle, address collateral) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _addPolymarketOracle(oracle, collateral);
    }

    /// @notice Remove a Polymarket oracle from the recognition list
    function removePolymarketOracle(address oracle) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _removePolymarketOracle(oracle);
    }

    /// @notice Swap the priority of two Polymarket oracles (front of list is checked first)
    function swapPolymarketOracleOrder(address oracle1, address oracle2) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _swapPolymarketOracleOrder(oracle1, oracle2);
    }

    /// @notice Update the Polymarket CollateralOnramp address used to wrap USDC.e to PolyUSD
    /// @dev Behind the timelock because a malicious onramp could steal a withdrawal's yield (or
    ///      drain mid-split for PolyUSD-backed markets).
    function setPolymarketOnramp(address newOnramp) external onlyRole(TIMELOCKED_ROLE) {
        _setPolymarketOnramp(newOnramp);
    }

    /// @notice Read the configured Polymarket CollateralOnramp address (zero if unset)
    function getPolymarketOnramp() external view returns (address) {
        return _getPolymarketOnramp();
    }

    /// @notice Update the Polymarket CollateralOfframp address used to unwrap PolyUSD into USDC.e
    /// @dev Behind the timelock for the same reason as the onramp setter.
    function setPolymarketOfframp(address newOfframp) external onlyRole(TIMELOCKED_ROLE) {
        _setPolymarketOfframp(newOfframp);
    }

    /// @notice Read the configured Polymarket CollateralOfframp address (zero if unset)
    function getPolymarketOfframp() external view returns (address) {
        return _getPolymarketOfframp();
    }

    /// @notice View the current ordered list of Polymarket oracles (oracle/collateral pairs)
    /// @dev Lives only on the extension (not on PolymarketMixin) so the main vault stays under
    ///      the 24kb runtime-bytecode limit. Reached via the vault's `fallback` delegation.
    function getPolymarketOracles() external view returns (DataTypes.PolymarketOracle[] memory) {
        return PolymarketLib.getPolymarketOracles();
    }

    // ============ Admin Functions - Emergency ============
    // Operator-gated so incidents can be reacted to without timelock delay.

    function enableEmergencyMode() external onlyRole(OPERATOR_ROLE) {
        _enableEmergencyMode();
    }

    /// @notice Toggle the forward-looking internal-capacity guard on `_batchDeposit`.
    /// @dev Disabling this lets deposits proceed even when the projection of "all currently
    ///      unpaired tokens get paired" would exceed vault caps. External vault limits on funds would still be checked
    function setInternalCapacityCheckDisabled(bool disabled) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _setInternalCapacityCheckDisabled(disabled);
    }

    /// @notice Read whether the forward-looking internal-capacity guard is currently disabled
    function isInternalCapacityCheckDisabled() external view returns (bool) {
        return _isInternalCapacityCheckDisabled();
    }

    function withdrawMaxDuringEmergency(address vault) external onlyRole(OPERATOR_ROLE) {
        _withdrawMaxDuringEmergency(vault);
    }

    function disableEmergencyMode() external onlyRole(OPERATOR_ROLE) {
        _disableEmergencyMode();
    }

    function enableVaultEmergency(address vault) external onlyRole(OPERATOR_ROLE) {
        _enableVaultEmergency(vault);
    }

    function disableVaultEmergency(address vault) external onlyRole(OPERATOR_ROLE) {
        _disableVaultEmergency(vault);
    }

    // ============ Admin Functions - Pause ============

    function setPauseAll(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseAll(paused);
    }

    function setPauseDeposits(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseDeposits(paused);
    }

    function setPauseWithdrawals(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseWithdrawals(paused);
    }

    function setPauseTransfers(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseTransfers(paused);
    }

    // ============ Admin Functions - ERC-1155 Metadata ============

    function setUri(string calldata newuri) external onlyRole(DEFAULT_MANAGER_ROLE) {
        string memory oldUri = uri(0);
        _setURI(newuri);
        emit IRobinStakingVaultEvents.ERC1155MetadataUriChanged(oldUri, newuri);
    }

    // ============ User Functions ============

    /// @notice Invalidate a set of signed-withdrawal nonces for a user.
    function invalidateNonces(address user, DataTypes.SignatureType signatureType, uint256[] calldata nonces) external {
        if (!_verifySignerForUser(msg.sender, user, signatureType)) {
            revert InvalidWithdrawalSignature();
        }
        _invalidateNonces(user, nonces);
        emit NoncesInvalidated(user, nonces);
    }

    /// @notice Invalidate every nonce in a 256-nonce word for a user (mass-cancel).
    function invalidateNonceWord(address user, DataTypes.SignatureType signatureType, uint256 wordPos) external {
        if (!_verifySignerForUser(msg.sender, user, signatureType)) {
            revert InvalidWithdrawalSignature();
        }
        _invalidateNonceWord(user, wordPos);
        emit IRobinStakingVaultEvents.NonceWordInvalidated(user, wordPos);
    }

    // ============ View Functions - AccountingMixin Wrappers ============

    function getTwapOracle() public view returns (address) {
        return _getTwapOracle();
    }

    function getTokenInfo(uint256 tokenId) public view returns (bytes32 conditionId, DataTypes.Side side) {
        return _getTokenInfo(tokenId);
    }

    function totalSupply(uint256 tokenId) public view returns (uint256) {
        return _totalSupply(tokenId);
    }

    function getTotalSharesYes(bytes32 conditionId) public view returns (uint256) {
        return _getTotalSharesYes(conditionId);
    }

    function getTotalSharesNo(bytes32 conditionId) public view returns (uint256) {
        return _getTotalSharesNo(conditionId);
    }

    function getMarketState(bytes32 conditionId) public view returns (DataTypes.MarketState memory) {
        return _getMarketState(conditionId);
    }

    function getMarketAssets(bytes32 conditionId) public view returns (uint256 yesAssets, uint256 noAssets) {
        return _getMarketAssets(conditionId);
    }

    function getMarketIndexes(bytes32 conditionId, uint256 twapPriceYes) public view returns (DataTypes.IndexResult memory) {
        return _getMarketIndexes(conditionId, twapPriceYes);
    }

    function getUserShares(address user, bytes32 conditionId) public view returns (uint256 yesShares, uint256 noShares) {
        return _getUserShares(user, conditionId);
    }

    function getUserAssets(address user, bytes32 conditionId) public view returns (uint256 yesAssets, uint256 noAssets) {
        return _getUserAssets(user, conditionId);
    }

    function getUserYield(address user, bytes32 conditionId, uint256 twapPriceYes) public view returns (uint256 yesYield, uint256 noYield) {
        return _getUserYield(user, conditionId, twapPriceYes);
    }

    function getUserYieldSnapshots(address user, bytes32 conditionId) public view returns (uint128 yieldSnapshotYes, uint128 yieldSnapshotNo) {
        return _getUserYieldSnapshots(user, conditionId);
    }

    function previewDeposit(bytes32 conditionId, DataTypes.Side side, uint256 amount) public view returns (uint256 shares) {
        return _previewDeposit(conditionId, side, amount);
    }

    function getShareValue(bytes32 conditionId, DataTypes.Side side, uint256 shares) public view returns (uint256 assets) {
        return _getShareValue(conditionId, side, shares);
    }

    function previewWithdraw(address user, bytes32 conditionId, DataTypes.Side side, uint256 sharesToBurn, uint256 twapPriceYes)
        public
        view
        returns (uint256 tokenAssets, uint256 yieldUsdc)
    {
        return _previewWithdraw(user, conditionId, side, sharesToBurn, twapPriceYes);
    }

    function getTwapGracePeriod() public view returns (uint256) {
        return _getTwapGracePeriod();
    }

    // ============ View Functions - YieldStrategyMixin Wrappers ============

    function getExternalVaults()
        public
        view
        returns (
            address[] memory addresses,
            uint256[] memory balances,
            uint256[] memory caps,
            bool[] memory activeFlags,
            bool[] memory emergencyFlags
        )
    {
        return _getExternalVaults();
    }

    function isEmergencyMode() public view returns (bool) {
        return _isEmergencyMode();
    }

    function getTotalAvailableCapacity() public view returns (uint256) {
        return _getTotalAvailableCapacity();
    }

    function getAvailableCapacity(address vault) public view returns (uint256) {
        return _getAvailableCapacityByAddress(vault);
    }

    function getTotalUsdcValue() public view returns (uint256) {
        return _getTotalUsdcValue();
    }

    function getTotalAvailableInternalCapacity() public view returns (uint256) {
        return _getTotalAvailableInternalCapacity();
    }

    // ============ View Functions - PausableMixin Wrappers ============

    function isPausedAll() public view returns (bool) {
        return _isPausedAll();
    }

    function isPausedDeposits() public view returns (bool) {
        return _isPausedDeposits();
    }

    function isPausedWithdrawals() public view returns (bool) {
        return _isPausedWithdrawals();
    }

    function isTransfersPaused() public view returns (bool) {
        return _isTransfersPaused();
    }

    // ============ Signed Withdrawal Verification ============

    /// @notice Validate a signed withdrawal (expiry + nonce + signature + signer authorization).
    ///         Reverts on any failure; otherwise returns without side effects.
    function verifySignedWithdrawal(DataTypes.SignedWithdrawal calldata signedWithdrawal) external view {
        _verifySignedWithdrawal(signedWithdrawal);
    }

    // ============ Overrides ============

    /// @notice Get Usdc reserved for protocol fees (should not be supplied to vaults)
    function _getReservedUsdc() internal view override returns (uint256) {
        return getAccumulatedProtocolFees();
    }

    /// @notice Get current total USDC value for view function calculations
    function _getTotalPoolAssetsCurrent() internal view override returns (uint256) {
        return _getTotalUsdcValue();
    }

    /// @notice Override to resolve diamond inheritance conflict
    /// @dev `ERC1155Holder` (from PolymarketMixin) and `ERC1155Upgradeable` (from AccountingMixin)
    ///      both define `supportsInterface`, so the override list must mention both.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable, ERC1155Upgradeable, ERC1155Holder) returns (bool) {
        return AccessControlUpgradeable.supportsInterface(interfaceId) || ERC1155Upgradeable.supportsInterface(interfaceId)
            || ERC1155Holder.supportsInterface(interfaceId);
    }
}
