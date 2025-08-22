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
- Maximum Reward: $99,980.4
- Submissions: 328
- Total Payout: $95,174.34 distributed among 44 participants.

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

## Medium severity issues

## Low severity issues



## Conclusion

An error occurred while generating the conclusion.

## Disclaimer


This report does not assert that the audited contracts are completely secure. Continuous review and comprehensive testing are advised before deploying critical smart contracts.


The dTRINITY audit competition illustrates the collaborative effort in identifying and rectifying potential vulnerabilities, enhancing the overall security and functionality of the platform.


Hats.finance does not provide any guarantee or warranty regarding the security of this project. Smart contract software should be used at the sole risk and responsibility of users.

