// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import "../contracts/ListaStakeManager.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployStakeManager is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);
        ListaStakeManager manager = new ListaStakeManager();

        address slisBNB = 0x4CE3d6c4B3ad75Ce25E9eA1b35607b937b1172db;

        bytes memory data = abi.encodeWithSelector(
        ListaStakeManager.initialize.selector,
            slisBNB,
            deployer,
            deployer,
            deployer,
            5e8,
            deployer,
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(slisBNB), deployer, data);
        vm.stopBroadcast();

        console.log("SLisBNB implementation deployed at: ", address(slisBNB));
        console.log("SLisBNB proxy deployed at: ", address(proxy));
    }
}