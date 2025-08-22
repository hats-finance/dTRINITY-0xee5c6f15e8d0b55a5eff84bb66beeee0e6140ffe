# **dTRINITY Audit Competition on Hats.finance** 


## Introduction to Hats.finance


Hats.finance builds autonomous security infrastructure for integration with major DeFi protocols to secure users' assets. 
It aims to be the decentralized choice for Web3 security, offering proactive security mechanisms like decentralized audit competitions and bug bounties. 
The protocol facilitates audit competitions to quickly secure smart contracts by having auditors compete, thereby reducing auditing costs and accelerating submissions. 
This aligns with their mission of fostering a robust, secure, and scalable Web3 ecosystem through decentralized security solutions​.

## About Hats Audit Competition


Hats Audit Competitions offer a unique and decentralized approach to enhancing the security of web3 projects. Leveraging the large collective expertise of hundreds of skilled auditors, these competitions foster a proactive bug hunting environment to fortify projects before their launch. Unlike traditional security assessments, Hats Audit Competitions operate on a time-based and results-driven model, ensuring that only successful auditors are rewarded for their contributions. This pay-for-results ethos not only allocates budgets more efficiently by paying exclusively for identified vulnerabilities but also retains funds if no issues are discovered. With a streamlined evaluation process, Hats prioritizes quality over quantity by rewarding the first submitter of a vulnerability, thus eliminating duplicate efforts and attracting top talent in web3 auditing. The process embodies Hats Finance's commitment to reducing fees, maintaining project control, and promoting high-quality security assessments, setting a new standard for decentralized security in the web3 space​​.

## dTRINITY Overview

The world_s first subsidized stablecoin protocol that pays interest rebates to borrowers instead of yield.

## Competition Details


- Type: A public audit competition hosted by dTRINITY
- Duration: 3 weeks
- Maximum Reward: $99,980.9
- Submissions: 328
- Total Payout: $95,174.82 distributed among 44 participants.

## Scope of Audit

## Project overview

dTRINITY is a stablecoin ecosystem that pays people who use the stablecoins productively. The stablecoins in the ecosystem are collectively referred to as dSTABLEs, like dUSD and dS. Each dSTABLE is backed by yield bearing and non-yield bearing assets. The yield generated from the reserve is used to incentivize active users of the stablecoin, such as borrowers on dLEND, our Aave V3 fork (which is not in scope of this audit). The main focus of this audit are the two new ERC4626 vaults we are launching, dLOOP and dSTAKE. dLOOP is a yield looping vault built on top of dLEND. dSTAKE is a lending vault also built on top of dLEND.

## Audit competition scope

```
| File Path                                                                                 | nSLOC |
| ----------------------------------------------------------------------------------------- | ----- |
| contracts/common/SupportsWithdrawalFee.sol                                                | 49    |
| contracts/common/RescuableVault.sol                                                       | 16    |
| contracts/common/SwappableVault.sol                                                       | 67    |
| contracts/odos/OdosSwapUtils.sol                                                          | 29    |
| contracts/dlend/core/misc/AaveOracle.sol                                                  | 62    |
| contracts/dstable/AmoVault.sol                                                            | 52    |
| contracts/dstable/AmoManager.sol                                                          | 215   |
| contracts/dstable/CollateralHolderVault.sol                                               | 76    |
| contracts/dstable/CollateralVault.sol                                                     | 110   |
| contracts/dstable/Issuer.sol                                                              | 103   |
| contracts/dstable/OracleAware.sol                                                         | 24    |
| contracts/dstable/RedeemerWithFees.sol                                                    | 187   |
| contracts/oracle_aggregator/helper/ChainlinkDecimalConverter.sol                          | 35    |
| contracts/oracle_aggregator/interface/api3/BaseAPI3Wrapper.sol                            | 35    |
| contracts/oracle_aggregator/interface/chainlink/BaseChainlinkWrapper.sol                  | 37    |
| contracts/oracle_aggregator/OracleAggregator.sol                                          | 62    |
| contracts/oracle_aggregator/wrapper/API3CompositeWrapperWithThresholding.sol              | 121   |
| contracts/oracle_aggregator/wrapper/HardPegOracleWrapper.sol                              | 22    |
| contracts/oracle_aggregator/wrapper/API3Wrapper.sol                                       | 27    |
| contracts/oracle_aggregator/wrapper/API3WrapperWithThresholding.sol                       | 37    |
| contracts/oracle_aggregator/wrapper/RedstoneChainlinkCompositeWrapperWithThresholding.sol | 122   |
| contracts/oracle_aggregator/wrapper/RedstoneChainlinkWrapper.sol                          | 28    |
| contracts/oracle_aggregator/wrapper/RedstoneChainlinkWrapperWithThresholding.sol          | 40    |
| contracts/oracle_aggregator/wrapper/ThresholdingUtils.sol                                 | 13    |
| contracts/vaults/dloop/core/venue/dlend/DLoopCoreDLend.sol                                | 171   |
| contracts/vaults/dloop/core/DLoopCoreBase.sol                                             | 734   |
| contracts/vaults/dloop/core/venue/dlend/interface/types/DataTypes.sol                     | 204   |
| contracts/vaults/dloop/periphery/DLoopDepositorBase.sol                                   | 253   |
| contracts/vaults/dloop/periphery/DLoopRedeemerBase.sol                                    | 223   |
| contracts/vaults/dloop/periphery/venue/odos/DLoopDepositorOdos.sol                        | 25    |
| contracts/vaults/dloop/periphery/venue/odos/DLoopRedeemerOdos.sol                         | 25    |
| contracts/vaults/dloop/periphery/venue/odos/OdosSwapLogic.sol                             | 21    |
| contracts/vaults/dstake/DStakeCollateralVault.sol                                         | 100   |
| contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter.sol                        | 101   |
| contracts/vaults/dstake/DStakeRouterDLend.sol                                             | 286   |
| contracts/vaults/dstake/DStakeToken.sol                                                   | 120   |
| contracts/vaults/dstake/rewards/DStakeRewardManagerDLend.sol                              | 194   |
| contracts/vaults/rewards_claimable/RewardClaimable.sol                                    | 153   |
| contracts/vaults/vesting/ERC20VestingNFT.sol                                              | 17    |
```

## High severity issues


- **Vulnerability in DStakeToken contract allows unauthorized withdrawals and redeems**

  The DStakeToken contract features a vulnerability within its `_withdraw` function, which can be indiscriminately called by any external user. This lack of restriction allows unauthorized users to withdraw funds without verification of the `msg.sender` or their allowance. The problem emerges prominently if an attacker exploits this flaw by invoking the `withdraw` or `redeem` functions with an account that has an existing balance, diverting the funds to an address under their control. 

To prevent such unauthorized withdrawals, a solution is proposed that involves implementing a pattern similar to the `_withdraw` function in the DPoolVaultLP contract. This approach includes an additional check to ensure that if the caller is not the account owner, the system will handle allowance spending accordingly by calling `_spendAllowance(owner, caller, shares)`. A proof of concept (PoC) and recommended test cases have been added to the code to validate the implementation and ensure it reverts unauthorized calls correctly. This improvement aims to enhance the overall security of the DStakeToken contract by mitigating potential exploitation scenarios. The development team acknowledges this oversight and is actively investigating.


  **Link**: [Issue #2](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/2)

## Medium severity issues


- **dLoop Protocol Vulnerability Allows Profitable Exploitation Through Minor Leverage Deviations**

  The dLoop protocol faces a critical design flaw in its rebalancing mechanism that offers subsidies to users for minor deviations from target leverage (e.g., from 2.99X to 3X). This design flaw allows users to exploit the system repeatedly, extracting value even during minimal leverage deviations. Because the subsidy is proportional to the protocol's total value locked (TVL) and there's no minimum deviation threshold, the protocol is vulnerable to frequent small-profit exploits, especially with low gas costs in planned deployment environments like Sonic. This creates a repetitive and potentially significant economic drain on the protocol. Despite proposed mitigations like capping subsidy payouts and introducing minimum-deviation checks, concerns remain over its architectural vulnerabilities under normal market volatility, potentially leading to protocol insolvency.


  **Link**: [Issue #314](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/314)


- **Permissive deallocation in `deallocateAmo` may cause accounting inaccuracies and DoS**

  The `deallocateAmo` function permits the removal of `dstableAmount` from any AMO vault without verifying if the vault had a prior allocation. This introduces a vulnerability where the global `totalAllocated` counter could be reduced incorrectly, especially when deallocating from a vault with no previous allocation or that is currently inactive. As a result, the `totalAllocated` becomes less than the actual allocations across vaults, causing discrepancies in accounting and potentially leading to a situation where legitimate vaults face reversion upon trying to deallocate due to perceived insufficient `totalAllocated`. To remediate this, deallocations should either be prohibited from zero-allocated vaults or should not affect the `totalAllocated` counter if the vault has zero allocation. This flaw can cause denial-of-service (DoS) conditions for properly allocated vaults, as they may become unable to access their funds.


  **Link**: [Issue #42](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/42)


- **Division by Zero Bug on First Collateral Withdrawal in Vault**

  A potential issue has been identified where, if a user tries to remove collateral from a vault for the first time without any existing debt, the withdrawal attempt can fail due to a division by zero error. This situation arises because the leverage before debt repayment is calculated as zero, which subsequently leads to a division by zero during the calculation process. As a result, the initial depositor's funds could become locked. The proposed solution involves implementing a check to bypass the repayment calculation when leverage is zero, or preventing withdrawals until debt has been created. Although classified as medium severity, practical exploitability is low since triggering the issue requires an unrealistic attack scenario. An update and expanded testing will be implemented to address this occurrence.


  **Link**: [Issue #15](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/15)

## Low severity issues


- **Withdrawal Fee Overflow Vulnerability Due to Large Asset Amount in DStable**

  The withdrawal fee calculation for DStable tokens may result in an overflow and revert in cases of massive withdrawals, such as when using a flash loan. This occurs because the current fee calculation method can overflow with large values. Switching to 512-bit multiplication using `oz Math.mulDiv()` is recommended to prevent this issue. Although the scenario is unlikely, it could lead to a loss of withdrawal fee profits for the protocol.


  **Link**: [Issue #332](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/332)


- **Critical Logic Flaw Causes DOS in Token Transfer During Leverage Decrease**

  The `DLoopDecreaseLeverageBase.sol` contract has a flaw in handling leftover collateral tokens during a leverage decrease operation. The logic mistakenly transfers all collateral to the `dLoopCore` contract before transferring the user's entitled collateral, causing a denial of service (DOS) as the contract's balance becomes zero. Reordering these transfers resolves the issue.


  **Link**: [Issue #324](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/324)


- **Interest Redirection to Rebalancing Subsidies Hinders Protocol Profitability**

  The `DLoopCoreDLend` vault faces a problem where accrued interest on collateral is redirected to rebalancing subsidies, depleting the vault's value and undermining profitability. This occurs because interest-induced leverage deviations trigger rebalancing, which is subsidized using the vault's own assets. Over time, this hinders sustainable growth.


  **Link**: [Issue #323](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/323)


- **Potential Leverage Manipulation in DLoopCoreBase Through CompoundRewards Function**

  The `DLoopCoreBase` contract's subsidy mechanism, designed to reward users for rebalancing a vault's leverage, can be exploited through the `compoundRewards()` function. Users might artificially destabilize the vault, claim subsidies, and profit by rebalancing leverage, despite being the cause of the imbalance. Safeguards are recommended to prevent this manipulation.


  **Link**: [Issue #321](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/321)


- **Reduce Contract Size and Deployment Costs by Removing Unused Functions in RedeemerBase**

  A contract contains many unused internal functions that inflate its size and deployment costs. These functions are redundant as their logic is directly implemented within a single function. Removing these unnecessary functions will streamline the code, reduce costs, and improve overall code quality without altering existing behavior.


  **Link**: [Issue #310](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/310)


- **Potential Unlimited Minting of Unbacked Tokens by Incentives Manager Role**

  The `issueUsingExcessCollateral()` function in the `Issuer` contract allows addresses with the `INCENTIVES_MANAGER_ROLE` to mint `dStable` tokens to the `amoManager` contract without real collateral backing. This could lead to unlimited unbacked minting, as minted tokens are deducted in supply calculations, bypassing collateral checks. The suggestion is to prevent minting directly to the `amoManager` to address this flaw.


  **Link**: [Issue #309](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/309)


- **Dynamic leverage calculation issues cause debt errors and potential withdrawal blocks**

  The issue revolves around inaccuracies in debt distribution due to precision errors from computing leverage in basis points (bps) within a lending protocol. This error causes minor debt shifting between users, impacting their ability to withdraw. Although this results in a slight imbalanced leverage, the protocol's safety is preserved, and the issue's impact is minimal and manageable. The potential solution includes increasing computation precision to avoid these minor discrepancies.


  **Link**: [Issue #306](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/306)


- **Flaw in Vault Asset Calculation Leads to Overvalued Share Pricing**

  The function `DLoopCoreBase.totalAssets()` only accounts for collateral, ignoring debt, leading to vault overvaluation. This flaw affects ERC4626 share pricing functions, causing systematic overvaluation without direct financial loss. However, it becomes problematic when linked with leftover token handling, resulting in economic loss through miscalculated share benefit. A fix is needed to correct misleading valuations.


  **Link**: [Issue #300](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/300)


- **Unnecessary Gas-Consuming Call in convertToVaultAsset Function**

  The `convertToVaultAsset()` function in `WrappedDLendConversionAdapter.sol` has an unnecessary call to `previewConvertToVaultAsset()`, whose results are immediately overwritten. This wastes gas and increases transaction costs without posing any direct security risk, possibly confusing future maintainers. Reducing this redundancy could optimize gas usage.


  **Link**: [Issue #289](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/289)


- **Potential Loss Due to Zero Shares on Edge Case Deposit in DStakeToken**

  In the `DStakeToken` contract, a withdrawal fee leaves a residual balance that can result in new users receiving 0 shares for small deposits. The recommendation is to have the `_withdraw()` method revert when shares equal zero. However, it's argued that the OpenZeppelin contract logic prevents this, ensuring even small deposits always yield non-zero shares. The issue is seen as mathematically correct but has a limited real-world impact, as the financial risk is minimal and there is no exploit for profit. A fix is recommended for improved protocol design.


  **Link**: [Issue #286](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/286)


- **Missing Input Restriction Allows Token Theft in DLoopDepositorBase Deposit Function**

  A vulnerability in the `DLoopDepositorBase::deposit()` function allows attackers to exploit unrestricted `dLoopCore` address inputs. This flaw permits malicious actors to create fake contracts, call the deposit function, and transfer leftover tokens to these fake contracts, posing a risk of token theft. The proposed fix includes adding input checks to prevent unauthorized fund transfers. Due to operational factors, the practical impact is limited, and most deployments only risk a small, dust-level token amount. However, this remains an underlying bug that needs addressing.


  **Link**: [Issue #279](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/279)


- **Systematic Misappropriation of Debt Tokens Affects User Deposits in DLoop Contracts**

  The DLoopDepositorBase.deposit() function misappropriates leftover debt tokens due to market fluctuations. This affects users by transferring these valuable tokens to a vault, leading to a systematic loss across all deposit transactions. The solution proposed involves adjusting the function to return tokens to users. However, challenges in implementing this without disrupting the system were highlighted, initiating further discussions on severity and user impact.


  **Link**: [Issue #275](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/275)


- **Fee Calculation Error in Withdraw Function Causes Unnecessary Reverts**

  The withdrawal function faced issues due to incorrect fee handling, leading to unwarranted reverts when exit fees were applied. This occurred because the gross asset amount was compared with the maximum withdrawable amount without accounting for fees. The fix involved following OpenZeppelin's fee structure for ERC-4626, checking shares against `maxRedeem(owner)`, and ensuring the net withdrawal amount was correct after fees. The impact was on correct accounting and user understanding but wasn't a severe exploit.


  **Link**: [Issue #273](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/273)


- **Potential DoS or Fund Loss in DLoopCoreBase Deposit Method**

  In the `DLoopCoreBase::_deposit()` method, a potential issue arises when `observedDiffBorrow` differs from the intended amount due to `BALANCE_DIFF_TOLERANCE`. If the borrowed amount is inadequate, the function may fail when attempting to transfer funds to the receiver, causing a denial of service (DoS). Conversely, excessive funds will remain in the contract, potentially leading to loss. However, in the current environment, such scenarios are considered unlikely due to precise transfer mechanisms and token restrictions.


  **Link**: [Issue #233](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/233)


- **Constructor Role Assignment Issue Prevents Contract Setup in AmoVault.sol**

  There is a potential setup issue in the `AmoVault` contract where the constructor sets an `_admin` role but calls `approveAmoManager()`, which requires the caller to have `DEFAULT_ADMIN_ROLE`. If `msg.sender` is not `_admin`, the function fails, preventing the contract from being set up properly.


  **Link**: [Issue #230](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/230)


- **Fixing incorrect debt token calculation for accurate leverage rebalancing**

  The current formula used in `_getRequiredDebtTokenAmountToRebalance` is incorrect, preventing the contract position from resetting to the desired 3X leverage. The function reduces leverage but fails to reach the target accurately, causing incomplete rebalancing. While the increase leverage calculation is accurate, the decrease function's shortcomings affect the precise recalibration. The issue does not pose a threat to user or caller funds.


  **Link**: [Issue #223](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/223)


- **Confusion arises from zero return in getRemainingVestingTime function for non-existent tokens**

  The `getRemainingVestingTime()` function in the `ERC20VestingNFT` contract currently returns zero when the vesting is complete or when the token does not exist. This can create confusion for users and third-party protocols. The recommendation is to modify the function to revert if the token does not exist, enhancing clarity.


  **Link**: [Issue #216](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/216)


- **Double-counting Collateral in increaseLeverage Function Causes Incorrect Logic Path**

  The leverage increase function mistakenly counts user collateral twice, considering both a newly transferred amount and the vault's existing balance. This results in an incorrect logic path, potentially skipping necessary flash loans, leading to leverage mismatches and economic inefficiencies. A suggested fix involves recalculating using only the vault's current balance. Although the issue isn't currently within audit scope, it is acknowledged for its potential impact.


  **Link**: [Issue #192](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/192)


- **Flashloan Leveraging Error Causes Incorrect Deposit Reversion and Potential Fund Loss**

  There is a discrepancy in leverage calculations between the flashloan code and the vault, leading to deposit errors. The flashloan assumes a fixed leverage target, while the vault uses the current leverage. This mismatch can cause erroneous transaction reversion, incorrect share minting, and potential incorrect debt handling. A fix is being developed to adjust the leverage calculation process, ensuring consistency between the peripheral and core operations and addressing the issue effectively.


  **Link**: [Issue #149](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/149)


- **Incorrect strict equality check in swap output causes function to revert**

  A potential issue exists where the `_swapExactOutput` function may revert if the swapper contract sends slightly more tokens (by 1 or 2 wei) than expected. This unintended behavior could cause denial of service in the deposit function. While funds aren't at risk, a fix is planned to handle minor discrepancies without enforcing strict equality.


  **Link**: [Issue #128](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/128)


- **Repay function vulnerability allows denial of service on user withdrawals**

  The repay function in a lending pool contract is susceptible to a denial-of-service attack. An attacker can exploit a small rounding tolerance in the repay logic, causing a user's withdrawal to fail by paying a tiny amount (e.g., 2 wei) on the vault's behalf. This results in a mismatch exceeding the balance tolerance, locking users' funds. A temporary mitigation involves users redeeming in smaller increments, while a future patch will permanently fix this issue by capping the repay amount to avoid edge cases.


  **Link**: [Issue #127](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/127)


- **Vulnerability in Share to Asset Calculation Affects Leverage and Withdrawals**

  The issue highlights a vulnerability where attackers can manipulate the Share to Asset calculation in a vault system, affecting leverage functions and withdrawals. By supplying an incorrect type of collateral, attackers can inflate the vault's perceived holdings, leading to an imbalance that can permanently deny service or prevent withdrawal for other users. The attacking process can be repeated until the system is vastly imbalanced. The proposed fix involves querying the actual collateral balance directly and using a public contract to counteract malicious deposits, along with an on-chain switch to enforce collateral type restrictions.


  **Link**: [Issue #119](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/119)


- **Frontrunning Attack on Dloop Vault Causes Permanent Contract Failure**

  An attacker can disrupt the Dloop vault's functionality by front-running the first deposit with a small collateral amount, causing an invalid leverage calculation. This would prevent any future deposits, bricking the vault. The issue results from external donations to the contract without permissions, showcasing a critical vulnerability in the leverage calculation mechanism.


  **Link**: [Issue #113](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/113)


- **Issue with Removing Deprecated Collateral Tokens from Rescue List in RescuableVault**

  RescuableVault#rescueToken is designed to retrieve tokens accidentally sent to a contract, but does not include collateral or debt tokens. However, if a collateral token is deprecated, it becomes permanently unrescuable since there's no method to remove it from `existingCollateralTokens`. This issue is recognized, but impacts only mistakenly sent tokens, not user funds or protocol operations. Future updates might address this limitation.


  **Link**: [Issue #112](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/112)


- **RedeemerWithFees Oracle Update Causes Incorrect dstableAmount Calculation**

  RedeemerWithFees uses an immutable variable, BASE_UNIT, to calculate dstable token amounts. Changes to the oracle can lead to BASE_UNIT inconsistencies, resulting in incorrect token calculations in the redeem function, potentially allowing unintended redemptions. A recommended fix is to modify calculations to use the current oracle's BASE_CURRENCY_UNIT.


  **Link**: [Issue #108](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/108)


- **Unverified Collateral Asset in Redeemer Contract Allows Unintended Access**

  The redemption function in a contract allows users to retrieve collateral tokens equivalent to their dStable assets. However, it fails to verify if the collateral asset is supported by the `CollateralVault`. This oversight enables unwanted access to disallowed collateral, creating a deviation from intended contract behavior without an incentive to exploit it.


  **Link**: [Issue #100](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/100)


- **Incorrect calculation causes underflow during leverage adjustments, leading to reverts**

  A leverage calculation bug causes a function to revert due to underflow when users attempt to correct over-leverage, leading to a potential temporary denial-of-service. The issue arises from subtracting before adding in the calculation, which can temporarily freeze the function without risking asset loss. The recommended fix involves rearranging the arithmetic order. Despite being classified as a low-severity issue, concerns were raised about potential risks like liquidation, prompting debates on the severity level.


  **Link**: [Issue #97](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/97)


- **Lack of Event Emissions in DLoopCoreBase Obscures Off-Chain State Tracking**

  The `DLoopCoreBase` abstract contract, used in leveraged lending and borrowing on dLend, lacks necessary event logging for its functions, making off-chain tracking of state changes difficult. This includes admin setter functions and leverage adjustments. Attachments include a proof of concept and an optional revised code. The issue has since been addressed in subsequent updates.


  **Link**: [Issue #92](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/92)


- **Hardcoded Reward Address Issue in Dlendcore Contract Limits Updates**

  The Dlendcore contract faces an issue where the reward incentive address is hardcoded, preventing updates if the lending pool decides to change it. This hardcoding renders reward claims ineffective once the address changes, though principal and interest accruals remain secure. The recommended fix involves adding an admin function to allow updates, ensuring flexibility and continued reward collection.


  **Link**: [Issue #90](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/90)


- **Potential Denial of Service in Deposit Function Due to Rounding Error**

  The vault contract could experience a denial of service (DoS) issue during deposit transactions due to a lending contract rounding error. If the contract requests 10e18 tokens but receives 1 wei less, the subsequent token transfer fails due to an insufficient balance. Although current integrations prevent this scenario, future updates or different protocols could reintroduce the vulnerability. A fix has been proposed.


  **Link**: [Issue #85](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/85)


- **ERC20VestingNFT Lacks Overridden tokenURI() for Dynamic Metadata Display**

  The ERC20VestingNFT smart contract utilizes NFTs to represent vesting positions of ERC-20 tokens. However, due to the lack of an overridden tokenURI() function, these NFTs display generic or missing metadata. This hampers user experience, transparency, and tracking of vesting progress, potentially leading to user confusion and decreased confidence in the system.


  **Link**: [Issue #81](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/81)


- **Misconfiguration of Withdrawal Fee Scale Leads to Fee Misunderstandings**

  In the SupportsWithdrawalFee contract, part of DStakeToken, a misalignment in the use of withdrawal fee percentages results in significantly undercharged fees—100 times less than intended. This discrepancy arises from the use of different scales for basis points, causing confusion about the fee's actual scale when using setWithdrawalFee according to documentation.


  **Link**: [Issue #76](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/76)


- **Withdrawals in the DStakeToken revert due to surplus deposit issue**

  The `DStakeToken::withdraw()` function may trigger a denial of service (DoS). When withdrawing, a surplus of dSTABLE might be generated and needs to be redeposited. This redeposit could revert if the surplus is too small or if the underlying market is frozen or paused—causing the entire withdraw operation to revert.


  **Link**: [Issue #73](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/73)


- **IncreaseLeverage function does not verify actual leverage after execution**

  The `increaseLeverage()` function predicts leverage increases but doesn't verify actual leverage after execution, creating potential over-leverage situations, particularly in high-utilization pools. This leads to liquidation risks in volatile markets, endangering depositors' assets. A post-action check is proposed to ensure actual leverage complies with the target limit.


  **Link**: [Issue #63](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/63)


- **Potential Security Risk from Not Revoking Old AmoManager Allowance After Replacement**

  In the `AmoVault` contract, changing an AmoManager doesn't revoke permissions for the old manager, allowing potential unauthorized access to funds. This poses a security risk if the previous manager is compromised. The proposed solution is to revoke old allowances before approving a new manager. While considered a low-probability issue, governance protocols can mitigate it by following best practices.


  **Link**: [Issue #37](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/37)


- **Enhancing Router Adapter Updates to Prevent TVL Calculation Errors**

  The `totalValueInDStable` function retrieves each asset's adapter from the router. If governance changes the adapter without updating the vault's supported assets, it may skip the asset or use an outdated adapter, leading to incorrect TVL. Recommended solutions include emitting events on adapter changes and ensuring all supported assets have non-zero adapters.


  **Link**: [Issue #25](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/25)


- **Vulnerability in DStakeCollateralVault allows removal avoidance by sending 1 wei token**

  A vulnerability in the `removeSupportedAsset()` function of the `DStakeCollateralVault` contract allows it to be bypassed by sending a minimal amount of token, hindering governance operations. The issue causes only a temporary disruption, but it can be resolved through code changes such as internal balance accounting or removing the balance check. While user operations remain unaffected, the bug impacts governance functionality, suggesting a medium severity classification.


  **Link**: [Issue #23](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/23)


- **Issue in OdosSwapLogic.swapExactOutput Causes Transaction Reverts and Flash-Loan Locking**

  `OdosSwapLogic.swapExactOutput()` improperly assumes it receives the output amount, while it actually gets the input amount spent. This logic error often causes transaction reverts, affecting functions like `deposit` and `redeem`, potentially stalling flash-loans. The solution involves adjusting variable names and logic to reflect actual data. The impact is mainly inconvenience rather than loss, with a fix forthcoming.


  **Link**: [Issue #17](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/17)


- **ERC-20 Tokens Not Fully Compatible with EIP20 Standard Cause Reverts**

  The report highlights potential issues with certain tokens not adhering to the EIP-20 standard, causing `approve` functions to return false or revert transactions. Although the contracts involved do not hold user funds, token incompatibility can lead to transaction reversion. The development team acknowledges the issue and plans to enhance robustness by adding a return-value check to improve future interaction with non-standard tokens.


  **Link**: [Issue #9](https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/9)



## Conclusion

The audit of dTRINITY's Hats.finance competition identified several security issues within various smart contracts, ranging from high to low severity. High severity issues, such as the vulnerability in the DStakeToken contract, permit unauthorized withdrawals due to insufficient access controls, posing a significant security risk. Medium severity issues involve systemic vulnerabilities in protocols like dLoop, which can be exploited for profit through minor leverage deviations and compositional errors in the `deallocateAmo` function that could lead to accounting inaccuracies and denial of service. Numerous low severity issues were also found, including logical and overflow errors that affect withdrawal fee computations, leverage handling, and transaction costs. These errors necessitate recalibrations in fee assessment, leverage calculations, and contract comprehensions to ensure robustness against strategic exploits and efficiency in operational processes. While some issues have limited real-world impact, cumulative effects could undermine system integrity and user confidence if not adequately addressed. The audit underscores the critical need for precise coding practices and continual evaluation to fortify the security and functionality of blockchain protocols.

## Disclaimer


This report does not assert that the audited contracts are completely secure. Continuous review and comprehensive testing are advised before deploying critical smart contracts.


The dTRINITY audit competition illustrates the collaborative effort in identifying and rectifying potential vulnerabilities, enhancing the overall security and functionality of the platform.


Hats.finance does not provide any guarantee or warranty regarding the security of this project. Smart contract software should be used at the sole risk and responsibility of users.

