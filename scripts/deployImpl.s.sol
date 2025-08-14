// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "forge-std/Script.sol";

import { ListaStakeManager } from "../contracts/ListaStakeManager.sol";

contract ImplDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy ListaStakeManager implementation
    ListaStakeManager impl = new ListaStakeManager();
    console.log("ListaStakeManager implementation: ", address(impl));

    vm.stopBroadcast();
  }
}
