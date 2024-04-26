import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { BigNumber, Contract, providers } from "ethers";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

import { impersonateAccount, toBytes32, toWei, readStorageAt } from "../helper";
import { accountFixture, deployFixture } from "../fixture";

describe("ListaStakeManager::withdraw", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  const RELAYER_FEE = "2000000000000000";
  const NATIVE_STAKING = "0x0000000000000000000000000000000000002001";

  let mockNativeStaking: MockContract;
  let snBnb: Contract;
  let stakeManager: Contract;
  let listaStakeManager: Contract;
  let admin: SignerWithAddress;
  let manager: SignerWithAddress;
  let bot: SignerWithAddress;
  let user: SignerWithAddress;
  let nativeStakingSigner: SignerWithAddress;
  let validator: SignerWithAddress;

  before(async function () {
    // Reset the Hardhat Network, starting a new instance
    await ethers.provider.send("hardhat_reset", []);
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
    snBnb = await upgrades.deployProxy(
      await ethers.getContractFactory("SnBnb"),
      [this.addrs[1].address]
    );
    await snBnb.deployed();
    admin = this.addrs[1];
    manager = this.addrs[2];
    bot = this.addrs[3];
    validator = this.addrs[5];
    user = this.addrs[6];

    stakeManager = await upgrades.deployProxy(
      await ethers.getContractFactory("SnStakeManager"),
      [
        snBnb.address,
        admin.address,
        manager.address,
        bot.address,
        100_000_000, // 1% sync fee to revenue pool
        this.addrs[4].address,
        this.addrs[5].address,
      ]
    );
    await stakeManager.deployed();

    // mock native staking contract behaviors
    await Promise.all([
      snBnb.connect(admin).setStakeManager(stakeManager.address),
      mockNativeStaking.mock.getRelayerFee.returns(RELAYER_FEE), // 0.016BNB relayer fee
      mockNativeStaking.mock.getMinDelegation.returns(toWei("1")),
      mockNativeStaking.mock.delegate.returns(),
      mockNativeStaking.mock.redelegate.returns(),
      mockNativeStaking.mock.undelegate.returns(),
    ]);
  });

  it("Should reverted when there is new requests or old requests have not been fully covered", async function () {
    await snBnb
      .connect(user)
      .approve(stakeManager.address, ethers.constants.MaxUint256);
    await stakeManager.connect(user).deposit({ value: toWei("10") });

    // upgrade
    const ListaStakeManager = await ethers.getContractFactory(
      "ListaStakeManager"
    );
    await stakeManager.connect(user).requestWithdraw(toWei("1"));
    listaStakeManager = await upgrades.upgradeProxy(
      stakeManager,
      ListaStakeManager,
      {
        unsafeAllowRenames: true,
      }
    );
    await listaStakeManager.deployed();
    // should be reverted when binary search covered index by 0.9bnb
    // await expect(
    //   listaStakeManager.connect(user).requestWithdraw(toWei("0.9"))
    // ).to.be.revertedWith("SnStakeManager: insufficient balance");
    await expect(
      listaStakeManager.connect(user).binarySearchCoveredIndex(toWei("0.9"))
    ).to.be.revertedWith(
      "No new requests or old requests have not been fully covered"
    );
  });

  it("Binary search covered index", async function () {
    await snBnb
      .connect(user)
      .approve(stakeManager.address, ethers.constants.MaxUint256);

    for (let i = 0; i < 2; i++) {
      await stakeManager.connect(user).deposit({ value: toWei("100") });
      await stakeManager.connect(user).requestWithdraw(toWei("1")); // 1st request of user1
      await stakeManager.connect(user).requestWithdraw(toWei("1")); // 2nd request of user1
      await stakeManager.connect(bot).delegate({ value: RELAYER_FEE });
      await stakeManager.connect(bot).undelegate({ value: RELAYER_FEE });
      await mockNativeStaking.mock.claimUndelegated.returns(toWei("2"));
      await nativeStakingSigner.sendTransaction({
        to: stakeManager.address,
        value: toWei("2"),
      });

      await stakeManager.connect(bot).claimUndelegated();
    }
    // nextUndelegateUUID should equal 2
    expect(await stakeManager.nextUndelegateUUID()).to.be.equal(2);
    // next confirmedUndelegatedUUID should equal 2
    expect(await stakeManager.confirmedUndelegatedUUID()).to.be.equal(2);

    // must add at least 1 requests before upgrade
    await stakeManager.connect(user).requestWithdraw(toWei("1")); // 2nd request of user1

    // upgrade
    const ListaStakeManager = await ethers.getContractFactory(
      "ListaStakeManager"
    );
    listaStakeManager = await upgrades.upgradeProxy(
      stakeManager,
      ListaStakeManager,
      {
        unsafeAllowRenames: true,
      }
    );
    await listaStakeManager.deployed();
    // handle old requests
    await stakeManager.connect(bot).undelegate();
    await mockNativeStaking.mock.claimUndelegated.returns(toWei("1"));
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: toWei("1"),
    });
    await stakeManager.connect(bot).claimUndelegated();
    // nextConfirmedRequestUUID should equal 2
    expect(await stakeManager.requestUUID()).to.be.equal(2);
    // next confirmedUndelegatedUUID should equal 3
    expect(await stakeManager.nextConfirmedRequestUUID()).to.be.equal(3);

    // new requests
    // 1 new request, next requestUUID = 3
    await listaStakeManager.connect(user).requestWithdraw(toWei("1"));
    // requestUUID = 3
    expect(await listaStakeManager.requestUUID()).to.be.equal("3");
    // nextConfirmedRequestUUID = 3
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.be.equal("3");

    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("0.9"))
      ).toString()
    ).to.be.equal("0");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("1"))
      ).toString()
    ).to.be.equal("0");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("1.1"))
      ).toString()
    ).to.be.equal("0");

    // 2 new requests, requestUUID = 4
    await listaStakeManager.connect(user).requestWithdraw(toWei("1"));
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("0.9"))
      ).toString()
    ).to.be.equal("0");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("1"))
      ).toString()
    ).to.be.equal("0");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("2"))
      ).toString()
    ).to.be.equal("1");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("2.1"))
      ).toString()
    ).to.be.equal("1");

    // 3 new requests, requestUUID = 5
    await listaStakeManager.connect(user).requestWithdraw(toWei("1"));
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("0.9"))
      ).toString()
    ).to.be.equal("0");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("1"))
      ).toString()
    ).to.be.equal("0");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("2"))
      ).toString()
    ).to.be.equal("1");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("2.9"))
      ).toString()
    ).to.be.equal("1");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("3"))
      ).toString()
    ).to.be.equal("2");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("3.1"))
      ).toString()
    ).to.be.equal("2");

    await expect(
      listaStakeManager.connect(bot).undelegateFrom(validator, toWei("1.5"))
    )
      .to.emit(listaStakeManager, "UndelegateFrom")
      .withArgs(validator, toWei("1.5"));
    await mockNativeStaking.mock.claimUndelegated.returns(toWei("1.5"));
    await nativeStakingSigner.sendTransaction({
      to: listaStakeManager.address,
      value: toWei("1.5"),
    });
    await listaStakeManager.connect(bot).claimUndelegated();

    // next confirmedUndelegatedUUID should equal 4
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.be.equal("4");
    // requestUUID should equal 5
    expect(await listaStakeManager.requestUUID()).to.be.equal("5");

    // 2 new requests left
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("0.9"))
      ).toString()
    ).to.be.equal("1");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("1"))
      ).toString()
    ).to.be.equal("1");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("2"))
      ).toString()
    ).to.be.equal("2");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager
          .connect(user)
          .binarySearchCoveredIndex(toWei("3"))
      ).toString()
    ).to.be.equal("2");
  });

  it("getAmountToUndelegate", async function () {
    await snBnb
      .connect(user)
      .approve(stakeManager.address, ethers.constants.MaxUint256);

    await stakeManager.connect(user).deposit({ value: toWei("100") });
    // must add at least 1 requests before upgrade
    await stakeManager.connect(user).requestWithdraw(toWei("1")); // 2nd request of user1

    // upgrade
    const ListaStakeManager = await ethers.getContractFactory(
      "ListaStakeManager"
    );
    listaStakeManager = await upgrades.upgradeProxy(
      stakeManager,
      ListaStakeManager,
      {
        unsafeAllowRenames: true,
      }
    );
    await listaStakeManager.deployed();
    // handle old requests
    await stakeManager.connect(bot).undelegate();
    await mockNativeStaking.mock.claimUndelegated.returns(toWei("1"));
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: toWei("1"),
    });
    await stakeManager.connect(bot).claimUndelegated();
    // 1 new requests
    await listaStakeManager.connect(user).requestWithdraw(toWei("1"));
    expect(await listaStakeManager.requestUUID()).to.be.equal("1");
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.be.equal("2");

    expect(
      ethers.BigNumber.from(
        await listaStakeManager.connect(user).getAmountToUndelegate()
      ).toString()
    ).to.be.equal(toWei("1"));
    // 2 new requests
    await listaStakeManager.connect(user).requestWithdraw(toWei("1"));
    expect(await listaStakeManager.requestUUID()).to.be.equal("3");
    expect(
      ethers.BigNumber.from(
        await listaStakeManager.connect(user).getAmountToUndelegate()
      ).toString()
    ).to.be.equal(toWei("2"));
  });
});
