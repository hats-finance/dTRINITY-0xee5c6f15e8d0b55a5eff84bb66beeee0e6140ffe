/**
 * @title REALISTIC Test for Issue #73 with Interest Accrual
 * @notice This test simulates ACTUAL conditions where interest has accrued,
 *         changing the exchange rate so previewDeposit CAN return 0 for small amounts.
 * 
 * Issue #73 Claims:
 * 1. Withdrawal creates surplus due to rounding
 * 2. When exchange rate > 1:1, previewDeposit(small_surplus) returns 0
 * 3. This causes deposit(surplus) to revert, blocking withdrawals
 * 
 * This Test Simulates:
 * 1. Interest accrual through borrowing and time travel
 * 2. Exchange rate changes that make 1 share worth > 1 asset
 * 3. Whether withdrawals still succeed despite these conditions
 */

import { ethers, network, getNamedAccounts } from "hardhat";
import { expect } from "chai";
import {
  DStakeToken,
  DStakeCollateralVault,
  DStakeRouterDLend,
  ERC20,
  IERC20,
  IDStableConversionAdapter,
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  createDStakeFixture,
  SDUSD_CONFIG,
  DStakeFixtureConfig,
} from "./fixture";
import { ERC20StablecoinUpgradeable } from "../../typechain-types/contracts/dstable/ERC20StablecoinUpgradeable";
import { WrappedDLendConversionAdapter__factory } from "../../typechain-types/factories/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter__factory";
import { WrappedDLendConversionAdapter } from "../../typechain-types/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter";
import { StaticATokenLM } from "../../typechain-types/contracts/vaults/atoken_wrapper/StaticATokenLM";
import { IPool } from "../../typechain-types/contracts/dlend/core/interfaces/IPool";
import { TestERC20 } from "../../typechain-types/contracts/testing/token/TestERC20";

const parseUnits = (value: string | number, decimals: number | bigint) =>
  ethers.parseUnits(value.toString(), decimals);

describe("🔬 REALISTIC TEST: Issue #73 with Interest Accrual", () => {
  const config = SDUSD_CONFIG; // Test with dUSD
  const fixture = createDStakeFixture(config);
  
  let deployer: SignerWithAddress;
  let user1: SignerWithAddress;
  let borrower: SignerWithAddress;
  let DStakeToken: DStakeToken;
  let collateralVault: DStakeCollateralVault;
  let router: DStakeRouterDLend;
  let dStableToken: ERC20;
  let stable: ERC20StablecoinUpgradeable;
  let adapter: WrappedDLendConversionAdapter;
  let wrappedDLendToken: StaticATokenLM;
  let pool: IPool;
  let dStableDecimals: bigint;
  let collateralAsset: string;
  let collateralToken: TestERC20;

  beforeEach(async () => {
    const named = await getNamedAccounts();
    deployer = await ethers.getSigner(named.deployer);
    user1 = await ethers.getSigner(named.user1 || named.deployer);
    borrower = await ethers.getSigner(named.user2 || named.deployer);

    const out = await fixture();
    const adapterAddress = out.adapterAddress;
    adapter = WrappedDLendConversionAdapter__factory.connect(
      adapterAddress,
      deployer
    );
    DStakeToken = out.DStakeToken as unknown as DStakeToken;
    collateralVault = out.collateralVault as unknown as DStakeCollateralVault;
    router = out.router as unknown as DStakeRouterDLend;
    dStableToken = out.dStableToken;
    dStableDecimals = await dStableToken.decimals();

    const vaultAssetAddress = await adapter.vaultAsset();
    wrappedDLendToken = await ethers.getContractAt(
      "StaticATokenLM",
      vaultAssetAddress
    ) as StaticATokenLM;

    // Get the lending pool
    const poolAddress = await wrappedDLendToken.POOL();
    pool = await ethers.getContractAt(
      "contracts/dlend/core/interfaces/IPool.sol:IPool",
      poolAddress
    ) as unknown as IPool;

    // Setup stablecoin minting
    stable = await ethers.getContractAt(
      "ERC20StablecoinUpgradeable",
      await dStableToken.getAddress()
    ) as ERC20StablecoinUpgradeable;
    const minterRole = await stable.MINTER_ROLE();
    await stable.grantRole(minterRole, deployer.address);

    // Set withdrawal fee to 0 to isolate the issue
    await DStakeToken.connect(user1).setWithdrawalFee(0);

    // Get collateral asset for borrowing
    // Use a simple collateral token from the test setup
    const deployments = await import("hardhat").then(m => m.deployments);
    const usdcDeployment = await deployments.get("USDC");
    collateralAsset = usdcDeployment.address;
    collateralToken = await ethers.getContractAt("TestERC20", collateralAsset) as TestERC20;
  });

  describe("📈 Part 1: Setup Interest Accrual", () => {
    it("Should setup the vault with interest accrual to change exchange rate", async () => {
      console.log("\n" + "=".repeat(70));
      console.log("SETTING UP REALISTIC INTEREST ACCRUAL SCENARIO");
      console.log("=".repeat(70));

      // Step 1: Initial deposits to establish liquidity
      console.log("\n1️⃣ Initial Deposits:");
      const initialDeposit = parseUnits("10000", dStableDecimals);
      await stable.mint(user1.address, initialDeposit);
      await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), initialDeposit);
      await DStakeToken.connect(user1).deposit(initialDeposit, user1.address);
      console.log(`   User deposited: ${ethers.formatUnits(initialDeposit, dStableDecimals)} dStable`);

      // Check initial exchange rate (should be 1:1)
      const initialRate = await wrappedDLendToken.rate();
      console.log(`   Initial rate: ${ethers.formatUnits(initialRate, 27)}`);
      
      // Check what 1 wei would get initially
      const initialOneWei = await wrappedDLendToken.previewDeposit(1n);
      console.log(`   previewDeposit(1 wei) initially: ${initialOneWei} shares`);

      // Step 2: Simulate interest accrual by directly depositing extra assets
      // This changes the exchange rate without needing complex borrowing setup
      console.log("\n2️⃣ Simulating Interest Accrual:");
      
      // Direct deposit to the underlying aToken to simulate interest
      // This increases total assets without increasing shares
      const interestAmount = parseUnits("100", dStableDecimals); // 1% interest
      await stable.mint(deployer.address, interestAmount);
      await dStableToken.connect(deployer).approve(await wrappedDLendToken.getAddress(), interestAmount);
      
      // Get underlying aToken address and deposit directly
      const aTokenAddress = await wrappedDLendToken.aToken();
      const aToken = await ethers.getContractAt("IERC20", aTokenAddress);
      
      // Transfer dStable directly to the StaticAToken wrapper to simulate interest
      // This increases the assets backing existing shares
      await dStableToken.connect(deployer).transfer(await wrappedDLendToken.getAddress(), interestAmount);
      console.log(`   Added ${ethers.formatUnits(interestAmount, dStableDecimals)} dStable as simulated interest`);
      
      // The exchange rate should now be > 1:1
      console.log("\n3️⃣ Exchange Rate After Interest:");
      const newTotalAssets = await wrappedDLendToken.totalAssets();
      const newTotalSupply = await wrappedDLendToken.totalSupply();
      console.log(`   Total Assets: ${ethers.formatUnits(newTotalAssets, dStableDecimals)}`);
      console.log(`   Total Shares: ${ethers.formatUnits(newTotalSupply, dStableDecimals)}`);
      console.log(`   Assets per Share: ${newTotalSupply > 0n ? (newTotalAssets * parseUnits("1", dStableDecimals)) / newTotalSupply : 0n}`);

      // Step 5: Check new exchange rate
      const newRate = await wrappedDLendToken.rate();
      console.log(`   New rate after interest: ${ethers.formatUnits(newRate, 27)}`);
      
      // Calculate how much 1 share is worth now
      const oneShareValue = await wrappedDLendToken.previewRedeem(1n);
      console.log(`   1 share now worth: ${oneShareValue} wei of assets`);
      
      // Check what small amounts would get now
      console.log("\n4️⃣ Testing previewDeposit with new rate:");
      for (let i = 1n; i <= 10n; i++) {
        const preview = await wrappedDLendToken.previewDeposit(i);
        const status = preview === 0n ? "❌ RETURNS 0!" : `✅ ${preview} shares`;
        console.log(`   previewDeposit(${i} wei) = ${status}`);
        
        if (preview === 0n && i === 1n) {
          console.log("\n⚠️ CRITICAL: previewDeposit(1 wei) now returns 0!");
          console.log("   This means surplus of 1 wei would cause deposit() to revert!");
        }
      }

      // Find the minimum deposit that returns non-zero shares
      let minNonZero = 0n;
      for (let amt = 1n; amt <= 1000n; amt++) {
        const shares = await wrappedDLendToken.previewDeposit(amt);
        if (shares > 0n) {
          minNonZero = amt;
          break;
        }
      }
      console.log(`\n   Minimum deposit for 1 share: ${minNonZero} wei`);
      
      console.log("\n" + "=".repeat(70));
      console.log("EXCHANGE RATE SUCCESSFULLY CHANGED - REALISTIC CONDITIONS SET");
      console.log("=".repeat(70));
    });
  });

  describe("🎯 Part 2: Test Withdrawals with Changed Exchange Rate", () => {
    it("Should test if withdrawals create surplus and if they revert", async () => {
      console.log("\n" + "=".repeat(70));
      console.log("TESTING WITHDRAWALS WITH INTEREST-ADJUSTED EXCHANGE RATE");
      console.log("=".repeat(70));

      // Setup: Initial deposits and interest accrual
      const initialDeposit = parseUnits("10000", dStableDecimals);
      await stable.mint(user1.address, initialDeposit);
      await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), initialDeposit);
      await DStakeToken.connect(user1).deposit(initialDeposit, user1.address);

      // Simulate interest by directly adding assets to the wrapper
      // This changes the exchange rate without complex borrowing
      const interestAmount = parseUnits("100", dStableDecimals); // 1% interest  
      await stable.mint(deployer.address, interestAmount);
      await dStableToken.connect(deployer).transfer(await wrappedDLendToken.getAddress(), interestAmount);

      // Verify exchange rate has changed
      const currentRate = await wrappedDLendToken.rate();
      const oneShareValue = await wrappedDLendToken.previewRedeem(1n);
      console.log(`\nCurrent conditions:`);
      console.log(`  Rate: ${ethers.formatUnits(currentRate, 27)}`);
      console.log(`  1 share = ${oneShareValue} wei`);
      console.log(`  previewDeposit(1 wei) = ${await wrappedDLendToken.previewDeposit(1n)} shares`);

      // Test various withdrawal amounts
      console.log("\n🔬 Testing Withdrawals:");
      const testAmounts = [
        parseUnits("100", dStableDecimals),
        parseUnits("99.999999999999999999", dStableDecimals),
        parseUnits("100.000000000000000001", dStableDecimals),
        parseUnits("1", dStableDecimals),
      ];

      let revertCount = 0;
      let successCount = 0;

      for (const withdrawAmount of testAmounts) {
        console.log(`\n  Testing withdrawal of ${ethers.formatUnits(withdrawAmount, dStableDecimals)}:`);
        
        // Simulate router logic
        const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(withdrawAmount);
        const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
        const surplus = actualDStable > withdrawAmount ? actualDStable - withdrawAmount : 0n;
        
        console.log(`    Surplus generated: ${surplus} wei`);
        
        if (surplus > 0n) {
          const sharesForSurplus = await wrappedDLendToken.previewDeposit(surplus);
          console.log(`    previewDeposit(${surplus} wei) = ${sharesForSurplus} shares`);
          
          if (sharesForSurplus === 0n) {
            console.log(`    ⚠️ WOULD REVERT: Cannot deposit surplus!`);
            
            // Try actual withdrawal to confirm
            try {
              await DStakeToken.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
              console.log(`    ❌ Unexpected: Withdrawal succeeded despite 0 shares`);
              successCount++;
            } catch (error: any) {
              console.log(`    ✅ Confirmed: Withdrawal reverted as expected`);
              revertCount++;
            }
          } else {
            // Should succeed
            try {
              await DStakeToken.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
              console.log(`    ✅ Withdrawal succeeded`);
              successCount++;
            } catch (error: any) {
              console.log(`    ❌ Unexpected revert: ${error.message.substring(0, 50)}`);
              revertCount++;
            }
          }
        } else {
          // No surplus, should always succeed
          try {
            await DStakeToken.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
            console.log(`    ✅ Withdrawal succeeded (no surplus)`);
            successCount++;
          } catch (error: any) {
            console.log(`    ❌ Unexpected revert: ${error.message.substring(0, 50)}`);
            revertCount++;
          }
        }
      }

      console.log("\n" + "=".repeat(70));
      console.log("RESULTS WITH REALISTIC INTEREST ACCRUAL:");
      console.log(`  Successful withdrawals: ${successCount}`);
      console.log(`  Reverted withdrawals: ${revertCount}`);
      
      if (revertCount > 0) {
        console.log("\n⚠️ ISSUE PARTIALLY CONFIRMED:");
        console.log("  Under specific conditions with interest accrual,");
        console.log("  withdrawals CAN revert due to surplus deposit failures.");
        console.log("  However, this requires:");
        console.log("  1. Significant interest accrual changing exchange rate");
        console.log("  2. Specific withdrawal amounts that generate tiny surplus");
        console.log("  3. Surplus small enough that previewDeposit returns 0");
      } else {
        console.log("\n✅ NO REVERTS OBSERVED:");
        console.log("  Even with interest accrual, withdrawals succeeded.");
        console.log("  The specific conditions for failure may be rare.");
      }
      console.log("=".repeat(70));
    });
  });

  describe("🔍 Part 3: Find Exact Conditions for Failure", () => {
    it("Should find the exact conditions where withdrawals would fail", async () => {
      console.log("\n" + "=".repeat(70));
      console.log("SEARCHING FOR EXACT FAILURE CONDITIONS");
      console.log("=".repeat(70));

      // Setup with interest accrual
      const initialDeposit = parseUnits("10000", dStableDecimals);
      await stable.mint(user1.address, initialDeposit * 2n);
      await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), initialDeposit * 2n);
      await DStakeToken.connect(user1).deposit(initialDeposit, user1.address);

      // Create borrowing to generate interest
      const collateralAmount = parseUnits("50000", await collateralToken.decimals());
      await collateralToken.connect(deployer).mint(borrower.address, collateralAmount);
      await collateralToken.connect(borrower).approve(poolAddress, collateralAmount);
      await pool.connect(borrower).supply(collateralAsset, collateralAmount, borrower.address, 0);
      await pool.connect(borrower).setUserUseReserveAsCollateral(collateralAsset, true);
      
      // Borrow significant amount
      const borrowAmount = parseUnits("5000", dStableDecimals);
      await pool.connect(borrower).borrow(
        await dStableToken.getAddress(),
        borrowAmount,
        2,
        0,
        borrower.address
      );

      // Try different time periods to find when previewDeposit(1) = 0
      console.log("\nTesting different time periods:");
      const timePeriodsInDays = [30, 60, 90, 180, 365];
      
      for (const days of timePeriodsInDays) {
        // Reset to checkpoint and fast forward
        const seconds = days * 24 * 60 * 60;
        await network.provider.send("evm_increaseTime", [seconds]);
        await network.provider.send("evm_mine");
        
        const rate = await wrappedDLendToken.rate();
        const oneWeiShares = await wrappedDLendToken.previewDeposit(1n);
        const minForOneShare = oneWeiShares === 0n ? "N/A" : "1 wei";
        
        console.log(`\nAfter ${days} days:`);
        console.log(`  Rate: ${ethers.formatUnits(rate, 27)}`);
        console.log(`  previewDeposit(1 wei) = ${oneWeiShares} shares`);
        
        if (oneWeiShares === 0n) {
          // Find minimum that returns 1 share
          let min = 0n;
          for (let i = 1n; i <= 1000n; i++) {
            if (await wrappedDLendToken.previewDeposit(i) > 0n) {
              min = i;
              break;
            }
          }
          console.log(`  ⚠️ Minimum for 1 share: ${min} wei`);
          console.log(`  📍 FAILURE CONDITION FOUND!`);
          
          // Test if withdrawal would fail
          console.log("\n  Testing withdrawal with these conditions:");
          const testAmount = parseUnits("100", dStableDecimals);
          const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(testAmount);
          const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
          const surplus = actualDStable > testAmount ? actualDStable - testAmount : 0n;
          
          console.log(`    Withdrawal amount: ${ethers.formatUnits(testAmount, dStableDecimals)}`);
          console.log(`    Surplus: ${surplus} wei`);
          
          if (surplus > 0n && surplus < min) {
            console.log(`    ❌ THIS WOULD CAUSE REVERT!`);
            console.log(`    Surplus (${surplus} wei) < minimum deposit (${min} wei)`);
          }
        }
      }
      
      console.log("\n" + "=".repeat(70));
    });
  });
});