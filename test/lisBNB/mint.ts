import { expect } from "chai";
import { Contract } from "ethers";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "ethereum-waffle";

import { accountFixture } from "../fixture";

describe("LisBNB::mint", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  let lisBNB: Contract;

  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;

    lisBNB = await upgrades.deployProxy(
      await ethers.getContractFactory("LisBNB"),
      [deployer.address],
      { initializer: "initialize" }
    );
    await lisBNB.deployed();
  });

  it("Can't setStakeManager if caller is not admin", async function () {
    await expect(
      lisBNB.connect(this.addrs[0]).setStakeManager(this.addrs[1].address)
    ).to.be.revertedWith("AccessControl: account");
  });

  it("Should be able to setStakeManager by admin", async function () {
    const manager = this.addrs[0].address;
    const tx = await lisBNB.connect(this.deployer).setStakeManager(manager);
    expect(tx).to.emit(lisBNB, "SetStakeManager").withArgs(manager);

    await expect(
      lisBNB.connect(this.deployer).setStakeManager(manager)
    ).to.be.revertedWith("Old address == new address");

    await expect(
      lisBNB.connect(this.deployer).setStakeManager(ADDRESS_ZERO)
    ).to.be.revertedWith("zero address provided");
  });

  it("Can't mint if caller is not manager", async function () {
    await expect(
      lisBNB.connect(this.deployer).mint(this.addrs[1].address, 1)
    ).to.be.revertedWith("Accessible only by StakeManager Contract");
  });

  it("Should be able to mint by manager", async function () {
    const recipient = this.addrs[1].address;
    const [balanceBefore] = await Promise.all([lisBNB.balanceOf(recipient)]);
    await lisBNB.connect(this.addrs[0]).mint(recipient, 100);
    const [balanceAfter] = await Promise.all([lisBNB.balanceOf(recipient)]);
    expect(balanceAfter.sub(balanceBefore)).to.equals(100);
  });

  it("Can't burn if caller is not manager", async function () {
    await expect(
      lisBNB.connect(this.deployer).burn(this.addrs[1].address, 1)
    ).to.be.revertedWith("Accessible only by StakeManager Contract");
  });

  it("Should be able to burn by manager", async function () {
    const recipient = this.addrs[1].address;
    const [balanceBefore] = await Promise.all([lisBNB.balanceOf(recipient)]);
    await lisBNB.connect(this.addrs[0]).burn(recipient, 80);
    const [balanceAfter] = await Promise.all([lisBNB.balanceOf(recipient)]);
    expect(balanceBefore.sub(balanceAfter)).to.equals(80);
  });
});
