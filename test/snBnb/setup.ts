import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "ethereum-waffle";

import { accountFixture, deployFixture } from "../fixture";

describe("SnBnb::setup", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;

  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;
  });

  it("Can't deploy with zero contract", async function () {
    const { deployContract } = await loadFixture(deployFixture);
    const snBnb = await deployContract("SnBnb");

    await expect(
      upgrades.deployProxy(await ethers.getContractFactory("SnBnb"), [
        ADDRESS_ZERO,
      ])
    ).to.be.revertedWith("zero address provided");

    await expect(snBnb.initialize(this.addrs[1].address)).to.be.revertedWith(
      "Initializable: contract is already initialized"
    );
  });

  it("Should be able to deploy proxy contract", async function () {
    const snBnb = await upgrades.deployProxy(
      await ethers.getContractFactory("SnBnb"),
      [this.addrs[0].address]
    );
    await snBnb.deployed();

    expect(await snBnb.name()).to.equals("Synclub Staked BNB");
    expect(await snBnb.symbol()).to.equals("SnBNB");
    // check admin role
    expect(
      await snBnb.hasRole(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        this.addrs[0].address
      )
    ).to.equals(true);
  });
});
