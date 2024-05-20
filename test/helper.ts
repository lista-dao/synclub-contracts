import { ethers, network } from "hardhat";

export const abi = new ethers.utils.AbiCoder();

/**
 * Create a test account
 * @param {string} address
 * @param {string} balance
 * @return {ethers.JsonRpcSigner}
 */
export async function impersonateAccount(address: string, balance = "0x0") {
  await network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [address],
  });

  await network.provider.send("hardhat_setBalance", [address, balance]);

  return await ethers.getSigner(address);
}

export async function readStorageAt(addr: string, slot: number) {
  const data = await ethers.provider.getStorageAt(addr, slot);
  return ethers.BigNumber.from(abi.decode(["uint256"], data)[0]);
}

export function toBytes32(num: number) {
  return ethers.utils.hexZeroPad(ethers.utils.hexlify(num), 32);
}

export function toWei(eth: string) {
  return ethers.utils.parseEther(eth);
}