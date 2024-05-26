import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { Contract } from "ethers";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { impersonateAccount, toWei } from "../helper";

import { accountFixture, deployFixture } from "../fixture";

describe("ListaStakeManager::access", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  const NATIVE_STAKING = "0x0000000000000000000000000000000000002001";
  const RELAYER_FEE = "2000000000000000";

  let mockSnBNB: MockContract;
  let mockNativeStaking: MockContract;
  let stakeManager: Contract;
  let admin: SignerWithAddress;
  let manager: SignerWithAddress;
  let bot: SignerWithAddress;
  let nativeStakingSigner: SignerWithAddress;

  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;

    const { deployMockContract } = await loadFixture(deployFixture);
    mockNativeStaking = await deployMockContract("MockNativeStaking", {
      address: NATIVE_STAKING,
    });
    nativeStakingSigner = await impersonateAccount(
      mockNativeStaking.address,
      toWei("10").toHexString()
    );

    mockSnBNB = await deployMockContract("SLisBNB");
    admin = this.addrs[1];
    manager = this.addrs[2];
    bot = this.addrs[3];

    stakeManager = await upgrades.deployProxy(
      await ethers.getContractFactory("ListaStakeManager"),
      [
        mockSnBNB.address,
        admin.address,
        manager.address,
        bot.address,
        1_000,
        this.addrs[4].address,
        this.addrs[5].address,
      ]
    );
    await stakeManager.deployed();

    // mock native staking contract behaviors
    await Promise.all([
      mockSnBNB.mock.mint.returns(),
      mockSnBNB.mock.totalSupply.returns(toWei("1000000")),
      mockNativeStaking.mock.getRelayerFee.returns(RELAYER_FEE), // 0.002BNB relayer fee
      mockNativeStaking.mock.getMinDelegation.returns(toWei("1")),
      mockNativeStaking.mock.delegate.returns(),
      mockNativeStaking.mock.redelegate.returns(),
      mockNativeStaking.mock.undelegate.returns(),
      mockNativeStaking.mock.claimReward.returns(toWei("0.01")),
    ]);
  });

  it("Can't propose new manager if caller is not manager", async function () {
    console.log("address: ", this.addrs[2].address);
    await expect(
      stakeManager.connect(manager).proposeNewManager(this.addrs[2].address)
    ).to.be.revertedWith("Old address == new address");

    await expect(
      stakeManager.connect(manager).proposeNewManager(ADDRESS_ZERO)
    ).to.be.revertedWith("zero address provided");
  });

  it("Should be able to propose new manager by manager", async function () {
    const nextManager = this.addrs[6].address;
    const originManager = (await stakeManager.getContracts())[0];

    console.log("stakeManager manager1: ", originManager);
    const tx = await stakeManager
      .connect(manager)
      .proposeNewManager(nextManager);

    console.log("nextManager manager1: ", nextManager);
    expect(tx).to.emit(stakeManager, "ProposeManager").withArgs(nextManager);
  });

  it("Can't accept new manager if caller isn't be proposed", async function () {
    await expect(
      stakeManager.connect(this.addrs[0]).acceptNewManager()
    ).to.be.revertedWith("Accessible only by Proposed Manager");
  });

  it("Should be able to accept new manager by proposed manager", async function () {
    const tx = await stakeManager.connect(this.addrs[6]).acceptNewManager();
    const originManager = (await stakeManager.getContracts())[0];

    console.log("stakeManager manager2: ", originManager);

    expect(tx)
      .to.emit(stakeManager, "SetManager")
      .withArgs(this.addrs[6].address);

    manager = this.addrs[6];
    const newManager = (await stakeManager.getContracts())[0];
    expect(newManager).to.equals(manager.address);
  });

  it("Can't call redelegate if caller is not bot", async function () {
    await expect(
      stakeManager.connect(manager).redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0)
    ).to.be.revertedWith(
      `is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );

    await expect(
      stakeManager.connect(bot).redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0)
    ).to.be.revertedWith("Invalid Redelegation");

  });

  it("Can't revoke bot role if caller is not admin", async function () {
    await expect(stakeManager.connect(this.deployer).revokeBotRole(bot.address))
      .to.be.reverted;

    await expect(
      stakeManager.connect(admin).revokeBotRole(ADDRESS_ZERO)
    ).to.be.revertedWith("zero address provided");
  });

  it("Should be able to revoke bot role by admin", async function () {
    const role = ethers.utils.id("BOT");

    expect(await stakeManager.hasRole(role, bot.address)).to.equals(true);

    const tx = await stakeManager.connect(admin).revokeBotRole(bot.address);

    expect(tx)
      .to.emit(stakeManager, "RoleRevoked")
      .withArgs(role, bot.address, admin.address);
    expect(
      await stakeManager.hasRole(ethers.utils.id("BOT"), bot.address)
    ).to.equals(false);
  });

  it("Can't set bot role if caller is not admin", async function () {
    await expect(
      stakeManager.connect(this.deployer).setBotRole(this.addrs[7].address)
    ).to.be.reverted;

    await expect(
      stakeManager.connect(admin).setBotRole(ADDRESS_ZERO)
    ).to.be.revertedWith("zero address provided");
  });

  it("Should be able to set bot role by admin", async function () {
    const nextBot = this.addrs[7].address;
    const role = ethers.utils.id("BOT");
    expect(await stakeManager.hasRole(role, nextBot)).to.equals(false);
    const tx = await stakeManager.connect(admin).setBotRole(nextBot);

    expect(tx)
      .to.emit(stakeManager, "RoleGranted")
      .withArgs(role, nextBot, admin.address);
    expect(
      await stakeManager.hasRole(ethers.utils.id("BOT"), nextBot)
    ).to.equals(true);

    bot = this.addrs[7];
  });

  it("Can't set bsc validator if caller is not manager", async function () {
    await expect(
      stakeManager.connect(this.deployer).setBSCValidator(bot.address)
    ).to.be.revertedWith("Accessible only by Manager");

    await expect(
      stakeManager.connect(manager).setBSCValidator(this.addrs[5].address)
    ).to.be.revertedWith("Old address == new address");

    await expect(
      stakeManager.connect(manager).setBSCValidator(ADDRESS_ZERO)
    ).to.be.revertedWith("zero address provided");
  });

  it("Should be able to set bsc validator by manager", async function () {
    const tx = await stakeManager
      .connect(manager)
      .setBSCValidator(this.addrs[8].address);

    expect(tx)
      .to.emit(stakeManager, "SetBSCValidator")
      .withArgs(this.addrs[8].address);
  });

  it("Can't set reserve amount if caller is not manager", async function () {
    await expect(
      stakeManager.connect(this.deployer).setReserveAmount(0)
    ).to.be.revertedWith("Accessible only by Manager");
  });

  it("Should be able to set reserve amount by manager", async function () {
    expect(await stakeManager.reserveAmount()).to.equals(0);
    const tx = await stakeManager.connect(manager).setReserveAmount(1);

    expect(tx).to.emit(stakeManager, "SetReserveAmount").withArgs(1);
    expect(await stakeManager.reserveAmount()).to.equals(1);
  });

  // it("Can't set min undelegate threshold if caller is not manager", async function () {
  //   await expect(
  //     stakeManager.connect(this.deployer).setMinUndelegateThreshold(bot.address)
  //   ).to.be.revertedWith("Accessible only by Manager");

  //   await expect(
  //     stakeManager.connect(manager).setMinUndelegateThreshold(0)
  //   ).to.be.revertedWith("Invalid Threshold");
  // });

  // it("Should be able to set min undelegate threshold by manager", async function () {
  //   expect(await stakeManager.minUndelegateThreshold()).to.equals(ONE_E18);
  //   const tx = await stakeManager.connect(manager).setMinUndelegateThreshold(1);

  //   expect(tx).to.emit(stakeManager, "SetMinUndelegateThreshold").withArgs(1);
  //   expect(await stakeManager.minUndelegateThreshold()).to.equals(1);
  // });

  it("Can't set sync fee if caller is not admin", async function () {
    await expect(
      stakeManager.connect(this.deployer).setSynFee(1_000_000)
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`
    );

    await expect(
      stakeManager.connect(admin).setSynFee(1_000_000_000_000)
    ).to.be.revertedWith("_synFee must not exceed 10000 (100%)");
  });

  it("Should be able to set sync fee by admin", async function () {
    await stakeManager.deposit({ value: toWei("1") });
    await stakeManager.connect(bot).delegateTo({ value: RELAYER_FEE });
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: toWei("0.01"),
    });

    expect(await stakeManager.synFee()).to.equals(1_000);
    const tx = await stakeManager.connect(admin).setSynFee(1);

    expect(tx).to.emit(stakeManager, "SetSynFee").withArgs(1);
    expect(await stakeManager.synFee()).to.equals(1);
  });

  it("Can't set redirect address if caller is not admin", async function () {
    await expect(
      stakeManager
        .connect(this.deployer)
        .setRedirectAddress(this.addrs[9].address)
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`
    );
  });

  it("Should be able to set redirect address by admin", async function () {
    expect(await stakeManager.redirectAddress()).to.equals(ADDRESS_ZERO);
    const tx = await stakeManager
      .connect(admin)
      .setRedirectAddress(this.addrs[9].address);

    expect(tx)
      .to.emit(stakeManager, "SetRedirectAddress")
      .withArgs(this.addrs[9].address);
    expect(await stakeManager.redirectAddress()).to.equals(
      this.addrs[9].address
    );

    await expect(
      stakeManager.connect(admin).setRedirectAddress(this.addrs[9].address)
    ).to.be.revertedWith("Old address == new address");
    await expect(
      stakeManager.connect(admin).setRedirectAddress(ADDRESS_ZERO)
    ).to.be.revertedWith("zero address provided");
  });

  it("Can't toggle pause if caller is not admin", async function () {
    await expect(
      stakeManager.connect(this.deployer).togglePause()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`
    );
  });

  it("Should be able to toggle pause by admin", async function () {
    expect(await stakeManager.paused()).to.equals(false);
    await stakeManager.connect(admin).togglePause();
    expect(await stakeManager.paused()).to.equals(true);
    await stakeManager.connect(admin).togglePause();
    expect(await stakeManager.paused()).to.equals(false);
  });
});
