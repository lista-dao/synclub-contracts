import { HardhatRuntimeEnvironment } from "hardhat/types";
import { HardhatUserConfig, task } from "hardhat/config";
import {
  deployDirect,
  deployProxy,
  upgradeProxy,
  forceUpgradeProxy,
  validateUpgrade,
} from "./scripts/tasks";

import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "@openzeppelin/hardhat-upgrades";
import "@openzeppelin/hardhat-defender";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-forta";
import "hardhat-storage-layout";

import {
  DEPLOYER_PRIVATE_KEY,
  ETHERSCAN_API_KEY,
  SMART_CHAIN_RPC,
  CHAIN_ID,
} from "./environment";

task("deploySnBnbProxy", "Deploy SnBnb Proxy only")
  .addPositionalParam("admin")
  .setAction(async ({ admin }, hre: HardhatRuntimeEnvironment) => {
    await deployProxy(hre, "SnBnb", admin);
  });

task("deploySlisBnbProxy", "Deploy slisBNB Proxy and Impl")
  .addPositionalParam("admin")
  .setAction(async ({ admin }, hre: HardhatRuntimeEnvironment) => {
    await deployProxy(hre, "SLisBNB", admin);
  });

task("upgradeSnBnbProxy", "Upgrade SnBnb Proxy")
  .addPositionalParam("proxyAddress")
  .setAction(async ({ proxyAddress }, hre: HardhatRuntimeEnvironment) => {
    await upgradeProxy(hre, "SnBnb", proxyAddress);
  });

task("deploySnBnbImpl", "Deploy SnBnb Implementation only").setAction(
  async (args, hre: HardhatRuntimeEnvironment) => {
    await deployDirect(hre, "SnBnb");
  }
);

task("deployListaStakeManagerProxy", "Deploy ListaStakeManager Proxy only")
  .addPositionalParam("slisBnb")
  .addPositionalParam("admin")
  .addPositionalParam("manager")
  .addPositionalParam("bot")
  .addPositionalParam("fee")
  .addPositionalParam("revenuePool")
  .addPositionalParam("validator")
  .setAction(
    async (
      { slisBnb, admin, manager, bot, fee, revenuePool, validator },
      hre: HardhatRuntimeEnvironment
    ) => {
      await deployProxy(
        hre,
        "ListaStakeManager",
        slisBnb,
        admin,
        manager,
        bot,
        fee,
        revenuePool,
        validator
      );
    }
  );

task("deployStakeManagerProxy", "Deploy StakeManager Proxy only")
  .addPositionalParam("snBnb")
  .addPositionalParam("admin")
  .addPositionalParam("manager")
  .addPositionalParam("bot")
  .addPositionalParam("fee")
  .addPositionalParam("revenuePool")
  .addPositionalParam("validator")
  .setAction(
    async (
      { snBnb, admin, manager, bot, fee, revenuePool, validator },
      hre: HardhatRuntimeEnvironment
    ) => {
      await deployProxy(
        hre,
        "SnStakeManager",
        snBnb,
        admin,
        manager,
        bot,
        fee,
        revenuePool,
        validator
      );
    }
  );

task("upgradeStakeManagerProxy", "Upgrade StakeManager Proxy")
  .addPositionalParam("proxyAddress")
  .setAction(async ({ proxyAddress }, hre: HardhatRuntimeEnvironment) => {
    await upgradeProxy(hre, "ListaStakeManager", proxyAddress);
  });

task("forceUpgradeStakeManagerProxy", "ForceImport Upgrade StakeManager Proxy")
  .addPositionalParam("proxyAddress")
  .setAction(async ({ proxyAddress }, hre: HardhatRuntimeEnvironment) => {
    await forceUpgradeProxy(
      hre,
      "contracts/ListaStakeManager.sol:ListaStakeManager",
      "contracts/oldContracts/ListaStakeManager.sol:ListaStakeManager",
      proxyAddress
    );
  });

task(
  "deployStakeManagerImpl",
  "Deploy StakeManager Implementation only"
).setAction(async (args, hre: HardhatRuntimeEnvironment) => {
  await validateUpgrade(
    hre,
    "contracts/oldContracts/ListaStakeManager.sol:ListaStakeManager",
    "contracts/ListaStakeManager.sol:ListaStakeManager"
  );
  await deployDirect(hre, "contracts/ListaStakeManager.sol:ListaStakeManager");
});

task(
  "deploySLisBNBImpl",
  "Deploy SLisBNB Implementation only, which is the new version of SnBnb"
).setAction(async (args, hre: HardhatRuntimeEnvironment) => {
  await validateUpgrade(hre, "SnBnb", "SLisBNB");
  await deployDirect(hre, "SLisBNB");
});

task("deployMockStaking", "Deploy Mock Native Staking contract").setAction(
  async (args, hre: HardhatRuntimeEnvironment) => {
    await deployDirect(hre, "MockNativeStaking");
  }
);

task(
  "validateUpgrade",
  "Validate contract upgrade from SnStakeManger to ListaStakeManager"
).setAction(async (args, hre: HardhatRuntimeEnvironment) => {
  await validateUpgrade(hre, "SnStakeManager", "ListaStakeManager");
});

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  solidity: {
    compilers: [
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  networks: {
    mainnet: {
      url: SMART_CHAIN_RPC,
      chainId: Number(CHAIN_ID),
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    testnet: {
      url: SMART_CHAIN_RPC,
      chainId: Number(CHAIN_ID),
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    hardhat: {
      allowUnlimitedContractSize: true,
    },
  },
  mocha: {
    timeout: 40000,
  },
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    // enabled: process.env.REPORT_GAS ? true : false,
  },
  etherscan: {
    apiKey: ETHERSCAN_API_KEY,
  },
};

export default config;
