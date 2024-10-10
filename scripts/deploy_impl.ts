import { ethers, upgrades } from "hardhat";

async function main() {
  const SLisLibrary = await ethers.getContractFactory("SLisLibrary");
  const sLisLibrary = await SLisLibrary.deploy();
  await sLisLibrary.deployed();
  console.log("SLisLibrary deployed to:", sLisLibrary.address);

  const NewStakeManagerFactory = await ethers.getContractFactory(
    "contracts/ListaStakeManager.sol:ListaStakeManager",
    {
      libraries: {
        SLisLibrary: sLisLibrary.address,
      },
    }
  );

  const newImpl = await NewStakeManagerFactory.deploy();
  await newImpl.deployed();
  console.log("New ListaStakeManager implementation deployed to:", newImpl.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
