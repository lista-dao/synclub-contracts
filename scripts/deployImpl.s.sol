// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script, console2} from "forge-std/Script.sol";
import {ListaStakeManager} from "../contracts/ListaStakeManager.sol";

/**
 * @title DeployImplScript
 * @notice Deploys a fresh ListaStakeManager implementation (logic) contract.
 *         This only deploys the impl; upgrading the proxy to point at it is a
 *         separate, privileged step performed by the ProxyAdmin owner.
 *
 * @dev ListaStakeManager links the `SLisLibrary` external library. Foundry
 *      automatically deploys and links it during broadcast, so `new
 *      ListaStakeManager()` is all that is required here.
 *
 * Usage (BSC mainnet, chainId 56):
 *   export DEPLOYER_PRIVATE_KEY=0x...
 *   forge script scripts/deployImpl.s.sol:DeployImplScript \
 *     --rpc-url https://bsc-dataseed.bnbchain.org \
 *     --broadcast \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY \
 *     -vvvv
 *
 * Dry run (no broadcast): omit --broadcast.
 */
contract DeployImplScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Chain id:  %s", block.chainid);
        console2.log("Deployer:  %s", deployer);

        vm.startBroadcast(deployerPrivateKey);
        ListaStakeManager impl = new ListaStakeManager();
        vm.stopBroadcast();

        console2.log("ListaStakeManager impl deployed at: %s", address(impl));
    }
}
