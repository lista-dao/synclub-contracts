import { ethers, upgrades, run } from "hardhat";

const admin = "0xeA71Ec772B5dd5aF1D15E31341d6705f9CB86232";
const contractName = "LisBNB";

async function main() {
  const Contract = await ethers.getContractFactory(contractName);

  console.log(`Deploying proxy ${contractName}`);
  const contract = await upgrades.deployProxy(Contract, [admin]);

  await contract.deployed();

  const contractImplAddress = await upgrades.erc1967.getImplementationAddress(
    contract.address
  );

  console.log(`Proxy ${contractName} deployed to:`, contract.address);
  console.log(`Impl ${contractName} deployed to:`, contractImplAddress);
  await run("verify:verify", { address: contractImplAddress });
}
// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
