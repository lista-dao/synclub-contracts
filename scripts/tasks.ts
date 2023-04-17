import { HardhatRuntimeEnvironment } from "hardhat/types";

export async function deployDirect(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  ...args: any
) {
  const Contract = await hre.ethers.getContractFactory(contractName);

  console.log(`Deploying ${contractName}: ${args}, ${args.length}`);
  const contract = args.length
    ? await Contract.deploy(...args)
    : await Contract.deploy();

  await contract.deployed();

  console.log(`${contractName} deployed to:`, contract.address);
}

export async function deployProxy(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  ...args: any
) {
  const Contract = await hre.ethers.getContractFactory(contractName);

  console.log(`Deploying proxy ${contractName}: ${args}, ${args.length}`);
  const contract = args.length
    ? await hre.upgrades.deployProxy(Contract, args)
    : await hre.upgrades.deployProxy(Contract);

  await contract.deployed();

  const contractImplAddress =
    await hre.upgrades.erc1967.getImplementationAddress(contract.address);

  console.log(`Proxy ${contractName} deployed to:`, contract.address);
  console.log(`Impl ${contractName} deployed to:`, contractImplAddress);
}

export async function upgradeProxy(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  proxyAddress: string
) {
  const Contract = await hre.ethers.getContractFactory(contractName);

  console.log(`Upgrading ${contractName} with proxy at: ${proxyAddress}`);

  const contract = await hre.upgrades.upgradeProxy(proxyAddress, Contract);
  await contract.deployed();

  const contractImplAddress =
    await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log(`Proxy ${contractName} deployed to:`, contract.address);
  console.log(`Impl ${contractName} deployed to:`, contractImplAddress);
}
