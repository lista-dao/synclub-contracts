// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import "../contracts/LisBNB.sol";
import "../contracts/SLisBNB.sol";
import "../contracts/ListaStakeManager.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployListBNB is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address admin = 0x6616EF47F4d997137a04C2AD7FF8e5c228dA4f06;

        address stakeManager = 0x035d0493f67ceCDd116D9BEd1EC47A56E3E98D25;
        address lisBNBAddr = 0x97B40fe5A128ce8CBbd8160DB53c9693503eA318;
        address slisBNBAddr = 0x4CE3d6c4B3ad75Ce25E9eA1b35607b937b1172db;
        vm.startBroadcast(deployerPrivateKey);

        ListaStakeManager manager = ListaStakeManager(payable(stakeManager));
        LisBNB lisBNB = LisBNB(lisBNBAddr);
        SLisBNB slisBNB = SLisBNB(slisBNBAddr);

        slisBNB.approve(stakeManager, 1e18 ether);
        manager.requestWithdraw(0.05 ether);
        manager.requestWithdrawByLisBnb(0.05 ether);
//        manager.whitelistValidator();

        vm.stopBroadcast();
    }
}
