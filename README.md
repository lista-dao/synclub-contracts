# snBNB

```shell
npx hardhat accounts
npx hardhat compile
npx hardhat clean
npx hardhat test
npx hardhat node
npx hardhat help
REPORT_GAS=true npx hardhat test
npx hardhat coverage
npx hardhat run scripts/deploy.ts
TS_NODE_FILES=true npx ts-node scripts/deploy.ts
npx eslint '**/*.{js,ts}'
npx eslint '**/*.{js,ts}' --fix
npx prettier '**/*.{json,sol,md}' --check
npx prettier '**/*.{json,sol,md}' --write
npx solhint 'contracts/**/*.sol'
npx solhint 'contracts/**/*.sol' --fix
```

## Deploying

To deploy contracts, run:

```bash
NODE_ENV=main npx hardhat deploySnBnbProxy <admin> --network <network>
NODE_ENV=main npx hardhat upgradeSnBnbProxy <proxyAddress> --network <network>
NODE_ENV=main npx hardhat deploySnBnbImpl --network <network>

NODE_ENV=main npx hardhat deployStakeManagerProxy <snBnb> <admin> <manager> <bot> <fee> <revenuePool> <validator> --network <network>
NODE_ENV=main npx hardhat upgradeStakeManagerProxy <proxyAddress> --network <network>
NODE_ENV=main npx hardhat deployStakeManagerImpl --network <network>

# deploy the implementation of LisBNB, which is the new version of SnBNB
NODE_ENV=main npx hardhat deployLisBNBImpl --network <network>
```

## Verifying on etherscan

```bash
NODE_ENV=main npx hardhat verify <address> <...args> --network <network>
```
