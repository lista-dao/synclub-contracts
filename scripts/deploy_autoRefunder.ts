import * as hrc from "hardhat";
import { deployProxy } from "./tasks";

async function main() {
  let admin, manager, bot, pauser, stakeManager, vault;

  if (hrc.network.name === "testnet") {
    let [deployer,] = await hrc.ethers.getSigners();
    admin = deployer.address;
    manager = deployer.address;
    bot = deployer.address;
    pauser = deployer.address;
    stakeManager = '0xc695F964011a5a1024931E2AF0116afBaC41B31B';
    vault = deployer.address;
  } else if (hrc.network.name === "mainnet") {
    admin = '0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253';
    manager = '0x8d388136d578dCD791D081c6042284CED6d9B0c6';
    bot = '0x9c975db5E112235b6c4a177C2A5c67ab4d758499';
    pauser = '0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8';
    stakeManager = '0x1adB950d8bB3dA4bE104211D5AB038628e477fE6';
    vault = '0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66';
  }

  deployProxy(hrc, "AutoRefunder", admin, manager, bot, pauser, stakeManager, vault);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
