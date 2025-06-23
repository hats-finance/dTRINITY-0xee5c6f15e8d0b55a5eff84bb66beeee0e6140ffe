// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDStableConversionAdapter} from "../interfaces/IDStableConversionAdapter.sol";
import {IStaticATokenLM} from "../../atoken_wrapper/interfaces/IStaticATokenLM.sol"; // Interface for StaticATokenLM
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title WrappedDLendConversionAdapter
 * @notice Adapter for converting between a dSTABLE asset (like dUSD) and a specific wrapped dLEND aToken
 *         (like wddUSD, implemented via StaticATokenLM). The wrapped dLEND token address must be provided at deployment.
 * @dev Implements the IDStableConversionAdapter interface.
 *      Interacts with a specific StaticATokenLM contract provided at deployment.
 */
contract WrappedDLendConversionAdapter is IDStableConversionAdapter {
    using SafeERC20 for IERC20;

    // --- Errors ---
    error ZeroAddress();
    error InvalidAmount();
    error TransferFailed();
    error InconsistentState(string message);

    // --- State ---
    address public immutable dStable; // The underlying dSTABLE asset (e.g., dUSD)
    IStaticATokenLM public immutable wrappedDLendToken; // The wrapped dLEND aToken (StaticATokenLM instance, e.g., wddUSD)
    address public immutable collateralVault; // The DStakeCollateralVault to deposit wrappedDLendToken into

    // --- Constructor ---
    /**
     * @param _dStable The address of the dSTABLE asset (e.g., dUSD)
     * @param _wrappedDLendToken The address of the wrapped dLEND token (StaticATokenLM, e.g., wddUSD)
     * @param _collateralVault The address of the DStakeCollateralVault
     */
    constructor(
        address _dStable,
        address _wrappedDLendToken,
        address _collateralVault
    ) {
        if (
            _dStable == address(0) ||
            _wrappedDLendToken == address(0) ||
            _collateralVault == address(0)
        ) {
            revert ZeroAddress();
        }
        dStable = _dStable;
        wrappedDLendToken = IStaticATokenLM(_wrappedDLendToken);
        collateralVault = _collateralVault;

        // Sanity check: Ensure the StaticATokenLM wrapper uses the correct underlying by casting to IERC4626
        if (IERC4626(_wrappedDLendToken).asset() != _dStable) {
            revert InconsistentState("StaticATokenLM underlying mismatch");
        }
    }

    // --- IDStableConversionAdapter Implementation ---

    /**
     * @inheritdoc IDStableConversionAdapter
     * @dev Converts dStable -> wrappedDLendToken by depositing into StaticATokenLM.
     *      The StaticATokenLM contract MUST be pre-approved to spend dStable held by this adapter.
     *      The StaticATokenLM contract mints the wrappedDLendToken directly to the collateralVault.
     */
    function convertToVaultAsset(
        uint256 dStableAmount
    )
        external
        override
        returns (address _vaultAsset, uint256 vaultAssetAmount)
    {
        if (dStableAmount == 0) {
            revert InvalidAmount();
        }

        // 1. Pull dStable from caller (Router)
        IERC20(dStable).safeTransferFrom(
            msg.sender,
            address(this),
            dStableAmount
        );

        // 2. Approve the StaticATokenLM wrapper to pull the dStable
        IERC20(dStable).forceApprove(address(wrappedDLendToken), dStableAmount);

        // 3. Deposit dStable into the StaticATokenLM wrapper, minting wrappedDLendToken to collateralVault
        (_vaultAsset, vaultAssetAmount) = previewConvertToVaultAsset(
            dStableAmount
        );
        vaultAssetAmount = IERC4626(address(wrappedDLendToken)).deposit(
            dStableAmount,
            collateralVault
        );

        return (address(wrappedDLendToken), vaultAssetAmount);
    }

    /**
     * @inheritdoc IDStableConversionAdapter
     * @dev Converts wrappedDLendToken -> dStable by withdrawing from StaticATokenLM.
     *      The StaticATokenLM contract sends the dStable directly to msg.sender.
     */
    function convertFromVaultAsset(
        uint256 vaultAssetAmount
    ) external override returns (uint256 dStableAmount) {
        if (vaultAssetAmount == 0) {
            revert InvalidAmount();
        }

        // 1. Preview the dStable amount to be received
        dStableAmount = previewConvertFromVaultAsset(vaultAssetAmount);
        if (dStableAmount == 0) {
            revert InvalidAmount();
        }

        // 2. Pull wrappedDLendToken (shares) from caller (Router)
        IERC20(address(wrappedDLendToken)).safeTransferFrom(
            msg.sender,
            address(this),
            vaultAssetAmount
        );

        // 3. Withdraw from StaticATokenLM, sending dStable to msg.sender
        uint256 withdrawn = IERC4626(address(wrappedDLendToken)).redeem(
            vaultAssetAmount,
            msg.sender,
            address(this)
        );
        if (withdrawn < dStableAmount) {
            revert InconsistentState("StaticATokenLM redeem mismatch");
        }
        return withdrawn;
    }

    /**
     * @inheritdoc IDStableConversionAdapter
     * @dev Uses StaticATokenLM's previewRedeem function to get the underlying value (dStable).
     */
    function assetValueInDStable(
        address _vaultAsset,
        uint256 vaultAssetAmount
    ) external view override returns (uint256 dStableValue) {
        require(
            _vaultAsset == address(wrappedDLendToken),
            "Incorrect vault asset address"
        );
        // previewRedeem takes shares (vaultAssetAmount) and returns assets (dStableValue)
        return
            IERC4626(address(wrappedDLendToken)).previewRedeem(
                vaultAssetAmount
            );
    }

    /**
     * @inheritdoc IDStableConversionAdapter
     */
    function vaultAsset() external view override returns (address) {
        return address(wrappedDLendToken);
    }

    /**
     * @inheritdoc IDStableConversionAdapter
     * @dev Preview the result of converting a given dSTABLE amount to wrappedDLendToken.
     */
    function previewConvertToVaultAsset(
        uint256 dStableAmount
    )
        public
        view
        override
        returns (address _vaultAsset, uint256 vaultAssetAmount)
    {
        _vaultAsset = address(wrappedDLendToken);
        vaultAssetAmount = IERC4626(address(wrappedDLendToken)).previewDeposit(
            dStableAmount
        );
    }

    /**
     * @inheritdoc IDStableConversionAdapter
     * @dev Preview the result of converting a given wrappedDLendToken amount to dSTABLE.
     */
    function previewConvertFromVaultAsset(
        uint256 vaultAssetAmount
    ) public view override returns (uint256 dStableAmount) {
        dStableAmount = IERC4626(address(wrappedDLendToken)).previewRedeem(
            vaultAssetAmount
        );
    }
}
