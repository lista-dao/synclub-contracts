import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { Contract, providers } from "ethers";
import { loadFixture } from "ethereum-waffle";
import type { MockContract } from "@ethereum-waffle/mock-contract";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

import { impersonateAccount, toBytes32, toWei, readStorageAt } from "../helper";
import { accountFixture, deployFixture } from "../fixture";
import { getContractAddress } from "ethers/lib/utils";

describe("SnStakeManager::upgrade", function () {
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
      mockNativeStaking.mock.claimReward.returns(0),
    ]);
  });

  it("Old User Requests should be able to be claimed after Upgrade ", async function () {
    await snBnb
      .connect(user)
      .approve(stakeManager.address, ethers.constants.MaxUint256);
    await stakeManager.connect(user).deposit({ value: toWei("2") });
    await stakeManager.connect(user).requestWithdraw(toWei("1")); // 1st request
    await stakeManager.connect(bot).delegate({ value: RELAYER_FEE });
    await stakeManager.connect(bot).undelegate({ value: RELAYER_FEE });
    await mockNativeStaking.mock.claimUndelegated.returns(toWei("1"));
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: toWei("1"),
    });

    await stakeManager.connect(bot).claimUndelegated();

    const count = await stakeManager.getUserWithdrawalRequests(user.address);
    expect(count.length).to.be.equal(1);
    const status = await stakeManager.getUserRequestStatus(user.address, 0);
    expect(status["_isClaimable"]).to.be.equal(true);
    expect(status["_amount"]).to.be.equal(toWei("1"));

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

    await listaStakeManager.connect(user).requestWithdraw(toWei("1")); // 2nd request
    await listaStakeManager
      .connect(bot)
      .undelegateFrom(validator.address, toWei("1"), { value: RELAYER_FEE });
    await mockNativeStaking.mock.claimUndelegated.returns(toWei("1"));
    await nativeStakingSigner.sendTransaction({
      to: stakeManager.address,
      value: toWei("1"),
    });
    await stakeManager.connect(bot).claimUndelegated();

    expect(await listaStakeManager.connect(user).claimWithdraw(0))
      .to.emit(listaStakeManager, "ClaimWithdrawal")
      .withArgs(user.address, 0, toWei("1"));
    expect(await listaStakeManager.connect(user).claimWithdraw(0)) // both requests should be claimed successfully
      .to.emit(listaStakeManager, "ClaimWithdrawal")
      .withArgs(user.address, 0, toWei("1"));
  });
});
