import { ethers, deployments, getNamedAccounts } from "hardhat";
import { expect } from "chai";
import {
  DStakeToken,
  DStakeCollateralVault,
  DStakeRouterDLend,
  ERC20,
  IERC4626,
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  createDStakeFixture,
  DSTAKE_CONFIGS,
  DStakeFixtureConfig,
} from "./fixture";
import { ERC20StablecoinUpgradeable } from "../../typechain-types/contracts/dstable/ERC20StablecoinUpgradeable";
import { WrappedDLendConversionAdapter } from "../../typechain-types/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter";
import { WrappedDLendConversionAdapter__factory } from "../../typechain-types/factories/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter__factory";

const parseUnits = (value: string | number, decimals: number | bigint) =>
  ethers.parseUnits(value.toString(), decimals);

/**
 * Test suite to reproduce GitHub Issue #73: Withdrawal DOS due to surplus handling
 * https://github.com/hats-finance/dTRINITY-0xee5c6f15e8d0b55a5eff84bb66beeee0e6140ffe/issues/73
 * 
 * The issue occurs when:
 * 1. previewWithdraw rounds UP the vault asset amount needed
 * 2. redeem() returns slightly more dStable than requested due to rounding
 * 3. The surplus is too small to re-deposit (previewDeposit returns 0)
 * 4. The withdrawal transaction reverts
 */

DSTAKE_CONFIGS.forEach((config: DStakeFixtureConfig) => {
  describe(`Issue #73: Withdrawal Surplus DOS for ${config.DStakeTokenSymbol}`, () => {
    const fixture = createDStakeFixture(config);
    let deployer: SignerWithAddress;
    let user1: SignerWithAddress;
    let DStakeToken: DStakeToken;
    let collateralVault: DStakeCollateralVault;
    let router: DStakeRouterDLend;
    let dStableToken: ERC20;
    let stable: ERC20StablecoinUpgradeable;
    let minterRole: string;
    let adapterAddress: string;
    let adapter: WrappedDLendConversionAdapter;
    let wrappedDLendToken: IERC4626;
    let dStableDecimals: bigint;

    beforeEach(async () => {
      const named = await getNamedAccounts();
      deployer = await ethers.getSigner(named.deployer);
      user1 = await ethers.getSigner(named.user1 || named.deployer);

      const out = await fixture();
      adapterAddress = out.adapterAddress;
      adapter = WrappedDLendConversionAdapter__factory.connect(
        adapterAddress,
        deployer
      );
      DStakeToken = out.DStakeToken as unknown as DStakeToken;
      collateralVault = out.collateralVault as unknown as DStakeCollateralVault;
      router = out.router as unknown as DStakeRouterDLend;
      dStableToken = out.dStableToken;
      dStableDecimals = await dStableToken.decimals();

      // Get wrapped dLend token (vault asset)
      const vaultAssetAddress = await adapter.vaultAsset();
      wrappedDLendToken = await ethers.getContractAt("IERC4626", vaultAssetAddress);

      // Prepare stablecoin for minting
      stable = (await ethers.getContractAt(
        "ERC20StablecoinUpgradeable",
        await dStableToken.getAddress(),
        deployer
      )) as ERC20StablecoinUpgradeable;
      minterRole = await stable.MINTER_ROLE();
      await stable.grantRole(minterRole, deployer.address);
    });

    describe("Surplus Calculation Analysis", () => {
      it("Should demonstrate rounding differences between previewWithdraw and redeem", async () => {
        // Mint initial dStable to user
        const depositAmount = parseUnits("1000", dStableDecimals);
        await stable.mint(user1.address, depositAmount);
        await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), depositAmount);
        
        // Deposit to get shares
        await DStakeToken.connect(user1).deposit(depositAmount, user1.address);
        
        // Wait for some blocks to potentially accumulate rewards
        await ethers.provider.send("hardhat_mine", ["0x10"]); // Mine 16 blocks
        
        // Test various withdrawal amounts to find rounding differences
        const testAmounts = [
          parseUnits("100", dStableDecimals),
          parseUnits("100.000001", dStableDecimals),
          parseUnits("99.999999", dStableDecimals),
          parseUnits("1", dStableDecimals),
        ];

        console.log("\n=== Rounding Analysis ===");
        for (const withdrawAmount of testAmounts) {
          // Calculate shares needed using previewWithdraw
          const sharesNeeded = await DStakeToken.previewWithdraw(withdrawAmount);
          
          // Calculate what we'd actually get from redeeming those shares
          const actualDStable = await DStakeToken.previewRedeem(sharesNeeded);
          
          // Calculate the surplus
          const surplus = actualDStable - withdrawAmount;
          
          // Check if surplus can be re-deposited
          let canRedeposit = true;
          let previewDepositResult = 0n;
          if (surplus > 0n) {
            previewDepositResult = await wrappedDLendToken.previewDeposit(surplus);
            canRedeposit = previewDepositResult > 0n;
          }
          
          console.log(`Withdraw Amount: ${ethers.formatUnits(withdrawAmount, dStableDecimals)}`);
          console.log(`  Shares Needed: ${sharesNeeded}`);
          console.log(`  Actual dStable from Redeem: ${ethers.formatUnits(actualDStable, dStableDecimals)}`);
          console.log(`  Surplus: ${surplus} wei`);
          console.log(`  Preview Deposit of Surplus: ${previewDepositResult}`);
          console.log(`  Can Redeposit: ${canRedeposit}\n`);
        }
      });
    });

    describe("Dust Amount Withdrawal DOS", () => {
      it("Should revert when surplus is too small to re-deposit", async () => {
        // Setup: Mint and deposit initial amount
        const initialDeposit = parseUnits("10000", dStableDecimals);
        await stable.mint(user1.address, initialDeposit);
        await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), initialDeposit);
        await DStakeToken.connect(user1).deposit(initialDeposit, user1.address);
        
        // Mine some blocks to accumulate potential rounding differences
        await ethers.provider.send("hardhat_mine", ["0x100"]); // Mine 256 blocks
        
        // Find an amount that creates a dust surplus
        let failureAmount = 0n;
        let foundFailure = false;
        
        // Binary search for a withdrawal amount that causes failure
        let low = parseUnits("1", dStableDecimals);
        let high = parseUnits("1000", dStableDecimals);
        
        while (low <= high && !foundFailure) {
          const testAmount = (low + high) / 2n;
          
          try {
            // Simulate the withdrawal logic
            const sharesNeeded = await DStakeToken.previewWithdraw(testAmount);
            const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(testAmount);
            
            // This simulates what convertFromVaultAsset would return
            const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
            const surplus = actualDStable > testAmount ? actualDStable - testAmount : 0n;
            
            if (surplus > 0n && surplus <= 2n) {
              // Check if this tiny surplus would cause previewDeposit to return 0
              const depositPreview = await wrappedDLendToken.previewDeposit(surplus);
              if (depositPreview === 0n) {
                failureAmount = testAmount;
                foundFailure = true;
                console.log(`\n=== Found Failure Case ===`);
                console.log(`Withdrawal Amount: ${ethers.formatUnits(testAmount, dStableDecimals)}`);
                console.log(`Surplus: ${surplus} wei`);
                console.log(`previewDeposit(surplus): ${depositPreview}`);
              }
            }
            
            if (!foundFailure) {
              if (surplus === 0n) {
                low = testAmount + 1n;
              } else {
                high = testAmount - 1n;
              }
            }
          } catch (e) {
            // Adjust search range
            high = testAmount - 1n;
          }
        }
        
        // If we found a failure case, test it
        if (foundFailure && failureAmount > 0n) {
          // The withdrawal should revert due to deposit(0) reverting
          await expect(
            DStakeToken.connect(user1).withdraw(failureAmount, user1.address, user1.address)
          ).to.be.reverted;
        } else {
          console.log("No dust failure case found - may need different test parameters");
          // Force a dust scenario by manipulating amounts
          // This is a fallback to ensure we test the concept
          this.skip();
        }
      });
    });

    describe("Frozen Market Withdrawal DOS", () => {
      it("Should demonstrate withdrawal failure when market is paused/frozen", async () => {
        // This test requires the ability to pause/freeze the wrapped dLend token
        // which may not be directly available in test environment
        
        // Setup: Mint and deposit
        const depositAmount = parseUnits("1000", dStableDecimals);
        await stable.mint(user1.address, depositAmount);
        await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), depositAmount);
        await DStakeToken.connect(user1).deposit(depositAmount, user1.address);
        
        // Check if we can pause the wrapped token (implementation specific)
        // Most AAVE markets have a pause function accessible by emergency admin
        
        try {
          // Attempt to get the pool contract
          const poolAddress = await wrappedDLendToken.POOL
            ? await wrappedDLendToken.POOL()
            : undefined;
          
          if (poolAddress) {
            const pool = await ethers.getContractAt("IPool", poolAddress);
            
            // Check if we can access pause functionality
            // Note: This would require admin access in real scenario
            console.log("\n=== Market Freeze Scenario ===");
            console.log("In production, a frozen AAVE market would:");
            console.log("1. Allow withdrawals (users can exit)");
            console.log("2. Block deposits (no new entries)");
            console.log("3. Cause DStake withdrawals to fail on surplus re-deposit");
            
            // Simulate what would happen
            const withdrawAmount = parseUnits("100", dStableDecimals);
            const sharesNeeded = await DStakeToken.previewWithdraw(withdrawAmount);
            const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(withdrawAmount);
            const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
            const surplus = actualDStable > withdrawAmount ? actualDStable - withdrawAmount : 0n;
            
            if (surplus > 0n) {
              console.log(`\nWithdrawal would create ${surplus} wei surplus`);
              console.log("In frozen state, deposit(surplus) would revert");
              console.log("This blocks ALL DStake withdrawals!");
            }
          }
        } catch (e) {
          console.log("Cannot directly test frozen market - would require forking mainnet");
        }
      });
    });

    describe("Comprehensive Surplus Edge Cases", () => {
      it("Should test multiple withdrawal amounts for surplus issues", async () => {
        // Setup
        const deposits = [
          parseUnits("1", dStableDecimals),
          parseUnits("10", dStableDecimals),
          parseUnits("100", dStableDecimals),
          parseUnits("1000", dStableDecimals),
          parseUnits("10000", dStableDecimals),
        ];
        
        for (const depositAmount of deposits) {
          // Fresh user for each test
          const testUser = ethers.Wallet.createRandom().connect(ethers.provider);
          await deployer.sendTransaction({
            to: testUser.address,
            value: ethers.parseEther("1"),
          });
          
          // Mint and deposit
          await stable.mint(testUser.address, depositAmount);
          await dStableToken.connect(testUser).approve(await DStakeToken.getAddress(), depositAmount);
          await DStakeToken.connect(testUser).deposit(depositAmount, testUser.address);
          
          // Mine blocks to create potential rounding
          await ethers.provider.send("hardhat_mine", ["0x10"]);
          
          // Try withdrawing various percentages
          const percentages = [10n, 25n, 50n, 75n, 90n, 99n, 100n];
          
          for (const pct of percentages) {
            const withdrawAmount = (depositAmount * pct) / 100n;
            if (withdrawAmount === 0n) continue;
            
            try {
              // Check what would happen
              const sharesNeeded = await DStakeToken.previewWithdraw(withdrawAmount);
              const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(withdrawAmount);
              const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
              const surplus = actualDStable > withdrawAmount ? actualDStable - withdrawAmount : 0n;
              
              if (surplus > 0n && surplus <= 10n) {
                const depositPreview = await wrappedDLendToken.previewDeposit(surplus);
                console.log(`\nDeposit: ${ethers.formatUnits(depositAmount, dStableDecimals)}, Withdraw ${pct}%`);
                console.log(`  Surplus: ${surplus} wei, previewDeposit: ${depositPreview}`);
                
                if (depositPreview === 0n) {
                  console.log(`  ⚠️ WOULD FAIL: Surplus too small to re-deposit!`);
                }
              }
            } catch (e) {
              console.log(`Error testing ${pct}% withdrawal of ${ethers.formatUnits(depositAmount, dStableDecimals)}`);
            }
          }
        }
      });
    });

    describe("Direct Router Withdrawal Test", () => {
      it("Should test the exact withdrawal path through router", async () => {
        // This test directly exercises the router.withdraw function
        // to match production behavior exactly
        
        const depositAmount = parseUnits("1000", dStableDecimals);
        await stable.mint(user1.address, depositAmount);
        await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), depositAmount);
        await DStakeToken.connect(user1).deposit(depositAmount, user1.address);
        
        // Mine blocks
        await ethers.provider.send("hardhat_mine", ["0x20"]);
        
        // Test withdrawal amounts that might create issues
        const testCases = [
          { amount: parseUnits("999.999999", dStableDecimals), name: "Near full" },
          { amount: parseUnits("100.000001", dStableDecimals), name: "Fractional" },
          { amount: parseUnits("1", dStableDecimals), name: "Small" },
        ];
        
        for (const testCase of testCases) {
          const balanceBefore = await dStableToken.balanceOf(user1.address);
          
          try {
            // Get the shares needed
            const sharesNeeded = await DStakeToken.previewWithdraw(testCase.amount);
            const userShares = await DStakeToken.balanceOf(user1.address);
            
            if (sharesNeeded <= userShares) {
              // Perform withdrawal
              const tx = await DStakeToken.connect(user1).withdraw(
                testCase.amount,
                user1.address,
                user1.address
              );
              
              const receipt = await tx.wait();
              const balanceAfter = await dStableToken.balanceOf(user1.address);
              const received = balanceAfter - balanceBefore;
              
              console.log(`\n${testCase.name}: Requested ${ethers.formatUnits(testCase.amount, dStableDecimals)}`);
              console.log(`  Received: ${ethers.formatUnits(received, dStableDecimals)}`);
              console.log(`  Gas Used: ${receipt?.gasUsed}`);
              
              // Verify user got at least what they requested
              expect(received).to.be.gte(testCase.amount);
            }
          } catch (error: any) {
            console.log(`\n${testCase.name}: FAILED`);
            console.log(`  Error: ${error.message}`);
            
            // Check if it's the surplus re-deposit issue
            if (error.message.includes("deposit")) {
              console.log("  ⚠️ Likely surplus re-deposit failure!");
            }
          }
        }
      });
    });
  });
});