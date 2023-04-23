import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";

import { accountFixture, deployFixture } from "../fixture";

describe("SnStakeManager::setup", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;

  let mockSnBNB: MockContract;

  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;
    const { deployMockContract } = await loadFixture(deployFixture);
    mockSnBNB = await deployMockContract("SnBnb");
  });

  it("Can't deploy with zero contract", async function () {
    const { deployContract } = await loadFixture(deployFixture);
    const stakeManager = await deployContract("SnStakeManager");

    const allArgs = [
      [
        ADDRESS_ZERO,
        this.addrs[1].address,
        this.addrs[2].address,
        this.addrs[3].address,
        1_000,
        this.addrs[4].address,
        this.addrs[5].address,
      ],
      [
        this.addrs[0].address,
        ADDRESS_ZERO,
        this.addrs[2].address,
        this.addrs[3].address,
        1_000,
        this.addrs[4].address,
        this.addrs[5].address,
      ],
      [
        this.addrs[0].address,
        this.addrs[1].address,
        ADDRESS_ZERO,
        this.addrs[3].address,
        1_000,
        this.addrs[4].address,
        this.addrs[5].address,
      ],
      [
        this.addrs[0].address,
        this.addrs[1].address,
        this.addrs[2].address,
        ADDRESS_ZERO,
        1_000,
        this.addrs[4].address,
        this.addrs[5].address,
      ],
      [
        this.addrs[0].address,
        this.addrs[1].address,
        this.addrs[2].address,
        this.addrs[3].address,
        1_000,
        ADDRESS_ZERO,
        this.addrs[5].address,
      ],
      [
        this.addrs[0].address,
        this.addrs[1].address,
        this.addrs[2].address,
        this.addrs[3].address,
        1_000,
        this.addrs[4].address,
        ADDRESS_ZERO,
      ],
    ];

    for (let i = 0; i < allArgs.length; i++) {
      await expect(stakeManager.initialize(...allArgs[i])).to.be.revertedWith(
        "zero address provided"
      );
    }

    await expect(
      stakeManager.initialize(
        this.addrs[0].address,
        this.addrs[1].address,
        this.addrs[2].address,
        this.addrs[3].address,
        1_000_000_000_00,
        this.addrs[4].address,
        this.addrs[5].address
      )
    ).to.be.revertedWith("_synFee must not exceed (100%)");
  });

  it("Should be able to setup contract with properly configurations", async function () {
    const { deployContract } = await loadFixture(deployFixture);
    const stakeManager = await deployContract("SnStakeManager");

    const tx = await stakeManager.initialize(
      mockSnBNB.address,
      this.addrs[1].address,
      this.addrs[2].address,
      this.addrs[3].address,
      1_000,
      this.addrs[4].address,
      this.addrs[5].address
    );

    expect(tx)
      .to.emit(stakeManager, "SetManager")
      .withArgs(this.addrs[2].address);
    expect(tx)
      .to.emit(stakeManager, "SetBotRole")
      .withArgs(this.addrs[3].address);
    expect(tx)
      .to.emit(stakeManager, "SetBCValidator")
      .withArgs(this.addrs[5].address);
    expect(tx)
      .to.emit(stakeManager, "SetRevenuePool")
      .withArgs(this.addrs[4].address);
    expect(tx)
      .to.emit(stakeManager, "SetMinDelegateThreshold")
      .withArgs("1000000000000000000");
    expect(tx)
      .to.emit(stakeManager, "SetMinUndelegateThreshold")
      .withArgs("1000000000000000000");
    expect(tx).to.emit(stakeManager, "SetSynFee").withArgs(1_000);

    await expect(
      stakeManager.initialize(
        mockSnBNB.address,
        this.addrs[1].address,
        this.addrs[2].address,
        this.addrs[3].address,
        1_000,
        this.addrs[4].address,
        this.addrs[5].address
      )
    ).to.be.revertedWith("Initializable: contract is already initialized");
  });
});
