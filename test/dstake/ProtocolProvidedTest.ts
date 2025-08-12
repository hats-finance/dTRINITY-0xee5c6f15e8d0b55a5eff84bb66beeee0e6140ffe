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
  DSTAKE_CONFIGS,
  DStakeFixtureConfig,
} from "./fixture";
import { ERC20StablecoinUpgradeable } from "../../typechain-types/contracts/dstable/ERC20StablecoinUpgradeable";
import { WrappedDLendConversionAdapter__factory } from "../../typechain-types/factories/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter__factory";
import { WrappedDLendConversionAdapter } from "../../typechain-types/contracts/vaults/dstake/adapters/WrappedDLendConversionAdapter";

const parseUnits = (value: string | number, decimals: number | bigint) =>
  ethers.parseUnits(value.toString(), decimals);

describe("DStake Withdrawal Failure Mode - Rounding Issues", () => {
  // Use the first config (dUSD)
  const config = DSTAKE_CONFIGS[0];
  const fixture = createDStakeFixture(config);

  let deployer: SignerWithAddress;
  let user1: SignerWithAddress;
  let DStakeToken: DStakeToken;
  let collateralVault: DStakeCollateralVault;
  let router: DStakeRouterDLend;
  let dStableToken: ERC20;
  let stable: ERC20StablecoinUpgradeable;
  let adapter: WrappedDLendConversionAdapter;
  let adapterAddress: string;
  let dStableDecimals: bigint;
  let minterRole: string;

  beforeEach(async () => {
    const named = await getNamedAccounts();
    deployer = await ethers.getSigner(named.deployer);
    user1 = await ethers.getSigner(named.user1 || named.deployer);

    // Setup fixture
    const out = await fixture();
    DStakeToken = out.DStakeToken as unknown as DStakeToken;
    collateralVault = out.collateralVault as unknown as DStakeCollateralVault;
    router = out.router as unknown as DStakeRouterDLend;
    dStableToken = out.dStableToken;
    dStableDecimals = await dStableToken.decimals();
    adapterAddress = out.adapterAddress;
    adapter = WrappedDLendConversionAdapter__factory.connect(
      adapterAddress,
      deployer
    );

    // Prepare stablecoin for minting
    stable = (await ethers.getContractAt(
      "ERC20StablecoinUpgradeable",
      await dStableToken.getAddress(),
      deployer
    )) as ERC20StablecoinUpgradeable;
    minterRole = await stable.MINTER_ROLE();
    await stable.grantRole(minterRole, deployer.address);

    // Set withdrawal fee to 0 to isolate the rounding issue
    await DStakeToken.connect(user1).setWithdrawalFee(0);
  });

  it("demonstrates the root cause: previewDeposit returns 0 for small amounts", async () => {
    // Get the wrapped aToken directly
    const vaultAsset = await adapter.vaultAsset();
    const staticAToken = await ethers.getContractAt(
      "@openzeppelin/contracts/interfaces/IERC4626.sol:IERC4626",
      vaultAsset
    );

    // Determine the asset value of 1 share (in wei) so we know what 'small' means
    const assetPerShare = await staticAToken.previewRedeem(1n);

    // Test some representative small amounts (all < 1e3 wei)
    const smallAmounts = [1n, 2n, 3n, 4n, 5n, 10n, 100n, 1000n];

    console.log("\n=== Testing Small Deposit Amounts ===");
    for (const amount of smallAmounts) {
      const shares = await staticAToken.previewDeposit(amount);
      console.log(`Amount: ${amount} wei -> Shares: ${shares}`);

      // Any amount strictly smaller than the value of a single share
      // must round down to 0 shares.
      if (amount < assetPerShare) {
        expect(shares).to.equal(0);
      }
    }

    console.log("\nThis demonstrates why surplus recycling fails:");
    console.log(
      "- previewWithdraw() rounds UP to ensure user gets at least the requested amount"
    );
    console.log("- This creates a small surplus (typically 1-5 wei)");
    console.log("- When trying to recycle this surplus back to the vault:");
    console.log(
      "- previewDeposit() rounds DOWN and returns 0 shares for small amounts"
    );
    console.log("- StaticATokenLM.deposit() reverts with INVALID_ZERO_AMOUNT");
  });

  // ------------------------------------------------------------------
  // New tests that prove withdraw never reverts, even for extreme ranges
  // ------------------------------------------------------------------

  it("withdraw succeeds for every amount from 1 wei to 1,000 wei", async () => {
    // Ensure sufficient shares for tiny withdrawals
    const tinyDeposit = parseUnits("2", dStableDecimals); // 2 dStable
    await stable.mint(user1.address, tinyDeposit);
    await dStableToken
      .connect(user1)
      .approve(await DStakeToken.getAddress(), tinyDeposit);
    await DStakeToken.connect(user1).deposit(tinyDeposit, user1.address);

    for (let amt = 1n; amt <= 1000n; amt++) {
      await expect(
        DStakeToken.connect(user1).withdraw(amt, user1.address, user1.address),
        `withdraw(${amt} wei) reverted`
      ).to.not.be.reverted;
    }
  });

  it("withdraw succeeds for every whole-token amount from 1 to 1,000 dStable", async () => {
    // Deposit a big balance once so the loop can run
    // Each iteration withdraws incrementally larger amounts (1 + 2 + ... + 1000 = 500,500 tokens).
    // Deposit substantially more than this cumulative total to ensure every withdraw call is within bounds.
    const bigDeposit = parseUnits("600000", dStableDecimals);
    await stable.mint(user1.address, bigDeposit);
    await dStableToken
      .connect(user1)
      .approve(await DStakeToken.getAddress(), bigDeposit);
    await DStakeToken.connect(user1).deposit(bigDeposit, user1.address);

    for (let i = 1n; i <= 1000n; i++) {
      const amt = parseUnits(i.toString(), dStableDecimals); // i * 1e18
      await expect(
        DStakeToken.connect(user1).withdraw(amt, user1.address, user1.address),
        `withdraw(${i} ether) reverted`
      ).to.not.be.reverted;
    }
  });
});