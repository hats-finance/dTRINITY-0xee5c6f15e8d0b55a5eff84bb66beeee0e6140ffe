// SPDX-License-Identifier: MIT
/* ———————————————————————————————————————————————————————————————————————————————— *
 *    _____     ______   ______     __     __   __     __     ______   __  __       *
 *   /\  __-.  /\__  _\ /\  == \   /\ \   /\ "-.\ \   /\ \   /\__  _\ /\ \_\ \      *
 *   \ \ \/\ \ \/_/\ \/ \ \  __<   \ \ \  \ \ \-.  \  \ \ \  \/_/\ \/ \ \____ \     *
 *    \ \____-    \ \_\  \ \_\ \_\  \ \_\  \ \_\\"\_\  \ \_\    \ \_\  \/\_____\    *
 *     \/____/     \/_/   \/_/ /_/   \/_/   \/_/ \/_/   \/_/     \/_/   \/_____/    *
 *                                                                                  *
 * ————————————————————————————————— dtrinity.org ————————————————————————————————— *
 *                                                                                  *
 *                                         ▲                                        *
 *                                        ▲ ▲                                       *
 *                                                                                  *
 * ———————————————————————————————————————————————————————————————————————————————— *
 * dTRINITY Protocol: https://github.com/dtrinity                                   *
 * ———————————————————————————————————————————————————————————————————————————————— */

pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BasisPointConstants} from "contracts/common/BasisPointConstants.sol";
import {ERC4626, ERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Erc20Helper} from "contracts/common/Erc20Helper.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RescuableVault} from "contracts/common/RescuableVault.sol";

/**
 * @title DLoopCoreBase
 * @dev A contract that executes leveraged operations on a lending pool using a collateral token and a debt token
 *      - A leveraged position is created by supplying a collateral token to the lending pool and borrowing a debt token
 *      - The leverage ratio will be changed if the collateral and debt values are changed (due to price changes)
 *      - The leverage can be increased by supplying more collateral token or decreasing the debt token
 *      - The leverage can be decreased by withdrawing collateral token or increasing the debt token
 *      - In order to keep the vault balanced, user can call increaseLeverage or decreaseLeverage to increase or decrease the leverage
 *        when it is away from the target leverage
 *      - There is a subsidy for the caller when increasing the leverage.
 */
abstract contract DLoopCoreBase is
    ERC4626,
    Ownable,
    ReentrancyGuard,
    RescuableVault
{
    using SafeERC20 for ERC20;

    /* Core state */

    uint32 public lowerBoundTargetLeverageBps;
    uint32 public upperBoundTargetLeverageBps;
    uint256 public maxSubsidyBps;

    /* Constants */

    uint32 public immutable targetLeverageBps; // ie. 30000 = 300% in basis points, means 3x leverage
    ERC20 public immutable collateralToken;
    ERC20 public immutable debtToken;

    uint256 public constant BALANCE_DIFF_TOLERANCE = 1;

    /* Errors */

    error TooImbalanced(
        uint256 currentLeverageBps,
        uint256 lowerBoundTargetLeverageBps,
        uint256 upperBoundTargetLeverageBps
    );
    error InsufficientAllowanceOfDebtAssetToRepay(
        address owner,
        address spender,
        address debtAsset,
        uint256 requiredAllowance
    );
    error DepositInsufficientToSupply(
        uint256 currentBalance,
        uint256 newTotalAssets
    );
    error CollateralLessThanDebt(
        uint256 totalCollateralBase,
        uint256 totalDebtBase
    );
    error InsufficientShareBalanceToRedeem(
        address owner,
        uint256 sharesToRedeem,
        uint256 shareBalance
    );
    error WithdrawableIsLessThanRequired(
        address token,
        uint256 assetToRemoveFromLending,
        uint256 withdrawableAmount
    );
    error DecreaseLeverageOutOfRange(
        uint256 newLeverageBps,
        uint256 targetLeverageBps, // lower bound
        uint256 currentLeverageBps // upper bound
    );
    error IncreaseLeverageOutOfRange(
        uint256 newLeverageBps,
        uint256 targetLeverageBps, // upper bound
        uint256 currentLeverageBps // lower bound
    );
    error TokenBalanceNotDecreasedAfterRepay(
        address token,
        uint256 tokenBalanceBefore,
        uint256 tokenBalanceAfter,
        uint256 expectedTokenBalance
    );
    error UnexpectedRepayAmountToPool(
        address token,
        uint256 tokenBalanceBefore,
        uint256 tokenBalanceAfter,
        uint256 expectedTokenBalance
    );
    error TokenBalanceNotDecreasedAfterSupply(
        address token,
        uint256 tokenBalanceBefore,
        uint256 tokenBalanceAfter,
        uint256 expectedTokenBalance
    );
    error UnexpectedSupplyAmountToPool(
        address token,
        uint256 tokenBalanceBefore,
        uint256 tokenBalanceAfter,
        uint256 expectedTokenBalance
    );
    error TokenBalanceNotIncreasedAfterBorrow(
        address token,
        uint256 tokenBalanceBefore,
        uint256 tokenBalanceAfter,
        uint256 expectedTokenBalance
    );
    error UnexpectedBorrowAmountFromPool(
        address token,
        uint256 borrowedAmountBefore,
        uint256 borrowedAmountAfter,
        uint256 expectedBorrowedAmount
    );
    error TokenBalanceNotIncreasedAfterWithdraw(
        address token,
        uint256 tokenBalanceBefore,
        uint256 tokenBalanceAfter,
        uint256 expectedTokenBalance
    );
    error UnexpectedWithdrawAmountFromPool(
        address token,
        uint256 withdrawableAmountBefore,
        uint256 withdrawableAmountAfter,
        uint256 expectedWithdrawableAmount
    );
    error InvalidLeverageBounds(
        uint256 lowerBound,
        uint256 targetLeverage,
        uint256 upperBound
    );
    error AssetPriceIsZero(address asset);
    error LeverageExceedsTarget(
        uint256 currentLeverageBps,
        uint256 targetLeverageBps
    );
    error LeverageBelowTarget(
        uint256 currentLeverageBps,
        uint256 targetLeverageBps
    );
    error RebalanceReceiveLessThanMinAmount(
        string operation,
        uint256 receivedAmount,
        uint256 minReceivedAmount
    );
    error InvalidLeverage(uint256 leverageBps);
    error TotalCollateralBaseIsZero();
    error TotalCollateralBaseIsLessThanTotalDebtBase(
        uint256 totalCollateralBase,
        uint256 totalDebtBase
    );

    /**
     * @dev Constructor for the DLoopCore contract
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _collateralToken Address of the collateral token
     * @param _debtToken Address of the debt token
     * @param _targetLeverageBps Target leverage in basis points
     * @param _lowerBoundTargetLeverageBps Lower bound of target leverage in basis points
     * @param _upperBoundTargetLeverageBps Upper bound of target leverage in basis points
     * @param _maxSubsidyBps Maximum subsidy in basis points
     */
    constructor(
        string memory _name,
        string memory _symbol,
        ERC20 _collateralToken,
        ERC20 _debtToken,
        uint32 _targetLeverageBps,
        uint32 _lowerBoundTargetLeverageBps,
        uint32 _upperBoundTargetLeverageBps,
        uint256 _maxSubsidyBps
    ) ERC20(_name, _symbol) ERC4626(_collateralToken) Ownable(msg.sender) {
        debtToken = _debtToken;
        collateralToken = _collateralToken;

        if (_targetLeverageBps < BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) {
            revert("Target leverage must be at least 100% in basis points");
        }

        if (
            _lowerBoundTargetLeverageBps >= _targetLeverageBps ||
            _targetLeverageBps >= _upperBoundTargetLeverageBps
        ) {
            revert InvalidLeverageBounds(
                _lowerBoundTargetLeverageBps,
                _targetLeverageBps,
                _upperBoundTargetLeverageBps
            );
        }

        // Make sure collateral token is ERC-20
        if (!Erc20Helper.isERC20(address(_collateralToken))) {
            revert("Collateral token must be an ERC-20");
        }

        // Make sure debt token is ERC-20
        if (!Erc20Helper.isERC20(address(_debtToken))) {
            revert("Debt token must be an ERC-20");
        }

        targetLeverageBps = _targetLeverageBps;
        lowerBoundTargetLeverageBps = _lowerBoundTargetLeverageBps;
        upperBoundTargetLeverageBps = _upperBoundTargetLeverageBps;
        maxSubsidyBps = _maxSubsidyBps;
    }

    /* Virtual Methods - Required to be implemented by derived contracts */

    /**
     * @dev Gets the total collateral and debt of a user in base currency
     * @param user Address of the user
     * @return totalCollateralBase Total collateral in base currency
     * @return totalDebtBase Total debt in base currency
     */
    function getTotalCollateralAndDebtOfUserInBase(
        address user
    )
        public
        view
        virtual
        returns (uint256 totalCollateralBase, uint256 totalDebtBase);

    /**
     * @dev Gets the additional rescue tokens
     *      - As the getRestrictedRescueTokens function is very critical and we do not
     *        want to override it in the derived contracts, we use this function to
     *        get the additional rescue tokens
     * @return address[] Additional rescue tokens
     */
    function _getAdditionalRescueTokensImplementation()
        internal
        view
        virtual
        returns (address[] memory);

    /**
     * @dev Gets the asset price from the oracle
     * @param asset Address of the asset
     * @return uint256 Price of the asset
     */
    function _getAssetPriceFromOracleImplementation(
        address asset
    ) internal view virtual returns (uint256);

    /**
     * @dev Supply tokens to the lending pool
     * @param token Address of the token
     * @param amount Amount of tokens to supply
     * @param onBehalfOf Address to supply on behalf of
     */
    function _supplyToPoolImplementation(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal virtual;

    /**
     * @dev Borrow tokens from the lending pool
     * @param token Address of the token
     * @param amount Amount of tokens to borrow
     * @param onBehalfOf Address to borrow on behalf of
     */
    function _borrowFromPoolImplementation(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal virtual;

    /**
     * @dev Repay debt to the lending pool
     * @param token Address of the token
     * @param amount Amount of tokens to repay
     * @param onBehalfOf Address to repay on behalf of
     */
    function _repayDebtToPoolImplementation(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal virtual;

    /**
     * @dev Withdraw tokens from the lending pool
     * @param token Address of the token
     * @param amount Amount of tokens to withdraw
     * @param onBehalfOf Address to withdraw on behalf of
     */
    function _withdrawFromPoolImplementation(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal virtual;

    /* Wrapper Functions */

    /**
     * @dev Supply tokens to the lending pool, and make sure the output is as expected
     * @param token Address of the token
     * @param amount Amount of tokens to supply
     * @param onBehalfOf Address to supply on behalf of
     */
    function _supplyToPool(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal {
        // At this step, we assume that the funds from the depositor are already in the vault

        uint256 tokenBalanceBeforeSupply = ERC20(token).balanceOf(onBehalfOf);

        _supplyToPoolImplementation(token, amount, onBehalfOf);

        uint256 tokenBalanceAfterSupply = ERC20(token).balanceOf(onBehalfOf);
        if (tokenBalanceAfterSupply >= tokenBalanceBeforeSupply) {
            revert TokenBalanceNotDecreasedAfterSupply(
                token,
                tokenBalanceBeforeSupply,
                tokenBalanceAfterSupply,
                amount
            );
        }

        // Now, as balance before must be greater than balance after, we can just check if the difference is the expected amount
        if (tokenBalanceBeforeSupply - tokenBalanceAfterSupply != amount) {
            revert UnexpectedSupplyAmountToPool(
                token,
                tokenBalanceBeforeSupply,
                tokenBalanceAfterSupply,
                amount
            );
        }
    }

    /**
     * @dev Borrow tokens from the lending pool, and make sure the output is as expected
     * @param token Address of the token
     * @param amount Amount of tokens to borrow
     * @param onBehalfOf Address to borrow on behalf of
     */
    function _borrowFromPool(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal {
        // At this step, we assume that the funds from the depositor are already in the vault

        uint256 tokenBalanceBeforeBorrow = ERC20(token).balanceOf(onBehalfOf);

        _borrowFromPoolImplementation(token, amount, onBehalfOf);

        uint256 tokenBalanceAfterBorrow = ERC20(token).balanceOf(onBehalfOf);
        if (tokenBalanceAfterBorrow <= tokenBalanceBeforeBorrow) {
            revert TokenBalanceNotIncreasedAfterBorrow(
                token,
                tokenBalanceBeforeBorrow,
                tokenBalanceAfterBorrow,
                amount
            );
        }

        // Allow a 1-wei rounding tolerance when comparing the observed balance change with `amount`
        uint256 observedDiffBorrow = tokenBalanceAfterBorrow -
            tokenBalanceBeforeBorrow;
        if (observedDiffBorrow > amount) {
            if (observedDiffBorrow - amount > BALANCE_DIFF_TOLERANCE) {
                revert UnexpectedBorrowAmountFromPool(
                    token,
                    tokenBalanceBeforeBorrow,
                    tokenBalanceAfterBorrow,
                    amount
                );
            }
        } else {
            if (amount - observedDiffBorrow > BALANCE_DIFF_TOLERANCE) {
                revert UnexpectedBorrowAmountFromPool(
                    token,
                    tokenBalanceBeforeBorrow,
                    tokenBalanceAfterBorrow,
                    amount
                );
            }
        }

        // Now, as balance before must be less than balance after, we can just check if the difference is the expected amount
        // NOTE: A second strict equality comparison is no longer necessary.
        // The tolerance enforcement performed above (±BALANCE_DIFF_TOLERANCE)
        // already guarantees that any rounding variance is within an
        // acceptable 1-wei window, so we purposefully avoid reverting here.
    }

    /**
     * @dev Repay debt to the lending pool, and make sure the output is as expected
     * @param token Address of the token
     * @param amount Amount of tokens to repay
     * @param onBehalfOf Address to repay on behalf of
     */
    function _repayDebtToPool(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal {
        // At this step, we assume that the funds from the depositor are already in the vault

        uint256 tokenBalanceBeforeRepay = ERC20(token).balanceOf(onBehalfOf);

        _repayDebtToPoolImplementation(token, amount, onBehalfOf);

        uint256 tokenBalanceAfterRepay = ERC20(token).balanceOf(onBehalfOf);

        // Ensure the balance actually decreased
        if (tokenBalanceAfterRepay >= tokenBalanceBeforeRepay) {
            revert TokenBalanceNotDecreasedAfterRepay(
                token,
                tokenBalanceBeforeRepay,
                tokenBalanceAfterRepay,
                amount
            );
        }

        // Now, allow a 1-wei rounding tolerance on the observed balance decrease.
        uint256 observedDiffRepay = tokenBalanceBeforeRepay -
            tokenBalanceAfterRepay;
        if (observedDiffRepay > amount) {
            if (observedDiffRepay - amount > BALANCE_DIFF_TOLERANCE) {
                revert UnexpectedRepayAmountToPool(
                    token,
                    tokenBalanceBeforeRepay,
                    tokenBalanceAfterRepay,
                    amount
                );
            }
        } else {
            if (amount - observedDiffRepay > BALANCE_DIFF_TOLERANCE) {
                revert UnexpectedRepayAmountToPool(
                    token,
                    tokenBalanceBeforeRepay,
                    tokenBalanceAfterRepay,
                    amount
                );
            }
        }
    }

    /**
     * @dev Withdraw tokens from the lending pool, and make sure the output is as expected
     * @param token Address of the token
     * @param amount Amount of tokens to withdraw
     * @param onBehalfOf Address to withdraw on behalf of
     */
    function _withdrawFromPool(
        address token,
        uint256 amount,
        address onBehalfOf
    ) internal {
        // At this step, we assume that the funds from the depositor are already in the vault

        uint256 tokenBalanceBeforeWithdraw = ERC20(token).balanceOf(onBehalfOf);

        _withdrawFromPoolImplementation(token, amount, onBehalfOf);

        uint256 tokenBalanceAfterWithdraw = ERC20(token).balanceOf(onBehalfOf);

        // Ensure the balance actually increased
        if (tokenBalanceAfterWithdraw <= tokenBalanceBeforeWithdraw) {
            revert TokenBalanceNotIncreasedAfterWithdraw(
                token,
                tokenBalanceBeforeWithdraw,
                tokenBalanceAfterWithdraw,
                amount
            );
        }

        // Allow a 1-wei rounding tolerance on the observed balance increase
        uint256 observedDiffWithdraw = tokenBalanceAfterWithdraw -
            tokenBalanceBeforeWithdraw;
        if (observedDiffWithdraw > amount) {
            if (observedDiffWithdraw - amount > BALANCE_DIFF_TOLERANCE) {
                revert UnexpectedWithdrawAmountFromPool(
                    token,
                    tokenBalanceBeforeWithdraw,
                    tokenBalanceAfterWithdraw,
                    amount
                );
            }
        } else {
            if (amount - observedDiffWithdraw > BALANCE_DIFF_TOLERANCE) {
                revert UnexpectedWithdrawAmountFromPool(
                    token,
                    tokenBalanceBeforeWithdraw,
                    tokenBalanceAfterWithdraw,
                    amount
                );
            }
        }
    }

    /* Safety */

    /**
     * @dev Gets the restricted rescue tokens
     * @return address[] Restricted rescue tokens
     */
    function getRestrictedRescueTokens()
        public
        view
        virtual
        override
        returns (address[] memory)
    {
        // Get the additional rescue tokens from the derived contract
        address[]
            memory additionalRescueTokens = _getAdditionalRescueTokensImplementation();

        // Restrict the rescue tokens to the collateral token and the debt token
        // as they are going to be used to compensate subsidies during the rebalance
        address[] memory restrictedRescueTokens = new address[](
            2 + additionalRescueTokens.length
        );
        restrictedRescueTokens[0] = address(collateralToken);
        restrictedRescueTokens[1] = address(debtToken);

        // Concatenate the restricted rescue tokens and the additional rescue tokens
        for (uint256 i = 0; i < additionalRescueTokens.length; i++) {
            restrictedRescueTokens[2 + i] = additionalRescueTokens[i];
        }
        return restrictedRescueTokens;
    }

    /* Helper Functions */

    /**
     * @dev Calculates the leveraged amount of the assets
     * @param assets Amount of assets
     * @return leveragedAssets Amount of leveraged assets
     */
    function getLeveragedAssets(uint256 assets) public view returns (uint256) {
        return
            (assets * targetLeverageBps) /
            BasisPointConstants.ONE_HUNDRED_PERCENT_BPS;
    }

    /**
     * @dev Calculates the unleveraged amount of the assets
     * @param leveragedAssets Amount of leveraged assets
     * @return unleveragedAssets Amount of unleveraged assets
     */
    function getUnleveragedAssets(
        uint256 leveragedAssets
    ) public view returns (uint256) {
        return
            (leveragedAssets * BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) /
            targetLeverageBps;
    }

    /**
     * @dev Gets the asset price from the oracle
     * @param asset Address of the asset
     * @return uint256 Price of the asset
     */
    function getAssetPriceFromOracle(
        address asset
    ) public view returns (uint256) {
        uint256 assetPrice = _getAssetPriceFromOracleImplementation(asset);

        // Sanity check
        if (assetPrice == 0) {
            revert AssetPriceIsZero(asset);
        }

        return assetPrice;
    }

    /**
     * @dev Converts an amount in base currency to the actual amount in the token
     * @param amountInBase Amount in base currency
     * @param token Address of the token
     * @return amountInToken Amount in the token
     */
    function convertFromBaseCurrencyToToken(
        uint256 amountInBase,
        address token
    ) public view returns (uint256) {
        // The price decimals is cancelled out in the division (as the amount and price are in the same unit)
        uint256 tokenPriceInBase = getAssetPriceFromOracle(token);
        return
            (amountInBase * 10 ** ERC20(token).decimals()) / tokenPriceInBase;
    }

    /**
     * @dev Converts an amount in the token to the actual amount in base currency
     * @param amountInToken Amount in the token
     * @param token Address of the token
     * @return amountInBase Amount in base currency
     */
    function convertFromTokenAmountToBaseCurrency(
        uint256 amountInToken,
        address token
    ) public view returns (uint256) {
        // The token decimals is cancelled out in the division (as the amount and price are in the same unit)
        uint256 tokenPriceInBase = getAssetPriceFromOracle(token);
        return
            (amountInToken * tokenPriceInBase) / 10 ** ERC20(token).decimals();
    }

    /**
     * @dev Override of totalAssets from ERC4626
     * @return uint256 Total assets in the vault
     */
    function totalAssets() public view virtual override returns (uint256) {
        // We override this function to return the total assets in the vault
        // with respect to the position in the lending pool
        // The dLend interest will be distributed to the dToken
        (uint256 totalCollateralBase, ) = getTotalCollateralAndDebtOfUserInBase(
            address(this)
        );
        // The price decimals is cancelled out in the division (as the amount and price are in the same unit)
        return
            convertFromBaseCurrencyToToken(
                totalCollateralBase,
                address(collateralToken)
            );
    }

    /* Safety */

    /**
     * @dev Returns whether the current leverage is too imbalanced
     * @return bool True if leverage is too imbalanced, false otherwise
     */
    function isTooImbalanced() public view returns (bool) {
        uint256 currentLeverageBps = getCurrentLeverageBps();
        // If there is no deposit yet, we don't need to rebalance, thus it is not too imbalanced
        return
            currentLeverageBps != 0 &&
            (currentLeverageBps < lowerBoundTargetLeverageBps ||
                currentLeverageBps > upperBoundTargetLeverageBps);
    }

    /* Deposit and Mint */

    /**
     * @dev Deposits assets into the vault
     *      - It will send the borrowed debt token and the minted shares to the receiver
     *      - The minted shares represent the position of the supplied collateral assets in the lending pool
     * @param caller Address of the caller
     * @param receiver Address to receive the minted shares
     * @param assets Amount of assets to deposit
     * @param shares Amount of shares to mint
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        /**
         * Example of how this function works:
         *
         * Suppose that the target leverage is 3x, and the baseLTVAsCollateral is 70%
         * - The collateral token is WETH
         * - The debt here is dUSD
         * - The current collateral token balance is 0 WETH
         * - The current debt token balance is 0 dUSD
         * - The current shares supply is 0
         * - Assume that the price of WETH is 2000 dUSD
         *
         * 1. User deposits 300 WETH
         * 2. The vault supplies 300 WETH to the lending pool
         * 3. The vault borrows 400,000 dUSD (300 * 2000 * 66.6666666%) from the lending pool
         *    - 66.666% is to keep the target leverage 3x
         * 4. The vault sends 400,000 dUSD to the receiver
         * 5. The vault mints 300 shares to the user (representing 300 WETH position in the lending pool)
         *
         * The current leverage is: (300 * 2000) / (300 * 2000 - 400,000) = 3x
         */

        // Make sure the current leverage is within the target range
        if (isTooImbalanced()) {
            revert TooImbalanced(
                getCurrentLeverageBps(),
                lowerBoundTargetLeverageBps,
                upperBoundTargetLeverageBps
            );
        }

        uint256 debtAssetBorrowed = _depositToPoolImplementation(
            caller,
            assets
        );

        // Transfer the debt asset to the receiver
        debtToken.safeTransfer(receiver, debtAssetBorrowed);

        // Mint the vault's shares to the depositor
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Handles the logic of supplying collateral token and borrowing debt token
     * @param caller Address of the caller
     * @param supplyAssetAmount Amount of assets to supply
     * @return debtAssetAmountToBorrow Amount of debt asset to borrow
     */
    function _depositToPoolImplementation(
        address caller,
        uint256 supplyAssetAmount // supply amount
    ) private returns (uint256) {
        // Transfer the assets to the vault (need the allowance before calling this function)
        collateralToken.safeTransferFrom(
            caller,
            address(this),
            supplyAssetAmount
        );

        // At this step, we assume that the funds from the depositor are already in the vault

        // Get current leverage before supplying (IMPORTANT: this is the leverage before supplying)
        uint256 currentLeverageBpsBeforeSupply = getCurrentLeverageBps();

        // Make sure we have enough balance to supply before supplying
        uint256 currentCollateralTokenBalance = collateralToken.balanceOf(
            address(this)
        );
        if (currentCollateralTokenBalance < supplyAssetAmount) {
            revert DepositInsufficientToSupply(
                currentCollateralTokenBalance,
                supplyAssetAmount
            );
        }

        // Supply the collateral token to the lending pool
        _supplyToPool(
            address(collateralToken),
            supplyAssetAmount,
            address(this)
        );

        // Get the amount of debt token to borrow that keeps the current leverage
        // If there is no deposit yet (leverage=0), we use the target leverage
        uint256 debtTokenAmountToBorrow = getBorrowAmountThatKeepCurrentLeverage(
                address(collateralToken),
                address(debtToken),
                supplyAssetAmount,
                currentLeverageBpsBeforeSupply > 0
                    ? currentLeverageBpsBeforeSupply
                    : targetLeverageBps
            );

        // Borrow the max amount of debt token
        _borrowFromPool(
            address(debtToken),
            debtTokenAmountToBorrow,
            address(this)
        );

        return debtTokenAmountToBorrow;
    }

    /* Withdraw and Redeem */

    /**
     * @dev Withdraws collateral assets from the vault
     *      - It requires to spend the debt token to repay the debt
     *      - It will send the withdrawn collateral assets to the receiver and burn the shares
     *      - The burned shares represent the position of the withdrawn assets in the lending pool
     * @param caller Address of the caller
     * @param receiver Address to receive the withdrawn assets
     * @param owner Address of the owner
     * @param assets Amount of assets to remove from the lending pool
     * @param shares Amount of shares to burn
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        /**
         * Example of how this function works:
         *
         * Suppose that the target leverage is 3x, and the baseLTVAsCollateral is 70%
         * - The collateral token is WETH
         * - The debt here is dUSD
         * - The current shares supply is 300
         * - The current leverage is 3x
         * - The current collateral token balance is 300 WETH
         * - The current debt token balance is 400,000 dUSD (300 * 2000 * 66.6666666%)
         * - Assume that the price of WETH is 2000 dUSD
         *
         * 1. User has 100 shares
         * 2. User wants to withdraw 100 WETH
         * 3. The vault burns 100 shares
         * 4. The vault transfers 133,333 dUSD (100 * 2000 * 66.6666666%) from the user to the vault
         *    - 66.6666% is to keep the target leverage 3x
         * 5. The vault repays 133,333 dUSD to the lending pool
         *    - The debt is now 266,667 dUSD (400,000 - 133,333)
         * 6. The vault withdraws 100 WETH from the lending pool
         *    - The collateral is now 200 WETH (300 - 100)
         * 7. The vault sends 100 WETH to the receiver
         *
         * The current leverage is: (200 * 2000) / (200 * 2000 - 266,667) = 3x
         */

        // Note that we need the allowance before calling this function
        // - Allowance for the message sender to spend the shares on behalf of the owner
        // - Allowance for the vault to burn the shares

        // If the owner is not the caller, then we need to spend the allowance
        // so that the caller can spend the shares on behalf of the owner
        if (owner != caller) {
            _spendAllowance(owner, caller, shares);
        }

        // Check user's balance before burning shares
        uint256 userShares = balanceOf(owner);
        if (userShares < shares) {
            revert InsufficientShareBalanceToRedeem(owner, shares, userShares);
        }

        // Burn the shares
        _burn(owner, shares);

        // Make sure the current leverage is within the target range
        if (isTooImbalanced()) {
            revert TooImbalanced(
                getCurrentLeverageBps(),
                lowerBoundTargetLeverageBps,
                upperBoundTargetLeverageBps
            );
        }

        // Withdraw the collateral from the lending pool
        // After this step, the _withdrawFromPool wrapper function will also assert that
        // the withdrawn amount is exactly the amount requested.
        _withdrawFromPoolImplementation(caller, assets);

        // Transfer the asset to the receiver
        collateralToken.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Handles the logic for repaying debt and withdrawing collateral from the pool
     *      - It calculates the required debt token to repay to keep the current leverage
     *        given the expected withdraw amount
     *      - Then performs the actual repay and withdraw
     * @param caller Address of the caller
     * @param collateralTokenToWithdraw The amount of collateral token to withdraw
     * @return repaidDebtTokenAmount The amount of debt token repaid
     */
    function _withdrawFromPoolImplementation(
        address caller,
        uint256 collateralTokenToWithdraw
    ) private returns (uint256 repaidDebtTokenAmount) {
        // Get the current leverage before repaying the debt (IMPORTANT: this is the leverage before repaying the debt)
        // It is used to calculate the expected withdrawable amount that keeps the current leverage
        uint256 leverageBpsBeforeRepayDebt = getCurrentLeverageBps();

        repaidDebtTokenAmount = getRepayAmountThatKeepCurrentLeverage(
            address(collateralToken),
            address(debtToken),
            collateralTokenToWithdraw,
            leverageBpsBeforeRepayDebt
        );

        // If don't have enough allowance, revert with the error message
        // This is to early-revert with instruction in the error message
        if (
            debtToken.allowance(caller, address(this)) < repaidDebtTokenAmount
        ) {
            revert InsufficientAllowanceOfDebtAssetToRepay(
                caller,
                address(this),
                address(debtToken),
                repaidDebtTokenAmount
            );
        }

        // Transfer the debt token to the vault to repay the debt
        debtToken.safeTransferFrom(
            caller,
            address(this),
            repaidDebtTokenAmount
        );

        // Repay the debt to withdraw the collateral
        _repayDebtToPool(
            address(debtToken),
            repaidDebtTokenAmount,
            address(this)
        );

        // Withdraw the collateral
        // At this step, the _withdrawFromPool wrapper function will also assert that
        // the withdrawn amount is exactly the amount requested.
        _withdrawFromPool(
            address(collateralToken),
            collateralTokenToWithdraw,
            address(this)
        );

        return repaidDebtTokenAmount;
    }

    /* Calculate */

    function getRepayAmountThatKeepCurrentLeverage(
        address collateralAsset,
        address debtAsset,
        uint256 targetWithdrawAmount,
        uint256 leverageBpsBeforeRepayDebt
    ) public view returns (uint256 repayAmount) {
        /* Formula definition:
         * - C1: totalCollateralBase before repay (in base currency)
         * - D1: totalDebtBase before repay (in base currency)
         * - C2: totalCollateralBase after repay (in base currency)
         * - D2: totalDebtBase after repay (in base currency)
         * - T: target leverage
         * - x: withdraw amount in base currency
         * - y: repay amount in base currency
         *
         * We have:
         *        C1 / (C1-D1) = C2 / (C2-D2)
         *        C2 = C1-x
         *        D2 = D1-y
         *        C1 / (C1-D1) = T <=> C1 = (C1-D1) * T <=> C1 = C1*T - D1*T <=> C1*T - C1 = D1*T <=> C1 = D1*T/(T-1)
         *
         * Formula expression:
         *        C1 / (C1-D1) = (C1-x) / (C1-x-D1+y)
         *    <=> C1 * (C1-x-D1+y) = (C1-x) * (C1-D1)
         *    <=> C1^2 - C1*x - C1*D1 + C1*y = C1^2 - C1*D1 - C1*x + D1*x
         *    <=> C1^2 - C1*x - C1*D1 + C1*y = C1^2 - C1*x - C1*D1 + D1*x
         *    <=> C1*y = x*D1
         *    <=> y = x*D1 / C1
         *    <=> y = x*D1 / [D1*T / (T-1)]
         *    <=> y = x * (T-1)/T
         *
         * Suppose that T' = T * ONE_HUNDRED_PERCENT_BPS, then:
         *
         *  => T = T' / ONE_HUNDRED_PERCENT_BPS
         * where T' is the target leverage in basis points unit
         *
         * We have:
         *      y = x * (T-1)/T
         *  <=> y = x * (T' / ONE_HUNDRED_PERCENT_BPS - 1) / (T' / ONE_HUNDRED_PERCENT_BPS)
         *  <=> y = x * (T' - ONE_HUNDRED_PERCENT_BPS) / T'
         */

        // Convert the target withdraw amount to base
        uint256 targetWithdrawAmountInBase = convertFromTokenAmountToBaseCurrency(
                targetWithdrawAmount,
                collateralAsset
            );

        // Calculate the repay amount in base
        uint256 repayAmountInBase = (targetWithdrawAmountInBase *
            (leverageBpsBeforeRepayDebt -
                BasisPointConstants.ONE_HUNDRED_PERCENT_BPS)) /
            leverageBpsBeforeRepayDebt;

        return convertFromBaseCurrencyToToken(repayAmountInBase, debtAsset);
    }

    /**
     * @dev Gets the borrow amount that keeps the current leverage
     * @param collateralAsset The collateral asset
     * @param debtAsset The debt asset
     * @param suppliedCollateralAmount The actual supplied amount of collateral asset
     * @param leverageBpsBeforeSupply Leverage in basis points before supplying
     * @return expectedBorrowAmount The expected borrow amount that keeps the current leverage
     */
    function getBorrowAmountThatKeepCurrentLeverage(
        address collateralAsset,
        address debtAsset,
        uint256 suppliedCollateralAmount,
        uint256 leverageBpsBeforeSupply
    ) public view returns (uint256 expectedBorrowAmount) {
        /* Formula definition:
         * - C1: totalCollateralBase before supply (in base currency)
         * - D1: totalDebtBase before supply (in base currency)
         * - C2: totalCollateralBase after supply (in base currency)
         * - D2: totalDebtBase after supply (in base currency)
         * - T: target leverage
         * - x: supply amount in base currency
         * - y: borrow amount in base currency
         *
         * We have:
         *      C1 / (C1-D1) = C2 / (C2-D2)
         *      C2 = C1+x
         *      D2 = D1+y
         *      C1 / (C1-D1) = T <=> C1 = (C1-D1) * T <=> C1 = C1*T - D1*T <=> C1*T - C1 = D1*T <=> C1 = D1*T/(T-1)
         *
         * Formula expression:
         *      C1 / (C1-D1) = (C1+x) / (C1+x-D1-y)
         *  <=> C1 * (C1+x-D1-y) = (C1+x) * (C1-D1)
         *  <=> C1^2 + C1*x - C1*D1 - C1*y = C1^2 - C1*D1 + C1*x - D1*x
         *  <=> C1*y = x*D1
         *  <=> y = x*D1 / C1
         *  <=> y = x * (T-1)/T
         *
         * Suppose that:
         *      T' = T * ONE_HUNDRED_PERCENT_BPS, then:
         *   => T = T' / ONE_HUNDRED_PERCENT_BPS
         * where:
         *      - T' is the target leverage in basis points unit
         *
         * This is the formula to calculate the borrow amount that keeps the current leverage:
         *      y = x * (T-1)/T
         *  <=> y = x * (T' / ONE_HUNDRED_PERCENT_BPS - 1) / (T' / ONE_HUNDRED_PERCENT_BPS)
         *  <=> y = x * (T' - ONE_HUNDRED_PERCENT_BPS) / T'
         */

        // Convert the actual supplied amount to base
        uint256 suppliedCollateralAmountInBase = convertFromTokenAmountToBaseCurrency(
                suppliedCollateralAmount,
                collateralAsset
            );

        // Calculate the borrow amount in base currency that keeps the current leverage
        uint256 borrowAmountInBase = (suppliedCollateralAmountInBase *
            (leverageBpsBeforeSupply -
                BasisPointConstants.ONE_HUNDRED_PERCENT_BPS)) /
            leverageBpsBeforeSupply;

        return convertFromBaseCurrencyToToken(borrowAmountInBase, debtAsset);
    }

    /* Rebalance */

    /**
     * @dev Gets the collateral token amount to reach the target leverage
     *      - This method is only being called for increasing the leverage quote in getAmountToReachTargetLeverage()
     * @param expectedTargetLeverageBps The expected target leverage in basis points unit
     * @param totalCollateralBase The total collateral base
     * @param totalDebtBase The total debt base
     * @param subsidyBps The subsidy in basis points unit
     * @param useVaultTokenBalance Whether to use the current token balance in the vault as the amount to rebalance
     * @return collateralTokenAmount The collateral token amount to reach the target leverage
     */
    function _getCollateralTokenAmountToReachTargetLeverage(
        uint256 expectedTargetLeverageBps,
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 subsidyBps,
        bool useVaultTokenBalance
    ) internal view returns (uint256) {
        /**
         * The formula is at getAmountToReachTargetLeverage()
         *
         * Calculate the amount of collateral token to supply
         * The original formula is:
         *      x = (T'*(C - D) - C*ONE_HUNDRED_PERCENT_BPS) * ONE_HUNDRED_PERCENT_BPS / (ONE_HUNDRED_PERCENT_BPS^2 + T' * k')
         *
         * However, the calculation of ONE_HUNDRED_PERCENT_BPS^2 causes arithmetic overflow,
         * so we need to simplify the formula to avoid the overflow.
         *
         * So, the transformed formula is:
         *      x = (T'*(C - D) - C*ONE_HUNDRED_PERCENT_BPS) / (ONE_HUNDRED_PERCENT_BPS + T' * k' / ONE_HUNDRED_PERCENT_BPS)
         */
        if (totalCollateralBase == 0) {
            revert TotalCollateralBaseIsZero();
        }
        if (totalCollateralBase < totalDebtBase) {
            revert TotalCollateralBaseIsLessThanTotalDebtBase(
                totalCollateralBase,
                totalDebtBase
            );
        }

        uint256 requiredCollateralTokenAmountInBase = (expectedTargetLeverageBps *
                (totalCollateralBase - totalDebtBase) -
                totalCollateralBase *
                BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) /
                (BasisPointConstants.ONE_HUNDRED_PERCENT_BPS +
                    ((expectedTargetLeverageBps * subsidyBps) /
                        BasisPointConstants.ONE_HUNDRED_PERCENT_BPS));

        // Convert to token unit
        uint256 requiredCollateralTokenAmount = convertFromBaseCurrencyToToken(
            requiredCollateralTokenAmountInBase,
            address(collateralToken)
        );

        if (useVaultTokenBalance) {
            // Get the current collateral token balance in the vault to compensate the required collateral amount
            // when increasing the leverage
            uint256 collateralBalanceInVault = collateralToken.balanceOf(
                address(this)
            );

            // If the required collateral token amount is more than the collateral balance in the vault,
            // the caller need to call increaseLeverage with the additional collateral token amount
            if (requiredCollateralTokenAmount > collateralBalanceInVault) {
                return requiredCollateralTokenAmount - collateralBalanceInVault;
            }

            // Otherwise, it is a free lunch, the user call increaseLeverage without having to pay
            // for the collateral token
            return 0;
        }

        // Otherwise, the user can call increaseLeverage with the required collateral token amount
        return requiredCollateralTokenAmount;
    }

    /**
     * @dev Gets the debt token amount to reach the target leverage
     *      - This method is only being called for decreasing the leverage quote in getAmountToReachTargetLeverage()
     * @param expectedTargetLeverageBps The expected target leverage in basis points unit
     * @param totalCollateralBase The total collateral base
     * @param totalDebtBase The total debt base
     * @param subsidyBps The subsidy in basis points unit
     * @param useVaultTokenBalance Whether to use the current token balance in the vault as the amount to rebalance
     * @return requiredDebtTokenAmount The debt token amount to reach the target leverage
     */
    function _getDebtTokenAmountToReachTargetLeverage(
        uint256 expectedTargetLeverageBps,
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 subsidyBps,
        bool useVaultTokenBalance
    ) internal view returns (uint256) {
        /**
         * The formula is at getAmountToReachTargetLeverage()
         *
         * Calculate the amount of debt token to repay
         * The original formula is:
         *      x = (C*ONE_HUNDRED_PERCENT_BPS - T'*(C - D)) * ONE_HUNDRED_PERCENT_BPS / (ONE_HUNDRED_PERCENT_BPS^2 + T' * k')
         *
         * However, the calculation of ONE_HUNDRED_PERCENT_BPS^2 causes arithmetic overflow,
         * so we need to simplify the formula to avoid the overflow.
         *
         * So, the transformed formula is:
         *      x = (C*ONE_HUNDRED_PERCENT_BPS - T'*(C - D)) / (ONE_HUNDRED_PERCENT_BPS + T' * k' / ONE_HUNDRED_PERCENT_BPS)
         */
        if (totalCollateralBase == 0) {
            revert TotalCollateralBaseIsZero();
        }
        if (totalCollateralBase < totalDebtBase) {
            revert TotalCollateralBaseIsLessThanTotalDebtBase(
                totalCollateralBase,
                totalDebtBase
            );
        }

        uint256 requiredDebtTokenAmountInBase = (totalCollateralBase *
            BasisPointConstants.ONE_HUNDRED_PERCENT_BPS -
            expectedTargetLeverageBps *
            (totalCollateralBase - totalDebtBase)) /
            (BasisPointConstants.ONE_HUNDRED_PERCENT_BPS +
                (expectedTargetLeverageBps * subsidyBps) /
                BasisPointConstants.ONE_HUNDRED_PERCENT_BPS);

        // Convert to token unit
        uint256 requiredDebtTokenAmount = convertFromBaseCurrencyToToken(
            requiredDebtTokenAmountInBase,
            address(debtToken)
        );

        if (useVaultTokenBalance) {
            // Get the current debt token balance in the vault to compensate the required debt amount
            uint256 debtTokenBalanceInVault = debtToken.balanceOf(
                address(this)
            );

            // If the required debt token amount is more than the debt token balance in the vault,
            // the caller need to call decreaseLeverage with the additional debt token amount
            if (requiredDebtTokenAmount > debtTokenBalanceInVault) {
                return requiredDebtTokenAmount - debtTokenBalanceInVault;
            }

            // Otherwise, it is a free lunch, the user call decreaseLeverage without having to pay
            // for the debt token
            return 0;
        }

        // Otherwise, the user can call decreaseLeverage with the required debt token amount
        return requiredDebtTokenAmount;
    }

    /**
     * @dev Gets the rebalance amount to reach the target leverage in token unit
     *      - This method is supposed to be used by the rebalancing service which will use it to quote the required
     *        collateral/debt amount and the corresponding direction (increase or decrease)
     * @param useVaultTokenBalance Whether to use the current token balance in the vault as the amount to rebalance
     *      - It will help to save the additional collateral/debt token transfer from the caller to the vault, while getting
     *        the same effect as calling increaseLeverage or decreaseLeverage with the required collateral/debt token amount
     * @return tokenAmount The amount of token to call increaseLeverage or decreaseLeverage (in token unit)
     *         - If the direction is 1, the amount is in collateral token
     *         - If the direction is -1, the amount is in debt token
     * @return direction The direction of the rebalance (1 for increase, -1 for decrease, 0 means no rebalance)
     */
    function getAmountToReachTargetLeverage(
        bool useVaultTokenBalance
    ) public view returns (uint256 tokenAmount, int8 direction) {
        /**
         * Formula definition:
         * - C: totalCollateralBase
         * - D: totalDebtBase
         * - T: target leverage
         * - k: subsidy (0.01 means 1%)
         * - x: change amount of collateral in base currency
         * - y: change amount of debt in base currency
         *
         * We have:
         *      y = x*(1+k)
         *      (C + x) / (C + x - D - y) = T
         *  <=> (C + x) / (C + x - D - x*(1+k)) = T
         *  <=> (C + x) = T * (C + x - D - x*(1+k))
         *  <=> C + x = T*C + T*x - T*D - T*x - T*x*k
         *  <=> C + x = T*C - T*D - T*x*k
         *  <=> x + T*x*k = T*C - T*D - C
         *  <=> x*(1 + T*k) = T*C - T*D - C
         *  <=> x = (T*(C - D) - C) / (1 + T*k)
         *
         * Suppose that:
         *      T' = T * ONE_HUNDRED_PERCENT_BPS
         *      k' = k * ONE_HUNDRED_PERCENT_BPS
         * then:
         *      T = T' / ONE_HUNDRED_PERCENT_BPS
         *      k = k' / ONE_HUNDRED_PERCENT_BPS
         * where:
         *      - T' is the target leverage in basis points unit
         *      - k' is the subsidy in basis points unit
         *
         * We have:
         *      x = (T*(C - D) - C) / (1 + T*k)
         *  <=> x = (T'*(C - D) / ONE_HUNDRED_PERCENT_BPS - C) / (1 + T'*k / ONE_HUNDRED_PERCENT_BPS)
         *  <=> x = (T'*(C - D) - C*ONE_HUNDRED_PERCENT_BPS) / (ONE_HUNDRED_PERCENT_BPS + T'*k)
         *  <=> x = (T'*(C - D) - C*ONE_HUNDRED_PERCENT_BPS) / (ONE_HUNDRED_PERCENT_BPS + T' * k' / ONE_HUNDRED_PERCENT_BPS)
         *  <=> x = (T'*(C - D) - C*ONE_HUNDRED_PERCENT_BPS) * ONE_HUNDRED_PERCENT_BPS / (ONE_HUNDRED_PERCENT_BPS^2 + T' * k')
         *
         * If x > 0, it means the user should increase the leverage, so the direction is 1
         *    => x = (T*(C - D) - C) / (1 + T*k)
         *    => x = (T'*(C - D) - C*ONE_HUNDRED_PERCENT_BPS) * ONE_HUNDRED_PERCENT_BPS / (ONE_HUNDRED_PERCENT_BPS^2 + T' * k')
         * If x < 0, it means the user should decrease the leverage, so the direction is -1
         *    => x = (C - T*(C - D)) / (1 + T*k)
         *    => x = (C*ONE_HUNDRED_PERCENT_BPS - T'*(C - D)) * ONE_HUNDRED_PERCENT_BPS / (ONE_HUNDRED_PERCENT_BPS^2 + T' * k')
         * If x = 0, it means the user should not rebalance, so the direction is 0
         */

        uint256 currentLeverageBps = getCurrentLeverageBps();
        uint256 subsidyBps = getCurrentSubsidyBps();
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase
        ) = getTotalCollateralAndDebtOfUserInBase(address(this));

        if (totalCollateralBase == 0) {
            // No collateral means no debt and no leverage, so no rebalance is needed
            return (0, 0);
        }

        // If the current leverage is below the target leverage, the user should increase the leverage
        if (currentLeverageBps < targetLeverageBps) {
            return (
                _getCollateralTokenAmountToReachTargetLeverage(
                    targetLeverageBps,
                    totalCollateralBase,
                    totalDebtBase,
                    subsidyBps,
                    useVaultTokenBalance
                ),
                1
            );
        }
        // If the current leverage is above the target leverage, the user should decrease the leverage
        else if (currentLeverageBps > targetLeverageBps) {
            return (
                _getDebtTokenAmountToReachTargetLeverage(
                    targetLeverageBps,
                    totalCollateralBase,
                    totalDebtBase,
                    subsidyBps,
                    useVaultTokenBalance
                ),
                -1
            );
        }

        // If the current leverage is equal to the target leverage, the user should not rebalance
        return (0, 0);
    }

    /**
     * @dev Gets the required collateral token amount to reach the target leverage
     * @param expectedTargetLeverageBps The expected target leverage in basis points unit
     * @param totalCollateralBase The total collateral base
     * @param totalDebtBase The total debt base
     * @param subsidyBps The subsidy in basis points unit
     * @param additionalCollateralTokenAmount The additional collateral token amount to supply
     * @return requiredCollateralTokenAmount The required collateral token amount to reach the target leverage
     */
    function _getRequiredCollateralTokenAmountToRebalance(
        uint256 expectedTargetLeverageBps,
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 subsidyBps,
        uint256 additionalCollateralTokenAmount
    ) internal view returns (uint256 requiredCollateralTokenAmount) {
        /* If the additional collateral token amount is 0, it means the expected collateral token amount to reach the target leverage
         * can be less than or equal to the current collateral token balance in the vault
         * Thus, we need to calculate the actual required collateral token amount to reach the target leverage
         * and then use the current collateral token balance in the vault to supply
         * - It is to avoid the situation where the current collateral token balance in the vault is too high
         *   and thus cannot call increaseLeverage with this balance as it will increase the leverage above the target leverage
         *
         * This function is only being used internally
         */
        if (additionalCollateralTokenAmount == 0) {
            return
                _getCollateralTokenAmountToReachTargetLeverage(
                    expectedTargetLeverageBps,
                    totalCollateralBase,
                    totalDebtBase,
                    subsidyBps,
                    false
                );
        }

        // Otherwise, it means the expected collateral token amount to reach the target leverage
        // is less than the current collateral token balance in the vault
        uint256 collateralTokenBalanceInVault = collateralToken.balanceOf(
            address(this)
        );
        return collateralTokenBalanceInVault + additionalCollateralTokenAmount;
    }

    /**
     * @dev Gets the required debt token amount to reach the target leverage
     * @param expectedTargetLeverageBps The expected target leverage in basis points unit
     * @param totalCollateralBase The total collateral base
     * @param totalDebtBase The total debt base
     * @param subsidyBps The subsidy in basis points unit
     * @param additionalDebtTokenAmount The additional debt token amount to repay
     * @return requiredDebtTokenAmount The required debt token amount to reach the target leverage
     */
    function _getRequiredDebtTokenAmountToRebalance(
        uint256 expectedTargetLeverageBps,
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 subsidyBps,
        uint256 additionalDebtTokenAmount
    ) internal view returns (uint256 requiredDebtTokenAmount) {
        /* If the additional debt token amount is 0, it means the expected debt token amount to reach the target leverage
         * can be less than or equal to the current debt token balance in the vault
         * Thus, we need to calculate the actual required debt token amount to reach the target leverage
         * and then use the current debt token balance in the vault to repay
         * - It is to avoid the situation where the current debt token balance in the vault is too high
         *   and thus cannot call decreaseLeverage with this balance as it will decrease the leverage below the target leverage
         *
         * This function is only being used internally
         */
        if (additionalDebtTokenAmount == 0) {
            return
                _getDebtTokenAmountToReachTargetLeverage(
                    expectedTargetLeverageBps,
                    totalCollateralBase,
                    totalDebtBase,
                    subsidyBps,
                    false
                );
        }

        uint256 debtTokenBalanceInVault = debtToken.balanceOf(address(this));
        return debtTokenBalanceInVault + additionalDebtTokenAmount;
    }

    /**
     * @dev Increases the leverage of the user by supplying collateral token and borrowing more debt token
     *      - It requires to spend the collateral token from the user's wallet to supply to the pool
     *      - It will send the borrowed debt token to the user's wallet
     * @param additionalCollateralTokenAmount The additional amount of collateral token to supply
     * @param minReceivedDebtTokenAmount The minimum amount of debt token to receive
     */
    function increaseLeverage(
        uint256 additionalCollateralTokenAmount,
        uint256 minReceivedDebtTokenAmount
    ) public nonReentrant {
        /**
         * Example of how this function works:
         *
         * Suppose that the target leverage is 3x, and the baseLTVAsCollateral is 70%
         * - The collateral token is WETH
         * - The debt here is dUSD
         * - Assume that the price of WETH is 2000 dUSD
         * - The current leverage is 1.25x
         *   - Total collateral: 100 WETH (100 * 2000 = 200,000 dUSD)
         *   - Total debt: 40,000 dUSD
         *   - Leverage: 200,000 / (200,000 - 40,000) = 1.25x
         *   - Assume that there is 0 collateral token in the vault
         *
         * 1. User call increaseLeverage with 50 WETH
         * 2. The vault transfers 50 WETH from the user's wallet to the vault
         * 3. The vault supplies 50 WETH to the lending pool
         * 4. The vault borrows 100,000 dUSD (50 * 2000) from the lending pool
         * 5. The vault sends 100,000 dUSD to the user
         *
         * The current leverage is now increased:
         *    - Total collateral: 150 WETH (150 * 2000 = 300,000 dUSD)
         *    - Total debt: 140,000 dUSD
         *    - Leverage: 300,000 / (300,000 - 140,000) = 1.875x
         */

        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase
        ) = getTotalCollateralAndDebtOfUserInBase(address(this));
        uint256 subsidyBps = getCurrentSubsidyBps();

        // Make sure only increase the leverage if it is below the target leverage
        uint256 currentLeverageBps = getCurrentLeverageBps();
        if (currentLeverageBps >= targetLeverageBps) {
            revert LeverageExceedsTarget(currentLeverageBps, targetLeverageBps);
        }

        // Need to calculate the required collateral token amount before transferring the additional collateral token
        // to the vault as it will change the current collateral token balance in the vault
        uint256 requiredCollateralTokenAmount = _getRequiredCollateralTokenAmountToRebalance(
                targetLeverageBps,
                totalCollateralBase,
                totalDebtBase,
                subsidyBps,
                additionalCollateralTokenAmount
            );

        // Only transfer the collateral token if there is an additional amount to supply
        if (additionalCollateralTokenAmount > 0) {
            // Transfer the additional collateral token from the caller to the vault
            collateralToken.safeTransferFrom(
                msg.sender,
                address(this),
                additionalCollateralTokenAmount
            );
        }

        // Calculate the amount of collateral token in base currency
        uint256 requiredCollateralTokenAmountInBase = convertFromTokenAmountToBaseCurrency(
                requiredCollateralTokenAmount,
                address(collateralToken)
            );

        // The amount of debt token to borrow (in base currency) is equal to the amount of collateral token supplied
        // plus the subsidy (bonus for the caller)
        uint256 borrowedDebtTokenInBase = (requiredCollateralTokenAmountInBase *
            (BasisPointConstants.ONE_HUNDRED_PERCENT_BPS + subsidyBps)) /
            BasisPointConstants.ONE_HUNDRED_PERCENT_BPS;

        // Calculate the new leverage after increasing the leverage
        uint256 newLeverageBps = ((totalCollateralBase +
            requiredCollateralTokenAmountInBase) *
            BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) /
            (totalCollateralBase +
                requiredCollateralTokenAmountInBase -
                totalDebtBase -
                borrowedDebtTokenInBase);

        // Make sure the new leverage is increasing and does not exceed the target leverage
        if (
            newLeverageBps > targetLeverageBps ||
            newLeverageBps <= currentLeverageBps
        ) {
            revert IncreaseLeverageOutOfRange(
                newLeverageBps,
                targetLeverageBps,
                currentLeverageBps
            );
        }

        // Supply the collateral token to the lending pool
        _supplyToPool(
            address(collateralToken),
            requiredCollateralTokenAmount,
            address(this)
        );

        // Borrow debt token
        uint256 borrowedDebtTokenAmount = convertFromBaseCurrencyToToken(
            borrowedDebtTokenInBase,
            address(debtToken)
        );

        // Slippage protection, to make sure the user receives at least minReceivedDebtTokenAmount
        if (borrowedDebtTokenAmount < minReceivedDebtTokenAmount) {
            revert RebalanceReceiveLessThanMinAmount(
                "increaseLeverage",
                borrowedDebtTokenAmount,
                minReceivedDebtTokenAmount
            );
        }

        // At this step, the _borrowFromPool wrapper function will also assert that
        // the borrowed amount is exactly the amount requested, thus we can safely
        // have the slippage check before calling this function
        _borrowFromPool(
            address(debtToken),
            borrowedDebtTokenAmount,
            address(this)
        );

        // Transfer the debt token to the user
        debtToken.safeTransfer(msg.sender, borrowedDebtTokenAmount);

        // Make sure the current leverage is below the target leverage after increasing the leverage
        currentLeverageBps = getCurrentLeverageBps();
        if (currentLeverageBps >= targetLeverageBps) {
            revert LeverageExceedsTarget(currentLeverageBps, targetLeverageBps);
        }
    }

    /**
     * @dev Decreases the leverage of the user by repaying debt and withdrawing collateral
     *      - It requires to spend the debt token from the user's wallet to repay the debt to the pool
     *      - It will send the withdrawn collateral asset to the user's wallet
     * @param additionalDebtTokenAmount The additional amount of debt token to repay
     * @param minReceivedAmount The minimum amount of collateral asset to receive
     */
    function decreaseLeverage(
        uint256 additionalDebtTokenAmount,
        uint256 minReceivedAmount
    ) public nonReentrant {
        /**
         * Example of how this function works:
         *
         * Suppose that the target leverage is 3x, and the baseLTVAsCollateral is 70%
         * - The collateral token is WETH
         * - The debt here is dUSD
         * - Assume that the price of WETH is 2000 dUSD
         * - The current leverage is 4x
         *   - Total collateral: 100 WETH (100 * 2000 = 200,000 dUSD)
         *   - Total debt: 150,000 dUSD
         *   - Leverage: 200,000 / (200,000 - 150,000) = 4x
         *
         * 1. User call decreaseLeverage with 20,000 dUSD
         * 2. The vault transfers 20,000 dUSD from the user's wallet to the vault
         * 3. The vault repays 20,000 dUSD to the lending pool
         * 4. The vault withdraws 10 WETH (20,000 / 2000) from the lending pool
         * 5. The vault sends 10 WETH to the user
         *
         * The current leverage is now decreased:
         *    - Total collateral: 90 WETH (90 * 2000 = 180,000 dUSD)
         *    - Total debt: 130,000 dUSD
         *    - Leverage: 180,000 / (180,000 - 130,000) = 3.6x
         */
        // Make sure only decrease the leverage if it is above the target leverage

        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase
        ) = getTotalCollateralAndDebtOfUserInBase(address(this));
        uint256 subsidyBps = getCurrentSubsidyBps();

        uint256 currentLeverageBps = getCurrentLeverageBps();
        if (currentLeverageBps <= targetLeverageBps) {
            revert LeverageBelowTarget(currentLeverageBps, targetLeverageBps);
        }

        // Need to calculate the required debt token amount before transferring the additional debt token
        // to the vault as it will change the current debt token balance in the vault
        uint256 requiredDebtTokenAmount = _getRequiredDebtTokenAmountToRebalance(
                targetLeverageBps,
                totalCollateralBase,
                totalDebtBase,
                subsidyBps,
                additionalDebtTokenAmount
            );

        // Only transfer the debt token if there is an additional amount to repay
        if (additionalDebtTokenAmount > 0) {
            // Transfer the additional debt token from the caller to the vault
            debtToken.safeTransferFrom(
                msg.sender,
                address(this),
                additionalDebtTokenAmount
            );
        }

        // Calculate the amount of debt token in base currency
        uint256 requiredDebtTokenAmountInBase = convertFromTokenAmountToBaseCurrency(
                requiredDebtTokenAmount,
                address(debtToken)
            );

        // The amount of collateral asset to withdraw is equal to the amount of debt token repaid
        // plus the subsidy (bonus for the caller)
        uint256 withdrawCollateralTokenInBase = (requiredDebtTokenAmountInBase *
            (BasisPointConstants.ONE_HUNDRED_PERCENT_BPS + subsidyBps)) /
            BasisPointConstants.ONE_HUNDRED_PERCENT_BPS;

        // Calculate the new leverage after decreasing the leverage
        uint256 newLeverageBps = ((totalCollateralBase -
            withdrawCollateralTokenInBase) *
            BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) /
            (totalCollateralBase -
                withdrawCollateralTokenInBase -
                totalDebtBase +
                requiredDebtTokenAmountInBase);

        // Make sure the new leverage is decreasing and is not below the target leverage
        if (
            newLeverageBps < targetLeverageBps ||
            newLeverageBps >= currentLeverageBps
        ) {
            revert DecreaseLeverageOutOfRange(
                newLeverageBps,
                targetLeverageBps,
                currentLeverageBps
            );
        }

        // Repay the debt token to the lending pool
        _repayDebtToPool(
            address(debtToken),
            requiredDebtTokenAmount,
            address(this)
        );

        // Withdraw collateral
        uint256 withdrawnCollateralTokenAmount = convertFromBaseCurrencyToToken(
            withdrawCollateralTokenInBase,
            address(collateralToken)
        );

        // Slippage protection, to make sure the user receives at least minReceivedAmount
        if (withdrawnCollateralTokenAmount < minReceivedAmount) {
            revert RebalanceReceiveLessThanMinAmount(
                "decreaseLeverage",
                withdrawnCollateralTokenAmount,
                minReceivedAmount
            );
        }

        // At this step, the _withdrawFromPool wrapper function will also assert that
        // the withdrawn amount is exactly the amount requested, thus we can safely
        // have the slippage check before calling this function
        _withdrawFromPool(
            address(collateralToken),
            withdrawnCollateralTokenAmount,
            address(this)
        );

        // Transfer the collateral asset to the user
        collateralToken.safeTransfer(
            msg.sender,
            withdrawnCollateralTokenAmount
        );
    }

    /* Informational */

    /**
     * @dev Gets the current leverage in basis points
     * @return uint256 The current leverage in basis points
     */
    function getCurrentLeverageBps() public view returns (uint256) {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase
        ) = getTotalCollateralAndDebtOfUserInBase(address(this));

        if (totalCollateralBase < totalDebtBase) {
            revert CollateralLessThanDebt(totalCollateralBase, totalDebtBase);
        }
        if (totalCollateralBase == 0) {
            return 0;
        }
        if (totalCollateralBase == totalDebtBase) {
            return type(uint256).max; // infinite leverage
        }
        // The leverage will be 1 if totalDebtBase is 0 (no more debt)
        uint256 leverageBps = ((totalCollateralBase *
            BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) /
            (totalCollateralBase - totalDebtBase));
        if (leverageBps <= BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) {
            revert InvalidLeverage(leverageBps);
        }
        return leverageBps;
    }

    /**
     * @dev Gets the current subsidy in basis points
     * @return uint256 The current subsidy in basis points
     */
    function getCurrentSubsidyBps() public view returns (uint256) {
        uint256 currentLeverageBps = getCurrentLeverageBps();

        uint256 subsidyBps;
        if (currentLeverageBps > targetLeverageBps) {
            subsidyBps =
                ((currentLeverageBps - targetLeverageBps) *
                    BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) /
                targetLeverageBps;
        } else {
            subsidyBps =
                ((targetLeverageBps - currentLeverageBps) *
                    BasisPointConstants.ONE_HUNDRED_PERCENT_BPS) /
                targetLeverageBps;
        }
        if (subsidyBps > maxSubsidyBps) {
            return maxSubsidyBps;
        }
        return subsidyBps;
    }

    /**
     * @dev Gets the address of the collateral token
     * @return address The address of the collateral token
     */
    function getCollateralTokenAddress() public view returns (address) {
        return address(collateralToken);
    }

    /**
     * @dev Gets the address of the debt token
     * @return address The address of the debt token
     */
    function getDebtTokenAddress() public view returns (address) {
        return address(debtToken);
    }

    /**
     * @dev Gets the default maximum subsidy in basis points
     * @return uint256 The default maximum subsidy in basis points
     */
    function getDefaultMaxSubsidyBps() public view returns (uint256) {
        return maxSubsidyBps;
    }

    /* Admin */

    /**
     * @dev Sets the maximum subsidy in basis points
     * @param _maxSubsidyBps New maximum subsidy in basis points
     */
    function setMaxSubsidyBps(
        uint256 _maxSubsidyBps
    ) public onlyOwner nonReentrant {
        maxSubsidyBps = _maxSubsidyBps;
    }

    /**
     * @dev Sets the lower and upper bounds of target leverage
     * @param _lowerBoundTargetLeverageBps New lower bound of target leverage in basis points
     * @param _upperBoundTargetLeverageBps New upper bound of target leverage in basis points
     */
    function setLeverageBounds(
        uint32 _lowerBoundTargetLeverageBps,
        uint32 _upperBoundTargetLeverageBps
    ) public onlyOwner nonReentrant {
        if (
            _lowerBoundTargetLeverageBps >= targetLeverageBps ||
            targetLeverageBps >= _upperBoundTargetLeverageBps
        ) {
            revert InvalidLeverageBounds(
                _lowerBoundTargetLeverageBps,
                targetLeverageBps,
                _upperBoundTargetLeverageBps
            );
        }

        lowerBoundTargetLeverageBps = _lowerBoundTargetLeverageBps;
        upperBoundTargetLeverageBps = _upperBoundTargetLeverageBps;
    }

    /* Overrides to add leverage check */

    function maxDeposit(address _user) public view override returns (uint256) {
        // Don't allow deposit if the leverage is too imbalanced
        if (isTooImbalanced()) {
            return 0;
        }
        return super.maxDeposit(_user);
    }

    function maxMint(address _user) public view override returns (uint256) {
        // Don't allow mint if the leverage is too imbalanced
        if (isTooImbalanced()) {
            return 0;
        }
        return super.maxMint(_user);
    }

    function maxWithdraw(address _user) public view override returns (uint256) {
        // Don't allow withdraw if the leverage is too imbalanced
        if (isTooImbalanced()) {
            return 0;
        }
        return super.maxWithdraw(_user);
    }

    function maxRedeem(address _user) public view override returns (uint256) {
        // Don't allow redeem if the leverage is too imbalanced
        if (isTooImbalanced()) {
            return 0;
        }
        return super.maxRedeem(_user);
    }
}
