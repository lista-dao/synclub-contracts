import { expect } from "chai";
import { Contract } from "ethers";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "ethereum-waffle";

import { accountFixture } from "../fixture";

describe("SLisBNB::mint", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  let slisBNB: Contract;

  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;

    slisBNB = await upgrades.deployProxy(
      await ethers.getContractFactory("SLisBNB"),
      [deployer.address],
      { initializer: "initialize" }
    );
    await slisBNB.deployed();
  });

  it("Can't setStakeManager if caller is not admin", async function () {
    await expect(
      slisBNB.connect(this.addrs[0]).setStakeManager(this.addrs[1].address)
    ).to.be.revertedWith("AccessControl: account");
  });

  it("Should be able to setStakeManager by admin", async function () {
    const manager = this.addrs[0].address;
    const tx = await slisBNB.connect(this.deployer).setStakeManager(manager);
    expect(tx).to.emit(slisBNB, "SetStakeManager").withArgs(manager);

    await expect(
      slisBNB.connect(this.deployer).setStakeManager(manager)
    ).to.be.revertedWith("Old address == new address");

    await expect(
      slisBNB.connect(this.deployer).setStakeManager(ADDRESS_ZERO)
    ).to.be.revertedWith("zero address provided");
  });

  it("Can't mint if caller is not manager", async function () {
    await expect(
      slisBNB.connect(this.deployer).mint(this.addrs[1].address, 1)
    ).to.be.revertedWith("Accessible only by StakeManager Contract");
  });

  it("Should be able to mint by manager", async function () {
    const recipient = this.addrs[1].address;
    const [balanceBefore] = await Promise.all([slisBNB.balanceOf(recipient)]);
    await slisBNB.connect(this.addrs[0]).mint(recipient, 100);
    const [balanceAfter] = await Promise.all([slisBNB.balanceOf(recipient)]);
    expect(balanceAfter.sub(balanceBefore)).to.equals(100);
  });

  it("Can't burn if caller is not manager", async function () {
    await expect(
      slisBNB.connect(this.deployer).burn(this.addrs[1].address, 1)
    ).to.be.revertedWith("Accessible only by StakeManager Contract");
  });

  it("Should be able to burn by manager", async function () {
    const recipient = this.addrs[1].address;
    const [balanceBefore] = await Promise.all([slisBNB.balanceOf(recipient)]);
    await slisBNB.connect(this.addrs[0]).burn(recipient, 80);
    const [balanceAfter] = await Promise.all([slisBNB.balanceOf(recipient)]);
    expect(balanceBefore.sub(balanceAfter)).to.equals(80);
  });
});
