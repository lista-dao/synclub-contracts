import * as hrc from "hardhat";
import { deployDirect } from "./tasks";

async function main() {
  deployDirect(hrc, "SnBnb");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
