import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { Contract, providers } from "ethers";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

import { impersonateAccount } from "../helper";
import { accountFixture, deployFixture } from "../fixture";
import { getContractAddress } from "ethers/lib/utils";

describe("SnStakeManager::staking", function() {
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

  before(async function() {
    // Reset the Hardhat Network, starting a new instance
    await ethers.provider.send(
      "hardhat_reset",
      [],
    );
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;
    const { deployMockContract } = await loadFixture(deployFixture);
    mockNativeStaking = await deployMockContract("MockNativeStaking", {
      address: NATIVE_STAKING,
    });
    nativeStakingSigner = await impersonateAccount(
      mockNativeStaking.address,
      ethers.utils.parseEther("10").toHexString()
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
      mockNativeStaking.mock.getMinDelegation.returns(
        ethers.utils.parseEther("1")
      ),
      mockNativeStaking.mock.delegate.returns(),
      mockNativeStaking.mock.redelegate.returns(),
      mockNativeStaking.mock.undelegate.returns(),
    ]);
  });

  it("Can't operate when system paused", async function() {
    await stakeManager.connect(admin).togglePause();

    await expect(
      stakeManager
        .connect(user)
        .deposit({ value: ethers.utils.parseEther("1") })
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(user).delegate()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager
        .connect(user)
        .redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0)
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

    await expect(
      stakeManager.connect(user).undelegate()
    ).to.be.revertedWith("Pausable: paused");

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

  it("Can't deposit with invalid amount", async function() {
    await expect(
      stakeManager.connect(user).deposit({ value: 0 })
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to deposit with properly confirations", async function() {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedUUID = await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedUUID).to.equals(0);

    expect(await stakeManager.convertBnbToSnBnb(1)).to.equals(1);
    const [balance1Before] = await Promise.all([
      snBnb.balanceOf(user.address),
    ]);

    await stakeManager.connect(user).deposit({
      value: ethers.utils.parseEther("0.2"),
    });
    expect(await stakeManager.convertBnbToSnBnb(1)).to.equals(1);
    const [balance1After] = await Promise.all([
      snBnb.balanceOf(user.address),
    ]);
    expect(balance1After.sub(balance1Before)).to.equals(
      ethers.utils.parseEther("0.2")
    );
  });

  it("Can't delegate if caller is not bot", async function() {
    await expect(
      stakeManager.connect(this.deployer).delegate()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Can't delegate without enough relayer fee", async function() {
    await expect(
      stakeManager.connect(bot).delegate({ value: 1 })
    ).to.be.revertedWith("Insufficient RelayFee");

    await expect(
      stakeManager.connect(bot).delegate({ value: RELAYER_FEE })
    ).to.be.revertedWith("Insufficient Deposit Amount");
  });

  it("Shoule be able to delegate by bot", async function() {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedUUID = await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedUUID).to.equals(0);

    await stakeManager.connect(this.addrs[7]).deposit({
      value: ethers.utils.parseEther("1"),
    });
    expect(await stakeManager.amountToDelegate()).to.equals(
      ethers.utils.parseEther("1.2")
    );

    const tx = await stakeManager.connect(bot).delegate({ value: RELAYER_FEE });
    expect(tx)
      .to.emit(stakeManager, "Delegate")
      .withArgs(ethers.utils.parseEther("1.2"));
    expect(await stakeManager.amountToDelegate()).to.equals(0);
    expect(await stakeManager.totalDelegated()).to.equals(
      ethers.utils.parseEther("1.2")
    );
  });

  it("Can't compound rewards if caller is not bot", async function() {
    await expect(
      stakeManager.connect(this.deployer).compoundRewards()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Should be able to compound by bot", async function() {
    const reward = ethers.utils.parseEther("0.1"); // 0.1
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
    expect(
      await stakeManager.convertBnbToSnBnb(ethers.utils.parseEther("1"))
    ).to.equals(ethers.utils.parseEther("0.923787528868360277"));
    await stakeManager.connect(user).deposit({
      value: ethers.utils.parseEther("1"),
    });
    await stakeManager.connect(bot).delegate({ value: RELAYER_FEE });

    // 1.2E + 1E + 0.1 * 99% E = 2.299E
    expect(await stakeManager.totalDelegated()).to.equals(
      ethers.utils.parseEther("2.299")
    );
  });

  it("Can't request withdraw with zero amount", async function() {
    await expect(
      stakeManager.connect(user).requestWithdraw(0)
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to request withdraw with property configrations", async function() {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedUUID = await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedUUID).to.equals(0);

    // approve first
    await snBnb
      .connect(user)
      .approve(stakeManager.address, ethers.constants.MaxUint256);
    expect(await stakeManager.amountToDelegate()).to.equals(0);
    expect(await snBnb.totalSupply()).to.equals(
      ethers.utils.parseEther("2.123787528868360277")
    );
    expect(
      await stakeManager.convertBnbToSnBnb(ethers.utils.parseEther("1"))
    ).to.equals(ethers.utils.parseEther("0.923787528868360277"));
    // (1 * 2.299) / (1.2 + 0.923787528868360277)
    expect(
      await stakeManager.convertSnBnbToBnb(ethers.utils.parseEther("1"))
    ).to.equals(ethers.utils.parseEther("1.0825"));

    const [balance1Before, balance2Before] = await Promise.all([
      snBnb.balanceOf(user.address),
      snBnb.balanceOf(stakeManager.address),
    ]);
    // 0.923787528868360277 + 0.2 = 1.123787528868360277
    const tx1 = await stakeManager
      .connect(user)
      .requestWithdraw(ethers.utils.parseEther("0.923787528868360277"));

    const res = await stakeManager.getUserWithdrawalRequests(
      user.address
    );

    expect(res[0][0]).to.equals(0);
    expect(res[0][1]).to.equals(
      ethers.utils.parseEther("0.923787528868360277")
    );

    const tx2 = await stakeManager
      .connect(user)
      .requestWithdraw(ethers.utils.parseEther("0.2"));
    const [balance1After, balance2After] = await Promise.all([
      snBnb.balanceOf(user.address),
      snBnb.balanceOf(stakeManager.address),
    ]);
    expect(tx1)
      .to.emit(stakeManager, "RequestWithdraw")
      .withArgs(
        user.address,
        ethers.utils.parseEther("0.923787528868360277")
      );
    expect(tx2)
      .to.emit(stakeManager, "RequestWithdraw")
      .withArgs(user.address, ethers.utils.parseEther("0.2"));
    expect(balance1Before.sub(balance1After)).to.equals(
      ethers.utils.parseEther("1.123787528868360277")
    );
    expect(balance2After.sub(balance2Before)).to.equals(
      ethers.utils.parseEther("1.123787528868360277")
    );
    // expect to receive BNB amount
    expect(
      await stakeManager.convertSnBnbToBnb(
        ethers.utils.parseEther("1.123787528868360277")
      )
    ).to.equals(ethers.utils.parseEther("1.216499999999999999"));
  });

  it("Can't claim withdraw with error idx", async function() {
    await expect(
      stakeManager.connect(user).claimWithdraw(2)
    ).to.be.revertedWith("Invalid index");
    await expect(
      stakeManager.connect(user).claimWithdraw(0)
    ).to.be.revertedWith("Not able to claim yet");

    const status1 = await stakeManager.getUserRequestStatus(
      user.address,
      0
    );
    const status2 = await stakeManager.getUserRequestStatus(
      user.address,
      1
    );
    expect(status1[0]).to.equals(false);
    expect(status1[1]).to.equals(
      ethers.utils.parseEther("0.999999999999999999")
    );
    expect(status2[0]).to.equals(false);
    expect(status2[1]).to.equals(ethers.utils.parseEther("0.2165"));
  });

  it("Can't undelegate if caller is not bot", async function() {
    await expect(
      stakeManager.connect(this.deployer).undelegate()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Should be able to undelegate by bot", async function() {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(0);
    const nextConfirmedUUID = await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedUUID).to.equals(0);

    expect(await stakeManager.totalSnBnbToBurn()).to.equals(
      ethers.utils.parseEther("1.123787528868360277")
    );
    expect(
      await stakeManager.convertSnBnbToBnb(
        ethers.utils.parseEther("1.123787528868360277")
      )
    ).to.equals(ethers.utils.parseEther("1.216499999999999999"));

    await mockNativeStaking.mock.getDelegated.returns(0);

    await stakeManager.connect(bot).undelegate({ value: RELAYER_FEE });

    const res = await stakeManager.getBotUndelegateRequest(0);
    expect(res[0]).not.to.equals(0);
    expect(res[1]).to.equals(0);
    expect(res[2]).to.equals(ethers.utils.parseEther("1.21649999"));
    expect(res[3]).to.equals(ethers.utils.parseEther("1.123787528868360277"));

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

  it("Can't claim undelegated if caller is not bot", async function() {
    await expect(
      stakeManager.connect(this.deployer).claimUndelegated()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Can't claim undelegated when nothing to claim", async function() {
    await mockNativeStaking.mock.claimUndelegated.returns(0);
    await expect(
      stakeManager.connect(bot).claimUndelegated()
    ).to.be.revertedWith("Nothing to undelegate");
  });

  it("Should be able to claim undelegated by bot", async function() {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(1);
    const confirmedUndelegatedUUID = await stakeManager.confirmedUndelegatedUUID();
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
    const confirmedUndelegatedUUID_ = await stakeManager.confirmedUndelegatedUUID();
    expect(confirmedUndelegatedUUID_).to.equals(1); // increase by 1

  });

  it("Can't claim faild delegation if caller is not bot", async function() {
    await expect(
      stakeManager.connect(this.deployer).claimFailedDelegation(false)
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Should be able to claim failed delegation by bot", async function() {
    const failedDelegationAmount = ethers.utils
      .parseEther("0.2164")
      .toString();

    await mockNativeStaking.mock.claimUndelegated.returns(
      failedDelegationAmount
    );
    await stakeManager.connect(bot).claimFailedDelegation(false);

    expect(await stakeManager.amountToDelegate()).to.equals(
      ethers.utils.parseEther("0.2164").toString()
    );
  });

  it("Should be able to claim withdraw by user", async function() {
    const requests = await stakeManager.getUserWithdrawalRequests(user.address);
    const uuid = await stakeManager.confirmedUndelegatedUUID();
    const botReq = await stakeManager.getBotUndelegateRequest(uuid - 1);

    const status1 = await stakeManager.getUserRequestStatus(
      user.address,
      0
    );
    expect(status1[0]).to.equals(true);
    expect(status1[1]).to.equals(
      ethers.utils.parseEther("0.999999991779695848")
    );

    const tx1 = await stakeManager.connect(user).claimWithdraw(0);
    const tx2 = await stakeManager.connect(user).claimWithdraw(0);
    // 0.999999991779695848 + 0.216499998220304151 = 216499999999999999
    expect(tx1)
      .to.emit(stakeManager, "ClaimWithdrawal")
      .withArgs(
        user.address,
        0,
        ethers.utils.parseEther("0.999999991779695848")
      );
    expect(tx2)
      .to.emit(stakeManager, "ClaimWithdrawal")
      .withArgs(
        user.address,
        0,
        ethers.utils.parseEther("0.216499998220304151")
      );
  });

  it("Should transfer BNB to redirect address", async function() {
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

  it("Can't deposite reserve if caller is not redirect address", async function() {
    await expect(
      stakeManager
        .connect(this.deployer)
        .depositReserve({ value: ethers.utils.parseEther("1") })
    ).to.be.revertedWith("Accessible only by RedirectAddress");

    expect(
      stakeManager
        .connect(this.addrs[10])
        .depositReserve({ value: ethers.utils.parseEther("0") })
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to deposit reserve", async function() {
    await stakeManager
      .connect(this.addrs[10])
      .depositReserve({ value: ethers.utils.parseEther("1") });

    expect(
      // await stakeManager.connect(this.addrs[10]).availableReserveAmount()
      await stakeManager.totalReserveAmount()
    ).to.equals(ethers.utils.parseEther("1").toString());
  });

  it("Can't withdraw reserve if caller is not redirect addres", async function() {
    await expect(
      stakeManager
        .connect(this.deployer)
        .withdrawReserve(ethers.utils.parseEther("0"))
    ).to.be.revertedWith("Accessible only by RedirectAddress");

    await expect(
      stakeManager
        .connect(this.addrs[10])
        .withdrawReserve(ethers.utils.parseEther("2"))
    ).to.be.revertedWith("Insufficient Balance");
  });

  it("Should be able to withdraw reserve", async function() {
    await stakeManager
      .connect(this.addrs[10])
      .withdrawReserve(ethers.utils.parseEther("0.5"));

    expect(
      // await stakeManager.connect(this.addrs[10]).availableReserveAmount()
      await stakeManager.totalReserveAmount()
    ).to.equals(ethers.utils.parseEther("0.5"));
  });

  it("Can't redelegate if caller is not manager", async function() {
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
        .redelegate(ADDRESS_ZERO, this.addrs[8].address, 0, { value: RELAYER_FEE })
    ).to.be.revertedWith("Insufficient Deposit Amount");
  });

  it("Should be able to redelegate with properly configurations", async function() {
    const validator1 = this.addrs[8].address;
    const validator2 = this.addrs[9].address;
    const amt = ethers.utils.parseEther("1");

    const tx = await stakeManager
      .connect(manager)
      .redelegate(validator1, validator2, amt, {
        value: RELAYER_FEE,
      });
    expect(tx)
      .to.emit(stakeManager, "ReDelegate")
      .withArgs(validator1, validator2, amt);
  });

  it("Should be able to get contracts", async function() {
    await stakeManager.connect(manager).setBCValidator(this.addrs[8].address);
    const res = await stakeManager.getContracts();
    expect(res[0]).to.equals(manager.address);
    expect(res[1]).to.equals(snBnb.address);
    expect(res[2]).to.equals(this.addrs[8].address);
  });


  it("Should be able to get token hub relay fee", async function() {
    await mockNativeStaking.mock.getRelayerFee.returns(RELAYER_FEE);
    expect(await stakeManager.getTokenHubRelayFee()).to.equals(RELAYER_FEE);
  });

  it("====Upgrade SnStakeManager to ListaStakeManager====", async function() {
    const uuid = await stakeManager.nextUndelegateUUID();
    expect(uuid).to.equals(1);
    const nextConfirmedUUID = await stakeManager.confirmedUndelegatedUUID();
    expect(nextConfirmedUUID).to.equals(1);

    const ListaStakeManager = await ethers.getContractFactory("ListaStakeManager");
    listaStakeManager = await upgrades.upgradeProxy(stakeManager, ListaStakeManager, {
      unsafeAllowRenames: true,
    });
    await listaStakeManager.deployed();

    expect(await listaStakeManager.undelegatedIndex()).to.equals(0);
  });

  it("Bot should be able to delegate to specified validator", async function() {
    validator = this.addrs[8].address;

    const _ = await listaStakeManager
      .connect(admin)
      .whitelistValidator(validator);

    await expect(listaStakeManager
      .connect(user)
      .deposit({ value: ethers.utils.parseEther("5") }))
      .to.emit(listaStakeManager, "Deposit")
      .withArgs(user.address, ethers.utils.parseEther("5"));

    await expect(listaStakeManager
      .connect(bot)
      .delegateTo(validator, ethers.utils.parseEther("2"), {
        value: RELAYER_FEE,
      }))
      .to.emit(listaStakeManager, "DelegateTo")
      .withArgs(validator, ethers.utils.parseEther("2"));
      const uuid = await listaStakeManager.nextUUID();
      const nextConfirmedUUID = await listaStakeManager.nextConfirmedUUID();
      expect(uuid).to.equals(1); // no change
      expect(nextConfirmedUUID).to.equals(1); // no change

      expect(await listaStakeManager.undelegatedIndex()).to.equals(0);
  });

  it("Should be able to get slisbnb withdraw limit", async function() {
    expect(await listaStakeManager.getSlisBnbWithdrawLimit()).to.equals(
      ethers.utils.parseEther("2.647667421268661235")
    );
  });

  it("User should be able to request withdraw", async function() {
    await expect(listaStakeManager.connect(user).requestWithdraw(ethers.utils.parseEther("1")))
    .to.emit(listaStakeManager, "RequestWithdraw")
    .withArgs(user.address, ethers.utils.parseEther("1"));

    const amount = await listaStakeManager.getAmountToUndelegate();
    expect(amount).to.equals(ethers.utils.parseEther("1.08250001"));

    const undelegatedIndex = await listaStakeManager.undelegatedIndex();
    expect(undelegatedIndex).to.equals(0);

    const uuid = await listaStakeManager.nextUUID();
    const nextConfirmedUUID = await listaStakeManager.nextConfirmedUUID();
    expect(uuid).to.equals(2); // increase by 1
    expect(nextConfirmedUUID).to.equals(1);

    const status = await listaStakeManager.getUserRequestStatus(user.address, 0);
    expect(status[0]).to.equals(false);
    expect(status[1]).to.equals(0);

    expect(await listaStakeManager.undelegatedIndex()).to.equals(0);
  });

  it("Bot should be able to undelegate from specified validator", async function() {
    await expect(listaStakeManager.connect(bot)
    .undelegate({ value: RELAYER_FEE }))
    .to.be.revertedWith("Nothing to undelegate");

    await expect(listaStakeManager.connect(bot)
    .undelegateFrom(validator, ethers.utils.parseEther("2"), { value: RELAYER_FEE }))
    .to.emit(listaStakeManager, "Undelegate")
    .withArgs(1, ethers.utils.parseEther("2"));

    const undelegatedIndex = await listaStakeManager.undelegatedIndex();
    expect(undelegatedIndex).to.equals(1);

    const uuid = await listaStakeManager.nextUUID();
    const nextConfirmedUUID = await listaStakeManager.nextConfirmedUUID();
    expect(uuid).to.equals(2); // no change
    expect(nextConfirmedUUID).to.equals(1); // no change

    expect(await listaStakeManager.undelegatedIndex()).to.equals(1); // increase by 1
  });

  it("Bot should be able to claim undelegate", async function() {
    await mockNativeStaking.mock.claimUndelegated.returns(ethers.utils.parseEther("2"));

    await expect(listaStakeManager.connect(bot).claimUndelegated())
    .to.emit(listaStakeManager, "ClaimUndelegated")
    .withArgs(2, ethers.utils.parseEther("2"));
    const uuid = await listaStakeManager.nextUUID();
    const nextConfirmedUUID = await listaStakeManager.nextConfirmedUUID();
    expect(uuid).to.equals(2); // no change
    expect(nextConfirmedUUID).to.equals(2); // increase by 1

    expect(await listaStakeManager.undelegatedIndex()).to.equals(1); // no change
  });

  it("User should be able to claim withdraw", async function() {
    const req = await listaStakeManager.getUserWithdrawalRequests(user.address);
    expect(req[0][0]).to.equals(1); // uuid is 1

    const balanceBefore = await ethers.provider.getBalance(user.address);
//    await listaStakeManager.connect(user).claimAllWithdrawals();

    await expect(listaStakeManager.connect(user).claimWithdraw(0))
    .to.emit(listaStakeManager, "ClaimWithdrawal")
    .withArgs(user.address, 0, ethers.utils.parseEther("1.08250001"));

    const balanceAfter = await ethers.provider.getBalance(user.address);
    expect(balanceAfter.sub(balanceBefore)).to.equals(ethers.utils.parseEther("1.082442521096633568"));

    expect(await listaStakeManager.undelegatedIndex()).to.equals(1); // no change
  });
});
