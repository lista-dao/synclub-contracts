// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console, StdStorage, stdStorage} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ListaStakeManager} from "../../contracts/ListaStakeManager.sol";
import {SLisBNB} from "../../contracts/SLisBNB.sol";
import {LisBNB} from "../../contracts/LisBNB.sol";
import {IStakeCredit} from "../../contracts/interfaces/IStakeCredit.sol";
import {IStakeManager} from "../../contracts/interfaces/IStakeManager.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract LisBNBTest is Test {
    using stdStorage for StdStorage;

    TransparentUpgradeableProxy proxy;
    ListaStakeManager manager;
    TransparentUpgradeableProxy snBNBProxy;
    SLisBNB snBNB;

    TransparentUpgradeableProxy lisBNBProxy;
    LisBNB lisBNB;

    address admin = address(0x1);
    address bot = address(0x2);

    function setUp() public {
        SLisBNB slisBNB = new SLisBNB();
        snBNBProxy = new TransparentUpgradeableProxy(address(slisBNB), admin, "");
        SLisBNB(payable(address(snBNBProxy))).initialize(bot);
        vm.deal(bot, 100 ether);
        snBNB = SLisBNB(payable(address(snBNBProxy)));

        ListaStakeManager listaStakeManager = new ListaStakeManager();
        proxy = new TransparentUpgradeableProxy(address(listaStakeManager), admin, "");

        vm.prank(bot);
        snBNB.setStakeManager(address(proxy));

        ListaStakeManager(payable(address(proxy))).initialize(
            address(snBNB),
            bot,
            bot,
            bot,
            5e8,
            bot,
            bot
        );
        manager = ListaStakeManager(payable(address(proxy)));

        LisBNB listaBNB = new LisBNB();
        lisBNBProxy = new TransparentUpgradeableProxy(address(listaBNB), admin, "");
        LisBNB(payable(address(lisBNBProxy))).initialize(bot);
        vm.deal(bot, 100 ether);
        lisBNB = LisBNB(payable(address(lisBNBProxy)));

        vm.prank(bot);
        lisBNB.setStakeManager(address(proxy));
        vm.prank(bot);
        manager.setLisBNB(address(lisBNB));

    }

    function test_nameAndSymbol() public {
        assertEq(lisBNB.name(), "Lista BNB");
        assertEq(lisBNB.symbol(), "lisBNB");
    }

    function test_depositV2() public {
        uint256 balance = 1000 ether;
        uint256 amount = 100 ether;
        vm.deal(bot, balance);
        vm.prank(bot);

        uint256 beforeAmountToDelegate = manager.amountToDelegate();

        vm.prank(bot);
        manager.depositV2{value: amount}();

        uint256 afterAmountToDelegate = manager.amountToDelegate();
        console.log("lisBNB: %d", lisBNB.balanceOf(bot));
        console.log("amountToDelegate: %v", afterAmountToDelegate - beforeAmountToDelegate);

        assertEq(lisBNB.balanceOf(bot), amount);
        assertEq(afterAmountToDelegate - beforeAmountToDelegate, amount);
    }

    function test_stake() public {
        uint256 balance = 1000 ether;
        uint256 amount = 100 ether;
        uint256 stakeAmount = 50 ether;
        vm.deal(bot, balance);
        vm.prank(bot);
        manager.depositV2{value: amount}();

        uint slisBNBAmount = manager.convertBnbToSnBnb(stakeAmount);

        vm.prank(bot);
        manager.stake(stakeAmount);
        console.log("lisBNB: %d", lisBNB.balanceOf(bot));
        console.log("slisBNB: %d", snBNB.balanceOf(bot));

        assertEq(lisBNB.balanceOf(bot), amount - stakeAmount);
        assertEq(snBNB.balanceOf(bot), slisBNBAmount);

        slisBNBAmount += manager.convertBnbToSnBnb(stakeAmount);
        vm.prank(bot);
        manager.stake(stakeAmount);
        console.log("lisBNB: %d", lisBNB.balanceOf(bot));
        console.log("slisBNB: %d", snBNB.balanceOf(bot));

        assertEq(lisBNB.balanceOf(bot), amount - stakeAmount*2);
        assertEq(snBNB.balanceOf(bot), slisBNBAmount);
    }

    function test_unstake() public {
        uint256 balance = 1000 ether;
        uint256 amount = 100 ether;
        uint256 stakeAmount = 50 ether;
        uint256 unstakeAmount = 10 ether;
        vm.deal(bot, balance);
        vm.prank(bot);
        manager.depositV2{value: amount}();

        vm.prank(bot);
        manager.stake(stakeAmount);

        uint256 beforeLisBNB = lisBNB.balanceOf(bot);
        uint256 beforeSlisBNB = snBNB.balanceOf(bot);
        uint256 mintLisBNB = manager.convertSnBnbToBnb(unstakeAmount);
        vm.prank(bot);
        manager.unstake(unstakeAmount);
        uint256 afterLisBNB = lisBNB.balanceOf(bot);
        uint256 afterSlisBNB = snBNB.balanceOf(bot);

        assertEq(afterLisBNB - beforeLisBNB, mintLisBNB);
        assertEq(beforeSlisBNB - afterSlisBNB, unstakeAmount);
    }

    function test_requestWithdrawByLisBNB() public {
        uint256 balance = 1000 ether;
        uint256 amount = 100 ether;
        uint256 depositV1Amount = 1 ether;
        uint256 withdrawAmount = 10 ether;

        vm.deal(bot, balance);
        vm.prank(bot);
        manager.deposit{value: depositV1Amount}();

        vm.prank(bot);
        manager.depositV2{value: amount}();

        uint256 beforeLisBNB = lisBNB.balanceOf(bot);

        uint256 slisBNBAmount = manager.convertBnbToSnBnb(withdrawAmount);
        vm.prank(bot);
        manager.requestWithdrawByLisBnb(withdrawAmount);
        uint256 afterLisBNB = lisBNB.balanceOf(bot);

        console.log("lisBNB: %d", lisBNB.balanceOf(bot));

        assertEq(beforeLisBNB - afterLisBNB, withdrawAmount);

        IStakeManager.WithdrawalRequest[] memory requests = manager.getUserWithdrawalRequests(bot);
        console.log("amountInSnBNB: %d startTime: %d uuid: %d", requests[0].amountInSnBnb, requests[0].startTime, requests[0].uuid);
        assertEq(requests.length, 1);
        assertEq(requests[0].amountInSnBnb, slisBNBAmount);
    }
}
