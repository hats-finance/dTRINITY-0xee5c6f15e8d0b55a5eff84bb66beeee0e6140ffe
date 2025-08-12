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
  SDUSD_CONFIG,
} from "./fixture";
import { ERC20StablecoinUpgradeable } from "../../typechain-types/contracts/dstable/ERC20StablecoinUpgradeable";
import { WrappedDLendConversionAdapter } from "../../typechain-types/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter";
import { WrappedDLendConversionAdapter__factory } from "../../typechain-types/factories/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter__factory";

const parseUnits = (value: string | number, decimals: number | bigint) =>
  ethers.parseUnits(value.toString(), decimals);

describe("Issue #73: Simple Surplus Reproduction Test", () => {
  const fixture = createDStakeFixture(SDUSD_CONFIG);
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
    wrappedDLendToken = await ethers.getContractAt("@openzeppelin/contracts/interfaces/IERC4626.sol:IERC4626", vaultAssetAddress);

    // Prepare stablecoin for minting
    stable = (await ethers.getContractAt(
      "ERC20StablecoinUpgradeable",
      await dStableToken.getAddress(),
      deployer
    )) as ERC20StablecoinUpgradeable;
    minterRole = await stable.MINTER_ROLE();
    await stable.grantRole(minterRole, deployer.address);
  });

  it("Should demonstrate the surplus issue with real values", async () => {
    console.log("\n====== SURPLUS ISSUE REPRODUCTION ======\n");
    
    // Step 1: Setup - Mint and deposit
    const depositAmount = parseUnits("1000", dStableDecimals);
    await stable.mint(user1.address, depositAmount);
    await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), depositAmount);
    await DStakeToken.connect(user1).deposit(depositAmount, user1.address);
    
    console.log(`1. Deposited: ${ethers.formatUnits(depositAmount, dStableDecimals)} dStable`);
    
    // Step 2: Test withdrawal to check for surplus
    const withdrawAmount = parseUnits("100", dStableDecimals);
    console.log(`\n2. Attempting to withdraw: ${ethers.formatUnits(withdrawAmount, dStableDecimals)} dStable`);
    
    // Step 3: Trace the exact calculation path used in the router
    const sharesNeeded = await DStakeToken.previewWithdraw(withdrawAmount);
    console.log(`   - Shares needed (from DStakeToken.previewWithdraw): ${sharesNeeded}`);
    
    // This is what the router does (line 204 in DStakeRouterDLend.sol)
    const vaultAssetAmount = await wrappedDLendToken.previewWithdraw(withdrawAmount);
    console.log(`   - Vault asset amount (from IERC4626.previewWithdraw): ${vaultAssetAmount}`);
    
    // This is what adapter.convertFromVaultAsset would return (uses redeem internally)
    const actualDStableFromRedeem = await wrappedDLendToken.previewRedeem(vaultAssetAmount);
    console.log(`   - Actual dStable from redeem: ${ethers.formatUnits(actualDStableFromRedeem, dStableDecimals)}`);
    
    // Calculate surplus
    const surplus = actualDStableFromRedeem - withdrawAmount;
    console.log(`\n3. SURPLUS DETECTED: ${surplus} wei`);
    
    if (surplus > 0n) {
      // Check if surplus can be re-deposited (line 238-242 in router)
      const previewDepositResult = await wrappedDLendToken.previewDeposit(surplus);
      console.log(`   - previewDeposit(${surplus} wei) returns: ${previewDepositResult}`);
      
      if (previewDepositResult === 0n) {
        console.log("\n⚠️  ISSUE CONFIRMED: Surplus too small to re-deposit!");
        console.log("   This would cause deposit(surplus) to revert at line 242 in DStakeRouterDLend.sol");
        console.log("   The entire withdrawal transaction would fail!\n");
        
        // Try to actually perform the withdrawal to confirm it reverts
        console.log("4. Attempting actual withdrawal (should revert)...");
        try {
          await DStakeToken.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
          console.log("   ❌ Withdrawal succeeded (unexpected - issue may not reproduce in this environment)");
        } catch (error: any) {
          console.log("   ✅ Withdrawal reverted as expected!");
          console.log(`   Error: ${error.message.substring(0, 100)}...`);
        }
      } else {
        console.log(`   - Surplus CAN be re-deposited (${previewDepositResult} shares)`);
        console.log("   No issue in this case");
      }
    } else {
      console.log("   No surplus generated - no issue");
    }
    
    // Test with different amounts to find problematic cases
    console.log("\n====== TESTING VARIOUS AMOUNTS ======\n");
    const testAmounts = [
      "1", "10", "50", "99.999999", "100.000001", "250", "500", "999.999999"
    ];
    
    for (const amount of testAmounts) {
      const testWithdrawAmount = parseUnits(amount, dStableDecimals);
      const testVaultAssetAmount = await wrappedDLendToken.previewWithdraw(testWithdrawAmount);
      const testActualDStable = await wrappedDLendToken.previewRedeem(testVaultAssetAmount);
      const testSurplus = testActualDStable > testWithdrawAmount ? testActualDStable - testWithdrawAmount : 0n;
      
      if (testSurplus > 0n) {
        const testPreviewDeposit = await wrappedDLendToken.previewDeposit(testSurplus);
        const wouldFail = testPreviewDeposit === 0n;
        console.log(`Amount: ${amount.padEnd(12)} | Surplus: ${testSurplus.toString().padEnd(4)} wei | Re-deposit: ${wouldFail ? "❌ WOULD FAIL" : "✅ OK"}`);
      }
    }
  });

  it("Should test the exact scenario from auditor's POC", async () => {
    console.log("\n====== AUDITOR'S POC SCENARIO ======\n");
    
    // Setup similar to auditor's test
    const assets = parseUnits("1000", dStableDecimals); // 1000 tokens with 18 decimals
    
    // Mint and deposit first
    await stable.mint(user1.address, assets * 2n);
    await dStableToken.connect(user1).approve(await DStakeToken.getAddress(), assets * 2n);
    await DStakeToken.connect(user1).deposit(assets * 2n, user1.address);
    
    console.log("Testing withdrawal patterns that create 1-2 wei surplus:");
    
    // Test pattern from auditor's POC
    for (let i = 0n; i < 10n; i++) {
      const testAmount = assets + i;
      
      // Get the preview amounts
      const previewWithdrawResult = await wrappedDLendToken.previewWithdraw(testAmount);
      const previewRedeemResult = await wrappedDLendToken.previewRedeem(previewWithdrawResult);
      const delta = previewRedeemResult > testAmount ? previewRedeemResult - testAmount : 0n;
      
      if (delta > 0n) {
        const previewDepositForDelta = await wrappedDLendToken.previewDeposit(delta);
        console.log(`Test ${i}: Amount=${ethers.formatUnits(testAmount, dStableDecimals)}`);
        console.log(`  Delta: ${delta} wei`);
        console.log(`  previewDeposit(delta): ${previewDepositForDelta}`);
        if (previewDepositForDelta === 0n) {
          console.log(`  ⚠️ WOULD CAUSE REVERT - deposit returns 0 shares!`);
        }
      }
    }
  });
});