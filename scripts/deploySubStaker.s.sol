// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubStaker} from "../contracts/SubStaker.sol";

/**
 * @title DeploySubStakerScript
 * @notice Deploys the SubStaker implementation and its ERC1967 proxy.
 *
 * @dev The proxy is initialized in its own constructor. Deploying it bare and calling
 *      `initialize` afterwards would let anyone front-run that call, set themselves as
 *      `stakeManager` and own the upgrade path, so the two must not be separate transactions.
 *
 *      Binding the proxy to the manager is deliberately NOT done here: `setSubStaker` is
 *      restricted to the timelock and goes through governance.
 *
 * Usage:
 *   export DEPLOYER_PRIVATE_KEY=0x...
 *   export STAKE_MANAGER=0x...
 *   forge script scripts/deploySubStaker.s.sol:DeploySubStakerScript \
 *     --rpc-url <rpc> --broadcast
 *
 * On testnet, run it through scripts/with-testnet-timelock.sh so the timelock constant
 * points at an account that exists on that chain.
 */
contract DeploySubStakerScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address stakeManager = vm.envAddress("STAKE_MANAGER");

        console2.log("Chain id:     %s", block.chainid);
        console2.log("Deployer:     %s", vm.addr(deployerPrivateKey));
        console2.log("StakeManager: %s", stakeManager);

        vm.startBroadcast(deployerPrivateKey);
        SubStaker impl = new SubStaker();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(SubStaker.initialize.selector, stakeManager));
        vm.stopBroadcast();

        console2.log("SubStaker impl deployed at:  %s", address(impl));
        console2.log("SubStaker proxy deployed at: %s", address(proxy));

        require(SubStaker(payable(address(proxy))).stakeManager() == stakeManager, "proxy not initialized");
    }
}
