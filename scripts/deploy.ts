import { ethers } from "hardhat";

async function main() {
  const stakeManagerContractFactory = await ethers.getContractFactory(
    "SnStakeManager"
  );
  const stakeManagerContract = await stakeManagerContractFactory.deploy();

  await stakeManagerContract.deployed();

  console.log(
    "SnStakeManager Contract deployed to:",
    stakeManagerContract.address
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
