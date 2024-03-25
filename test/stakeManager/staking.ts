import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { Contract, providers } from "ethers";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

import { impersonateAccount, toBytes32, toWei, readStorageAt } from "../helper";
import { accountFixture, deployFixture } from "../fixture";
import { getContractAddress } from "ethers/lib/utils";

describe("ListaStakeManager::staking", function () {
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
  let validator: string;

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
      mockNativeStaking.mock.getRelayerFee.returns(RELAYER_FEE), // 0.002BNB relayer fee
      mockNativeStaking.mock.getMinDelegation.returns(toWei("1")),
      mockNativeStaking.mock.delegate.returns(),
      mockNativeStaking.mock.redelegate.returns(),
      mockNativeStaking.mock.undelegate.returns(),
    ]);
  });

  it("Can't operate when system paused", async function () {
    await stakeManager.connect(admin).togglePause();

    await expect(
      stakeManager.connect(user).deposit({ value: toWei("1") })
    ).to.be.revertedWith("Pausable: paused");

    await expect(stakeManager.connect(user).delegate()).to.be.revertedWith(
      "Pausable: paused"
    );

    await expect(
      stakeManager.connect(user).redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0)
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(user).compoundRewards()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(user).requestWithdraw(0)
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(user).claimWithdraw(0)
    ).to.be.revertedWith("Pausable: paused");

    await expect(stakeManager.connect(user).undelegate()).to.be.revertedWith(
      "Pausable: paused"
    );

    await expect(
      stakeManager.connect(user).claimUndelegated()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(user).claimFailedDelegation(false)
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(user).depositReserve()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(user).withdrawReserve(1)
    ).to.be.revertedWith("Pausable: paused");

    await stakeManager.connect(admin).togglePause();
  });

  it("Can't deposit with invalid amount", async function () {
    await expect(
      stakeManager.connect(user).deposit({ value: 0 })
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to deposit with properly confirations", async function () {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedRequestUUID =
      await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedRequestUUID).to.equals(0);

    expect(await stakeManager.convertBnbToSnBnb(1)).to.equals(1);
    const [balance1Before] = await Promise.all([snBnb.balanceOf(user.address)]);

    await stakeManager.connect(user).deposit({
      value: toWei("0.2"),
    });
    expect(await stakeManager.convertBnbToSnBnb(1)).to.equals(1);
    const [balance1After] = await Promise.all([snBnb.balanceOf(user.address)]);
    expect(balance1After.sub(balance1Before)).to.equals(toWei("0.2"));
  });

  it("Can't delegate if caller is not bot", async function () {
    await expect(
      stakeManager.connect(this.deployer).delegate()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Can't delegate without enough relayer fee", async function () {
    await expect(
      stakeManager.connect(bot).delegate({ value: 1 })
    ).to.be.revertedWith("Insufficient RelayFee");

    await expect(
      stakeManager.connect(bot).delegate({ value: RELAYER_FEE })
    ).to.be.revertedWith("Insufficient Deposit Amount");
  });

  it("Shoule be able to delegate by bot", async function () {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedRequestUUID =
      await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedRequestUUID).to.equals(0);

    await stakeManager.connect(this.addrs[7]).deposit({
      value: toWei("1"),
    });
    expect(await stakeManager.amountToDelegate()).to.equals(toWei("1.2"));

    const tx = await stakeManager.connect(bot).delegate({ value: RELAYER_FEE });
    expect(tx).to.emit(stakeManager, "Delegate").withArgs(toWei("1.2"));
    expect(await stakeManager.amountToDelegate()).to.equals(0);
    expect(await stakeManager.totalDelegated()).to.equals(toWei("1.2"));
  });

  it("Can't compound rewards if caller is not bot", async function () {
    await expect(
      stakeManager.connect(this.deployer).compoundRewards()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Should be able to compound by bot", async function () {
    const reward = toWei("0.1"); // 0.1
    const revenuePool = this.addrs[4].address;
    await mockNativeStaking.mock.claimReward.returns(reward);

    const [balance1Before, balance2Before, balance3Before] = await Promise.all([
      ethers.provider.getBalance(revenuePool),
      ethers.provider.getBalance(stakeManager.address),
      stakeManager.amountToDelegate(),
    ]);

    // mock send reward
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: reward,
    });
    const tx = await stakeManager.connect(bot).compoundRewards();

    const [balance1After, balance2After, balance3After] = await Promise.all([
      ethers.provider.getBalance(revenuePool),
      ethers.provider.getBalance(stakeManager.address),
      stakeManager.amountToDelegate(),
    ]);
    const rewardToRevenuePool = reward.div(100);
    const rewardToCompound = reward.sub(rewardToRevenuePool);
    expect(tx)
      .to.emit(stakeManager, "RewardsCompounded")
      .withArgs(rewardToCompound);
    expect(balance1After.sub(balance1Before)).to.equals(rewardToRevenuePool);
    expect(balance2After.sub(balance2Before)).to.equals(rewardToCompound);
    expect(balance3After.sub(balance3Before)).to.equals(rewardToCompound);

    // 1 * 1.2 / (1.2 + 0.099)
    expect(await stakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.923787528868360277")
    );
    await stakeManager.connect(user).deposit({
      value: toWei("1"),
    });
    await stakeManager.connect(bot).delegate({ value: RELAYER_FEE });

    // 1.2E + 1E + 0.1 * 99% E = 2.299E
    expect(await stakeManager.totalDelegated()).to.equals(toWei("2.299"));
  });

  it("Can't request withdraw with zero amount", async function () {
    await expect(
      stakeManager.connect(user).requestWithdraw(0)
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to request withdraw with property configrations", async function () {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedRequestUUID =
      await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedRequestUUID).to.equals(0);

    // approve first
    await snBnb
      .connect(user)
      .approve(stakeManager.address, ethers.constants.MaxUint256);
    expect(await stakeManager.amountToDelegate()).to.equals(0);
    expect(await snBnb.totalSupply()).to.equals(toWei("2.123787528868360277"));
    expect(await stakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.923787528868360277")
    );
    // (1 * 2.299) / (1.2 + 0.923787528868360277)
    expect(await stakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.0825")
    );

    const [balance1Before, balance2Before] = await Promise.all([
      snBnb.balanceOf(user.address),
      snBnb.balanceOf(stakeManager.address),
    ]);
    // 0.923787528868360277 + 0.2 = 1.123787528868360277
    const tx1 = await stakeManager
      .connect(user)
      .requestWithdraw(toWei("0.923787528868360277"));

    const res = await stakeManager.getUserWithdrawalRequests(user.address);

    expect(res[0][0]).to.equals(0);
    expect(res[0][1]).to.equals(toWei("0.923787528868360277"));

    const tx2 = await stakeManager.connect(user).requestWithdraw(toWei("0.2"));
    const [balance1After, balance2After] = await Promise.all([
      snBnb.balanceOf(user.address),
      snBnb.balanceOf(stakeManager.address),
    ]);
    expect(tx1)
      .to.emit(stakeManager, "RequestWithdraw")
      .withArgs(user.address, toWei("0.923787528868360277"));
    expect(tx2)
      .to.emit(stakeManager, "RequestWithdraw")
      .withArgs(user.address, toWei("0.2"));
    expect(balance1Before.sub(balance1After)).to.equals(
      toWei("1.123787528868360277")
    );
    expect(balance2After.sub(balance2Before)).to.equals(
      toWei("1.123787528868360277")
    );
    // expect to receive BNB amount
    expect(
      await stakeManager.convertSnBnbToBnb(toWei("1.123787528868360277"))
    ).to.equals(toWei("1.216499999999999999"));
  });

  it("Can't claim withdraw with error idx", async function () {
    await expect(
      stakeManager.connect(user).claimWithdraw(2)
    ).to.be.revertedWith("Invalid index");
    await expect(
      stakeManager.connect(user).claimWithdraw(0)
    ).to.be.revertedWith("Not able to claim yet");

    const status1 = await stakeManager.getUserRequestStatus(user.address, 0);
    const status2 = await stakeManager.getUserRequestStatus(user.address, 1);
    expect(status1[0]).to.equals(false);
    expect(status1[1]).to.equals(toWei("0.999999999999999999"));
    expect(status2[0]).to.equals(false);
    expect(status2[1]).to.equals(toWei("0.2165"));
  });

  it("Can't undelegate if caller is not bot", async function () {
    await expect(
      stakeManager.connect(this.deployer).undelegate()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Should be able to undelegate by bot", async function () {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedRequestUUID =
      await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedRequestUUID).to.equals(0);

    expect(await stakeManager.totalSnBnbToBurn()).to.equals(
      toWei("1.123787528868360277")
    );
    expect(
      await stakeManager.convertSnBnbToBnb(toWei("1.123787528868360277"))
    ).to.equals(toWei("1.216499999999999999"));

    await mockNativeStaking.mock.getDelegated.returns(0);

    await stakeManager.connect(bot).undelegate({ value: RELAYER_FEE });

    const res = await stakeManager.getBotUndelegateRequest(0);
    expect(res[0]).not.to.equals(0);
    expect(res[1]).to.equals(0);
    expect(res[2]).to.equals(toWei("1.21649999"));
    expect(res[3]).to.equals(toWei("1.123787528868360277"));

    expect(await stakeManager.totalSnBnbToBurn()).to.equals(0);
    // 2.299 - 1.21649999
    expect(await stakeManager.totalDelegated()).to.equals(
      "1082500010000000000"
    );

    await expect(
      stakeManager.connect(bot).undelegate({ value: RELAYER_FEE })
    ).to.be.revertedWith("Insufficient Withdraw Amount");

    const uuid_ = await stakeManager.nextUndelegateUUID();
    expect(uuid_).to.equals(1); // increase by 1
    const nextConfirmedUUID_ = await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedUUID_).to.equals(0);
  });

  it("Can't claim undelegated if caller is not bot", async function () {
    await expect(
      stakeManager.connect(this.deployer).claimUndelegated()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Can't claim undelegated when nothing to claim", async function () {
    await mockNativeStaking.mock.claimUndelegated.returns(0);
    await expect(
      stakeManager.connect(bot).claimUndelegated()
    ).to.be.revertedWith("Nothing to undelegate");
  });

  it("Should be able to claim undelegated by bot", async function () {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(1);
    const confirmedUndelegatedUUID =
      await stakeManager.confirmedUndelegatedUUID();
    expect(confirmedUndelegatedUUID).to.equals(0);

    const claimedAmount = ethers.utils
      .parseEther("1.216499999999999999")
      .toString();

    await mockNativeStaking.mock.claimUndelegated.returns(claimedAmount);
    await expect(stakeManager.connect(bot).claimUndelegated())
      .to.emit(stakeManager, "ClaimUndelegated")
      .withArgs(confirmedUndelegatedUUID + 1, claimedAmount);
    // mock send reward
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: claimedAmount,
    });

    const uuid_ = await stakeManager.nextUndelegateUUID();
    expect(uuid_).to.equals(1);
    const confirmedUndelegatedUUID_ =
      await stakeManager.confirmedUndelegatedUUID();
    expect(confirmedUndelegatedUUID_).to.equals(1); // increase by 1
  });

  it("Can't claim faild delegation if caller is not bot", async function () {
    await expect(
      stakeManager.connect(this.deployer).claimFailedDelegation(false)
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Should be able to claim failed delegation by bot", async function () {
    const failedDelegationAmount = ethers.utils.parseEther("0.2164").toString();

    await mockNativeStaking.mock.claimUndelegated.returns(
      failedDelegationAmount
    );
    await stakeManager.connect(bot).claimFailedDelegation(false);

    expect(await stakeManager.amountToDelegate()).to.equals(
      toWei("0.2164").toString()
    );
  });

  it("Should be able to claim withdraw by user", async function () {
    const requests = await stakeManager.getUserWithdrawalRequests(user.address);
    const uuid = await stakeManager.confirmedUndelegatedUUID();
    const botReq = await stakeManager.getBotUndelegateRequest(uuid - 1);

    const status1 = await stakeManager.getUserRequestStatus(user.address, 0);
    expect(status1[0]).to.equals(true);
    expect(status1[1]).to.equals(toWei("0.999999991779695848"));

    const tx1 = await stakeManager.connect(user).claimWithdraw(0);
    const tx2 = await stakeManager.connect(user).claimWithdraw(0);
    // 0.999999991779695848 + 0.216499998220304151 = 216499999999999999
    expect(tx1)
      .to.emit(stakeManager, "ClaimWithdrawal")
      .withArgs(user.address, 0, toWei("0.999999991779695848"));
    expect(tx2)
      .to.emit(stakeManager, "ClaimWithdrawal")
      .withArgs(user.address, 0, toWei("0.216499998220304151"));
  });

  it("Should transfer BNB to redirect address", async function () {
    const tx = await stakeManager
      .connect(admin)
      .setRedirectAddress(this.addrs[10].address);

    const [balance1Before] = await Promise.all([
      ethers.provider.getBalance(this.addrs[10].address),
    ]);

    await this.addrs[8].sendTransaction({
      to: stakeManager.address,
      value: 100,
    });
    const [balance1After] = await Promise.all([
      ethers.provider.getBalance(this.addrs[10].address),
    ]);
    expect(tx)
      .to.emit(stakeManager, "SetRedirectAddress")
      .withArgs(this.addrs[10].address);
    expect(balance1After.sub(balance1Before)).to.equals(100);
  });

  it("Can't deposite reserve if caller is not redirect address", async function () {
    await expect(
      stakeManager.connect(this.deployer).depositReserve({ value: toWei("1") })
    ).to.be.revertedWith("Accessible only by RedirectAddress");

    expect(
      stakeManager.connect(this.addrs[10]).depositReserve({ value: toWei("0") })
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to deposit reserve", async function () {
    await stakeManager
      .connect(this.addrs[10])
      .depositReserve({ value: toWei("1") });

    expect(
      // await stakeManager.connect(this.addrs[10]).availableReserveAmount()
      await stakeManager.totalReserveAmount()
    ).to.equals(toWei("1").toString());
  });

  it("Can't withdraw reserve if caller is not redirect addres", async function () {
    await expect(
      stakeManager.connect(this.deployer).withdrawReserve(toWei("0"))
    ).to.be.revertedWith("Accessible only by RedirectAddress");

    await expect(
      stakeManager.connect(this.addrs[10]).withdrawReserve(toWei("2"))
    ).to.be.revertedWith("Insufficient Balance");
  });

  it("Should be able to withdraw reserve", async function () {
    await stakeManager.connect(this.addrs[10]).withdrawReserve(toWei("0.5"));

    expect(
      // await stakeManager.connect(this.addrs[10]).availableReserveAmount()
      await stakeManager.totalReserveAmount()
    ).to.equals(toWei("0.5"));
  });

  it("Can't redelegate if caller is not manager", async function () {
    await expect(
      stakeManager
        .connect(this.deployer)
        .redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0)
    ).to.be.revertedWith("Accessible only by Manager");

    await expect(
      stakeManager
        .connect(manager)
        .redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0, { value: 0 })
    ).to.be.revertedWith("Invalid Redelegation");

    await expect(
      stakeManager
        .connect(manager)
        .redelegate(ADDRESS_ZERO, this.addrs[8].address, 0, { value: 0 })
    ).to.be.revertedWith("Insufficient RelayFee");

    await expect(
      stakeManager
        .connect(manager)
        .redelegate(ADDRESS_ZERO, this.addrs[8].address, 0, {
          value: RELAYER_FEE,
        })
    ).to.be.revertedWith("Insufficient Deposit Amount");
  });

  it("Should be able to redelegate with properly configurations", async function () {
    const validator1 = this.addrs[8].address;
    const validator2 = this.addrs[9].address;
    const amt = toWei("1");

    const tx = await stakeManager
      .connect(manager)
      .redelegate(validator1, validator2, amt, {
        value: RELAYER_FEE,
      });
    expect(tx)
      .to.emit(stakeManager, "ReDelegate")
      .withArgs(validator1, validator2, amt);
  });

  it("Should be able to get contracts", async function () {
    await stakeManager.connect(manager).setBCValidator(this.addrs[8].address);
    const res = await stakeManager.getContracts();
    expect(res[0]).to.equals(manager.address);
    expect(res[1]).to.equals(snBnb.address);
    expect(res[2]).to.equals(this.addrs[8].address);
  });

  it("Should be able to get token hub relay fee", async function () {
    await mockNativeStaking.mock.getRelayerFee.returns(RELAYER_FEE);
    expect(await stakeManager.getTokenHubRelayFee()).to.equals(RELAYER_FEE);
  });

  it("Check states before upgrade", async function () {
    expect(await stakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await stakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000")
    );
    expect(await stakeManager.amountToDelegate()).to.equals(
      toWei("0.216400000000000000")
    );
    expect(await stakeManager.nextUndelegateUUID()).to.equals(1);
    expect(await stakeManager.confirmedUndelegatedUUID()).to.equals(1);
    expect(await stakeManager.reserveAmount()).to.equals(0);
    expect(await stakeManager.totalReserveAmount()).to.equals(toWei("0.5"));

    const uuid = await stakeManager.confirmedUndelegatedUUID();
    const botRequest = await stakeManager.getBotUndelegateRequest(uuid - 1);
    expect(botRequest["endTime"]).not.to.equals(0);
    const botRequest_ = await stakeManager.getBotUndelegateRequest(uuid);
    expect(botRequest_["startTime"]).to.equals(0);

    expect(await stakeManager.getTotalPooledBnb()).to.equals(
      toWei("1.08250001")
    );
    expect(await stakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.923787520334526371")
    );
    expect(await stakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.082500010000000000")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("1"));
  });

  it("==== Upgrade SnStakeManager to ListaStakeManager ====", async function () {
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
    await mockNativeStaking.mock.claimReward.returns(toWei("0.01"));
  });

  it("Check states after upgrade", async function () {
    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("0.216400000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(1);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(1);
    expect(await listaStakeManager.reserveAmount()).to.equals(0);
    expect(await listaStakeManager.totalReserveAmount()).to.equals(
      toWei("0.5")
    );
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(0);

    const pendingUndelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals(toBytes32(0));
    const undelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toBytes32(0));
    const slisBnbToBurnQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toBytes32(0));

    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0); // no new request

    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("1.08250001")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.800092380599608493")
    ); // 0.866100010000000000 * 0.923787520334526371
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.923787520334526371")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.082500010000000000")
    );
    expect(await listaStakeManager.totalShares()).to.equals(toWei("1"));
    expect(await snBnb.totalSupply()).to.equals(toWei("1"));

    expect(
      await listaStakeManager.getUserWithdrawalRequests(user.address)
    ).to.deep.equals([]); // old requests are processed
  });

  it("Use should be able to deposit", async function () {
    await expect(listaStakeManager.connect(user).deposit({ value: toWei("5") }))
      .to.emit(listaStakeManager, "Deposit")
      .withArgs(user.address, toWei("5"));
  });

  it("Check states after deposit", async function () {
    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("5.226300000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(1);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(1);
    expect(await listaStakeManager.reserveAmount()).to.equals(0);
    expect(await listaStakeManager.totalReserveAmount()).to.equals(
      toWei("0.5")
    );
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(0);

    const pendingUndelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals(toBytes32(0));
    const undelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toBytes32(0));
    const slisBnbToBurnQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toBytes32(0));

    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0); // no new request

    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("6.092400010000000000") // 0.01 reward included
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.792841451914669975")
    ); // 0.866100010000000000 * 0.915415590301944431
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.915415590301944431")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.092400010000000000")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("5.577077951509722157")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("5.577077951509722157")); // 1 + 5 * exchange rate

    expect(
      await listaStakeManager.getUserWithdrawalRequests(user.address)
    ).to.deep.equals([]); // old requests are processed
  });

  it("Bot should be able to delegate to specified validator", async function () {
    validator = this.addrs[8].address;
    await listaStakeManager.connect(admin).whitelistValidator(validator);

    await expect(
      listaStakeManager.connect(bot).delegateTo(validator, toWei("2"), {
        value: RELAYER_FEE,
      })
    )
      .to.emit(listaStakeManager, "DelegateTo")
      .withArgs(validator, toWei("2"));
  });

  it("Check states after delegateTo", async function () {
    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("2.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.226300000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(1);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(1);
    expect(await listaStakeManager.reserveAmount()).to.equals(0);
    expect(await listaStakeManager.totalReserveAmount()).to.equals(
      toWei("0.5")
    );
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(0);

    const pendingUndelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals(toBytes32(0));
    const undelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toBytes32(0));
    const slisBnbToBurnQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toBytes32(0));

    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0); // no new request

    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("6.092400010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("2.623672632518558837")
    ); // 2.866100010000000000 * 0.915415590301944431
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.915415590301944431")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.092400010000000000")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("5.577077951509722157")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("5.577077951509722157"));

    expect(
      await listaStakeManager.getUserWithdrawalRequests(user.address)
    ).to.deep.equals([]); // old requests are processed
  });

  it("User should be able to request withdraw", async function () {
    await expect(listaStakeManager.connect(user).requestWithdraw(toWei("1")))
      .to.emit(listaStakeManager, "RequestWithdraw")
      .withArgs(user.address, toWei("1"));

    const requests = await listaStakeManager.getUserWithdrawalRequests(
      user.address
    );
    expect(requests.length).to.equals(1);
    expect(requests[0]["uuid"]).to.equals(2);
    expect(requests[0]["amountInSnBnb"]).to.equals(toWei("1"));

    const status = await listaStakeManager.getUserRequestStatus(
      user.address,
      0
    );
    expect(status["_isClaimable"]).to.equals(false);
    expect(status["_amount"]).to.equals(toWei("1.094175130000000000"));
  });

  it("Check states after requestWithdraw", async function () {
    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("2.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.236200000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(2); // 1 -> 2
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(1);
    expect(await listaStakeManager.reserveAmount()).to.equals(0);
    expect(await listaStakeManager.totalReserveAmount()).to.equals(
      toWei("0.5")
    );
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(0);

    const pendingUndelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals(toBytes32(0));
    const undelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toBytes32(0));
    const slisBnbToBurnQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toBytes32(0));

    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0); // first in queue

    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("6.102300010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(
      toWei("1.094175130000000000")
    );
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("1.619416148630081897")
    ); // (totalDelegated - amountToUndelegate) * exchangeRate
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.913930475782969929")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.094175133117531476")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("5.577077951509722157")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("5.577077951509722157"));
  });

  it("Bot should be able to undelegate from specified validator", async function () {
    await expect(
      listaStakeManager.connect(bot).undelegate({ value: RELAYER_FEE })
    ).to.be.revertedWith("Nothing to undelegate");
    await mockNativeStaking.mock.undelegate.returns();

    await expect(
      listaStakeManager
        .connect(bot)
        .undelegateFrom(validator, toWei("2"), { value: RELAYER_FEE })
    )
      .to.emit(listaStakeManager, "Undelegate")
      .withArgs(1, toWei("2"));

    const status = await listaStakeManager.getUserRequestStatus(
      user.address,
      0
    );
    expect(status["_isClaimable"]).to.equals(false);
    expect(status["_amount"]).to.equals(toWei("1.094175130000000000"));
  });

  it("Check states after undelegateFrom", async function () {
    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.246100000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(2);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(1);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1); // 0 -> 1

    const pendingUndelegatedQuota = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals("905824870000000000");
    const undelegatedQuota = await ethers.provider.getStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toBytes32(0));
    const slisBnbToBurnQuota = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toWei("0.824900344355623323"));

    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0);

    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("4.112200010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.790273103247704401")
    ); // totalDelegated * exchangeRate
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.912450172177811660")
    ); // become smaller
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.095950256235062953")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("3.752177607154098834")
    ); //  -= 2 * exchangeRate
    expect(await snBnb.totalSupply()).to.equals(toWei("4.577077951509722157")); //   -= 1
  });

  it("Bot should be able to claim undelegate", async function () {
    await mockNativeStaking.mock.claimUndelegated.returns(toWei("2"));

    await expect(listaStakeManager.connect(bot).claimUndelegated())
      .to.emit(listaStakeManager, "ClaimUndelegated")
      .withArgs(3, toWei("2"));

    const status = await listaStakeManager.getUserRequestStatus(
      user.address,
      0
    );
    expect(status["_isClaimable"]).to.equals(true);
    expect(status["_amount"]).to.equals(toWei("1.094175130000000000"));
  });

  it("Check states after claimUndelegated", async function () {
    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.246100000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(2);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3); // 1 -> 3 ??
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1);

    const pendingUndelegatedQuota = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals(toWei("0.905824870000000000"));
    const undelegatedQuota = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toWei("0.905824870000000000"));
    const slisBnbToBurnQuota = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toWei("0.824900344355623323"));

    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0);

    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("4.112200010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.790273103247704401")
    ); // totalDelegated * exchangeRate
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.912450172177811660")
    ); // become smaller
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.095950256235062953")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("3.752177607154098834")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("4.577077951509722157"));
  });

  it("User should be able to claim withdraw", async function () {
    const status = await listaStakeManager.getUserRequestStatus(
      user.address,
      0
    );
    expect(status["_isClaimable"]).to.equals(true);
    expect(status["_amount"]).to.equals(toWei("1.094175130000000000"));

    const req = await listaStakeManager.getUserWithdrawalRequests(user.address);
    expect(req.length).to.equals(1);
    expect(req[0]["uuid"]).to.equals(2);
    expect(req[0]["amountInSnBnb"]).to.equals(toWei("1"));

    await expect(listaStakeManager.connect(user).claimWithdraw(0))
      .to.emit(listaStakeManager, "ClaimWithdrawal")
      .withArgs(user.address, 0, toWei("1.094175130000000000"));

    const requests_ = await listaStakeManager.getUserWithdrawalRequests(
      user.address
    );
    expect(requests_.length).to.equals(0); // all requests are processed
  });

  it("Check states after claimWithdraw", async function () {
    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.246100000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(2);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3); // 1 -> 3 ??
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1);

    const pendingUndelegatedQuota = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals(toWei("0.905824870000000000"));
    const undelegatedQuota = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toWei("0.905824870000000000"));
    const slisBnbToBurnQuota = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toWei("0.824900344355623323"));

    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0);

    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("4.112200010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.790273103247704401")
    ); // totalDelegated * exchangeRate
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.912450172177811660")
    ); // become smaller
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.095950256235062953")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("3.752177607154098834")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("4.577077951509722157"));
  });

  it("Test slisBnbToBurnQuota is not zero", async function () {
    await expect(listaStakeManager.connect(user).deposit({ value: toWei("5") }))
      .to.emit(listaStakeManager, "Deposit")
      .withArgs(user.address, toWei("5"));

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("8.256000000000000000")
    ); // += 5
    expect(await listaStakeManager.requestUUID()).to.equals(2);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1);
    const pendingUndelegatedQuota = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota).to.equals(toWei("0.905824870000000000"));
    const undelegatedQuota = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota).to.equals(toWei("0.905824870000000000"));
    const slisBnbToBurnQuota = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota).to.equals(toWei("0.824900344355623323"));
    const uuid = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid)).to.equals(0);
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("9.122100010000000000")
    ); // += 5
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.788375113460175623")
    ); // smaller than before
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.910258751134497300")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.098588724089336200")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("8.303471362826585336")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("9.128371707182208659")); //  += 5 * exchangeRate

    console.log("Check states 1 Passed");

    await expect(
      listaStakeManager.connect(bot).delegateTo(validator, toWei("5"), {
        value: RELAYER_FEE,
      })
    )
      .to.emit(listaStakeManager, "DelegateTo")
      .withArgs(validator, toWei("5"));

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("5.866100010000000000")
    ); //  += 5
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.256000000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(2);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1);
    const pendingUndelegatedQuota2 = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota2).to.equals(toWei("0.905824870000000000"));
    const undelegatedQuota2 = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota2).to.equals(toWei("0.905824870000000000"));
    const slisBnbToBurnQuota2 = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota2).to.equals(toWei("0.824900344355623323"));
    const uuid2 = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid2)).to.equals(0);
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("9.122100010000000000")
    ); // += 5
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(0);
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("5.339668869132662125")
    ); // += 5 * exchangeRate
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.910258751134497300")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.098588724089336200")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("8.303471362826585336")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("9.128371707182208659")); //  += 5 * exchangeRate

    console.log("Check states 2 Passed");

    await expect(listaStakeManager.connect(user).requestWithdraw(toWei("5")))
      .to.emit(listaStakeManager, "RequestWithdraw")
      .withArgs(user.address, toWei("5"));

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("5.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.265900000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(3); // 2 -> 3
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1);
    const pendingUndelegatedQuota3 = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota3).to.equals(toWei("0.905824870000000000"));
    const undelegatedQuota3 = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota3).to.equals(toWei("0.905824870000000000"));
    const slisBnbToBurnQuota3 = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota3).to.equals(toWei("0.824900344355623323"));
    const uuid3 = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid3)).to.equals(1); // 0 -> 1
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("9.132000010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(
      toWei("4.593080110000000000") // 5 * 1.082500010000000000 - 0.917499990000000000
    );
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("1.157521273804550004") //  -= 4.495000060000000000
    );
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.909271939743086502")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.099780996521842060")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("8.303471362826585336")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("9.128371707182208659"));

    console.log("Check states 3 Passed");

    await mockNativeStaking.mock.undelegate.returns();
    await expect(
      listaStakeManager
        .connect(bot)
        .undelegateFrom(validator, toWei("3"), { value: RELAYER_FEE })
    )
      .to.emit(listaStakeManager, "Undelegate")
      .withArgs(1, toWei("3"));

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("2.866100010000000000")
    ); // -= 3
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.275800000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(3);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1); // Notice: no change since 3 < 5
    const pendingUndelegatedQuota4 = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota4).to.equals(toWei("3.905824870000000000")); //  += 3
    const undelegatedQuota4 = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota4).to.equals(toWei("0.905824870000000000"));
    const slisBnbToBurnQuota4 = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota4).to.equals(toWei("3.549762141272143745")); // = real total supply - burned - (totalPooledBnb * exchangeRate) /// += 3 * exchangeRate?
    const uuid4 = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid4)).to.equals(1);
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("6.141900010000000000")
    ); //  -= 3
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(
      toWei("1.593080110000000000") // -= pendingUndelegatedQuota4
    );
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("1.156267764074829711")
    );
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.908287265638840140")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.100973268954347920")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("5.578609565910064914")
    ); // sisBnb.totalSupply - burnQuota
    expect(await snBnb.totalSupply()).to.equals(toWei("9.128371707182208659")); // Notice: no change since not burned

    console.log("Check states 4 Passed");

    await mockNativeStaking.mock.claimUndelegated.returns(toWei("3"));
    await expect(listaStakeManager.connect(bot).claimUndelegated())
      .to.emit(listaStakeManager, "ClaimUndelegated")
      .withArgs(3, toWei("3"));

    const status5 = await listaStakeManager.getUserRequestStatus(
      user.address,
      0
    );
    expect(status5["_isClaimable"]).to.equals(false);
    expect(status5["_amount"]).to.equals(toWei("5.498904980000000000")); // 5 * exchangeRate

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("2.866100010000000000")
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.275800000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(3);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1);
    const pendingUndelegatedQuota5 = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota5).to.equals(toWei("3.905824870000000000"));
    const undelegatedQuota5 = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota5).to.equals(toWei("3.905824870000000000")); //  += 3
    const slisBnbToBurnQuota5 = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota5).to.equals(toWei("3.549762141272143745")); // = real total supply - burned - (totalPooledBnb * exchangeRate)
    const uuid5 = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid5)).to.equals(1);
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("6.141900010000000000")
    ); //  -= 3
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(
      toWei("1.593080110000000000")
    );
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("1.156267764074829711")
    );
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.908287265638840140")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.100973268954347920")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("5.578609565910064914")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("9.128371707182208659"));

    console.log("Check states 5 Passed");

    await mockNativeStaking.mock.undelegate.returns();
    await expect(
      listaStakeManager
        .connect(bot)
        .undelegateFrom(validator, toWei("1"), { value: RELAYER_FEE })
    )
      .to.emit(listaStakeManager, "Undelegate")
      .withArgs(1, toWei("1"));

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("1.866100010000000000") //  -= 1
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.285700000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(3);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(1);
    const pendingUndelegatedQuota6 = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota6).to.equals(toWei("4.905824870000000000")); // += 1
    const undelegatedQuota6 = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota6).to.equals(toWei("3.905824870000000000"));
    const slisBnbToBurnQuota6 = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota6).to.equals(toWei("4.456587713761790546")); // = real total supply - burned - (totalPooledBnb * exchangeRate)
    const uuid6 = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid6)).to.equals(1);
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("5.151800010000000000")
    ); //  -= 1
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(
      toWei("0.593080110000000000")
    );
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("1.154406999608212921")
    );
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.906825572489646800")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.102747904709554238")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("4.671783993420418113") // -= 1 * exchangeRate
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("9.128371707182208659")); // Notice: no change since not burned
    console.log("Check states 6 Passed");

    await expect(
      listaStakeManager
        .connect(bot)
        .undelegateFrom(validator, toWei("1.000000000001"), {
          value: RELAYER_FEE,
        })
    )
      .to.emit(listaStakeManager, "Undelegate")
      .withArgs(2, toWei("1"));

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000") //  -= 1
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.295600000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(3);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(3);
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(2); //  += 1
    const pendingUndelegatedQuota7 = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota7).to.equals(toWei("0.406919890000000000")); // += 1 - 5 * 1.082500010000000000
    const undelegatedQuota7 = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota7).to.equals(toWei("3.905824870000000000"));
    const slisBnbToBurnQuota7 = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota7).to.equals(toWei("0.361674019507873243")); // = real total supply - burned - (totalPooledBnb * exchangeRate)
    const uuid7 = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid7)).to.equals(1);
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("4.161700010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(
      toWei("0")
    );
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.783895258457545281")
    );
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.905086305746082696")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.104867009534165741")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("3.766697687674335416") // -= 1 * exchangeRate
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("4.128371707182208659"));

    console.log("Check states 7 Passed");

    await mockNativeStaking.mock.claimUndelegated.returns(toWei("5"));
    await expect(listaStakeManager.connect(bot).claimUndelegated())
      .to.emit(listaStakeManager, "ClaimUndelegated")
      .withArgs(4, toWei("5"));

    expect(await listaStakeManager.totalSnBnbToBurn()).to.equals(0);
    expect(await listaStakeManager.totalDelegated()).to.equals(
      toWei("0.866100010000000000") //  -= 1
    );
    expect(await listaStakeManager.amountToDelegate()).to.equals(
      toWei("3.295600000000000000")
    );
    expect(await listaStakeManager.requestUUID()).to.equals(3);
    expect(await listaStakeManager.nextConfirmedRequestUUID()).to.equals(4); // 3 -> 4
    expect(await listaStakeManager.nextUndelegatedRequestIndex()).to.equals(2);
    const pendingUndelegatedQuota8 = await readStorageAt(
      listaStakeManager.address,
      218
    );
    expect(pendingUndelegatedQuota8).to.equals(toWei("0.406919890000000000"));
    const undelegatedQuota8 = await readStorageAt(
      listaStakeManager.address,
      219
    );
    expect(undelegatedQuota8).to.equals(toWei("3.406919890000000000")); // += 5 - 5 * 1.082500010000000000
    const slisBnbToBurnQuota8 = await readStorageAt(
      listaStakeManager.address,
      223
    );
    expect(slisBnbToBurnQuota8).to.equals(toWei("0.361674019507873243")); // = real total supply - burned - (totalPooledBnb * exchangeRate)
    const uuid8 = await listaStakeManager.requestUUID();
    expect(await listaStakeManager.requestIndexMap(uuid8)).to.equals(1);
    expect(await listaStakeManager.getTotalPooledBnb()).to.equals(
      toWei("4.161700010000000000")
    );
    expect(await listaStakeManager.getAmountToUndelegate()).to.equals(
      toWei("0")
    );
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      toWei("0.783895258457545281")
    );
    expect(await listaStakeManager.convertBnbToSnBnb(toWei("1"))).to.equals(
      toWei("0.905086305746082696")
    );
    expect(await listaStakeManager.convertSnBnbToBnb(toWei("1"))).to.equals(
      toWei("1.104867009534165741")
    );
    expect(await listaStakeManager.totalShares()).to.equals(
      toWei("3.766697687674335416")
    );
    expect(await snBnb.totalSupply()).to.equals(toWei("4.128371707182208659"));

    console.log("Check states 8 Passed");
  });
});
