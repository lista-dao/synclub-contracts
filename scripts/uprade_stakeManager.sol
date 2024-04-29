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

        address proxyAddr = 0x035d0493f67ceCDd116D9BEd1EC47A56E3E98D25;
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(proxyAddr);

        proxy.upgradeTo(address(manager));

        vm.stopBroadcast();

        console.log("StakeManager implementation deployed at: ", address(manager));
        console.log("StakeManager proxy upgrade success!");
    }
}