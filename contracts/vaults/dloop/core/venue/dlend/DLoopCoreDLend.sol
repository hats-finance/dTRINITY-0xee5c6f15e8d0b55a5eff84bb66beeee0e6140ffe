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

import {IPriceOracleGetter} from "./interface/IPriceOracleGetter.sol";
import {IPool as ILendingPool, DataTypes} from "./interface/IPool.sol";
import {IPoolAddressesProvider} from "./interface/IPoolAddressesProvider.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DLoopCoreBase} from "../../DLoopCoreBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RewardClaimable} from "contracts/vaults/rewards_claimable/RewardClaimable.sol";
import {IRewardsController} from "./interface/IRewardsController.sol";

/**
 * @title DLoopCoreDLend
 * @dev Read the documentation of DLoopCoreBase for more details
 *      - This contract implement dLEND-specific lending operations for DLoopCoreBase
 */
contract DLoopCoreDLend is DLoopCoreBase, RewardClaimable {
    using SafeERC20 for ERC20;

    /* Constants */

    uint8 public constant AAVE_PRICE_ORACLE_DECIMALS = 8;

    // Note that there is a vulnerability in stable interest rate mode, so we will never use it
    // See contracts/lending/core/protocol/libraries/types/DataTypes.sol
    uint256 public constant VARIABLE_LENDING_INTERST_RATE_MODE = 2; // 0 = NONE, 1 = STABLE, 2 = VARIABLE

    // Maximum percentage factor (100.00%)
    uint256 public constant PERCENTAGE_FACTOR = 1e4;

    /* State */

    IPoolAddressesProvider public immutable lendingPoolAddressesProvider;
    IRewardsController public immutable dLendRewardsController;
    address public immutable dLendAssetToClaimFor;
    address public immutable targetStaticATokenWrapper;

    /* Errors */

    error ZeroAddress();

    /**
     * @dev Constructor for the DLoopCoreDLend contract
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _collateralToken Address of the collateral token
     * @param _debtToken Address of the debt token
     * @param _lendingPoolAddressesProvider Address of the lending pool addresses provider
     * @param _targetLeverageBps Target leverage in basis points
     * @param _lowerBoundTargetLeverageBps Lower bound of target leverage in basis points
     * @param _upperBoundTargetLeverageBps Upper bound of target leverage in basis points
     * @param _maxSubsidyBps Maximum subsidy in basis points
     * @param _rewardsController Address of the dLEND rewards controller
     * @param _dLendAssetToClaimFor Address of the dLEND asset to claim for
     * @param _targetStaticATokenWrapper Address of the target static aToken wrapper
     * @param _treasury Address of the treasury
     * @param _maxTreasuryFeeBps Maximum treasury fee in basis points
     * @param _initialTreasuryFeeBps Initial treasury fee in basis points
     */
    constructor(
        string memory _name,
        string memory _symbol,
        ERC20 _collateralToken,
        ERC20 _debtToken,
        IPoolAddressesProvider _lendingPoolAddressesProvider,
        uint32 _targetLeverageBps,
        uint32 _lowerBoundTargetLeverageBps,
        uint32 _upperBoundTargetLeverageBps,
        uint256 _maxSubsidyBps,
        IRewardsController _rewardsController,
        address _dLendAssetToClaimFor,
        address _targetStaticATokenWrapper,
        address _treasury,
        uint256 _maxTreasuryFeeBps,
        uint256 _initialTreasuryFeeBps,
        uint256 _initialExchangeThreshold
    )
        DLoopCoreBase(
            _name,
            _symbol,
            _collateralToken,
            _debtToken,
            _targetLeverageBps,
            _lowerBoundTargetLeverageBps,
            _upperBoundTargetLeverageBps,
            _maxSubsidyBps
        )
        RewardClaimable(
            address(_debtToken),
            _treasury,
            _maxTreasuryFeeBps,
            _initialTreasuryFeeBps,
            _initialExchangeThreshold
        )
    {
        // Always use the debt token as the exchange asset in reward claim logic
        lendingPoolAddressesProvider = _lendingPoolAddressesProvider;
        dLendRewardsController = _rewardsController;
        dLendAssetToClaimFor = _dLendAssetToClaimFor;
        targetStaticATokenWrapper = _targetStaticATokenWrapper;

        if (getLendingOracle().BASE_CURRENCY() != address(0)) {
            revert("Invalid price oracle base currency");
        }

        uint256 oracleUnit = getLendingOracle().BASE_CURRENCY_UNIT();

        if (oracleUnit != 10 ** AAVE_PRICE_ORACLE_DECIMALS) {
            revert("Invalid price oracle unit");
        }
    }

    /**
     * @inheritdoc DLoopCoreBase
     * @return address[] Additional rescue tokens
     */
    function _getAdditionalRescueTokensImplementation()
        internal
        view
        override
        returns (address[] memory)
    {
        DataTypes.ReserveData memory reserveData = _getReserveData(
            address(collateralToken)
        );
        address[] memory additionalRescueTokens = new address[](3);
        additionalRescueTokens[0] = reserveData.aTokenAddress;
        additionalRescueTokens[1] = reserveData.variableDebtTokenAddress;
        additionalRescueTokens[2] = reserveData.stableDebtTokenAddress;
        return additionalRescueTokens;
    }

    /**
     * @dev Gets the asset price from the oracle
     * @param asset Address of the asset
     * @return uint256 Price of the asset
     */
    function _getAssetPriceFromOracleImplementation(
        address asset
    ) internal view override returns (uint256) {
        return getLendingOracle().getAssetPrice(asset);
    }

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
    ) internal override {
        ILendingPool lendingPool = getLendingPool();

        // Approve the lending pool to spend the token
        ERC20(token).forceApprove(address(lendingPool), amount);

        // Supply the token to the lending pool
        lendingPool.supply(token, amount, onBehalfOf, 0);
    }

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
    ) internal override {
        getLendingPool().borrow(
            token,
            amount,
            VARIABLE_LENDING_INTERST_RATE_MODE,
            0,
            onBehalfOf
        );
    }

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
    ) internal override {
        ILendingPool lendingPool = getLendingPool();

        // Approve the lending pool to spend the token
        ERC20(token).forceApprove(address(lendingPool), amount);

        // Repay the debt
        lendingPool.repay(
            token,
            amount,
            VARIABLE_LENDING_INTERST_RATE_MODE,
            onBehalfOf
        );
    }

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
    ) internal override {
        getLendingPool().withdraw(token, amount, onBehalfOf);
    }

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
        override
        returns (uint256 totalCollateralBase, uint256 totalDebtBase)
    {
        (totalCollateralBase, totalDebtBase, , , , ) = getLendingPool()
            .getUserAccountData(user);
        return (totalCollateralBase, totalDebtBase);
    }

    /* Helper functions */

    /**
     * @dev Gets the lending oracle
     * @return IPriceOracleGetter The lending oracle interface
     */
    function getLendingOracle() public view returns (IPriceOracleGetter) {
        return
            IPriceOracleGetter(lendingPoolAddressesProvider.getPriceOracle());
    }

    /**
     * @dev Gets the lending pool
     * @return ILendingPool The lending pool interface
     */
    function getLendingPool() public view returns (ILendingPool) {
        return ILendingPool(lendingPoolAddressesProvider.getPool());
    }

    /**
     * @dev Gets the lending pool address
     * @return address The lending pool address
     */
    function getLendingPoolAddress() public view returns (address) {
        return address(getLendingPool());
    }

    /**
     * @dev Gets the oracle address
     * @return address The oracle address
     */
    function getOracleAddress() public view returns (address) {
        return address(getLendingOracle());
    }

    /**
     * @dev Gets the reserve data for a token
     * @param tokenAddress The address of the token
     * @return DataTypes.ReserveData The reserve data
     */
    function _getReserveData(
        address tokenAddress
    ) internal view returns (DataTypes.ReserveData memory) {
        return getLendingPool().getReserveData(tokenAddress);
    }

    /**
     * @dev Gets the DToken address for a token
     * @param tokenAddress The address of the token
     * @return address The DToken address
     */
    function _getDTokenAddress(
        address tokenAddress
    ) internal view returns (address) {
        return _getReserveData(tokenAddress).aTokenAddress;
    }

    /**
     * @dev Gets the DToken balance of the vault
     * @param tokenAddress The address of the token
     * @return uint256 The DToken balance of the vault
     */
    function getDTokenBalance(
        address tokenAddress
    ) public view returns (uint256) {
        return ERC20(_getDTokenAddress(tokenAddress)).balanceOf(address(this));
    }

    /* RewardClaimable functions */

    /**
     * @dev Claims multiple rewards
     * @param rewardTokens The reward tokens to claim
     * @param receiver The address to receive the claimed rewards
     * @return rewardAmounts The amount of rewards claimed for each token (have the same length as the tokens array)
     */
    function _claimRewards(
        address[] calldata rewardTokens,
        address receiver
    ) internal override returns (uint256[] memory rewardAmounts) {
        if (rewardTokens.length == 0) {
            revert ZeroRewardTokens();
        }
        if (receiver == address(0)) {
            revert ZeroReceiverAddress();
        }

        rewardAmounts = new uint256[](rewardTokens.length);
        address[] memory assetsToClaimForPayload = new address[](1);
        assetsToClaimForPayload[0] = dLendAssetToClaimFor;

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            if (rewardToken == address(0)) {
                revert ZeroAddress(); // Cannot claim zero address token
            }

            uint256 balanceBefore = ERC20(rewardToken).balanceOf(receiver);

            // Claim all available amount of the specific reward token
            dLendRewardsController.claimRewardsOnBehalf(
                assetsToClaimForPayload, // Asset held by the wrapper in dLEND
                type(uint256).max, // Claim all
                targetStaticATokenWrapper, // User earning rewards is the wrapper
                receiver,
                rewardToken // The reward token to claim
            );

            uint256 balanceAfter = ERC20(rewardToken).balanceOf(receiver);
            rewardAmounts[i] = balanceAfter - balanceBefore;
        }
        return rewardAmounts;
    }

    /**
     * @dev Processes the exchange asset deposit from the caller
     * @param amount The amount of exchange asset to deposit
     */
    function _processExchangeAssetDeposit(uint256 amount) internal override {
        // As the exchange asset is the debt token, we use it to repay the debt,
        // which means to reduce the borrowing interest to be paid
        _repayDebtToPoolImplementation(exchangeAsset, amount, address(this));
    }
}
