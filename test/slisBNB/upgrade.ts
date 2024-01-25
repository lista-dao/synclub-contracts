import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "ethereum-waffle";

import { accountFixture } from "../fixture";

describe("SLisBNB::upgrade", function () {
  before(async function () {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;
  });

  it("should be able to upgrade", async function () {
    const SnBNB = await ethers.getContractFactory("SnBnb");
    const SLisBNB = await ethers.getContractFactory("SLisBNB");
    const snBNB = await upgrades.deployProxy(SnBNB, [this.deployer.address], {
      initializer: "initialize",
    });
    await snBNB.deployed();
    await upgrades.validateUpgrade(snBNB.address, SLisBNB);
    const slisBNB = await upgrades.upgradeProxy(snBNB.address, SLisBNB);
    expect(slisBNB.address).to.equals(snBNB.address);
  });

  it("name and symbol should be changed correctly after upgraded", async function () {
    const SnBNB = await ethers.getContractFactory("SnBnb");
    const SLisBNB = await ethers.getContractFactory("SLisBNB");
    const snBNB = await upgrades.deployProxy(SnBNB, [this.deployer.address], {
      initializer: "initialize",
    });
    await snBNB.deployed();
    expect(await snBNB.name()).to.equals("Synclub Staked BNB");
    expect(await snBNB.symbol()).to.equals("SnBNB");
    const slisBNB = await upgrades.upgradeProxy(snBNB.address, SLisBNB);
    expect(await slisBNB.name()).to.equals("Staked Lista BNB");
    expect(await slisBNB.symbol()).to.equals("slisBNB");
  });

  it("the admin roles shouldn't be changed after upgraded and can be changed by admin after upgraded", async function () {
    const SnBNB = await ethers.getContractFactory("SnBnb");
    const SLisBNB = await ethers.getContractFactory("SLisBNB");
    const snBNB = await upgrades.deployProxy(SnBNB, [this.addrs[1].address], {
      initializer: "initialize",
    });
    await snBNB.deployed();
    const adminRole = await snBNB.DEFAULT_ADMIN_ROLE();
    await expect(
      snBNB.connect(this.addrs[1]).grantRole(adminRole, this.addrs[2].address)
    )
      .to.emit(snBNB, "RoleGranted")
      .withArgs(adminRole, this.addrs[2].address, this.addrs[1].address);
    const deployerPreviousAdminRole = await snBNB.hasRole(
      adminRole,
      this.deployer.address
    );
    const addrs1PreviousAdminRole = await snBNB.hasRole(
      adminRole,
      this.addrs[1].address
    );
    const addrs2PreviousAdminRole = await snBNB.hasRole(
      adminRole,
      this.addrs[2].address
    );
    const slisBNB = await upgrades.upgradeProxy(snBNB.address, SLisBNB);
    expect(await slisBNB.hasRole(adminRole, this.deployer.address)).to.equals(
      false
    );
    expect(await slisBNB.hasRole(adminRole, this.addrs[1].address)).to.equals(
      true
    );
    expect(await slisBNB.hasRole(adminRole, this.addrs[2].address)).to.equals(
      true
    );
    expect(await slisBNB.hasRole(adminRole, this.deployer.address)).to.equals(
      deployerPreviousAdminRole
    );
    expect(await slisBNB.hasRole(adminRole, this.addrs[1].address)).to.equals(
      addrs1PreviousAdminRole
    );
    expect(await slisBNB.hasRole(adminRole, this.addrs[2].address)).to.equals(
      addrs2PreviousAdminRole
    );
    // update deployer to admin
    await expect(
      await slisBNB
        .connect(this.addrs[1])
        .grantRole(adminRole, this.deployer.address)
    )
      .to.emit(slisBNB, "RoleGranted")
      .withArgs(adminRole, this.deployer.address, this.addrs[1].address);
    expect(await slisBNB.hasRole(adminRole, this.deployer.address)).to.equals(
      true
    );
    // remove addrs[1] from admin
    await expect(await slisBNB.revokeRole(adminRole, this.addrs[1].address))
      .to.emit(slisBNB, "RoleRevoked")
      .withArgs(adminRole, this.addrs[1].address, this.deployer.address);
    expect(await slisBNB.hasRole(adminRole, this.addrs[1].address)).to.equals(
      false
    );
  });

  it("the stakeManager shouldn't be changed after upgraded and can mint/burn after upgraded", async function () {
    const SnBNB = await ethers.getContractFactory("SnBnb");
    const SLisBNB = await ethers.getContractFactory("SLisBNB");
    const snBNB = await upgrades.deployProxy(SnBNB, [this.addrs[0].address], {
      initializer: "initialize",
    });
    await snBNB.deployed();
    // set stakeManager
    const manager = this.addrs[1];
    const tx = await snBNB
      .connect(this.addrs[0])
      .setStakeManager(manager.address);
    expect(tx).to.emit(snBNB, "SetStakeManager").withArgs(manager.address);
    const recipient1 = this.addrs[1].address;
    const recipient2 = this.addrs[2].address;
    const recipient3 = this.addrs[3].address;
    await snBNB.connect(manager).mint(recipient2, 100);
    await snBNB.connect(manager).mint(recipient3, 10);
    await snBNB.connect(manager).burn(recipient3, 1);
    const [balance1, balance2, balance3] = await Promise.all([
      snBNB.balanceOf(recipient1),
      snBNB.balanceOf(recipient2),
      snBNB.balanceOf(recipient3),
    ]);
    expect(balance1).to.equals(0);
    expect(balance2).to.equals(100);
    expect(balance3).to.equals(9);

    const slisBNB = await upgrades.upgradeProxy(snBNB.address, SLisBNB);

    const [balanceAfter1, balanceAfter2, balanceAfter3] = await Promise.all([
      slisBNB.balanceOf(recipient1),
      slisBNB.balanceOf(recipient2),
      slisBNB.balanceOf(recipient3),
    ]);
    expect(balance1).to.equals(balanceAfter1);
    expect(balance2).to.equals(balanceAfter2);
    expect(balance3).to.equals(balanceAfter3);

    await expect(
      slisBNB.connect(this.deployer).mint(this.addrs[1].address, 1)
    ).to.be.revertedWith("Accessible only by StakeManager Contract");

    await slisBNB.connect(manager).mint(recipient2, 100);
    await slisBNB.connect(manager).mint(recipient3, 10);
    await slisBNB.connect(manager).burn(recipient3, 1);

    const [balanceChanged1, balanceChanged2, balanceChanged3] =
      await Promise.all([
        slisBNB.balanceOf(recipient1),
        slisBNB.balanceOf(recipient2),
        slisBNB.balanceOf(recipient3),
      ]);
    expect(balanceChanged1.sub(balanceAfter1)).to.equals(0);
    expect(balanceChanged2.sub(balanceAfter2)).to.equals(100);
    expect(balanceChanged3.sub(balanceAfter3)).to.equals(9);
  });

  it("the allowances shouldn't be changed after upgraded and can work well after upgraded", async function () {
    const SnBNB = await ethers.getContractFactory("SnBnb");
    const SLisBNB = await ethers.getContractFactory("SLisBNB");
    const snBNB = await upgrades.deployProxy(SnBNB, [this.addrs[0].address], {
      initializer: "initialize",
    });
    await snBNB.deployed();
    // set stakeManager
    const manager = this.addrs[1];
    const tx = await snBNB
      .connect(this.addrs[0])
      .setStakeManager(manager.address);
    expect(tx).to.emit(snBNB, "SetStakeManager").withArgs(manager.address);
    const recipient1 = this.addrs[1].address;
    const recipient2 = this.addrs[2].address;
    const recipient3 = this.addrs[3].address;
    await snBNB.connect(manager).mint(recipient2, 100);
    await snBNB.connect(manager).mint(recipient3, 10);
    // approve
    await snBNB.connect(this.addrs[2]).approve(recipient1, 50);

    const slisBNB = await upgrades.upgradeProxy(snBNB.address, SLisBNB);

    const [allowance1, allowance2, allowance3] = await Promise.all([
      slisBNB.allowance(recipient2, recipient1),
      slisBNB.allowance(recipient2, recipient2),
      slisBNB.allowance(recipient2, recipient3),
    ]);
    expect(allowance1).to.equals(50);
    expect(allowance2).to.equals(0);
    expect(allowance3).to.equals(0);

    await expect(
      slisBNB.connect(this.addrs[2]).transferFrom(recipient2, recipient1, 50)
    ).to.be.revertedWith("ERC20: insufficient allowance");

    await expect(
      slisBNB.connect(this.addrs[1]).transferFrom(recipient2, recipient1, 51)
    ).to.be.revertedWith("ERC20: insufficient allowance");

    await expect(
      slisBNB.connect(this.addrs[1]).transferFrom(recipient2, recipient1, 50)
    )
      .to.emit(slisBNB, "Transfer")
      .withArgs(recipient2, recipient1, 50);

    expect(await slisBNB.allowance(recipient2, recipient1)).to.equals(0);

    const [balanceChanged1, balanceChanged2, balanceChanged3] =
      await Promise.all([
        slisBNB.balanceOf(recipient1),
        slisBNB.balanceOf(recipient2),
        slisBNB.balanceOf(recipient3),
      ]);
    expect(balanceChanged1).to.equals(50);
    expect(balanceChanged2).to.equals(50);
    expect(balanceChanged3).to.equals(10);
  });
});
