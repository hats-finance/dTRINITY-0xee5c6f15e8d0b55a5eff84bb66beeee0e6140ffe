// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RewardClaimable} from "../../rewards_claimable/RewardClaimable.sol";
import {DStakeRouterDLend} from "../DStakeRouterDLend.sol";
import {IDStakeCollateralVault} from "../interfaces/IDStakeCollateralVault.sol";
import {IDStableConversionAdapter} from "../interfaces/IDStableConversionAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Interface for the Aave/dLEND RewardsController
interface IDLendRewardsController {
    function claimRewardsOnBehalf(
        address[] calldata assets,
        uint256 amount,
        address user,
        address to,
        address reward
    ) external returns (uint256);

    function setClaimer(address user, address claimer) external;
}

/**
 * @title DStakeRewardManagerDLend
 * @notice Manages claiming of dLEND rewards earned by a specific StaticATokenLM wrapper
 *         (associated with a DStakeCollateralVault) and compounds dStable (provided by a caller)
 *         into the DStakeCollateralVault.
 * @dev Implements the RewardClaimable interface.
 *      The caller of `compoundRewards` provides dStable (the exchangeAsset). This contract
 *      then claims specified reward tokens earned by the `targetStaticATokenWrapper`.
 *      The net rewards (after treasury fee) are sent to the receiver specified by the caller.
 *      The initially provided dStable is then converted to the DStakeCollateralVault's
 *      default deposit asset and deposited into the vault.
 */
contract DStakeRewardManagerDLend is RewardClaimable {
    using SafeERC20 for IERC20;

    // --- State ---
    address public immutable dStakeCollateralVault; // The ultimate beneficiary vault
    DStakeRouterDLend public immutable dStakeRouter;
    IDLendRewardsController public dLendRewardsController; // Settable by admin
    address public immutable targetStaticATokenWrapper; // The StaticATokenLM instance earning rewards
    address public immutable dLendAssetToClaimFor; // The actual aToken in dLEND held by the wrapper

    // --- Events ---
    event DLendRewardsControllerUpdated(
        address oldController,
        address newController
    );
    event ExchangeAssetProcessed(
        address indexed vaultAsset,
        uint256 vaultAssetAmount,
        uint256 dStableCompoundedAmount
    );

    // --- Errors ---
    error InvalidRouter();
    error InvalidAdapter(address adapter);
    error AdapterReturnedUnexpectedAsset(address expected, address actual);
    error DefaultDepositAssetNotSet();
    error AdapterNotSetForDefaultAsset();
    // Errors also used/defined in RewardClaimable but declared here for clarity if inherited versions are not picked up
    error ZeroAddress();

    // --- Constructor ---
    constructor(
        address _dStakeCollateralVault,
        address _dStakeRouter,
        address _dLendRewardsController,
        address _targetStaticATokenWrapper,
        address _dLendAssetToClaimFor,
        address _treasury,
        uint256 _maxTreasuryFeeBps,
        uint256 _initialTreasuryFeeBps,
        uint256 _initialExchangeThreshold
    )
        RewardClaimable(
            IDStakeCollateralVault(_dStakeCollateralVault).dStable(), // exchangeAsset is dStable
            _treasury,
            _maxTreasuryFeeBps,
            _initialTreasuryFeeBps,
            _initialExchangeThreshold
        )
    {
        if (
            _dStakeCollateralVault == address(0) ||
            _dStakeRouter == address(0) ||
            _dLendRewardsController == address(0) ||
            _targetStaticATokenWrapper == address(0) ||
            _dLendAssetToClaimFor == address(0)
        ) {
            revert ZeroAddress();
        }
        if (exchangeAsset == address(0)) {
            revert InvalidRouter(); // dStable from collateral vault was zero, or vault address was wrong
        }

        dStakeCollateralVault = _dStakeCollateralVault;
        dStakeRouter = DStakeRouterDLend(_dStakeRouter);
        dLendRewardsController = IDLendRewardsController(
            _dLendRewardsController
        );
        targetStaticATokenWrapper = _targetStaticATokenWrapper;
        dLendAssetToClaimFor = _dLendAssetToClaimFor;

        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REWARDS_MANAGER_ROLE, msg.sender);
    }

    // --- RewardClaimable Overrides ---

    /**
     * @inheritdoc RewardClaimable
     * @dev Claims specified reward tokens from dLEND on behalf of the `targetStaticATokenWrapper`.
     *      Rewards are claimed to `_receiverForClaimedRawRewards` (typically address(this) when
     *      called from the base compoundRewards function).
     */
    function _claimRewards(
        address[] calldata _tokensToClaim,
        address _receiverForClaimedRawRewards
    ) internal virtual override returns (uint256[] memory rewardAmounts) {
        if (_tokensToClaim.length == 0) {
            revert ZeroRewardTokens();
        }
        if (_receiverForClaimedRawRewards == address(0)) {
            revert ZeroReceiverAddress();
        }

        rewardAmounts = new uint256[](_tokensToClaim.length);
        address[] memory assetsToClaimForPayload = new address[](1);
        assetsToClaimForPayload[0] = dLendAssetToClaimFor;

        for (uint256 i = 0; i < _tokensToClaim.length; i++) {
            address rewardToken = _tokensToClaim[i];
            if (rewardToken == address(0)) {
                revert ZeroAddress(); // Cannot claim zero address token
            }

            uint256 balanceBefore = IERC20(rewardToken).balanceOf(
                _receiverForClaimedRawRewards
            );

            // Claim all available amount of the specific reward token
            dLendRewardsController.claimRewardsOnBehalf(
                assetsToClaimForPayload, // Asset held by the wrapper in dLEND
                type(uint256).max, // Claim all
                targetStaticATokenWrapper, // User earning rewards is the wrapper
                _receiverForClaimedRawRewards,
                rewardToken // The reward token to claim
            );

            uint256 balanceAfter = IERC20(rewardToken).balanceOf(
                _receiverForClaimedRawRewards
            );
            rewardAmounts[i] = balanceAfter - balanceBefore;
        }
        return rewardAmounts;
    }

    /**
     * @inheritdoc RewardClaimable
     * @dev Processes the dStable (exchangeAsset) provided by the caller of `compoundRewards`.
     *      This dStable is converted into the DStakeCollateralVault's default deposit asset
     *      via the DStakeRouter and an appropriate adapter, and then deposited into the vault.
     *      The adapter is expected to transfer the compounded asset directly to dStakeCollateralVault.
     */
    function _processExchangeAssetDeposit(
        uint256 amountDStableToCompound
    ) internal virtual override {
        if (amountDStableToCompound == 0) {
            // RewardClaimable base function checks amount >= exchangeThreshold, implying amount > 0.
            return;
        }

        address defaultVaultAsset = dStakeRouter.defaultDepositVaultAsset();
        if (defaultVaultAsset == address(0)) {
            revert DefaultDepositAssetNotSet();
        }

        address adapterAddress = dStakeRouter.vaultAssetToAdapter(
            defaultVaultAsset
        );
        if (adapterAddress == address(0)) {
            revert AdapterNotSetForDefaultAsset();
        }

        IDStableConversionAdapter adapter = IDStableConversionAdapter(
            adapterAddress
        );

        // Approve the adapter to spend the dStable held by this contract
        IERC20(exchangeAsset).forceApprove(adapterAddress, amountDStableToCompound);

        // The adapter's convertToVaultAsset function is expected to:
        // 1. Pull `amountDStableToCompound` from this contract (msg.sender).
        // 2. Convert it to `defaultVaultAsset`.
        // 3. Deposit/transfer the `defaultVaultAsset` directly to the `dStakeCollateralVault`.
        (
            address convertedVaultAsset,
            uint256 convertedVaultAssetAmount
        ) = adapter.convertToVaultAsset(amountDStableToCompound);

        if (convertedVaultAsset != defaultVaultAsset) {
            revert AdapterReturnedUnexpectedAsset(
                defaultVaultAsset,
                convertedVaultAsset
            );
        }

        emit ExchangeAssetProcessed(
            convertedVaultAsset,
            convertedVaultAssetAmount,
            amountDStableToCompound
        );
    }

    /**
     * @notice Override to deposit exchangeAsset for wrapper positions before claiming rewards and distribute rewards
     */
    function compoundRewards(
        uint256 amount,
        address[] calldata rewardTokens,
        address receiver
    ) public override nonReentrant {
        // Validate input
        if (amount < exchangeThreshold) {
            revert ExchangeAmountTooLow(amount, exchangeThreshold);
        }
        if (receiver == address(0)) {
            revert ZeroReceiverAddress();
        }
        if (rewardTokens.length == 0) {
            revert ZeroRewardTokens();
        }

        // Transfer the exchange asset from the caller to this contract
        IERC20(exchangeAsset).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Deposit exchange asset to collateral vault to establish wrapper positions
        _processExchangeAssetDeposit(amount);

        // Emit compound event
        emit RewardCompounded(exchangeAsset, amount, rewardTokens);

        // Claim rewards from dLEND
        uint256[] memory rewardAmounts = _claimRewards(
            rewardTokens,
            address(this)
        );

        if (rewardAmounts.length != rewardTokens.length) {
            revert RewardAmountsLengthMismatch(
                rewardAmounts.length,
                rewardTokens.length
            );
        }

        // Distribute rewards: fee to treasury, net to receiver
        for (uint256 i = 0; i < rewardTokens.length; ++i) {
            uint256 rewardAmount = rewardAmounts[i];
            uint256 treasuryFee = getTreasuryFee(rewardAmount);
            if (treasuryFee > rewardAmount) {
                revert TreasuryFeeExceedsRewardAmount(
                    treasuryFee,
                    rewardAmount
                );
            }
            IERC20(rewardTokens[i]).safeTransfer(treasury, treasuryFee);
            IERC20(rewardTokens[i]).safeTransfer(
                receiver,
                rewardAmount - treasuryFee
            );
        }
    }

    // --- Admin Functions ---

    /**
     * @notice Sets the address of the dLEND RewardsController contract.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     * @param _newDLendRewardsController The address of the new rewards controller.
     */
    function setDLendRewardsController(
        address _newDLendRewardsController
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newDLendRewardsController == address(0)) {
            revert ZeroAddress();
        }
        address oldController = address(dLendRewardsController);
        dLendRewardsController = IDLendRewardsController(
            _newDLendRewardsController
        );
        emit DLendRewardsControllerUpdated(
            oldController,
            _newDLendRewardsController
        );
    }
}
