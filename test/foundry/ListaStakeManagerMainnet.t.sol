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
import "../../contracts/interfaces/IStakeCredit.sol";

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
    address manager = makeAddr("manager");
    address validator_A = 0x343dA7Ff0446247ca47AA41e2A25c5Bbb230ED0A;
    address validator_B = 0xF2B1d86DC7459887B1f7Ce8d840db1D87613Ce7f;
    address validator_C = 0x7766A5EE8294343bF6C8dcf3aA4B6D856606703A;
    IStakeCredit credit_A =
        IStakeCredit(0xeC06CB25d9add4bDd67B61432163aFF9028Aa921);

    address user_A = address(0xAA);

    function setUp() public {
        vm.createSelectFork("https://bsc-dataseed.binance.org");
        slisBnb = SLisBNB(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B);
        stakeManager = ListaStakeManager(payable(proxy));

        address newImpl = address(new ListaStakeManager());

        vm.prank(timelock);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(proxy), newImpl);
        vm.stopPrank();

        vm.startPrank(admin);
        stakeManager.grantRole(stakeManager.MANAGER(), manager);
        vm.stopPrank();

        assertTrue(stakeManager.hasRole(stakeManager.MANAGER(), manager));
    }

    // delegate all voting power to validator_A
    function test_delegateVoteTo() public {
        uint256 balance = govToken.balanceOf(address(stakeManager));
        uint256 votes_A = govToken.getVotes(validator_A);

        // delegate to zero address should be reverted
        vm.prank(admin);
        vm.expectRevert("Invalid Address");
        stakeManager.delegateVoteTo(address(0));

        // Step 1, delegate voting power to stakeManager itself to track the voting power
        // Commented because already initialized
        // vm.prank(admin);
        // stakeManager.delegateVoteTo(address(stakeManager));

        // Step 2, delegate voting power to validator_A
        vm.prank(admin);
        stakeManager.delegateVoteTo(validator_A);

        uint256 votes_A_after = govToken.getVotes(validator_A) - votes_A;
        assertEq(govToken.delegates(address(stakeManager)), validator_A);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
        assertEq(votes_A_after, balance);

        // delegate voting power to user_A
        vm.prank(admin);
        stakeManager.delegateVoteTo(user_A);
        assertEq(govToken.delegates(address(stakeManager)), user_A);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
        assertEq(govToken.getVotes(user_A), balance);
        assertEq(govToken.getVotes(validator_A), votes_A); // validator_A's voting power moved to user_A

        // cannot delegate voting power to user_A again
        vm.prank(admin);
        vm.expectRevert("Already Delegated");
        stakeManager.delegateVoteTo(user_A);
    }

    function test_delegateVoteTo_and_stake_Bnb() public {
        // Step 1, delegate voting power to stakeManager itself to track the voting power
        // Commented because already initialized
        // vm.prank(admin);
        // stakeManager.delegateVoteTo(address(stakeManager));

        // Step 2, delegate voting power to validator_A
        uint256 votes_A_before = govToken.getVotes(validator_A);
        uint256 balance1 = govToken.balanceOf(address(stakeManager));
        vm.prank(admin);
        stakeManager.delegateVoteTo(validator_A);

        uint256 votes_A = govToken.getVotes(validator_A);
        assertEq(govToken.delegates(address(stakeManager)), validator_A);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
        assertEq(votes_A, votes_A_before + balance1);

        skip(1 days);

        // Step 3, users stake BNB
        deal(user_A, 10000 ether);
        stakeManager.deposit{value: 10 ether}();
        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 10 ether);
        uint256 balance2 = govToken.balanceOf(address(stakeManager));

        assertEq(govToken.getVotes(validator_A), votes_A_before + balance2);
        assertEq(govToken.getVotes(address(stakeManager)), 0);
    }

    // cancel the vote delegation by delegating to itself
    function test_cancelVoteDelegation() public {
        uint256 votes_A_before = govToken.getVotes(validator_A);
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
        assertEq(govToken.getVotes(validator_A), votes_A_before);
    }

    function test_refundCommission_normal() public {
        deal(manager, 100000 ether);

        uint256 exRate_0 = stakeManager.convertSnBnbToBnb(1 ether);
        skip(1 days);

        // Refun 1 bnb, 2 days
        vm.prank(manager);
        stakeManager.refundCommission{value: 1 ether}(2);
        uint256 exRate_1 = stakeManager.convertSnBnbToBnb(1 ether);

        assertEq(exRate_1, exRate_0);
        (
            uint dailySlisBnb,
            uint remainingSlisBnb,
            uint lastBurnTime
        ) = stakeManager.refund();

        assertEq(dailySlisBnb, stakeManager.convertBnbToSnBnb(1 ether) / 2);
        assertEq(remainingSlisBnb, stakeManager.convertBnbToSnBnb(1 ether));
        assertEq(lastBurnTime, 0);

        skip(1 hours);
        uint _amount = stakeManager.amountToDelegate();
        vm.prank(bot);
        stakeManager.delegateTo(validator_A, _amount);

        // First burn
        skip(1 days);
        uint pooled_A = credit_A.getPooledBNB(address(stakeManager));
        vm.mockCall(
            address(credit_A),
            abi.encodeWithSignature("getPooledBNB(address)"),
            abi.encode(pooled_A + 1 ether + 0.1 ether) // original + refund + reward
        );
        vm.prank(bot);
        stakeManager.compoundRewards();
        (
            uint dailySlisBnb_2,
            uint remainingSlisBnb_2,
            uint lastBurnTime_2
        ) = stakeManager.refund();
        assertEq(dailySlisBnb_2, dailySlisBnb);
        assertEq(remainingSlisBnb_2, remainingSlisBnb - dailySlisBnb);
        assertEq(lastBurnTime_2, block.timestamp);

        // Second burn
        skip(1 days);
        // vm.clearMockedCalls();
        vm.mockCall(
            address(credit_A),
            abi.encodeWithSignature("getPooledBNB(address)"),
            abi.encode(pooled_A + 1 ether + 0.22 ether) // original + refund + reward
        );
        vm.prank(bot);
        stakeManager.compoundRewards();
        (
            uint dailySlisBnb_3,
            uint remainingSlisBnb_3,
            uint lastBurnTime_3
        ) = stakeManager.refund();
        assertEq(dailySlisBnb_3, dailySlisBnb);
        assertApproxEqAbs(remainingSlisBnb_3, 0, 1); // 0 or 1 wei remaining
        assertEq(lastBurnTime_3, block.timestamp);

        // Third time
        skip(1 days);
        vm.mockCall(
            address(credit_A),
            abi.encodeWithSignature("getPooledBNB(address)"),
            abi.encode(pooled_A + 3 ether)
        );
        vm.prank(bot);
        stakeManager.compoundRewards();
        (dailySlisBnb, remainingSlisBnb, lastBurnTime) = stakeManager.refund();
        assertEq(dailySlisBnb, 0);
        assertEq(remainingSlisBnb, 0);
        assertEq(lastBurnTime, block.timestamp);

        // Second Refund: 2 bnb, 3 days
        vm.prank(manager);
        stakeManager.refundCommission{value: 2 ether}(3);
        (dailySlisBnb, remainingSlisBnb, lastBurnTime) = stakeManager.refund();

        assertEq(dailySlisBnb, stakeManager.convertBnbToSnBnb(2 ether) / 3);
        assertEq(remainingSlisBnb, stakeManager.convertBnbToSnBnb(2 ether));
        assertEq(lastBurnTime, block.timestamp);

        // Second Refund: 1st burn
        skip(1 days);
        vm.mockCall(
            address(credit_A),
            abi.encodeWithSignature("getPooledBNB(address)"),
            abi.encode(pooled_A + 3 ether + 0.45 ether) // original + refund + reward
        );
        vm.prank(bot);
        stakeManager.compoundRewards();
        (dailySlisBnb_2, remainingSlisBnb_2, lastBurnTime_2) = stakeManager
            .refund();
        assertEq(dailySlisBnb_2, dailySlisBnb);
        assertEq(remainingSlisBnb_2, remainingSlisBnb - dailySlisBnb);
        assertEq(lastBurnTime_2, block.timestamp);

        // Second Refund: 2nd burn
        skip(1 days);
        vm.mockCall(
            address(credit_A),
            abi.encodeWithSignature("getPooledBNB(address)"),
            abi.encode(pooled_A + 3 ether + 0.75 ether) // original + refund + reward
        );
        vm.prank(bot);
        stakeManager.compoundRewards();
        (dailySlisBnb_3, remainingSlisBnb_3, lastBurnTime_3) = stakeManager
            .refund();
        assertEq(dailySlisBnb_3, dailySlisBnb_2);
        assertEq(remainingSlisBnb_3, remainingSlisBnb_2 - dailySlisBnb_3);
        assertEq(lastBurnTime_3, block.timestamp);

        // Second Refund: 3rd burn
        skip(1 days);
        vm.mockCall(
            address(credit_A),
            abi.encodeWithSignature("getPooledBNB(address)"),
            abi.encode(pooled_A + 3 ether + 0.95 ether) // original + refund + reward
        );
        vm.prank(bot);
        stakeManager.compoundRewards();
        (dailySlisBnb, remainingSlisBnb, lastBurnTime) = stakeManager
            .refund();
        assertEq(dailySlisBnb, dailySlisBnb_3);
        assertApproxEqAbs(remainingSlisBnb, 0, 2); // 0 or 1 or 2 wei remaining
        assertEq(lastBurnTime, block.timestamp);
    }
}
