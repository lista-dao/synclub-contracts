import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "ethereum-waffle";

import { accountFixture, deployFixture } from "../fixture";

describe("SLisBNB::setup", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;

  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;
  });

  it("Can't deploy with zero contract", async function () {
    const { deployContract } = await loadFixture(deployFixture);
    const slisBNB = await deployContract("SLisBNB");

    await expect(
      upgrades.deployProxy(
        await ethers.getContractFactory("SLisBNB"),
        [ADDRESS_ZERO],
        { initializer: "initialize" }
      )
    ).to.be.revertedWith("zero address provided");

    await expect(slisBNB.initialize(this.addrs[1].address)).to.be.revertedWith(
      "Initializable: contract is already initialized"
    );
  });

  it("Should be able to deploy proxy contract", async function () {
    const slisBNB = await upgrades.deployProxy(
      await ethers.getContractFactory("SLisBNB"),
      [this.addrs[0].address]
    );
    await slisBNB.deployed();

    expect(await slisBNB.name()).to.equals("Staked Lista BNB");
    expect(await slisBNB.symbol()).to.equals("slisBNB");
    // check admin role
    expect(
      await slisBNB.hasRole(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        this.addrs[0].address
      )
    ).to.equals(true);
  });
});
