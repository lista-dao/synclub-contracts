// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import "../contracts/LisBNB.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployListBNB is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address admin = vm.envAddress("ADMIN_ADDRESS");
        vm.startBroadcast(deployerPrivateKey);
        LisBNB lisBNB = new LisBNB();

        bytes memory data = abi.encodeWithSelector(LisBNB.initialize.selector, admin);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(lisBNB), deployer, data);
        vm.stopBroadcast();

        console.log("LisBNB implementation deployed at: ", address(lisBNB));
        console.log("LisBNB proxy deployed at: ", address(proxy));
    }
}