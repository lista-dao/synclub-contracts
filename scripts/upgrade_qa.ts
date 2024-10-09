import { ethers, upgrades } from "hardhat";

const stakeManagerProxy = "0xc695F964011a5a1024931E2AF0116afBaC41B31B";

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

  await upgrades.validateUpgrade(stakeManagerProxy, NewStakeManagerFactory, {
    unsafeAllowLinkedLibraries: true,
  });
  console.log("StakeManager upgrade validated");

  const newStakeManager = await upgrades.upgradeProxy(
    stakeManagerProxy,
    NewStakeManagerFactory,
    {
      unsafeAllowLinkedLibraries: true,
    }
  );
  console.log("StakeManager upgraded to:", newStakeManager.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
