import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "ethereum-waffle";

import { accountFixture, deployFixture } from "../fixture";

describe("LisBNB::setup", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;

  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;
  });

  it("Can't deploy with zero contract", async function () {
    const { deployContract } = await loadFixture(deployFixture);
    const lisBNB = await deployContract("LisBNB");

    await expect(
      upgrades.deployProxy(
        await ethers.getContractFactory("LisBNB"),
        [ADDRESS_ZERO],
        { initializer: "initialize" }
      )
    ).to.be.revertedWith("zero address provided");

    await expect(lisBNB.initialize(this.addrs[1].address)).to.be.revertedWith(
      "Initializable: contract is already initialized"
    );
  });

  it("Should be able to deploy proxy contract", async function () {
    const lisBNB = await upgrades.deployProxy(
      await ethers.getContractFactory("LisBNB"),
      [this.addrs[0].address]
    );
    await lisBNB.deployed();

    expect(await lisBNB.name()).to.equals("Lista Staked BNB");
    expect(await lisBNB.symbol()).to.equals("lisBNB");
    // check admin role
    expect(
      await lisBNB.hasRole(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        this.addrs[0].address
      )
    ).to.equals(true);
  });
});
