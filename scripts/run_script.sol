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
        address admin = 0xeA71Ec772B5dd5aF1D15E31341d6705f9CB86232;
        vm.startBroadcast(deployerPrivateKey);
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(0x97B40fe5A128ce8CBbd8160DB53c9693503eA318);

        proxy.changeAdmin(admin);

        proxy = ITransparentUpgradeableProxy(0x035d0493f67ceCDd116D9BEd1EC47A56E3E98D25);
        proxy.changeAdmin(admin);

        proxy = ITransparentUpgradeableProxy(0x4CE3d6c4B3ad75Ce25E9eA1b35607b937b1172db);
        proxy.changeAdmin(admin);


        vm.stopBroadcast();
    }
}
