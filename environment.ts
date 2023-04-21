import * as dotenv from "dotenv";
import * as path from "path";

import { ethers } from "ethers";

const envSuffix = process.env.NODE_ENV === "main" ? "" : ".test";

dotenv.config({ path: path.join(__dirname, ".env" + envSuffix) });

const DEPLOYER_PRIVATE_KEY =
  process.env.DEPLOYER_PRIVATE_KEY || ethers.Wallet.createRandom().privateKey;
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";
const SMART_CHAIN_RPC = process.env.SMART_CHAIN_RPC || "";
const CHAIN_ID = process.env.CHAIN_ID || "";
const DEFENDER_TEAM_API_KEY = process.env.DEFENDER_TEAM_API_KEY || "";
const DEFENDER_TEAM_API_SECRET_KEY =
  process.env.DEFENDER_TEAM_API_SECRET_KEY || "";

export {
  DEPLOYER_PRIVATE_KEY,
  ETHERSCAN_API_KEY,
  SMART_CHAIN_RPC,
  CHAIN_ID,
  DEFENDER_TEAM_API_KEY,
  DEFENDER_TEAM_API_SECRET_KEY,
};
