// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IDStakeRouter} from "./interfaces/IDStakeRouter.sol";
import {IDStableConversionAdapter} from "./interfaces/IDStableConversionAdapter.sol";
import {IDStakeCollateralVault} from "./DStakeCollateralVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title DStakeRouterDLend
 * @notice Orchestrates deposits, withdrawals, and asset exchanges for a DStakeToken vault.
 * @dev Interacts with the DStakeToken, DStakeCollateralVault, and various IDStableConversionAdapters.
 *      This contract is non-upgradeable but replaceable via DStakeToken governance.
 *      Relies on the associated DStakeToken for role management.
 */
contract DStakeRouterDLend is IDStakeRouter, AccessControl {
    using SafeERC20 for IERC20;

    // --- Errors ---
    error ZeroAddress();
    error AdapterNotFound(address vaultAsset);
    error ZeroPreviewWithdrawAmount(address vaultAsset);
    error InsufficientDStableFromAdapter(
        address vaultAsset,
        uint256 expected,
        uint256 actual
    );
    error VaultAssetManagedByDifferentAdapter(
        address vaultAsset,
        address existingAdapter
    );
    error ZeroInputDStableValue(address fromAsset, uint256 fromAmount);
    error AdapterAssetMismatch(
        address adapter,
        address expectedAsset,
        address actualAsset
    );
    error SlippageCheckFailed(
        address toAsset,
        uint256 calculatedAmount,
        uint256 minAmount
    );
    error InconsistentState(string message);

    // --- Roles ---
    bytes32 public constant DSTAKE_TOKEN_ROLE = keccak256("DSTAKE_TOKEN_ROLE");
    bytes32 public constant COLLATERAL_EXCHANGER_ROLE =
        keccak256("COLLATERAL_EXCHANGER_ROLE");

    // --- State ---
    address public immutable dStakeToken; // The DStakeToken this router serves
    IDStakeCollateralVault public immutable collateralVault; // The DStakeCollateralVault this router serves
    address public immutable dStable; // The underlying dSTABLE asset address

    // Governance-configurable risk parameters
    uint256 public dustTolerance = 1; // 1 wei default tolerance

    mapping(address => address) public vaultAssetToAdapter; // vaultAsset => adapterAddress
    address public defaultDepositVaultAsset; // Default strategy for deposits

    // Struct used to pack local variables in functions prone to "stack too deep" compiler errors
    struct ExchangeLocals {
        address fromAdapterAddress;
        address toAdapterAddress;
        IDStableConversionAdapter fromAdapter;
        IDStableConversionAdapter toAdapter;
        uint256 dStableValueIn;
        uint256 calculatedToVaultAssetAmount;
    }

    // --- Constructor ---
    constructor(address _dStakeToken, address _collateralVault) {
        if (_dStakeToken == address(0) || _collateralVault == address(0)) {
            revert ZeroAddress();
        }
        dStakeToken = _dStakeToken;
        collateralVault = IDStakeCollateralVault(_collateralVault);
        dStable = collateralVault.dStable(); // Fetch dStable address from vault
        if (dStable == address(0)) {
            revert ZeroAddress();
        }

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DSTAKE_TOKEN_ROLE, _dStakeToken);
    }

    // --- External Functions (IDStakeRouter Interface) ---

    /**
     * @inheritdoc IDStakeRouter
     */
    function deposit(
        uint256 dStableAmount,
        address receiver
    ) external override onlyRole(DSTAKE_TOKEN_ROLE) {
        address adapterAddress = vaultAssetToAdapter[defaultDepositVaultAsset];
        if (adapterAddress == address(0)) {
            revert AdapterNotFound(defaultDepositVaultAsset);
        }

        (
            address vaultAssetExpected,
            uint256 expectedShares
        ) = IDStableConversionAdapter(adapterAddress)
                .previewConvertToVaultAsset(dStableAmount);

        uint256 mintedShares = _executeDeposit(
            adapterAddress,
            vaultAssetExpected,
            dStableAmount
        );

        if (mintedShares < expectedShares) {
            revert SlippageCheckFailed(
                vaultAssetExpected,
                mintedShares,
                expectedShares
            );
        }

        emit Deposited(
            vaultAssetExpected,
            mintedShares,
            dStableAmount,
            receiver
        );
    }

    /**
     * @dev Performs the actual pull-approve-convert sequence and returns the number of shares
     *      minted to the collateral vault.
     * @param adapterAddress The adapter to use for conversion.
     * @param vaultAssetExpected The vault asset that the adapter should mint.
     * @param dStableAmount The amount of dStable being deposited.
     * @return mintedShares The number of vault asset shares minted.
     */
    function _executeDeposit(
        address adapterAddress,
        address vaultAssetExpected,
        uint256 dStableAmount
    ) private returns (uint256 mintedShares) {
        uint256 beforeBal = IERC20(vaultAssetExpected).balanceOf(
            address(collateralVault)
        );

        // Pull dStable from caller (DStakeToken)
        IERC20(dStable).safeTransferFrom(
            msg.sender,
            address(this),
            dStableAmount
        );

        // Approve adapter to spend dStable
        IERC20(dStable).forceApprove(adapterAddress, dStableAmount);

        // Convert dStable to vault asset (minted directly to collateral vault)
        (
            address vaultAssetActual,
            uint256 reportedShares
        ) = IDStableConversionAdapter(adapterAddress).convertToVaultAsset(
                dStableAmount
            );

        if (vaultAssetActual != vaultAssetExpected) {
            revert AdapterAssetMismatch(
                adapterAddress,
                vaultAssetExpected,
                vaultAssetActual
            );
        }

        mintedShares =
            IERC20(vaultAssetExpected).balanceOf(address(collateralVault)) -
            beforeBal;

        if (mintedShares != reportedShares) {
            revert InconsistentState("Adapter mis-reported shares");
        }
    }

    /**
     * @inheritdoc IDStakeRouter
     */
    function withdraw(
        uint256 dStableAmount,
        address receiver,
        address owner
    ) external override onlyRole(DSTAKE_TOKEN_ROLE) {
        address adapterAddress = vaultAssetToAdapter[defaultDepositVaultAsset];
        if (adapterAddress == address(0)) {
            revert AdapterNotFound(defaultDepositVaultAsset);
        }
        IDStableConversionAdapter adapter = IDStableConversionAdapter(
            adapterAddress
        );

        // 1. Determine vault asset and required amount
        address vaultAsset = adapter.vaultAsset();
        // Use previewConvertFromVaultAsset to get the required vaultAssetAmount for the target dStableAmount
        uint256 vaultAssetAmount = IERC4626(vaultAsset).previewWithdraw(
            dStableAmount
        );
        if (vaultAssetAmount == 0) revert ZeroPreviewWithdrawAmount(vaultAsset);

        // 2. Pull vaultAsset from collateral vault
        collateralVault.sendAsset(vaultAsset, vaultAssetAmount, address(this));

        // 3. Approve adapter (set required allowance using standard approve)
        IERC20(vaultAsset).forceApprove(adapterAddress, vaultAssetAmount);

        // 4. Call adapter to convert and send dStable to receiver
        // Temporarily transfer to this contract, then forward to receiver if needed
        uint256 receivedDStable = adapter.convertFromVaultAsset(
            vaultAssetAmount
        );

        // Sanity check: Ensure adapter returned at least the requested amount
        if (receivedDStable < dStableAmount) {
            revert InsufficientDStableFromAdapter(
                vaultAsset,
                dStableAmount,
                receivedDStable
            );
        }

        // 5. Transfer ONLY the requested amount to the user
        IERC20(dStable).safeTransfer(receiver, dStableAmount);

        // 6. If adapter over-delivered, immediately convert the surplus dStable
        //    back into vault-asset shares so the value is reflected in
        //    totalAssets() for all shareholders.
        uint256 surplus = receivedDStable - dStableAmount;
        if (surplus > 0) {
            // Give the adapter allowance to pull the surplus
            IERC20(dStable).forceApprove(adapterAddress, surplus);

            // Convert surplus dStable → vault asset (minted directly to the vault)
            (address mintedAsset, ) = adapter.convertToVaultAsset(surplus);

            // Sanity: adapter must mint the same asset we just redeemed from
            if (mintedAsset != vaultAsset) {
                revert AdapterAssetMismatch(
                    adapterAddress,
                    vaultAsset,
                    mintedAsset
                );
            }

            // Shares minted directly to collateralVault; surplus value now captured in accounting
        }

        emit Withdrawn(
            vaultAsset,
            vaultAssetAmount,
            dStableAmount,
            owner,
            receiver
        );
    }

    // --- External Functions (Exchange/Rebalance) ---

    /**
     * @notice Exchanges `fromVaultAssetAmount` of one vault asset for another via their adapters.
     * @dev Uses dSTABLE as the intermediary asset. Requires COLLATERAL_EXCHANGER_ROLE.
     * @param fromVaultAsset The address of the asset to sell.
     * @param toVaultAsset The address of the asset to buy.
     * @param fromVaultAssetAmount The amount of the `fromVaultAsset` to exchange.
     * @param minToVaultAssetAmount The minimum amount of `toVaultAsset` the solver is willing to accept.
     */
    function exchangeAssetsUsingAdapters(
        address fromVaultAsset,
        address toVaultAsset,
        uint256 fromVaultAssetAmount,
        uint256 minToVaultAssetAmount
    ) external onlyRole(COLLATERAL_EXCHANGER_ROLE) {
        address fromAdapterAddress = vaultAssetToAdapter[fromVaultAsset];
        address toAdapterAddress = vaultAssetToAdapter[toVaultAsset];
        if (fromAdapterAddress == address(0))
            revert AdapterNotFound(fromVaultAsset);
        if (toAdapterAddress == address(0))
            revert AdapterNotFound(toVaultAsset);

        IDStableConversionAdapter fromAdapter = IDStableConversionAdapter(
            fromAdapterAddress
        );
        IDStableConversionAdapter toAdapter = IDStableConversionAdapter(
            toAdapterAddress
        );

        // 1. Get assets and calculate equivalent dStable amount
        uint256 dStableAmountEquivalent = fromAdapter
            .previewConvertFromVaultAsset(fromVaultAssetAmount);

        // 2. Pull fromVaultAsset from collateral vault
        collateralVault.sendAsset(
            fromVaultAsset,
            fromVaultAssetAmount,
            address(this)
        );

        // 3. Approve fromAdapter & Convert fromVaultAsset -> dStable (sent to this router)
        IERC20(fromVaultAsset).forceApprove(
            fromAdapterAddress,
            fromVaultAssetAmount
        );
        uint256 receivedDStable = fromAdapter.convertFromVaultAsset(
            fromVaultAssetAmount
        );

        // 4. Approve toAdapter & Convert dStable -> toVaultAsset (sent to collateralVault)
        IERC20(dStable).forceApprove(toAdapterAddress, receivedDStable);
        (
            address actualToVaultAsset,
            uint256 resultingToVaultAssetAmount
        ) = toAdapter.convertToVaultAsset(receivedDStable);
        require(actualToVaultAsset == toVaultAsset, "Adapter asset mismatch");
        // Slippage control: ensure output meets minimum requirement
        if (resultingToVaultAssetAmount < minToVaultAssetAmount) {
            revert SlippageCheckFailed(
                toVaultAsset,
                resultingToVaultAssetAmount,
                minToVaultAssetAmount
            );
        }

        // --- Underlying value parity check ---
        uint256 resultingDStableEquivalent = toAdapter
            .previewConvertFromVaultAsset(resultingToVaultAssetAmount);

        // Rely on Solidity 0.8 checked arithmetic: if `dustTolerance` is greater than
        // `dStableAmountEquivalent`, the subtraction will underflow and the transaction
        // will revert automatically. This saves gas compared to a ternary guard.
        uint256 minRequiredDStable = dStableAmountEquivalent - dustTolerance;

        if (resultingDStableEquivalent < minRequiredDStable) {
            revert SlippageCheckFailed(
                dStable,
                resultingDStableEquivalent,
                minRequiredDStable
            );
        }

        emit Exchanged(
            fromVaultAsset,
            toVaultAsset,
            fromVaultAssetAmount,
            resultingToVaultAssetAmount,
            dStableAmountEquivalent,
            msg.sender
        );
    }

    /**
     * @notice Exchanges assets between the collateral vault and an external solver.
     * @dev Pulls `fromVaultAsset` from the solver (`msg.sender`) and sends `toVaultAsset` from the vault to the solver.
     *      Requires COLLATERAL_EXCHANGER_ROLE.
     * @param fromVaultAsset The address of the asset the solver is providing.
     * @param toVaultAsset The address of the asset the solver will receive from the vault.
     * @param fromVaultAssetAmount The amount of `fromVaultAsset` provided by the solver.
     * @param minToVaultAssetAmount The minimum amount of `toVaultAsset` the solver is willing to accept.
     */
    function exchangeAssets(
        address fromVaultAsset,
        address toVaultAsset,
        uint256 fromVaultAssetAmount,
        uint256 minToVaultAssetAmount
    ) external onlyRole(COLLATERAL_EXCHANGER_ROLE) {
        if (fromVaultAssetAmount == 0) {
            revert InconsistentState("Input amount cannot be zero");
        }
        if (fromVaultAsset == address(0) || toVaultAsset == address(0)) {
            revert ZeroAddress();
        }

        ExchangeLocals memory locals;

        // Resolve adapters
        locals.fromAdapterAddress = vaultAssetToAdapter[fromVaultAsset];
        locals.toAdapterAddress = vaultAssetToAdapter[toVaultAsset];

        if (locals.fromAdapterAddress == address(0))
            revert AdapterNotFound(fromVaultAsset);
        if (locals.toAdapterAddress == address(0))
            revert AdapterNotFound(toVaultAsset);

        locals.fromAdapter = IDStableConversionAdapter(
            locals.fromAdapterAddress
        );
        locals.toAdapter = IDStableConversionAdapter(locals.toAdapterAddress);

        // Calculate dStable received for the input asset
        locals.dStableValueIn = locals.fromAdapter.previewConvertFromVaultAsset(
            fromVaultAssetAmount
        );
        if (locals.dStableValueIn == 0) {
            revert ZeroInputDStableValue(fromVaultAsset, fromVaultAssetAmount);
        }

        // Calculate expected output vault asset amount
        (address expectedToAsset, uint256 tmpToAmount) = locals
            .toAdapter
            .previewConvertToVaultAsset(locals.dStableValueIn);

        if (expectedToAsset != toVaultAsset) {
            revert AdapterAssetMismatch(
                locals.toAdapterAddress,
                toVaultAsset,
                expectedToAsset
            );
        }

        locals.calculatedToVaultAssetAmount = tmpToAmount;

        // Slippage check
        if (locals.calculatedToVaultAssetAmount < minToVaultAssetAmount) {
            revert SlippageCheckFailed(
                toVaultAsset,
                locals.calculatedToVaultAssetAmount,
                minToVaultAssetAmount
            );
        }

        // --- Asset movements ---

        // 1. Pull `fromVaultAsset` from solver to this contract
        IERC20(fromVaultAsset).safeTransferFrom(
            msg.sender,
            address(this),
            fromVaultAssetAmount
        );

        // 2. Transfer the asset into the collateral vault
        IERC20(fromVaultAsset).safeTransfer(
            address(collateralVault),
            fromVaultAssetAmount
        );

        // 3. Send the calculated amount of `toVaultAsset` to the solver
        collateralVault.sendAsset(
            toVaultAsset,
            locals.calculatedToVaultAssetAmount,
            msg.sender
        );

        emit Exchanged(
            fromVaultAsset,
            toVaultAsset,
            fromVaultAssetAmount,
            locals.calculatedToVaultAssetAmount,
            locals.dStableValueIn,
            msg.sender
        );
    }

    // --- External Functions (Governance - Managed by Admin) ---

    /**
     * @notice Adds or updates a conversion adapter for a given vault asset.
     * @dev Only callable by an address with DEFAULT_ADMIN_ROLE.
     * @param vaultAsset The address of the vault asset.
     * @param adapterAddress The address of the new adapter contract.
     */
    function addAdapter(
        address vaultAsset,
        address adapterAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapterAddress == address(0) || vaultAsset == address(0)) {
            revert ZeroAddress();
        }
        address adapterVaultAsset = IDStableConversionAdapter(adapterAddress)
            .vaultAsset();
        if (adapterVaultAsset != vaultAsset)
            revert AdapterAssetMismatch(
                adapterAddress,
                vaultAsset,
                adapterVaultAsset
            );
        if (
            vaultAssetToAdapter[vaultAsset] != address(0) &&
            vaultAssetToAdapter[vaultAsset] != adapterAddress
        ) {
            revert VaultAssetManagedByDifferentAdapter(
                vaultAsset,
                vaultAssetToAdapter[vaultAsset]
            );
        }
        vaultAssetToAdapter[vaultAsset] = adapterAddress;

        // Inform the collateral vault of the new supported asset list (no-op if already added)
        try collateralVault.addSupportedAsset(vaultAsset) {} catch {}

        emit AdapterSet(vaultAsset, adapterAddress);
    }

    /**
     * @notice Removes a conversion adapter for a given vault asset.
     * @dev Only callable by an address with DEFAULT_ADMIN_ROLE.
     * @dev Does not automatically migrate funds. Ensure assets managed by this adapter are zero
     *      in the collateral vault or migrated via exchangeAssets before calling.
     * @param vaultAsset The address of the vault asset to remove.
     */
    function removeAdapter(
        address vaultAsset
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address adapterAddress = vaultAssetToAdapter[vaultAsset];
        if (adapterAddress == address(0)) {
            revert AdapterNotFound(vaultAsset);
        }
        delete vaultAssetToAdapter[vaultAsset];

        // Inform the collateral vault to remove supported asset (ignore if not present)
        try collateralVault.removeSupportedAsset(vaultAsset) {} catch {}

        emit AdapterRemoved(vaultAsset, adapterAddress);
    }

    /**
     * @notice Sets the default vault asset to use for new deposits.
     * @dev Only callable by an address with DEFAULT_ADMIN_ROLE.
     * @param vaultAsset The address of the vault asset to set as default.
     */
    function setDefaultDepositVaultAsset(
        address vaultAsset
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vaultAssetToAdapter[vaultAsset] == address(0)) {
            revert AdapterNotFound(vaultAsset);
        }
        defaultDepositVaultAsset = vaultAsset;
        emit DefaultDepositVaultAssetSet(vaultAsset);
    }

    // --- Events ---
    event Deposited(
        address indexed vaultAsset,
        uint256 vaultAssetAmount,
        uint256 dStableAmount,
        address receiver
    );
    event Withdrawn(
        address indexed vaultAsset,
        uint256 vaultAssetAmount,
        uint256 dStableAmount,
        address owner,
        address receiver
    );
    event Exchanged(
        address indexed fromAsset,
        address indexed toAsset,
        uint256 fromAssetAmount,
        uint256 toAssetAmount,
        uint256 dStableAmountEquivalent,
        address indexed exchanger
    );
    event AdapterSet(address indexed vaultAsset, address adapterAddress);
    event AdapterRemoved(address indexed vaultAsset, address adapterAddress);
    event DefaultDepositVaultAssetSet(address indexed vaultAsset);
    event DustToleranceSet(uint256 newDustTolerance);

    // --- Governance setters ---

    /**
     * @notice Updates the `dustTolerance` used for value-parity checks.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     * @param _dustTolerance The new tolerance value in wei of dStable.
     */
    function setDustTolerance(
        uint256 _dustTolerance
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        dustTolerance = _dustTolerance;
        emit DustToleranceSet(_dustTolerance);
    }
}
