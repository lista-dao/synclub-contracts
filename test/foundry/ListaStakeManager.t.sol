// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../../contracts/ListaStakeManager.sol";
import "../../contracts/SLisBNB.sol";
import "../../contracts/mock/MockClaim.sol";

import {IStakeManager} from "../../contracts/interfaces/IStakeManager.sol";

contract ListaStakeManagerTest is Test {
    address private constant STAKE_HUB = 0x0000000000000000000000000000000000002002;

    IStakeManager public stakeManager;
    SLisBNB public slisBnb;

    address public proxyAdminOwner = address(0x2A11AA);

    address public admin = address(0x5A11AA1);
    address public manager = address(0x5A11AA2);
    address public bot = address(0x5A11AA3);
    address public revenuePool = address(0x5A11AA4);
    address public validator = address(0x5A11AA6);

    uint256 public synFee = 500000000;

    address public user_A = address(0x2A);
    address public validator_A = address(0x5A);
    address public credit_A = address(0x55A);

    ClaimMock public claimMock;
    CreditMock public creditMock;

    function setUp() public {
        SLisBNB slisBnbImpl = new SLisBNB();
        TransparentUpgradeableProxy slisBnbProxy = new TransparentUpgradeableProxy(
            address(slisBnbImpl), proxyAdminOwner, abi.encodeWithSignature("initialize(address)", admin)
        );
        slisBnb = SLisBNB(address(slisBnbProxy));

        ListaStakeManager stakeManagerImpl = new ListaStakeManager();
        TransparentUpgradeableProxy stakeManagerProxy = new TransparentUpgradeableProxy(
            address(stakeManagerImpl),
            proxyAdminOwner,
            abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,address,address)",
                address(slisBnb),
                admin,
                manager,
                bot,
                synFee,
                revenuePool,
                validator
            )
        );
        stakeManager = IStakeManager(address(stakeManagerProxy));

        vm.startPrank(admin);
        slisBnb.setStakeManager(address(stakeManager));
        vm.stopPrank();

        creditMock = new CreditMock();
        creditMock.setStakeManager(address(stakeManager));

        claimMock = new ClaimMock();

        // Modify `nextConfirmedRequestUUID` to have it start from 1
        vm.store(address(stakeManager), bytes32(uint256(205)), bytes32(uint256(1)));
    }

    function test_deposit() public {
        deal(user_A, 1 ether);

        vm.prank(user_A);
        stakeManager.deposit{value: 0.5 ether}();
        vm.stopPrank();

        assertEq(stakeManager.getTotalPooledBnb(), 0.5 ether);
        assertEq(slisBnb.balanceOf(user_A), 0.5 ether);
    }

    function test_whitelistValidator() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);
        vm.stopPrank();
    }

    function test_delegateTo_validator_A() public {
        deal(user_A, 100 ether);
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("minDelegationBNBChange()"), abi.encode(0));

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);
        vm.stopPrank();

        vm.prank(user_A);
        stakeManager.deposit{value: 1 ether}();
        vm.stopPrank();

        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 1 ether);
        vm.stopPrank();

        assertEq(stakeManager.getTotalPooledBnb(), 1 ether);
        assertEq(slisBnb.balanceOf(user_A), 1 ether);
    }

    function test_requestWithdraw() public {
        deal(user_A, 10 ether);

        vm.prank(user_A);
        stakeManager.deposit{value: 5 ether}();
        vm.stopPrank();

        assertEq(stakeManager.getTotalPooledBnb(), 5 ether);
        assertEq(slisBnb.balanceOf(user_A), 5 ether);

        vm.prank(user_A);
        slisBnb.approve(address(stakeManager), 5 ether);
        vm.stopPrank();

        vm.prank(user_A);
        stakeManager.requestWithdraw(1 ether);
        vm.stopPrank();

        assertEq(slisBnb.balanceOf(user_A), 4 ether);
        assertEq(stakeManager.getTotalPooledBnb(), 5 ether);
    }

    function test_undelegateFrom_validator_A() public {
        deal(user_A, 100 ether);
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("minDelegationBNBChange()"), abi.encode(0));
        vm.mockCall(
            credit_A, abi.encodeWithSignature("getSharesByPooledBNB(uint256)", 1e18), abi.encode(1000000000000000000)
        );
        vm.mockCall(
            credit_A, abi.encodeWithSignature("getPooledBNBByShares(uint256)", 1e18), abi.encode(1000000000000000000)
        );

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);
        vm.stopPrank();

        vm.prank(user_A);
        stakeManager.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 10 ether);
        vm.stopPrank();

        assertEq(stakeManager.getTotalPooledBnb(), 10 ether);
        assertEq(slisBnb.balanceOf(user_A), 10 ether);

        vm.prank(user_A);
        slisBnb.approve(address(stakeManager), 5 ether);
        vm.stopPrank();

        vm.prank(user_A);
        stakeManager.requestWithdraw(2 ether);
        vm.stopPrank();

        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("undelegate(address,uint256)", validator_A, 1 ether), abi.encode(0)
        );
        vm.prank(bot);
        stakeManager.undelegateFrom(validator_A, 1 ether);
        vm.stopPrank();

        assertEq(stakeManager.getTotalPooledBnb(), 10 ether);
        assertEq(stakeManager.getAmountToUndelegate(), 1 ether); // 2 ether - 1 ether
    }

    function test_claimWithdraw() public {
        deal(user_A, 100 ether);
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("minDelegationBNBChange()"), abi.encode(0));
        vm.mockCall(
            credit_A, abi.encodeWithSignature("getSharesByPooledBNB(uint256)", 3e18), abi.encode(3000000000000000000)
        );
        vm.mockCall(
            credit_A, abi.encodeWithSignature("getPooledBNBByShares(uint256)", 3e18), abi.encode(3000000000000000000)
        );

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);

        vm.prank(user_A);
        stakeManager.deposit{value: 10 ether}();

        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 10 ether);

        assertEq(stakeManager.getTotalPooledBnb(), 10 ether);
        assertEq(slisBnb.balanceOf(user_A), 10 ether);

        vm.prank(user_A);
        slisBnb.approve(address(stakeManager), 5 ether);

        vm.prank(user_A);
        stakeManager.requestWithdraw(2 ether);

        vm.prank(user_A);
        stakeManager.requestWithdraw(1 ether);

        vm.mockCall(
            STAKE_HUB,
            abi.encodeWithSignature("undelegate(address,uint256)", validator_A, 3 ether), // undelegate 3 ether
            abi.encode(0)
        );
        vm.prank(bot);
        stakeManager.undelegateFrom(validator_A, 3 ether);

        assertEq(stakeManager.getTotalPooledBnb(), 10 ether);
        assertEq(stakeManager.getAmountToUndelegate(), 0); // undelegate all requested amount

        skip(7 days);

        // Injecting mocks of precompiles
        deal(credit_A, 1000 ether);
        vm.etch(STAKE_HUB, address(claimMock).code);
        vm.etch(credit_A, address(creditMock).code);

        credit_A.call(abi.encodeWithSignature("setStakeManager(address)", address(stakeManager)));
        credit_A.call(abi.encodeWithSignature("setAmount(uint256)", 3000000000000000000)); // make the mock credit contract send 3 BNB to stakeManager

        STAKE_HUB.call(abi.encodeWithSignature("setCreditMock(address)", credit_A));

        vm.prank(bot);
        stakeManager.claimUndelegated(validator_A);

        uint256 balanceBefore = address(user_A).balance;
        vm.prank(user_A);
        stakeManager.claimWithdraw(0);
        uint256 balanceAfter = address(user_A).balance;

        assertEq(balanceAfter - balanceBefore, 2 ether);

        // Bot claims the rest 1 BNB for user_A
        balanceBefore = address(user_A).balance;
        vm.prank(user_A);
        vm.expectRevert(
            "AccessControl: account 0x000000000000000000000000000000000000002a is missing role 0x902cbe3a02736af9827fb6a90bada39e955c0941e08f0c63b3a662a7b17a4e2b"
        );
        stakeManager.claimWithdrawFor(user_A, 0);
        vm.prank(bot);
        stakeManager.claimWithdrawFor(user_A, 0);
        balanceAfter = address(user_A).balance;
        assertEq(balanceAfter - balanceBefore, 1 ether);
    }

    function test_setAnnualRate() public {
        vm.recordLogs();
        vm.prank(admin);
        stakeManager.setAnnualRate(10000000); // 0.1%
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(abi.decode(entries[0].data, (uint256)), 10000000);
    }
}
