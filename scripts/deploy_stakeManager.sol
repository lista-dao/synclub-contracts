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
        address admin = vm.envAddress("ADMIN_ADDRESS");
        vm.startBroadcast(deployerPrivateKey);
        ListaStakeManager manager = new ListaStakeManager();

        address slisBNB = 0x4CE3d6c4B3ad75Ce25E9eA1b35607b937b1172db;
        address bscValidator = 0x696606f04f7597F444265657C8c13039Fd759b14;

        bytes memory data = abi.encodeWithSelector(
        ListaStakeManager.initialize.selector,
            slisBNB,
            admin,
            admin,
            admin,
            5e8,
            admin,
            bscValidator
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(manager), deployer, data);
        vm.stopBroadcast();

        console.log("StakeManager implementation deployed at: ", address(slisBNB));
        console.log("StakeManager proxy deployed at: ", address(proxy));
    }
}