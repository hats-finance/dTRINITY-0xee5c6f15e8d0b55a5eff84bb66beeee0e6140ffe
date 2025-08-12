/**
 * @title Simplified Realistic Test for Issue #73
 * @notice This test demonstrates whether withdrawals can fail when:
 *         1. Exchange rate changes from 1:1 (simulating interest)
 *         2. Small surplus is generated
 *         3. previewDeposit(surplus) returns 0
 */

import hre, { ethers, network, getNamedAccounts, deployments } from "hardhat";
import { expect } from "chai";
import {
  DStakeToken,
  DStakeCollateralVault,
  DStakeRouterDLend,
  ERC20,
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  createDStakeFixture,
  SDUSD_CONFIG,
} from "./fixture";
import { ERC20StablecoinUpgradeable } from "../../typechain-types/contracts/dstable/ERC20StablecoinUpgradeable";
import { WrappedDLendConversionAdapter__factory } from "../../typechain-types/factories/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter__factory";
import { StaticATokenLM } from "../../typechain-types/contracts/vaults/atoken_wrapper/StaticATokenLM";
import { IPool } from "../../typechain-types/contracts/dlend/core/interfaces/IPool";
import { getConfig } from "../../config/config";
import { TestERC20 } from "../../typechain-types/contracts/testing/token/TestERC20";

const parseUnits = (value: string | number, decimals: number | bigint) =>
  ethers.parseUnits(value.toString(), decimals);

describe("🔬 SIMPLIFIED REALISTIC TEST: Issue #73", () => {
  const config = SDUSD_CONFIG;
  const fixture = createDStakeFixture(config);
  
  let deployer: SignerWithAddress;
  let user1: SignerWithAddress;
  let DStakeToken: DStakeToken;
  let collateralVault: DStakeCollateralVault;
  let router: DStakeRouterDLend;
  let dStableToken: ERC20;
  let stable: ERC20StablecoinUpgradeable;
  let wrappedDLendToken: StaticATokenLM;
  let dStableDecimals: bigint;

  beforeEach(async () => {
    const named = await getNamedAccounts();
    deployer = await ethers.getSigner(named.deployer);
    user1 = await ethers.getSigner(named.user1 || named.deployer);

    const out = await fixture();
    const adapterAddress = out.adapterAddress;
    const adapter = WrappedDLendConversionAdapter__factory.connect(
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

    stable = await ethers.getContractAt(
      "ERC20StablecoinUpgradeable",
      await dStableToken.getAddress()
    ) as ERC20StablecoinUpgradeable;
    const minterRole = await stable.MINTER_ROLE();
    await stable.grantRole(minterRole, deployer.address);

    // Set withdrawal fee to 0 to isolate the issue
    await DStakeToken.connect(user1).setWithdrawalFee(0);
  });

  describe("📊 Analysis: Exchange Rate Impact on Withdrawals", () => {
    it("Should demonstrate how exchange rate affects surplus and withdrawals", async () => {
      console.log("\n" + "=".repeat(70));
      console.log("EXCHANGE RATE IMPACT ANALYSIS");
      console.log("=".repeat(70));

      // Initial deposit
      const initialDeposit = parseUnits("10000", dStableDecimals);
      await stable.mint(user1.address, initialDeposit);
      await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), initialDeposit);
      await DStakeToken.connect(user1).deposit(initialDeposit, user1.address);

      console.log("\n1️⃣ Initial State (1:1 Exchange Rate):");
      let rate = await wrappedDLendToken.convertToAssets(parseUnits("1", dStableDecimals));
      console.log(`   1 share = ${ethers.formatUnits(rate, dStableDecimals)} assets`);
      console.log(`   previewDeposit(1 wei) = ${await wrappedDLendToken.previewDeposit(1n)} shares`);

      // Test withdrawal with 1:1 rate
      const testAmount = parseUnits("100", dStableDecimals);
      let vaultAssetAmount = await wrappedDLendToken.previewWithdraw(testAmount);
      let actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
      let surplus = actualDStable > testAmount ? actualDStable - testAmount : 0n;
      console.log(`   Withdrawal of 100: surplus = ${surplus} wei`);

      // Now let's simulate interest by using the actual dLEND pool
      console.log("\n2️⃣ Simulating Interest Accrual:");
      
      // Get the pool from the wrapper
      const poolAddress = await wrappedDLendToken.POOL();
      const pool = await ethers.getContractAt(
        "contracts/dlend/core/interfaces/IPool.sol:IPool",
        poolAddress
      ) as unknown as IPool;

      // Get collateral from config
      const globalConfig = await getConfig(hre);
      const dStableCollaterals = globalConfig.dStables[
        config.dStableSymbol
      ].collaterals.filter((addr) => addr !== ethers.ZeroAddress);
      const collateralAsset = dStableCollaterals[dStableCollaterals.length - 1];
      const collateralToken = await ethers.getContractAt(
        "TestERC20",
        collateralAsset
      ) as unknown as TestERC20;
      
      // Setup collateral
      const collateralDecimals = await collateralToken.decimals();
      const collateralAmount = parseUnits("50000", collateralDecimals);
      
      // The test tokens should have the mint function
      await collateralToken.connect(deployer).approve(poolAddress, collateralAmount);
      
      // Supply collateral
      await pool.connect(deployer).deposit(collateralAsset, collateralAmount, deployer.address, 0);
      await pool.connect(deployer).setUserUseReserveAsCollateral(collateralAsset, true);
      
      // Borrow dStable to create interest
      const borrowAmount = parseUnits("1000", dStableDecimals);
      await pool.connect(deployer).borrow(
        await dStableToken.getAddress(),
        borrowAmount,
        2, // Variable rate
        0,
        deployer.address
      );
      console.log(`   Borrowed ${ethers.formatUnits(borrowAmount, dStableDecimals)} dStable`);

      // Fast forward time to accrue interest
      const days = 365; // 1 year for significant interest
      await network.provider.send("evm_increaseTime", [days * 24 * 60 * 60]);
      await network.provider.send("evm_mine");
      console.log(`   Advanced time by ${days} days`);

      // Trigger interest update with small transaction
      await stable.mint(deployer.address, 1n);
      await dStableToken.connect(deployer).approve(poolAddress, 1n);
      await pool.connect(deployer).supply(await dStableToken.getAddress(), 1n, deployer.address, 0);

      console.log("\n3️⃣ After Interest Accrual:");
      rate = await wrappedDLendToken.convertToAssets(parseUnits("1", dStableDecimals));
      console.log(`   1 share = ${ethers.formatUnits(rate, dStableDecimals)} assets`);
      
      // Check minimum deposit
      let minForOneShare = 0n;
      for (let i = 1n; i <= 1000n; i++) {
        const shares = await wrappedDLendToken.previewDeposit(i);
        if (shares > 0n) {
          minForOneShare = i;
          break;
        }
      }
      console.log(`   Minimum deposit for 1 share: ${minForOneShare} wei`);
      console.log(`   previewDeposit(1 wei) = ${await wrappedDLendToken.previewDeposit(1n)} shares`);

      // Test withdrawal after interest
      vaultAssetAmount = await wrappedDLendToken.previewWithdraw(testAmount);
      actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
      surplus = actualDStable > testAmount ? actualDStable - testAmount : 0n;
      console.log(`   Withdrawal of 100: surplus = ${surplus} wei`);

      if (surplus > 0n && surplus < minForOneShare) {
        console.log("\n⚠️ CRITICAL ISSUE FOUND!");
        console.log(`   Surplus (${surplus} wei) < Min deposit (${minForOneShare} wei)`);
        console.log(`   previewDeposit(${surplus}) = ${await wrappedDLendToken.previewDeposit(surplus)}`);
        console.log("   This surplus cannot be re-deposited!");
        
        // Try actual withdrawal
        console.log("\n4️⃣ Testing Actual Withdrawal:");
        try {
          await DStakeToken.connect(user1).withdraw(testAmount, user1.address, user1.address);
          console.log("   ❌ Withdrawal succeeded (unexpected if surplus can't be deposited)");
        } catch (error: any) {
          console.log("   ✅ Withdrawal reverted as expected!");
          console.log(`   Error: ${error.message.substring(0, 100)}`);
        }
      } else if (surplus > 0n) {
        console.log("\n✅ Surplus can be re-deposited:");
        console.log(`   previewDeposit(${surplus}) = ${await wrappedDLendToken.previewDeposit(surplus)} shares`);
        
        // Withdrawal should succeed
        await expect(
          DStakeToken.connect(user1).withdraw(testAmount, user1.address, user1.address)
        ).to.not.be.reverted;
        console.log("   Withdrawal succeeded as expected");
      } else {
        console.log("\n✅ No surplus generated - withdrawal safe");
        await expect(
          DStakeToken.connect(user1).withdraw(testAmount, user1.address, user1.address)
        ).to.not.be.reverted;
      }

      console.log("\n" + "=".repeat(70));
      console.log("CONCLUSION:");
      if (minForOneShare > 1n) {
        console.log("With significant interest accrual, previewDeposit CAN return 0");
        console.log("for small amounts. However, whether this causes DOS depends on:");
        console.log("1. Whether withdrawals generate surplus");
        console.log("2. Whether surplus is smaller than minimum deposit");
        console.log("3. Current implementation of the router");
      } else {
        console.log("Even with interest, previewDeposit(1 wei) returns non-zero.");
        console.log("The DOS scenario requires more extreme conditions.");
      }
      console.log("=".repeat(70));
    });
  });
});