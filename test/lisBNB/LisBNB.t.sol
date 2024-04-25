// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console, StdStorage, stdStorage} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ListaStakeManager} from "../../contracts/ListaStakeManager.sol";
import {SLisBNB} from "../../contracts/SLisBNB.sol";
import {LisBNB} from "../../contracts/LisBNB.sol";
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

    function test_compoundRewards() public {
        uint256 totalBnbInValidator = 101 ether;
        uint256 totalDelegated = 100 ether;
        uint256 totalFee = 0.1 ether;

        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.getTotalBnbInValidators.selector),
            abi.encode(totalBnbInValidator)
        );
        vm.deal(bot, 100 ether);

        assertEq(manager.getTotalBnbInValidators(), totalBnbInValidator);

        stdstore.target(address(manager)).sig("totalDelegated()").checked_write(totalDelegated);
        assertEq(manager.totalDelegated(), totalDelegated);
        stdstore.target(address(manager)).sig("totalFee()").checked_write(totalFee);

        assertEq(manager.totalFee(), totalFee);
        vm.prank(bot);
        manager.compoundRewards();

        console.log("totalDelegated: %d", manager.totalDelegated());
        console.log("totalFee: %d", manager.totalFee());
        console.log("totalBnbInValidator: %d", manager.getTotalBnbInValidators());
        // totalProfit = 101 - 100 - 0.1 = 0.9
        // fee = 0.9 * 5 / 100 = 0.045
        // totalFee = 0.1 + 0.045 = 0.145
        // totalDelegated = 100 + 0.9 - 0.045 = 100.855
        vm.assertEq(manager.totalFee(), 0.145 ether);
        vm.assertEq(manager.totalDelegated(), 100.855 ether);
    }


    function test_compoundRewardsRevert() public {
        uint256 totalBnbInValidator = 99 ether;
        uint256 totalDelegated = 100 ether;
        uint256 totalFee = 0.1 ether;

        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.getTotalBnbInValidators.selector),
            abi.encode(totalBnbInValidator)
        );
        vm.deal(bot, 100 ether);

        assertEq(manager.getTotalBnbInValidators(), totalBnbInValidator);

        stdstore.target(address(manager)).sig("totalDelegated()").checked_write(totalDelegated);
        assertEq(manager.totalDelegated(), totalDelegated);
        stdstore.target(address(manager)).sig("totalFee()").checked_write(totalFee);

        assertEq(manager.totalFee(), totalFee);
        vm.prank(bot);

        vm.expectRevert("No new fee to compound");
        manager.compoundRewards();
    }

    function test_claimFee() public {
        uint256 totalFee = 1 ether;

        vm.deal(bot, 100 ether);
        vm.prank(bot);
        vm.expectRevert("No fee to claim");
        manager.claimFee();

        stdstore.target(address(manager)).sig("totalFee()").checked_write(totalFee);
        assertEq(manager.totalFee(), totalFee);
        uint256 amountSlisBNB = manager.convertBnbToSnBnb(totalFee);
        console.log("aaa");

        vm.prank(bot);
        manager.claimFee();

        console.log("totalDelegated: %d", manager.totalDelegated());
        console.log("totalFee: %d", manager.totalFee());
        console.log("amountSlisBNB: %d", snBNB.balanceOf(bot));

        assertEq(manager.totalFee(), 0);
        assertEq(manager.totalDelegated(), totalFee);
        assertEq(snBNB.balanceOf(bot), amountSlisBNB);
    }
}
