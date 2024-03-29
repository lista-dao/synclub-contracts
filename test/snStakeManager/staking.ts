import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { Contract } from "ethers";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

import { impersonateAccount } from "../helper";
import { accountFixture, deployFixture } from "../fixture";

describe("SnStakeManager::staking", function () {
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  const RELAYER_FEE = "2000000000000000";
  const NATIVE_STAKING = "0x0000000000000000000000000000000000002001";

  let mockNativeStaking: MockContract;
  let snBnb: Contract;
  let stakeManager: Contract;
  let admin: SignerWithAddress;
  let manager: SignerWithAddress;
  let bot: SignerWithAddress;
  let nativeStakingSigner: SignerWithAddress;

  before(async function () {
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

  it("Can't operate when system paused", async function () {
    await stakeManager.connect(admin).togglePause();

    await expect(
      stakeManager
        .connect(this.addrs[6])
        .deposit({ value: ethers.utils.parseEther("1") })
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).delegate()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager
        .connect(this.addrs[6])
        .redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0)
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).compoundRewards()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).requestWithdraw(0)
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).claimWithdraw(0)
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).undelegate()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).claimUndelegated()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).claimFailedDelegation()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).depositReserve()
    ).to.be.revertedWith("Pausable: paused");

    await expect(
      stakeManager.connect(this.addrs[6]).withdrawReserve(1)
    ).to.be.revertedWith("Pausable: paused");

    await stakeManager.connect(admin).togglePause();
  });

  it("Can't deposit with invalid amount", async function () {
    await expect(
      stakeManager.connect(this.addrs[6]).deposit({ value: 0 })
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to deposit with properly confirations", async function () {
    expect(await stakeManager.convertBnbToSnBnb(1)).to.equals(1);
    const [balance1Before] = await Promise.all([
      snBnb.balanceOf(this.addrs[6].address),
    ]);

    await stakeManager.connect(this.addrs[6]).deposit({
      value: ethers.utils.parseEther("0.2"),
    });
    expect(await stakeManager.convertBnbToSnBnb(1)).to.equals(1);
    const [balance1After] = await Promise.all([
      snBnb.balanceOf(this.addrs[6].address),
    ]);
    expect(balance1After.sub(balance1Before)).to.equals(
      ethers.utils.parseEther("0.2")
    );
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
    await stakeManager.connect(this.addrs[6]).deposit({
      value: ethers.utils.parseEther("1"),
    });
    await stakeManager.connect(bot).delegate({ value: RELAYER_FEE });

    // 1.2E + 1E + 0.1 * 99% E = 2.299E
    expect(await stakeManager.totalDelegated()).to.equals(
      ethers.utils.parseEther("2.299")
    );
  });

  it("Can't request withdraw with zero amount", async function () {
    await expect(
      stakeManager.connect(this.addrs[6]).requestWithdraw(0)
    ).to.be.revertedWith("Invalid Amount");
  });

  it("Should be able to request withdraw with property configrations", async function () {
    // approve first
    await snBnb
      .connect(this.addrs[6])
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
      snBnb.balanceOf(this.addrs[6].address),
      snBnb.balanceOf(stakeManager.address),
    ]);
    // 0.923787528868360277 + 0.2 = 1.123787528868360277
    const tx1 = await stakeManager
      .connect(this.addrs[6])
      .requestWithdraw(ethers.utils.parseEther("0.923787528868360277"));

    const res = await stakeManager.getUserWithdrawalRequests(
      this.addrs[6].address
    );

    expect(res[0][0]).to.equals(0);
    expect(res[0][1]).to.equals(
      ethers.utils.parseEther("0.923787528868360277")
    );

    const tx2 = await stakeManager
      .connect(this.addrs[6])
      .requestWithdraw(ethers.utils.parseEther("0.2"));
    const [balance1After, balance2After] = await Promise.all([
      snBnb.balanceOf(this.addrs[6].address),
      snBnb.balanceOf(stakeManager.address),
    ]);
    expect(tx1)
      .to.emit(stakeManager, "RequestWithdraw")
      .withArgs(
        this.addrs[6].address,
        ethers.utils.parseEther("0.923787528868360277")
      );
    expect(tx2)
      .to.emit(stakeManager, "RequestWithdraw")
      .withArgs(this.addrs[6].address, ethers.utils.parseEther("0.2"));
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

  it("Can't claim withdraw with error idx", async function () {
    await expect(
      stakeManager.connect(this.addrs[6]).claimWithdraw(2)
    ).to.be.revertedWith("Invalid index");
    await expect(
      stakeManager.connect(this.addrs[6]).claimWithdraw(0)
    ).to.be.revertedWith("Not able to claim yet");

    const status1 = await stakeManager.getUserRequestStatus(
      this.addrs[6].address,
      0
    );
    const status2 = await stakeManager.getUserRequestStatus(
      this.addrs[6].address,
      1
    );
    expect(status1[0]).to.equals(false);
    expect(status1[1]).to.equals(
      ethers.utils.parseEther("0.999999999999999999")
    );
    expect(status2[0]).to.equals(false);
    expect(status2[1]).to.equals(ethers.utils.parseEther("0.2165"));
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
    expect(res[0]).to.equals(0);
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
    const claimedAmount = ethers.utils
      .parseEther("1.216499999999999999")
      .toString();
    await mockNativeStaking.mock.claimUndelegated.returns(claimedAmount);
    await stakeManager.connect(bot).claimUndelegated();
    // mock send reward
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: claimedAmount,
    });
  });

  it("Can't claim faild delegation if caller is not bot", async function () {
    await expect(
      stakeManager.connect(this.deployer).claimFailedDelegation()
    ).to.be.revertedWith(
      `AccessControl: account ${this.deployer.address.toLowerCase()} is missing role ${ethers.utils.id(
        "BOT"
      )}`
    );
  });

  it("Should be able to claim failed delegation by bot", async function () {
    const failedDelegationAmount = ethers.utils
      .parseEther("100.216499999999999999")
      .toString();
    await mockNativeStaking.mock.claimUndelegated.returns(
      failedDelegationAmount
    );
    await stakeManager.connect(bot).claimFailedDelegation();

    expect(await stakeManager.amountToDelegate()).to.equals(
      ethers.utils.parseEther("100.216499999999999999").toString()
    );
  });

  it("Should be able to claim withdraw by user", async function () {
    const status1 = await stakeManager.getUserRequestStatus(
      this.addrs[6].address,
      0
    );
    expect(status1[0]).to.equals(true);
    expect(status1[1]).to.equals(
      ethers.utils.parseEther("0.999999991779695848")
    );

    const tx1 = await stakeManager.connect(this.addrs[6]).claimWithdraw(0);
    const tx2 = await stakeManager.connect(this.addrs[6]).claimWithdraw(0);
    // 0.999999991779695848 + 0.216499998220304151 = 216499999999999999
    expect(tx1)
      .to.emit(stakeManager, "ClaimWithdrawal")
      .withArgs(
        this.addrs[6].address,
        0,
        ethers.utils.parseEther("0.999999991779695848")
      );
    expect(tx2)
      .to.emit(stakeManager, "ClaimWithdrawal")
      .withArgs(
        this.addrs[6].address,
        0,
        ethers.utils.parseEther("0.216499998220304151")
      );
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

  it("Should be able to deposit reserve", async function () {
    await stakeManager
      .connect(this.addrs[10])
      .depositReserve({ value: ethers.utils.parseEther("1") });

    expect(
      // await stakeManager.connect(this.addrs[10]).availableReserveAmount()
      await stakeManager.availableReserveAmount()
    ).to.equals(ethers.utils.parseEther("1").toString());
  });

  it("Can't withdraw reserve if caller is not redirect addres", async function () {
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

  it("Should be able to withdraw reserve", async function () {
    await stakeManager
      .connect(this.addrs[10])
      .withdrawReserve(ethers.utils.parseEther("0.5"));

    expect(
      // await stakeManager.connect(this.addrs[10]).availableReserveAmount()
      await stakeManager.availableReserveAmount()
    ).to.equals(ethers.utils.parseEther("0.5"));
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
    ).to.be.revertedWith("Insufficient RelayFee");

    await expect(
      stakeManager
        .connect(manager)
        .redelegate(ADDRESS_ZERO, ADDRESS_ZERO, 0, { value: RELAYER_FEE })
    ).to.be.revertedWith("Insufficient Deposit Amount");
  });

  it("Should be able to redelegate with properly configurations", async function () {
    const tx = await stakeManager
      .connect(manager)
      .redelegate(ADDRESS_ZERO, ADDRESS_ZERO, ethers.utils.parseEther("1"), {
        value: RELAYER_FEE,
      });
    expect(tx)
      .to.emit(stakeManager, "ReDelegate")
      .withArgs(ADDRESS_ZERO, ADDRESS_ZERO, ethers.utils.parseEther("1"));
  });

  it("Should be able to get contracts", async function () {
    await stakeManager.connect(manager).setBCValidator(this.addrs[8].address);
    const res = await stakeManager.getContracts();
    expect(res[0]).to.equals(manager.address);
    expect(res[1]).to.equals(snBnb.address);
    expect(res[2]).to.equals(this.addrs[8].address);
  });

  it("Should be able to get sbnb withdraw limit", async function () {
    expect(await stakeManager.getSnBnbWithdrawLimit()).to.equals(
      ethers.utils.parseEther("0.010686186535830937")
    );
  });

  it("Should be able to get token hub relay fee", async function () {
    await mockNativeStaking.mock.getRelayerFee.returns(RELAYER_FEE);
    expect(await stakeManager.getTokenHubRelayFee()).to.equals(RELAYER_FEE);
  });
});
