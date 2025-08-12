import { ethers, deployments, getNamedAccounts } from "hardhat";
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
import { WrappedDLendConversionAdapter } from "../../typechain-types/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter";
import { WrappedDLendConversionAdapter__factory } from "../../typechain-types/factories/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter__factory";

const parseUnits = (value: string | number, decimals: number | bigint) =>
  ethers.parseUnits(value.toString(), decimals);

/**
 * DEFINITIVE TEST FOR ISSUE #73
 * 
 * This test attempts to prove or disprove whether the dust surplus DOS is:
 * 1. Mathematically possible
 * 2. Practically achievable in realistic conditions
 * 
 * Key claims to verify:
 * - Can we create a 1 wei surplus from withdrawal rounding?
 * - Does previewDeposit(1 wei) return 0 in realistic conditions?
 * - Would this cause withdrawal to revert?
 */

describe("DEFINITIVE: Issue #73 Dust Surplus DOS Verification", () => {
  const fixture = createDStakeFixture(SDUSD_CONFIG);
  let deployer: SignerWithAddress;
  let user1: SignerWithAddress;
  let DStakeToken: DStakeToken;
  let collateralVault: DStakeCollateralVault;
  let router: DStakeRouterDLend;
  let dStableToken: ERC20;
  let stable: ERC20StablecoinUpgradeable;
  let wrappedDLendToken: any; // Using any to access all methods
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
      "@openzeppelin/contracts/interfaces/IERC4626.sol:IERC4626",
      vaultAssetAddress
    );

    stable = (await ethers.getContractAt(
      "ERC20StablecoinUpgradeable",
      await dStableToken.getAddress(),
      deployer
    )) as ERC20StablecoinUpgradeable;
    const minterRole = await stable.MINTER_ROLE();
    await stable.grantRole(minterRole, deployer.address);
  });

  describe("Part 1: Mathematical Possibility", () => {
    it("Should verify if rounding can create surplus", async () => {
      console.log("\n=== MATHEMATICAL POSSIBILITY TEST ===\n");
      
      // Setup: Large deposit to simulate realistic vault state
      const largeDeposit = parseUnits("1000000", dStableDecimals); // 1M tokens
      await stable.mint(deployer.address, largeDeposit);
      await dStableToken.connect(deployer).approve(await DStakeToken.getAddress(), largeDeposit);
      await DStakeToken.connect(deployer).deposit(largeDeposit, deployer.address);
      
      // Setup user with smaller amount
      const userDeposit = parseUnits("1000", dStableDecimals);
      await stable.mint(user1.address, userDeposit);
      await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), userDeposit);
      await DStakeToken.connect(user1).deposit(userDeposit, user1.address);
      
      // Test various withdrawal amounts
      const testAmounts = [
        parseUnits("100", dStableDecimals),
        parseUnits("100", dStableDecimals) + 1n, // Add 1 wei
        parseUnits("100", dStableDecimals) - 1n, // Subtract 1 wei
        parseUnits("99.999999999999999999", dStableDecimals),
        parseUnits("100.000000000000000001", dStableDecimals),
      ];
      
      let surplusFound = false;
      
      for (const amount of testAmounts) {
        try {
          // Check the math
          const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(amount);
          const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
          const surplus = actualDStable > amount ? actualDStable - amount : 0n;
          
          if (surplus > 0n) {
            surplusFound = true;
            console.log(`✅ SURPLUS FOUND!`);
            console.log(`  Withdraw amount: ${amount}`);
            console.log(`  Vault asset amount: ${vaultAssetAmount}`);
            console.log(`  Actual dStable from redeem: ${actualDStable}`);
            console.log(`  Surplus: ${surplus} wei`);
            
            // Check if this surplus would cause issues
            const depositPreview = await wrappedDLendToken.previewDeposit(surplus);
            console.log(`  previewDeposit(${surplus} wei) = ${depositPreview}`);
            
            if (depositPreview === 0n) {
              console.log(`  ⚠️ THIS WOULD CAUSE REVERT!`);
            }
          }
        } catch (e) {
          // Skip amounts that are too large
        }
      }
      
      if (!surplusFound) {
        console.log("❌ No surplus found with current vault implementation");
      }
    });
  });

  describe("Part 2: Check previewDeposit behavior", () => {
    it("Should test previewDeposit with tiny amounts", async () => {
      console.log("\n=== PREVIEW DEPOSIT BEHAVIOR ===\n");
      
      // Setup vault with some assets
      const deposit = parseUnits("10000", dStableDecimals);
      await stable.mint(deployer.address, deposit);
      await dStableToken.connect(deployer).approve(await DStakeToken.getAddress(), deposit);
      await DStakeToken.connect(deployer).deposit(deposit, deployer.address);
      
      // Test previewDeposit with tiny amounts
      const tinyAmounts = [1n, 2n, 5n, 10n, 100n, 1000n, 10000n];
      
      console.log("Testing previewDeposit with tiny amounts:");
      for (const amount of tinyAmounts) {
        const preview = await wrappedDLendToken.previewDeposit(amount);
        console.log(`  previewDeposit(${amount} wei) = ${preview} shares`);
        
        if (preview === 0n) {
          console.log(`    ⚠️ Returns 0 - would cause deposit to revert!`);
        }
      }
      
      // Find the minimum amount that returns non-zero
      let minNonZero = 0n;
      for (let i = 1n; i <= 1000000n; i++) {
        const preview = await wrappedDLendToken.previewDeposit(i);
        if (preview > 0n) {
          minNonZero = i;
          break;
        }
      }
      
      if (minNonZero > 0n) {
        console.log(`\nMinimum deposit for non-zero shares: ${minNonZero} wei`);
        if (minNonZero > 1n) {
          console.log("⚠️ Deposits below this amount would revert!");
        }
      } else {
        console.log("\n✅ All deposits return non-zero shares");
      }
    });
  });

  describe("Part 3: Attempt actual withdrawal with forced conditions", () => {
    it("Should attempt to force the failure condition", async () => {
      console.log("\n=== FORCED FAILURE ATTEMPT ===\n");
      
      // Setup with specific amounts that might trigger rounding
      const amounts = [
        parseUnits("999.999999999999999999", dStableDecimals),
        parseUnits("1000.000000000000000001", dStableDecimals),
        parseUnits("1234.567890123456789012", dStableDecimals),
      ];
      
      for (const depositAmount of amounts) {
        console.log(`\nTesting with deposit: ${ethers.formatUnits(depositAmount, dStableDecimals)}`);
        
        // Fresh user for clean test
        const testUser = ethers.Wallet.createRandom().connect(ethers.provider);
        await deployer.sendTransaction({
          to: testUser.address,
          value: ethers.parseEther("1"),
        });
        
        // Mint and deposit
        await stable.mint(testUser.address, depositAmount);
        await dStableToken.connect(testUser).approve(await DStakeToken.getAddress(), depositAmount);
        await DStakeToken.connect(testUser).deposit(depositAmount, testUser.address);
        
        // Try various withdrawal percentages
        const percentages = [99n, 100n];
        
        for (const pct of percentages) {
          const withdrawAmount = (depositAmount * pct) / 100n;
          
          // Preview the operation
          const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(withdrawAmount);
          const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
          const surplus = actualDStable > withdrawAmount ? actualDStable - withdrawAmount : 0n;
          
          console.log(`  Withdrawing ${pct}%: surplus = ${surplus} wei`);
          
          if (surplus > 0n && surplus <= 10n) {
            const depositPreview = await wrappedDLendToken.previewDeposit(surplus);
            console.log(`    previewDeposit(${surplus}) = ${depositPreview}`);
            
            if (depositPreview === 0n) {
              console.log(`    ⚠️ Attempting withdrawal (should revert)...`);
              
              try {
                await DStakeToken.connect(testUser).withdraw(
                  withdrawAmount,
                  testUser.address,
                  testUser.address
                );
                console.log(`    ❌ Withdrawal succeeded (unexpected)`);
              } catch (error: any) {
                console.log(`    ✅ Withdrawal reverted!`);
                console.log(`    Error: ${error.message.substring(0, 100)}`);
                
                // This confirms the issue!
                expect(error.message).to.include("revert");
                return; // Test successful - issue reproduced
              }
            }
          }
        }
      }
      
      console.log("\n❌ Could not reproduce the exact failure condition");
      console.log("This suggests the issue requires very specific conditions that may not");
      console.log("occur in practice with the current vault implementation.");
    });
  });

  describe("Part 4: Direct simulation of router logic", () => {
    it("Should directly test the router withdrawal logic", async () => {
      console.log("\n=== DIRECT ROUTER LOGIC TEST ===\n");
      
      // Setup
      const deposit = parseUnits("1000", dStableDecimals);
      await stable.mint(user1.address, deposit);
      await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), deposit);
      await DStakeToken.connect(user1).deposit(deposit, user1.address);
      
      const withdrawAmount = parseUnits("100", dStableDecimals);
      
      // Simulate exact router logic
      console.log("Simulating router.withdraw() logic:");
      
      // Line 204: previewWithdraw
      const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(withdrawAmount);
      console.log(`1. vaultAssetAmount from previewWithdraw: ${vaultAssetAmount}`);
      
      // Line 217-219: What convertFromVaultAsset would return (uses redeem)
      const receivedDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
      console.log(`2. receivedDStable from redeem: ${receivedDStable}`);
      
      // Line 236: Calculate surplus
      const surplus = receivedDStable > withdrawAmount ? receivedDStable - withdrawAmount : 0n;
      console.log(`3. surplus: ${surplus} wei`);
      
      if (surplus > 0n) {
        // Line 242: This is where it could fail
        const sharesForSurplus = await wrappedDLendToken.previewDeposit(surplus);
        console.log(`4. previewDeposit(surplus): ${sharesForSurplus} shares`);
        
        if (sharesForSurplus === 0n) {
          console.log("\n⚠️ ISSUE CONFIRMED!");
          console.log("deposit(surplus) would revert because previewDeposit returns 0");
          console.log("This would cause the entire withdrawal to fail!");
          
          // Verify actual withdrawal would fail
          await expect(
            DStakeToken.connect(user1).withdraw(withdrawAmount, user1.address, user1.address)
          ).to.be.reverted;
          
          return; // Issue confirmed
        } else {
          console.log("\n✅ Surplus can be re-deposited - no issue");
        }
      } else {
        console.log("\n✅ No surplus generated - no issue");
      }
    });
  });

  describe("Part 5: Exchange rate manipulation test", () => {
    it("Should test with different exchange rates", async () => {
      console.log("\n=== EXCHANGE RATE TEST ===\n");
      
      // Initial setup
      const initialDeposit = parseUnits("100", dStableDecimals);
      await stable.mint(deployer.address, initialDeposit);
      await dStableToken.connect(deployer).approve(wrappedDLendToken.target, initialDeposit);
      
      // Direct deposit to wrapped token to establish initial rate
      await wrappedDLendToken.connect(deployer).deposit(initialDeposit, deployer.address);
      
      // Now test through DStake
      const userDeposit = parseUnits("1000", dStableDecimals);
      await stable.mint(user1.address, userDeposit);
      await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), userDeposit);
      await DStakeToken.connect(user1).deposit(userDeposit, user1.address);
      
      // Check current exchange rate
      const oneShare = parseUnits("1", dStableDecimals);
      const assetsPerShare = await wrappedDLendToken.convertToAssets(oneShare);
      console.log(`Current rate: 1 share = ${ethers.formatUnits(assetsPerShare, dStableDecimals)} assets`);
      
      // Test withdrawal with current rate
      const withdrawAmount = parseUnits("99.999999999999999999", dStableDecimals);
      const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(withdrawAmount);
      const actualDStable = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
      const surplus = actualDStable > withdrawAmount ? actualDStable - withdrawAmount : 0n;
      
      console.log(`Withdraw amount: ${ethers.formatUnits(withdrawAmount, dStableDecimals)}`);
      console.log(`Surplus: ${surplus} wei`);
      
      if (surplus > 0n) {
        const depositPreview = await wrappedDLendToken.previewDeposit(surplus);
        console.log(`previewDeposit(${surplus} wei) = ${depositPreview}`);
        
        if (depositPreview === 0n) {
          console.log("⚠️ ISSUE CONFIRMED WITH CURRENT EXCHANGE RATE!");
        }
      }
    });
  });
});