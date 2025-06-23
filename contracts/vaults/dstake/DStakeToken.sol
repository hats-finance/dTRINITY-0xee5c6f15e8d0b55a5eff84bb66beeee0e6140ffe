// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDStakeCollateralVault} from "./interfaces/IDStakeCollateralVault.sol";
import {IDStakeRouter} from "./interfaces/IDStakeRouter.sol";
import {BasisPointConstants} from "../../common/BasisPointConstants.sol";
import {SupportsWithdrawalFee} from "../../common/SupportsWithdrawalFee.sol";

/**
 * @title DStakeToken
 * @dev ERC4626-compliant token representing shares in the DStakeCollateralVault.
 */
contract DStakeToken is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    SupportsWithdrawalFee
{
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // --- Errors ---
    error ZeroAddress();

    // --- State ---
    IDStakeCollateralVault public collateralVault;
    IDStakeRouter public router;

    uint256 public constant MAX_WITHDRAWAL_FEE_BPS =
        BasisPointConstants.ONE_PERCENT_BPS;

    // --- Initializer ---
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _dStable,
        string memory _name,
        string memory _symbol,
        address _initialAdmin,
        address _initialFeeManager
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(_dStable);
        __AccessControl_init();
        _initializeWithdrawalFee(0);

        if (
            address(_dStable) == address(0) ||
            _initialAdmin == address(0) ||
            _initialFeeManager == address(0)
        ) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(FEE_MANAGER_ROLE, _initialFeeManager);
    }

    // --- SupportsWithdrawalFee Implementation ---
    function _maxWithdrawalFeeBps()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return MAX_WITHDRAWAL_FEE_BPS;
    }

    /**
     * @notice Public getter for the current withdrawal fee in basis points.
     */
    function withdrawalFeeBps() public view returns (uint256) {
        return getWithdrawalFeeBps(); // Uses getter from SupportsWithdrawalFee
    }

    /**
     * @notice Public getter for the maximum withdrawal fee in basis points.
     */
    function maxWithdrawalFeeBps() public view returns (uint256) {
        return MAX_WITHDRAWAL_FEE_BPS;
    }

    // --- ERC4626 Overrides ---

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Delegates call to the collateralVault to get the total value of managed assets.
     */
    function totalAssets() public view virtual override returns (uint256) {
        if (address(collateralVault) == address(0)) {
            return 0;
        }
        return collateralVault.totalValueInDStable();
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Pulls dSTABLE asset from depositor, then delegates the core deposit logic
     *      (converting dSTABLE to vault assets) to the router.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        if (
            address(router) == address(0) ||
            address(collateralVault) == address(0)
        ) {
            revert ZeroAddress(); // Router or Vault not set
        }

        // Pull assets from caller
        super._deposit(caller, receiver, assets, shares); // This handles the ERC20 transfer

        // Approve router to spend the received assets (necessary because super._deposit transfers to this contract)
        IERC20(asset()).forceApprove(address(router), assets);

        // Delegate conversion and vault update logic to router
        router.deposit(assets, receiver);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Override to handle withdrawals with fees correctly.
     *      The `assets` parameter is the net amount of assets the user wants to receive.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256 shares) {
        shares = previewWithdraw(assets); // Calculate shares needed for net amount
        uint256 grossAssets = convertToAssets(shares); // Calculate gross amount from shares

        require(
            grossAssets <= maxWithdraw(owner),
            "ERC4626: withdraw more than max"
        );

        _withdraw(_msgSender(), receiver, owner, grossAssets, shares); // Pass GROSS amount to _withdraw
        return shares;
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Override to ensure the withdrawal fee is deducted only once.
     *      The `shares` parameter is converted to its equivalent gross asset value, then the
     *      internal _withdraw handles fee calculation. The returned value is the net assets
     *      actually received by the `receiver`, matching previewRedeem().
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256 assets) {
        uint256 grossAssets = convertToAssets(shares); // shares → gross assets before fee

        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");

        // Perform withdrawal using gross assets so that _withdraw computes the correct fee once
        _withdraw(_msgSender(), receiver, owner, grossAssets, shares);

        // Net assets the user effectively receives
        assets = _getNetAmountAfterFee(grossAssets);
        return assets;
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Calculates withdrawal fee, then delegates the core withdrawal logic
     *      (converting vault assets back to dSTABLE) to the router.
     *      The `assets` parameter is now the gross amount that needs to be withdrawn from the vault.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets, // This is now the GROSS amount
        uint256 shares
    ) internal virtual override {
        if (
            address(router) == address(0) ||
            address(collateralVault) == address(0)
        ) {
            revert ZeroAddress(); // Router or Vault not set
        }

        uint256 fee = _calculateWithdrawalFee(assets); // Calculate fee on GROSS amount
        uint256 amountToSend = assets - fee; // Send NET amount to user

        // Burn shares from owner
        _burn(owner, shares);

        // Delegate conversion and vault update logic to router
        // Router is responsible for ensuring `amountToSend` of dSTABLE reaches the `receiver`.
        router.withdraw(amountToSend, receiver, owner);

        // Emit ERC4626 Withdraw event
        emit Withdraw(caller, receiver, owner, assets, shares);

        // Optional: Emit fee event
        if (fee > 0) {
            emit WithdrawalFee(owner, receiver, fee);
        }
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Preview withdraw including withdrawal fee.
     */
    function previewWithdraw(
        uint256 assets
    ) public view virtual override returns (uint256) {
        uint256 grossAssetsRequired = _getGrossAmountRequiredForNet(assets);
        return super.previewWithdraw(grossAssetsRequired);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Preview redeem including withdrawal fee.
     */
    function previewRedeem(
        uint256 shares
    ) public view virtual override returns (uint256) {
        uint256 grossAssets = super.previewRedeem(shares);
        return _getNetAmountAfterFee(grossAssets);
    }

    // --- Governance Functions ---

    /**
     * @notice Sets the address of the DStakeRouter contract.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     * @param _router The address of the new router contract.
     */
    function setRouter(address _router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_router == address(0)) {
            revert ZeroAddress();
        }
        router = IDStakeRouter(_router);
        emit RouterSet(_router);
    }

    /**
     * @notice Sets the address of the DStakeCollateralVault contract.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     * @param _collateralVault The address of the new collateral vault contract.
     */
    function setCollateralVault(
        address _collateralVault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_collateralVault == address(0)) {
            revert ZeroAddress();
        }
        collateralVault = IDStakeCollateralVault(_collateralVault);
        emit CollateralVaultSet(_collateralVault);
    }

    /**
     * @notice Sets the withdrawal fee in basis points.
     * @dev Requires FEE_MANAGER_ROLE.
     * @param _feeBps The new withdrawal fee (e.g., 10 = 0.1%).
     */
    function setWithdrawalFee(
        uint256 _feeBps
    ) external onlyRole(FEE_MANAGER_ROLE) {
        _setWithdrawalFee(_feeBps);
    }

    // --- Events ---
    event RouterSet(address indexed router);
    event CollateralVaultSet(address indexed collateralVault);
}
