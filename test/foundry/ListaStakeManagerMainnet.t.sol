// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import "../../contracts/ListaStakeManager.sol";
import "../../contracts/SLisBNB.sol";

contract ListaStakeManagerMainnet is Test {
    ListaStakeManager public stakeManager;
    SLisBNB public slisBnb;

    address proxy = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    ERC20VotesUpgradeable govToken =
        ERC20VotesUpgradeable(0x0000000000000000000000000000000000002005);

    address timelock = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
    ProxyAdmin proxyAdmin =
        ProxyAdmin(0x8Ce30a8d13D6d729708232aA415d7DA46a4FA07b);

    address bot = 0x9c975db5E112235b6c4a177C2A5c67ab4d758499;
    address admin = 0x5C0F11c927216E4D780E2a219b06632Fb027274E;
    address validator_A = 0x343dA7Ff0446247ca47AA41e2A25c5Bbb230ED0A;
    address validator_B = 0xF2B1d86DC7459887B1f7Ce8d840db1D87613Ce7f;
    address validator_C = 0x7766A5EE8294343bF6C8dcf3aA4B6D856606703A;

    address user_A = address(0xAA);

    function setUp() public {
        vm.createSelectFork("https://bsc-dataseed.binance.org");
        slisBnb = SLisBNB(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B);
        stakeManager = ListaStakeManager(payable(proxy));

        address newImpl = address(new ListaStakeManager());
        vm.prank(timelock);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(proxy), newImpl);
    }

    // delegate all voting power to validator_A
    function test_delegateVoteTo() public {
        uint256 balance = govToken.balanceOf(address(stakeManager));
        uint256 votes_A = govToken.getVotes(validator_A);

        // delegate to zero address should be reverted
        vm.prank(admin);
        vm.expectRevert("Invalid Address");
        stakeManager.delegateVoteTo(address(0));

        // before activation, delegate voting power to validator_A should be reverted
        vm.prank(admin);
        vm.expectRevert("Invalid Change");
        stakeManager.delegateVoteTo(validator_A);

        // Step 1, delegate voting power to stakeManager itself to track the voting power
        vm.prank(admin);
        stakeManager.delegateVoteTo(address(stakeManager));

        // Step 2, delegate voting power to validator_A
        vm.prank(admin);
        stakeManager.delegateVoteTo(validator_A);

        votes_A = govToken.getVotes(validator_A) - votes_A;
        assertEq(govToken.delegates(address(stakeManager)), validator_A);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
        assertEq(votes_A, balance);

        // delegate voting power to user_A
        vm.prank(admin);
        stakeManager.delegateVoteTo(user_A);
        assertEq(govToken.delegates(address(stakeManager)), user_A);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
        assertEq(govToken.getVotes(user_A), balance);
        assertEq(govToken.getVotes(validator_A), 0); // validator_A has no voting power after delegation to user_A

        // cannot delegate voting power to user_A again
        vm.prank(admin);
        vm.expectRevert("Already Delegated");
        stakeManager.delegateVoteTo(user_A);
    }

    function test_delegateVoteTo_and_stake_Bnb() public {
        // Step 1, delegate voting power to stakeManager itself to track the voting power
        vm.prank(admin);
        stakeManager.delegateVoteTo(address(stakeManager));

        // Step 2, delegate voting power to validator_A
        uint256 balance1 = govToken.balanceOf(address(stakeManager));
        vm.prank(admin);
        stakeManager.delegateVoteTo(validator_A);

        uint256 votes_A = govToken.getVotes(validator_A);
        assertEq(govToken.delegates(address(stakeManager)), validator_A);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
        assertEq(votes_A, balance1);

        skip(1 days);

        // Step 3, users stake BNB
        deal(user_A, 10000 ether);
        stakeManager.deposit{value: 10 ether}();
        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 10 ether);
        uint256 balance2 = govToken.balanceOf(address(stakeManager));

        assertEq(govToken.getVotes(validator_A), balance2);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
    }

    // cancel the vote delegation by delegating to itself
    function test_cancelVoteDelegation() public {
        uint256 balance = govToken.balanceOf(address(stakeManager));
        test_delegateVoteTo();
        vm.prank(admin);
        stakeManager.delegateVoteTo(address(stakeManager));
        assertEq(
            govToken.delegates(address(stakeManager)),
            address(stakeManager)
        );
        assertEq(govToken.getVotes(address(stakeManager)), balance);
        assertEq(govToken.getVotes(user_A), 0); // user_A has no voting power after cancellation
        assertEq(govToken.getVotes(validator_A), 0); // validator_A has no voting power after delegation to user_A
    }

    /*
    // test delegate voting power by re-delegating
    function test_votingPower_by_redelegate() public {
        // 1. turn on the vote delegation
        vm.prank(admin);
        stakeManager.toggleVote();
        assertTrue(stakeManager.delegateVotePower());

        // 2. delegate voting power to validator_B
        uint256 amount = 100 ether; // 100 BNB
        uint256 govBalance = govToken.balanceOf(address(stakeManager));
        vm.prank(bot);
        stakeManager.redelegate(validator_A, validator_B, amount); // now validator_B has all the voting power
        govBalance = govToken.balanceOf(address(stakeManager));

        assertEq(govToken.delegates(address(stakeManager)), validator_B);

        // 3. delegate voting power to validator_C
        vm.startPrank(bot);
        stakeManager.redelegate(validator_B, validator_C, amount);
        vm.stopPrank();
        assertEq(govToken.delegates(address(stakeManager)), validator_C);

        console.log("///////// Re-delegate: B -> C");
        govBalance = govToken.balanceOf(address(stakeManager));
        console.log("///////// Clear delegation");
        vm.startPrank(address(stakeManager));
        govToken.delegate(address(stakeManager));
        vm.stopPrank();
        assertEq(
            govToken.delegates(address(stakeManager)),
            address(stakeManager)
        );
        govBalance = govToken.balanceOf(address(stakeManager));
    }
    */
}
