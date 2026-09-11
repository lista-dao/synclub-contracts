// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../../contracts/ListaStakeManager.sol";
import {ErrorsLib} from "../../contracts/libraries/ErrorsLib.sol";
import "../../contracts/SLisBNB.sol";
import "../../contracts/mock/MockClaim.sol";
import "../../contracts/SubStaker.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IStakeManager} from "../../contracts/interfaces/IStakeManager.sol";

interface IStakeManagerExtended is IStakeManager {
    function grantRole(bytes32 role, address account) external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

contract ListaStakeManagerTest is Test {
    address private constant STAKE_HUB = 0x0000000000000000000000000000000000002002;

    ListaStakeManager public stakeManager;
    SLisBNB public slisBnb;

    address public proxyAdminOwner = address(0x2A11AA);

    address public admin = address(0x5A11AA1);
    address public manager = address(0x5A11AA2);
    address public bot = address(0x5A11AA3);
    address public revenuePool = address(0x5A11AA4);
    address public validator = address(0x5A11AA6);
    address public guardian = makeAddr("guardian");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 public synFee = 500000000;

    address public user_A = address(0x2A);
    address public user_B = address(0x2B);
    address public validator_A = address(0x5A);
    address public validator_B = address(0x6A);
    address public credit_A = address(0x55A);
    address public credit_B = address(0x56A);

    ClaimMock public claimMock;
    CreditMock public creditMock;

    function setUp() public {
        // BSC holds burned BNB at the zero address; mirror that so guards cannot assume it is empty
        vm.deal(address(0), 99_245 ether);

        uint256 bufferSizePct = 0;
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
                "initialize(address,address,address,address,uint256,address,address,uint256)",
                address(slisBnb),
                admin,
                manager,
                bot,
                synFee,
                revenuePool,
                validator,
                bufferSizePct
            )
        );
        stakeManager = ListaStakeManager(payable(address(stakeManagerProxy)));

        assertTrue(stakeManager.hasRole(stakeManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(stakeManager.hasRole(stakeManager.MANAGER(), manager));
        assertTrue(stakeManager.hasRole(stakeManager.BOT(), bot));

        vm.prank(admin);
        slisBnb.setStakeManager(address(stakeManager));

        creditMock = new CreditMock();
        creditMock.setStakeManager(address(stakeManager));

        claimMock = new ClaimMock();

        vm.prank(admin);
        IStakeManagerExtended(address(stakeManager)).grantRole(GUARDIAN, guardian);

        // Modify `nextConfirmedRequestUUID` to have it start from 1
        vm.store(address(stakeManager), bytes32(uint256(205)), bytes32(uint256(1)));

        assertEq(stakeManager.bufferSizePct(), 0);
    }

    function test_pause_and_unpause() public {
        IStakeManagerExtended _stakeManager = IStakeManagerExtended(address(stakeManager));

        vm.prank(guardian);
        _stakeManager.pause();
        vm.stopPrank();

        assertTrue(_stakeManager.paused());

        vm.prank(manager);
        _stakeManager.unpause();
        vm.stopPrank();

        assertFalse(_stakeManager.paused());
    }

    function test_deposit() public {
        deal(user_A, 1 ether);

        vm.prank(user_A);
        stakeManager.deposit{value: 0.5 ether}();
        vm.stopPrank();

        assertEq(stakeManager.getTotalPooledBnb(), 0.5 ether);
        assertEq(slisBnb.balanceOf(user_A), 0.5 ether);
        assertEq(stakeManager.getAmountToUndelegate(), 0);
        assertEq(stakeManager.getSlisBnbWithdrawLimit(), 0);
    }

    function test_whitelistValidator() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(
            STAKE_HUB,
            abi.encodeWithSignature("getValidatorCreditContract(address)", validator_B),
            abi.encode(address(0))
        );

        vm.startPrank(admin);
        stakeManager.whitelistValidator(validator_A);

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        stakeManager.whitelistValidator(validator_B);
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

    function test_removeValidator() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_B), abi.encode(credit_B)
        );
        vm.mockCall(credit_A, abi.encodeWithSignature("getPooledBNB(address)"), abi.encode(0x00));
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(0x00));

        vm.startPrank(admin);
        stakeManager.whitelistValidator(validator_A);
        stakeManager.whitelistValidator(validator_B);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert("Validator should be inactive");
        stakeManager.removeValidator(validator_A);

        stakeManager.disableValidator(validator_A);
        stakeManager.removeValidator(validator_A);

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        stakeManager.removeValidator(address(0));
        vm.stopPrank();
    }

    function test_redelegate() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(
            credit_A,
            abi.encodeWithSignature("getSharesByPooledBNB(uint256)", uint256(0.5 ether)),
            abi.encode(uint256(0.5 ether))
        );

        test_delegateTo_validator_A();
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("redelegate(address,address,uint256,bool)"), abi.encode(0x00));

        vm.startPrank(bot);
        vm.expectRevert(ErrorsLib.InactiveValidator.selector);
        stakeManager.redelegate(validator_A, validator_B, 0.5 ether);
        vm.stopPrank();

        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_B), abi.encode(credit_B)
        );

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_B);
        vm.stopPrank();

        vm.startPrank(bot);
        stakeManager.redelegate(validator_A, validator_B, 0.5 ether);
        vm.stopPrank();
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
        // the manager holds every share on this credit; SubStaker is unbound in these tests
        vm.mockCall(
            credit_A,
            abi.encodeWithSignature("balanceOf(address)", address(stakeManager)),
            abi.encode(type(uint256).max)
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

        assertEq(stakeManager.totalDelegated(), 10 ether);
        assertEq(stakeManager.amountToDelegate(), 0);
        assertEq(stakeManager.unbondingBnb(), 1 ether);
        assertEq(stakeManager.getTotalPooledBnb(), 10 ether);
        assertEq(stakeManager.getAmountToUndelegate(), 1 ether); // 2 ether - 1 ether
        assertEq(stakeManager.getSlisBnbWithdrawLimit(), 8 ether); // 10 - 1 - 1 - 0
        assertEq(stakeManager.undelegatedQuota(), 0);
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
        // the manager holds every share on this credit; SubStaker is unbound in these tests
        vm.mockCall(
            credit_A,
            abi.encodeWithSignature("balanceOf(address)", address(stakeManager)),
            abi.encode(type(uint256).max)
        );
        vm.mockCall(
            credit_A, abi.encodeWithSignature("claimableUnbondRequest(address)", address(stakeManager)), abi.encode(1)
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
        credit_A.call(abi.encodeWithSignature("setAmount(uint256)", 1000000000000000000)); // make the mock credit contract send 3 BNB to stakeManager
        STAKE_HUB.call(abi.encodeWithSignature("setCreditMock(address)", credit_A));

        // 1st undelegation 1 bnb
        vm.prank(bot);
        stakeManager.claimUndelegated(validator_A);

        assertEq(stakeManager.unbondingBnb(), 2 ether);
        assertEq(stakeManager.undelegatedQuota(), 1 ether); // cannot fullfill the 2 bnb request
        assertEq(stakeManager.totalDelegated(), 10 ether);
        assertEq(stakeManager.getSlisBnbWithdrawLimit(), 7 ether); // 10 - 0 - 2 - 1

        skip(7 days);

        // 2nd undelegation 2 bnb
        credit_A.call(abi.encodeWithSignature("setAmount(uint256)", 2000000000000000000)); // make the mock credit contract send 3 BNB to stakeManager
        vm.prank(bot);
        stakeManager.claimUndelegated(validator_A);
        assertEq(stakeManager.unbondingBnb(), 0);
        assertEq(stakeManager.undelegatedQuota(), 0); // can fullfill all requests
        assertEq(stakeManager.totalDelegated(), 7 ether);
        assertEq(stakeManager.getSlisBnbWithdrawLimit(), 7 ether); // 7 - 0 - 0 - 0

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

    function test_setMinBnb() public {
        vm.recordLogs();
        vm.startPrank(admin);
        stakeManager.setMinBnb(0.1 ether);
        assertEq(stakeManager.minBnb(), 0.1 ether);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(abi.decode(entries[0].data, (uint256)), 0.1 ether);

        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        stakeManager.setMinBnb(0);

        vm.stopPrank();
    }

    function test_setBufferSizePct() public {
        vm.recordLogs();
        vm.startPrank(admin);
        stakeManager.setBufferSizePct(10 ** 9); // 10%
        vm.stopPrank();
        assertEq(stakeManager.bufferSizePct(), 10 ** 9);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(abi.decode(entries[0].data, (uint256)), 10 ** 9);
    }

    function test_setInstantWithdrawFeeRate() public {
        vm.recordLogs();
        vm.startPrank(admin);
        stakeManager.setInstantWithdrawFeeRate(10000000); // 0.1%
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(abi.decode(entries[0].data, (uint256)), 10000000);
    }

    function test_setInstantWhitelist() public {
        assertFalse(stakeManager.instantWhitelist(user_A));

        // only DEFAULT_ADMIN_ROLE can manage the whitelist
        vm.prank(user_A);
        vm.expectRevert();
        stakeManager.setInstantWhitelist(user_A, true);

        // zero address is rejected
        vm.prank(admin);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        stakeManager.setInstantWhitelist(address(0), true);

        // admin whitelists user_A
        vm.prank(admin);
        stakeManager.setInstantWhitelist(user_A, true);
        assertTrue(stakeManager.instantWhitelist(user_A));

        // no-op guard: setting the same status reverts
        vm.prank(admin);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        stakeManager.setInstantWhitelist(user_A, true);

        // admin removes user_A
        vm.prank(admin);
        stakeManager.setInstantWhitelist(user_A, false);
        assertFalse(stakeManager.instantWhitelist(user_A));
    }

    function test_setInstantWhitelistOff() public {
        // whitelist is enforced by default
        assertFalse(stakeManager.instantWhitelistOff());

        // only DEFAULT_ADMIN_ROLE can flip the global switch
        vm.prank(user_A);
        vm.expectRevert();
        stakeManager.setInstantWhitelistOff(true);

        // no-op guard: setting the already-stored status reverts
        vm.prank(admin);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        stakeManager.setInstantWhitelistOff(false);

        // admin disables the whitelist globally
        vm.prank(admin);
        stakeManager.setInstantWhitelistOff(true);
        assertTrue(stakeManager.instantWhitelistOff());

        // admin re-enables enforcement
        vm.prank(admin);
        stakeManager.setInstantWhitelistOff(false);
        assertFalse(stakeManager.instantWhitelistOff());
    }

    function test_instantWithrdraw() public {
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
        // the manager holds every share on this credit; SubStaker is unbound in these tests
        vm.mockCall(
            credit_A,
            abi.encodeWithSignature("balanceOf(address)", address(stakeManager)),
            abi.encode(type(uint256).max)
        );

        // initialize the stakeManager with total pooled BNB of 1000 Bnb
        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);
        vm.prank(admin);
        stakeManager.setMinBnb(0.0001 ether);
        deal(user_B, 1000 ether);
        stakeManager.deposit{value: 1000 ether}();
        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 1000 ether);
        assertEq(stakeManager.getTotalPooledBnb(), 1000 ether);
        assertEq(stakeManager.amountToDelegate(), 0, "buffer size should be 0");

        // config max buffer size to 10%
        test_setBufferSizePct();
        // config instant withdraw fee rate to 0.1%
        test_setInstantWithdrawFeeRate();

        deal(user_A, 200 ether);

        vm.prank(user_A);
        stakeManager.deposit{value: 10 ether}();

        assertEq(stakeManager.amountToDelegate(), 10 ether, "buffer size should be 10 Bnb");
        (bool _skipDelegate, uint256 _maxBufferSize, uint256 _currentBufferSize) =
            stakeManager.skipDelegateOrNot(10 ether);
        assertTrue(_skipDelegate, "Should skip delegation since buffer size <= 10%");
        assertEq(_maxBufferSize, 100 ether + 1 ether); // 10% of (1000 Bnb + 10 Bnb)
        assertEq(_currentBufferSize, 10 ether);

        vm.expectRevert();
        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 10 ether);

        assertEq(stakeManager.getTotalPooledBnb(), 1000 ether + 10 ether);
        assertEq(slisBnb.balanceOf(user_A), 10 ether);

        // user deposit more Bnb
        vm.prank(user_A);
        stakeManager.deposit{value: 150 ether}();
        (bool skipDelegate, uint256 maxBufferSize, uint256 currentBufferSize) = stakeManager.skipDelegateOrNot(1 ether);
        assertFalse(skipDelegate, "Should not skip delegation since buffer size > 10%");
        assertEq(maxBufferSize, 116 ether);
        assertEq(currentBufferSize, 10 ether + 150 ether); // 10% of (1000 Bnb + 160 Bnb)

        // delegate the 160 - 116 + 1 = 43 Bnb to validator_A; 1 Bnb is for the edge case
        vm.prank(bot);
        stakeManager.delegateTo(validator_A, 43 ether);

        assertEq(stakeManager.amountToDelegate(), 117 ether, "buffer size should be 116 Bnb");
        assertEq(stakeManager.getTotalPooledBnb(), 1160 ether);
        assertEq(slisBnb.balanceOf(user_A), 160 ether);

        // by default the whitelist is enforced: a non-whitelisted user is rejected
        assertFalse(stakeManager.instantWhitelistOff());
        vm.prank(user_A);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        stakeManager.instantWithdraw(6 ether);

        // global switch off: the whitelist is bypassed, so a non-whitelisted user
        // passes the gate and only fails later on the min-amount check
        vm.prank(admin);
        stakeManager.setInstantWhitelistOff(true);
        vm.prank(user_A);
        vm.expectRevert(ErrorsLib.AmountTooSmall.selector);
        stakeManager.instantWithdraw(0);

        // re-enable enforcement
        vm.prank(admin);
        stakeManager.setInstantWhitelistOff(false);

        // whitelist user_A for instant withdrawal
        vm.prank(admin);
        stakeManager.setInstantWhitelist(user_A, true);
        assertTrue(stakeManager.instantWhitelist(user_A));

        vm.startPrank(user_A);
        slisBnb.approve(address(stakeManager), 6 ether);
        uint256 _min = stakeManager.minBnb() - 1;
        vm.expectRevert(ErrorsLib.AmountTooSmall.selector);
        stakeManager.instantWithdraw(_min);

        stakeManager.instantWithdraw(6 ether);
        vm.stopPrank();

        uint256 fee = (6 ether * 0.1) / 100; // 0.1% fee
        assertEq(stakeManager.amountToDelegate(), 111 ether + fee);
        assertEq(stakeManager.getTotalPooledBnb(), 1154 ether + fee);
        assertEq(slisBnb.balanceOf(address(stakeManager)), fee);
        assertEq(slisBnb.balanceOf(user_A), 154 ether);
        assertEq(stakeManager.instantWithdrawFee(), fee);

        vm.prank(bot);
        stakeManager.claimWithdrawFee(fee);
        assertEq(slisBnb.balanceOf(revenuePool), fee, "revenuePool should receive the withdraw fee");
        assertEq(stakeManager.instantWithdrawFee(), 0, "Instant withdraw fee should be reset to 0");
    }

    function test_receive() public {
        vm.deal(user_A, 10 ether);
        vm.deal(admin, 10 ether);

        // setting admin as the credit contract for simplicity
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(admin)
        );
        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);
        vm.prank(admin);
        (bool success,) = address(stakeManager).call{value: 10 ether, gas: 2300}("");
        vm.prank(user_A);
        (success,) = address(stakeManager).call{value: 10 ether, gas: 2300}("");
        assertTrue(success);
    }

    address private constant GOV_BNB = 0x0000000000000000000000000000000000002005;
    /// Owner of this proxy's ProxyAdmin on mainnet, hardcoded in ListaStakeManager
    address private constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

    event SetSubStaker(address indexed _subStaker);
    event SetSubValidator(address indexed _validator, bool _toSub);

    /// Deploys a SubStaker behind a proxy and binds it
    function _bindSubStaker() private returns (SubStaker sub) {
        SubStaker impl = new SubStaker();
        sub = SubStaker(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeWithSelector(SubStaker.initialize.selector, address(stakeManager))
                ))
        );

        vm.prank(TIMELOCK);
        stakeManager.setSubStaker(address(sub));
    }

    /// Both govBNB buckets must be steerable: the manager's own, and the SubStaker's
    function test_bothVoteDelegateesCanBeChanged() public {
        address listaVoter = makeAddr("listaVoter");
        address club48 = makeAddr("club48");

        SubStaker sub = _bindSubStaker();

        vm.mockCall(GOV_BNB, abi.encodeWithSignature("delegates(address)"), abi.encode(address(0)));
        vm.mockCall(GOV_BNB, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        vm.mockCall(GOV_BNB, abi.encodeWithSignature("getVotes(address)"), abi.encode(uint256(0)));
        vm.mockCall(GOV_BNB, abi.encodeWithSignature("delegate(address)"), abi.encode());

        // the manager's own tranche
        vm.expectCall(GOV_BNB, abi.encodeWithSignature("delegate(address)", listaVoter));
        vm.prank(admin);
        stakeManager.delegateVoteTo(listaVoter);

        // the SubStaker's tranche, set by the same admin role, straight on the SubStaker
        vm.expectCall(GOV_BNB, abi.encodeWithSignature("delegate(address)", club48));
        vm.prank(admin);
        sub.setVoteDelegatee(club48);

        // and neither is reachable without that role
        vm.prank(bot);
        vm.expectRevert();
        stakeManager.delegateVoteTo(listaVoter);

        vm.prank(bot);
        vm.expectRevert(SubStaker.NotAdmin.selector);
        sub.setVoteDelegatee(club48);
    }

    /// Binding routes every future deposit to the bound address, so DEFAULT_ADMIN must not reach it
    function test_setSubStaker_onlyTimelock() public {
        SubStaker impl = new SubStaker();
        address sub = address(
            new ERC1967Proxy(
                address(impl), abi.encodeWithSelector(SubStaker.initialize.selector, address(stakeManager))
            )
        );

        vm.prank(admin);
        vm.expectRevert(ErrorsLib.NotTimelock.selector);
        stakeManager.setSubStaker(sub);

        vm.prank(bot);
        vm.expectRevert(ErrorsLib.NotTimelock.selector);
        stakeManager.setSubStaker(sub);

        vm.expectEmit(true, false, false, true);
        emit SetSubStaker(sub);
        vm.prank(TIMELOCK);
        stakeManager.setSubStaker(sub);
        assertEq(stakeManager.subStaker(), sub);
    }

    /// Dust shares are the reason this exists: repeated partial exits floor BNB->shares, and the
    /// residue is a share count no BNB amount converts to exactly. Naming the shares clears it.
    function test_undelegateSharesFrom_clearsDustAndRoutesToHolder() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        // rate is just above 1:1, so 1 wei of BNB floors to 0 shares - the dust is unnameable
        vm.mockCall(
            credit_A, abi.encodeWithSignature("getSharesByPooledBNB(uint256)", uint256(1)), abi.encode(uint256(0))
        );
        vm.mockCall(
            credit_A, abi.encodeWithSignature("getPooledBNBByShares(uint256)", uint256(1)), abi.encode(uint256(1))
        );
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));
        vm.mockCall(credit_A, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));

        vm.prank(admin);
        stakeManager.setReserveAmount(1 ether);

        // the BNB-denominated call cannot reach a single share
        vm.prank(bot);
        vm.expectRevert();
        stakeManager.undelegateFrom(validator_A, 1);

        // naming the share works, and goes out under the manager's own identity
        vm.expectCall(STAKE_HUB, abi.encodeWithSignature("undelegate(address,uint256)", validator_A, uint256(1)));
        vm.prank(bot);
        assertEq(stakeManager.undelegateSharesFrom(validator_A, 1), 1);
        assertEq(stakeManager.unbondingBnb(), 1);

        // for a sub validator the same call has to leave through the SubStaker instead
        SubStaker sub = _bindSubStaker();
        vm.prank(admin);
        stakeManager.setSubValidator(validator_A, true);

        vm.mockCall(address(sub), abi.encodeWithSignature("undelegate(address,uint256)"), abi.encode());
        vm.expectCall(address(sub), abi.encodeWithSignature("undelegate(address,uint256)", validator_A, uint256(1)));
        vm.prank(bot);
        stakeManager.undelegateSharesFrom(validator_A, 1);
    }

    /// The share-denominated entry point must honour the same quota ceiling and the same role
    function test_undelegateSharesFrom_keepsQuotaAndRole() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(credit_A, abi.encodeWithSignature("getPooledBNBByShares(uint256)"), abi.encode(uint256(100 ether)));

        // nothing queued and no reserve, so 100 BNB of shares is over the ceiling
        vm.prank(bot);
        vm.expectRevert(ErrorsLib.AmountTooLarge.selector);
        stakeManager.undelegateSharesFrom(validator_A, 1);

        vm.prank(admin);
        stakeManager.setReserveAmount(100 ether);

        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("undelegate(address,uint256)"), abi.encode());
        vm.prank(bot);
        stakeManager.undelegateSharesFrom(validator_A, 1);

        // and it is bot-only, like its BNB-denominated twin
        vm.prank(user_A);
        vm.expectRevert();
        stakeManager.undelegateSharesFrom(validator_A, 1);
    }

    /// An unbond request that has matured but not been claimed still blocks a route change.
    /// StakeCredit only drops a request from `_unbondRequestsQueue` inside `claim`, and
    /// `lockedBNBs(account, 0)` sums the whole queue with no maturity filter, so the drained
    /// checks already see it - there is no window where shares are zero but BNB is stranded.
    function test_maturedUnbondRequestBlocksRouteChange() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        SubStaker first = _bindSubStaker();

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);

        // no shares left, but a matured request still sits in the credit's unbond queue
        vm.mockCall(credit_A, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(1 ether)));

        SubStaker impl = new SubStaker();
        address second = address(
            new ERC1967Proxy(
                address(impl), abi.encodeWithSelector(SubStaker.initialize.selector, address(stakeManager))
            )
        );

        vm.prank(TIMELOCK);
        vm.expectRevert(ErrorsLib.SubStakerNotDrained.selector);
        stakeManager.setSubStaker(second);

        vm.prank(admin);
        vm.expectRevert(ErrorsLib.AmountTooLarge.selector);
        stakeManager.setSubValidator(validator_A, true);

        // once the claim is taken the queue empties and both route changes open up
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));
        vm.prank(admin);
        stakeManager.setSubValidator(validator_A, true);
        assertTrue(stakeManager.subValidators(validator_A));

        vm.prank(TIMELOCK);
        stakeManager.setSubStaker(second);
        assertEq(stakeManager.subStaker(), second);
        assertTrue(address(first) != second);
    }

    /// Rebinding away from a SubStaker that still holds something would strand it for good
    function test_setSubStaker_requiresOldAccountDrained() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        // bind before whitelisting so the first bind walks an empty credit list
        SubStaker first = _bindSubStaker();

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_A);

        SubStaker impl = new SubStaker();
        SubStaker second = SubStaker(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeWithSelector(SubStaker.initialize.selector, address(stakeManager))
                ))
        );

        // still holding shares on a whitelisted validator
        vm.mockCall(credit_A, abi.encodeWithSignature("balanceOf(address)", address(first)), abi.encode(uint256(1)));
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));

        vm.prank(TIMELOCK);
        vm.expectRevert(ErrorsLib.SubStakerNotDrained.selector);
        stakeManager.setSubStaker(address(second));

        // rebinding the same address is a no-op and stays allowed
        vm.prank(TIMELOCK);
        stakeManager.setSubStaker(address(first));

        // shares gone but BNB stranded on the account still blocks the swap
        vm.mockCall(credit_A, abi.encodeWithSignature("balanceOf(address)", address(first)), abi.encode(uint256(0)));
        vm.deal(address(first), 1 wei);
        vm.prank(TIMELOCK);
        vm.expectRevert(ErrorsLib.SubStakerNotDrained.selector);
        stakeManager.setSubStaker(address(second));

        // fully empty, so the swap goes through
        vm.deal(address(first), 0);
        vm.prank(TIMELOCK);
        stakeManager.setSubStaker(address(second));
        assertEq(stakeManager.subStaker(), address(second));
    }

    /// Each leg must be priced separately: StakeCredit floors every burn, so converting the total

    /// The launch shape: a fresh validator is whitelisted, handed to the SubStaker, and every
    /// flow on it routes there without the manager holding anything
    function test_subValidator_routesEveryFlowToSubStaker() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_B), abi.encode(credit_B)
        );
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("minDelegationBNBChange()"), abi.encode(uint256(1 ether)));
        vm.mockCall(credit_B, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        vm.mockCall(credit_B, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));

        SubStaker sub = _bindSubStaker();

        vm.prank(admin);
        stakeManager.whitelistValidator(validator_B);

        // a brand new validator is empty on both sides, so no migration is involved
        vm.prank(admin);
        stakeManager.setSubValidator(validator_B, true);
        assertTrue(stakeManager.subValidators(validator_B));

        vm.deal(user_A, 100 ether);
        vm.prank(user_A);
        stakeManager.deposit{value: 10 ether}();

        vm.mockCall(address(sub), abi.encodeWithSignature("delegate(address,bool)"), abi.encode());
        vm.expectCall(address(sub), abi.encodeWithSignature("delegate(address,bool)", validator_B, false));

        vm.prank(bot);
        stakeManager.delegateTo(validator_B, 10 ether);

        // and the position is read off the SubStaker, not this contract
        vm.mockCall(
            credit_B, abi.encodeWithSignature("getPooledBNB(address)", address(sub)), abi.encode(uint256(10 ether))
        );
        assertEq(stakeManager.getDelegated(validator_B), 10 ether);
    }

    /// Reassigning a validator that still holds something would orphan that position
    function test_setSubValidator_requiresValidatorEmpty() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));

        SubStaker sub = _bindSubStaker();
        assertTrue(address(sub) != address(0));

        // the manager still holds shares on it
        vm.mockCall(
            credit_A, abi.encodeWithSignature("balanceOf(address)", address(stakeManager)), abi.encode(uint256(1))
        );
        vm.prank(admin);
        vm.expectRevert(ErrorsLib.AmountTooLarge.selector);
        stakeManager.setSubValidator(validator_A, true);

        // drained, so the handover goes through
        vm.mockCall(
            credit_A, abi.encodeWithSignature("balanceOf(address)", address(stakeManager)), abi.encode(uint256(0))
        );
        vm.expectEmit(true, false, false, true);
        emit SetSubValidator(validator_A, true);
        vm.prank(admin);
        stakeManager.setSubValidator(validator_A, true);
        assertTrue(stakeManager.subValidators(validator_A));

        // and handing it back is announced too, so indexers see both edges
        vm.mockCall(credit_A, abi.encodeWithSignature("balanceOf(address)", address(sub)), abi.encode(uint256(0)));
        vm.expectEmit(true, false, false, true);
        emit SetSubValidator(validator_A, false);
        vm.prank(admin);
        stakeManager.setSubValidator(validator_A, false);
        assertFalse(stakeManager.subValidators(validator_A));
    }

    /// Redelegation follows whichever account owns the validator, and cannot cross between them
    /// The share-denominated move exists to empty a position exactly; it must keep every guard
    /// its BNB-denominated twin has, and must route through the owning account the same way.
    function test_redelegateShares_emptiesPositionAndKeepsGuards() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_B), abi.encode(credit_B)
        );
        // 1 wei of BNB floors to 0 shares, so the BNB-denominated call cannot name this residue
        vm.mockCall(credit_A, abi.encodeWithSignature("getSharesByPooledBNB(uint256)"), abi.encode(uint256(0)));
        vm.mockCall(credit_A, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));
        vm.mockCall(credit_B, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        vm.mockCall(credit_B, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("redelegate(address,address,uint256,bool)"), abi.encode());

        SubStaker sub = _bindSubStaker();

        vm.startPrank(admin);
        stakeManager.whitelistValidator(validator_A);
        stakeManager.whitelistValidator(validator_B);
        vm.stopPrank();

        // the exact share count goes through untouched
        vm.expectCall(
            STAKE_HUB,
            abi.encodeWithSignature("redelegate(address,address,uint256,bool)", validator_A, validator_B, 1, false)
        );
        vm.prank(bot);
        stakeManager.redelegateShares(validator_A, validator_B, 1);

        // same validator on both ends
        vm.prank(bot);
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        stakeManager.redelegateShares(validator_A, validator_A, 1);

        // destination not whitelisted
        vm.prank(bot);
        vm.expectRevert(ErrorsLib.InactiveValidator.selector);
        stakeManager.redelegateShares(validator_A, makeAddr("stranger"), 1);

        // bot-only
        vm.prank(user_A);
        vm.expectRevert();
        stakeManager.redelegateShares(validator_A, validator_B, 1);

        // crossing accounts is refused, exactly as for redelegate
        vm.prank(admin);
        stakeManager.setSubValidator(validator_A, true);

        vm.prank(bot);
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        stakeManager.redelegateShares(validator_A, validator_B, 1);

        // both on the SubStaker's side: it moves its own position
        vm.prank(admin);
        stakeManager.setSubValidator(validator_B, true);

        vm.mockCall(address(sub), abi.encodeWithSignature("redelegate(address,address,uint256,bool)"), abi.encode());
        vm.expectCall(
            address(sub),
            abi.encodeWithSignature("redelegate(address,address,uint256,bool)", validator_A, validator_B, 1, false)
        );
        vm.prank(bot);
        stakeManager.redelegateShares(validator_A, validator_B, 1);
    }

    function test_redelegate_followsValidatorOwnership() public {
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_A), abi.encode(credit_A)
        );
        vm.mockCall(
            STAKE_HUB, abi.encodeWithSignature("getValidatorCreditContract(address)", validator_B), abi.encode(credit_B)
        );
        vm.mockCall(credit_A, abi.encodeWithSignature("getSharesByPooledBNB(uint256)"), abi.encode(uint256(1e18)));
        vm.mockCall(credit_A, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        vm.mockCall(credit_A, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));
        vm.mockCall(credit_B, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        vm.mockCall(credit_B, abi.encodeWithSignature("lockedBNBs(address,uint256)"), abi.encode(uint256(0)));
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("redelegate(address,address,uint256,bool)"), abi.encode());

        SubStaker sub = _bindSubStaker();

        vm.startPrank(admin);
        stakeManager.whitelistValidator(validator_A);
        stakeManager.whitelistValidator(validator_B);
        vm.stopPrank();

        // both on the manager's side: it redelegates for itself
        vm.expectCall(
            STAKE_HUB,
            abi.encodeWithSignature("redelegate(address,address,uint256,bool)", validator_A, validator_B, 1e18, false)
        );
        vm.prank(bot);
        stakeManager.redelegate(validator_A, validator_B, 1 ether);

        // hand validator_A over; now the sides differ and the move is refused
        vm.prank(admin);
        stakeManager.setSubValidator(validator_A, true);

        vm.prank(bot);
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        stakeManager.redelegate(validator_A, validator_B, 1 ether);

        // hand validator_B over too, and the SubStaker moves its own position
        vm.prank(admin);
        stakeManager.setSubValidator(validator_B, true);

        vm.mockCall(address(sub), abi.encodeWithSignature("redelegate(address,address,uint256,bool)"), abi.encode());
        vm.expectCall(
            address(sub),
            abi.encodeWithSignature("redelegate(address,address,uint256,bool)", validator_A, validator_B, 1e18, false)
        );
        vm.prank(bot);
        stakeManager.redelegate(validator_A, validator_B, 1 ether);
    }
}
