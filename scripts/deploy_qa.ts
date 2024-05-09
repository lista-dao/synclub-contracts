import { ethers, upgrades } from "hardhat";

const admin = "";
const manager = "";
const bot = "";
const revenuePool = "";
const validator = "";

async function main() {
  const slisBnbContractFactory = await ethers.getContractFactory("SLisBNB");

  const slisBnb = await upgrades.deployProxy(slisBnbContractFactory, [admin]);
  slisBnb.deployed();

  console.log("SLisBNB Contract deployed to:", slisBnb.address);

  const stakeManagerContractFactory = await ethers.getContractFactory(
    "contracts/oldContracts/SnStakeManager.sol:SnStakeManager"
  );

  const stakeManager = await upgrades.deployProxy(stakeManagerContractFactory, [
    slisBnb.address,
    admin,
    manager,
    bot,
    "500000000", // 5% fee
    revenuePool,
    validator,
  ]);

  await stakeManager.deployed();

  console.log("SnStakeManager Contract deployed to:", stakeManager.address);
  const tx = await slisBnb.setStakeManager(stakeManager.address);
  console.log("setStakeManager tx:", tx.hash);

  // user deposit 0.01 bnb and then request withdraw all
  await stakeManager.deposit({ value: ethers.utils.parseEther("0.001") });
  await slisBnb.approve(stakeManager.address, ethers.utils.parseEther("0.01"));
  await stakeManager.requestWithdraw(ethers.utils.parseEther("0.001"));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
