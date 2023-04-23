import { expect } from "chai";
import { ethers } from "hardhat";
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

    await expect(snBnb.initialize(ADDRESS_ZERO)).to.be.revertedWith(
      "zero address provided"
    );

    await snBnb.initialize(this.addrs[0].address);
    expect(await snBnb.name()).to.equals("Synclub BNB");
    expect(await snBnb.symbol()).to.equals("SnBNB");
    // check admin role
    expect(
      await snBnb.hasRole(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        this.addrs[0].address
      )
    ).to.equals(true);

    await expect(snBnb.initialize(this.addrs[1].address)).to.be.revertedWith(
      "Initializable: contract is already initialized"
    );
  });
});
