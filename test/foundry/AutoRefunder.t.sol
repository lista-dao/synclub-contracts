// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../../contracts/ListaStakeManager.sol";
import "../../contracts/AutoRefunder.sol";
import "../../contracts/SLisBNB.sol";

contract AutoRefunderTest is Test {
    AutoRefunder autoRefunder;
    ListaStakeManager stakeManager;
    SLisBNB public slisBnb;

    address vault = makeAddr("vault");

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address bot = makeAddr("bot");
    address pauser = makeAddr("pauser");

    function setUp() public {
        setup_stakeManager();

        AutoRefunder autoRefunderImpl = new AutoRefunder();
        ERC1967Proxy proxy_ = new ERC1967Proxy(
            address(autoRefunderImpl),
            abi.encodeWithSelector(
                AutoRefunder.initialize.selector,
                admin,
                manager,
                bot,
                pauser,
                address(stakeManager),
                vault
            )
        );
        autoRefunder = AutoRefunder(payable(address(proxy_)));

        assertEq(autoRefunder.stakeManager(), address(stakeManager));
        assertEq(autoRefunder.vault(), vault);
        assertEq(autoRefunder.refundRatio(), 6000);
        assertEq(autoRefunder.refundDays(), 30);

        assertTrue(
            autoRefunder.hasRole(autoRefunder.DEFAULT_ADMIN_ROLE(), admin)
        );
        assertTrue(autoRefunder.hasRole(autoRefunder.MANAGER(), manager));
        assertTrue(autoRefunder.hasRole(autoRefunder.BOT(), bot));
        assertTrue(autoRefunder.hasRole(autoRefunder.PAUSER(), pauser));
    }

    function setup_stakeManager() public {
        address proxyAdminOwner = address(0x2A11AA);
        address revenuePool = address(0x5A11AA4);
        address validator = address(0x5A11AA6);

        uint256 synFee = 500000000;

        SLisBNB slisBnbImpl = new SLisBNB();
        TransparentUpgradeableProxy slisBnbProxy = new TransparentUpgradeableProxy(
                address(slisBnbImpl),
                proxyAdminOwner,
                abi.encodeWithSignature("initialize(address)", admin)
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
        stakeManager = ListaStakeManager(payable(address(stakeManagerProxy)));

        assertTrue(
            stakeManager.hasRole(stakeManager.DEFAULT_ADMIN_ROLE(), admin)
        );
        vm.startPrank(admin);
        slisBnb.setStakeManager(address(stakeManager));
        vm.stopPrank();
    }

    function test_autoRefund() public {
        uint256 totalAmount = 100 ether;

        (bool success, ) = address(autoRefunder).call{value: totalAmount}("");
        require(success, "Funding failed");
        assertEq(address(autoRefunder).balance, totalAmount);

        vm.startPrank(admin);
        stakeManager.grantRole(stakeManager.MANAGER(), address(autoRefunder));
        assertTrue(
            stakeManager.hasRole(stakeManager.MANAGER(), address(autoRefunder))
        );
        vm.stopPrank();

        vm.expectRevert();
        autoRefunder.autoRefund();

        vm.startPrank(bot);
        autoRefunder.autoRefund();
        vm.stopPrank();

        assertEq(address(autoRefunder).balance, 0);
        assertEq(address(stakeManager).balance, (totalAmount * 6000) / 10000);
        assertEq(address(vault).balance, (totalAmount * 4000) / 10000);
        assertEq(
            IERC20Metadata(address(slisBnb)).balanceOf(address(stakeManager)),
            (totalAmount * 6000) / 10000
        );

        uint dailySlisBnb;
        uint remainingSlisBnb;
        uint lastBurnTime;

        (dailySlisBnb, remainingSlisBnb, lastBurnTime) = stakeManager.refund();
        assertEq(dailySlisBnb, (totalAmount * 6000) / 10000 / 30);
        assertEq(remainingSlisBnb, (totalAmount * 6000) / 10000);
        assertEq(lastBurnTime, 0);
    }

    function test_changeRefundRatio() public {
        vm.expectRevert();
        autoRefunder.changeRefundRatio(5000);

        vm.startPrank(manager);
        vm.expectRevert("Invalid refund ratio");
        autoRefunder.changeRefundRatio(0);
        vm.expectRevert("Invalid refund ratio");
        autoRefunder.changeRefundRatio(10000);
        vm.expectRevert("Same refund ratio");
        autoRefunder.changeRefundRatio(6000);
        autoRefunder.changeRefundRatio(5000); // success
        vm.stopPrank();

        assertEq(autoRefunder.refundRatio(), 5000);
    }

    function test_changeRefundDays() public {
        vm.expectRevert();
        autoRefunder.changeRefundDays(15);

        vm.startPrank(manager);
        vm.expectRevert("Invalid refund days");
        autoRefunder.changeRefundDays(0);
        vm.expectRevert("Invalid refund days");
        autoRefunder.changeRefundDays(30);
        autoRefunder.changeRefundDays(15); // success
        vm.stopPrank();

        assertEq(autoRefunder.refundDays(), 15);
    }

    function test_emergencyWithdraw() public {
        deal(address(autoRefunder), 99 ether);

        vm.expectRevert();
        autoRefunder.emergencyWithdraw();

        vm.prank(manager);
        autoRefunder.emergencyWithdraw(); // success

        assertEq(99 ether, address(manager).balance);
        assertEq(0, address(autoRefunder).balance);
    }
}
