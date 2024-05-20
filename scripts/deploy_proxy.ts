import { deployProxy } from "./tasks";
import { ethers, upgrades } from "hardhat";

const admin = "0x245b3Ee7fCC57AcAe8c208A563F54d630B5C4eD7";
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
}
// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
