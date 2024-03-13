import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { Contract } from "ethers";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

import { impersonateAccount } from "../helper";
import { accountFixture, deployFixture } from "../fixture";

describe("ListaStakeManager::staking::basic", function() {
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  const RELAYER_FEE = "2000000000000000";
  const NATIVE_STAKING = "0x0000000000000000000000000000000000002001";

  let mockNativeStaking: MockContract;
  let slisBnb: Contract;
  let stakeManager: Contract;
  let admin: SignerWithAddress;
  let manager: SignerWithAddress;
  let bot: SignerWithAddress;
  let user: SignerWithAddress;
  let validator: string;
  let nativeStakingSigner: SignerWithAddress;

  before(async function() {
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
    slisBnb = await upgrades.deployProxy(
      await ethers.getContractFactory("SLisBNB"),
      [this.addrs[1].address]
    );
    await slisBnb.deployed();
    admin = this.addrs[1];
    manager = this.addrs[2];
    bot = this.addrs[3];
    user = this.addrs[6];
    validator = this.addrs[8].address;


    stakeManager = await upgrades.deployProxy(
      await ethers.getContractFactory("ListaStakeManager"),
      [
        slisBnb.address,
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
      slisBnb.connect(admin).setStakeManager(stakeManager.address),
      mockNativeStaking.mock.getRelayerFee.returns(RELAYER_FEE), // 0.002BNB relayer fee
      mockNativeStaking.mock.getMinDelegation.returns(
        ethers.utils.parseEther("0.5")
      ),
      mockNativeStaking.mock.delegate.returns(),
      mockNativeStaking.mock.redelegate.returns(),
      mockNativeStaking.mock.undelegate.returns(),
    ]);
  });


  // 1. user deposit 0.5 BNB
  it("Step 1 - Should be able to deposit", async function() {
    expect(await stakeManager.convertBnbToSlisBnb(1)).to.equals(1);
    const [balance1Before] = await Promise.all([
      slisBnb.balanceOf(user.address),
    ]);

    await stakeManager.connect(user).deposit({
      value: ethers.utils.parseEther("0.5"),
    });
    expect(await stakeManager.convertBnbToSlisBnb(1)).to.equals(1);
    const [balance1After] = await Promise.all([
      slisBnb.balanceOf(user.address),
    ]);
    expect(balance1After.sub(balance1Before)).to.equals(
      ethers.utils.parseEther("0.5")
    );
  });

  // 2. bot delegate 0.5 BNB to staking contract
  it("Step 2 - Should be able to delegate to specified validator by bot", async function() {
    await stakeManager
      .connect(admin)
      .whitelistValidator(validator);

    //await stakeManager.connect(user).deposit({ value: ethers.utils.parseEther("5") });

    const tx = await stakeManager
      .connect(bot)
      .delegateTo(validator, ethers.utils.parseEther("0.5"), {
        value: RELAYER_FEE,
      });

    expect(tx)
      .to.emit(stakeManager, "DelegateTo")
      .withArgs(validator, ethers.utils.parseEther("0.5"));
  });

  // 3. user requests to withdraw 0.5 slisBnb
  it("Step 3 - Should be able to request withdraw", async function() {
    // approve first
    await slisBnb
      .connect(user)
      .approve(stakeManager.address, ethers.constants.MaxUint256);
    expect(await stakeManager.amountToDelegate()).to.equals(0);
    expect(await slisBnb.totalSupply()).to.equals(
      ethers.utils.parseEther("0.5")
    );
    const tx1 = await stakeManager
      .connect(user)
      .requestWithdraw(ethers.utils.parseEther("0.5"));

    const res = await stakeManager.getUserWithdrawalRequests(
      user.address
    );

    expect(res[0][0]).to.equals(ethers.constants.MaxUint256);
    expect(res[0][1]).to.equals(ethers.utils.parseEther("0.5"));

    await expect(stakeManager
      .connect(user)
      .requestWithdraw(ethers.utils.parseEther("0.2"))).to.be.revertedWith("Not enough BNB to withdraw");
  });

  // 4. bot undelegate 0.5 BNB from validator
  it("Step 4 - Should be able to undelegate by bot", async function() {
    await mockNativeStaking.mock.getMinDelegation.returns(ethers.utils.parseEther("0.5"));

    await stakeManager.connect(bot).undelegateFrom(validator, ethers.utils.parseEther("0.5"),
      { value: RELAYER_FEE });

    const res = await stakeManager.getBotUndelegateRequest(0);
    expect(res[0]).not.to.equals(0);
    expect(res[1]).to.equals(0);
    expect(res[2]).to.equals(ethers.utils.parseEther("0.5"));
    expect(res[3]).to.equals(ethers.utils.parseEther("0.5"));
  });


  // 5. bot claims
  it("Step 5 - Should be able to claim undelegated by bot", async function() {
    const claimedAmount = ethers.utils
      .parseEther("1.216499999999999999")
      .toString();
    const uuid = await stakeManager.confirmedUndelegatedUUID();
    //    const botReq = await stakeManager.getBotUndelegateRequest(uuid);
    //    console.log(botReq);

    await mockNativeStaking.mock.claimUndelegated.returns(claimedAmount);
    await expect(stakeManager.connect(bot).claimUndelegated()).to.emit(stakeManager, "ClaimUndelegated").withArgs(uuid + 1, claimedAmount);
    // mock send reward
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: claimedAmount,
    });
  });


  // 6. user claims
  it("Step 6 - Should be able to claim withdraw by user", async function() {
    const requests = await stakeManager.getUserWithdrawalRequests(user.address);
    const uuid = await stakeManager.confirmedUndelegatedUUID();
    const botReq = await stakeManager.getBotUndelegateRequest(uuid - 1);

    const status1 = await stakeManager.getUserRequestStatus(
      user.address,
      0
    );
    expect(status1[0]).to.equals(true);
    expect(status1[1]).to.equals(ethers.utils.parseEther("0.5"));

    await expect(stakeManager.connect(user).claimAllWithdrawals())
      .to.emit(stakeManager, "ClaimAllWithdrawals")
      .withArgs(user.address, ethers.utils.parseEther("0.5"));
    // const tx1 = await stakeManager.connect(user).claimWithdraw(0);
    // expect(tx1)
    //   .to.emit(stakeManager, "ClaimWithdrawal")
    //   .withArgs(
    //     user.address,
    //     0,
    //     ethers.utils.parseEther("0.5")
    //   );
  });
});
