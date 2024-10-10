// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../contracts/libraries/SLisLibrary.sol";

contract SLisLibraryTest is Test {

    uint256 decimals = 1e10;

    function setUp() public {}

    function test_calculateFeeFromDailyProfit() public {
        uint256 _profit = 1 ether; // 1 BNB
        uint256 _synFee = 500000000; // 5%

        uint256 _fee = SLisLibrary.calculateFeeFromDailyProfit(_profit, _synFee, decimals);
        // 1 * 5% = 0.05 BNB
        assertEq(_fee, 0.05 ether);
    }

    function test_calculateFeeFromAPY() public {
        uint256 _principal = 36500 ether; // 36500 BNB
        uint256 _annualRate = 10000000; // 0.1%

        uint256 _fee = SLisLibrary.calculateFeeFromAPY(_principal, _annualRate, decimals);
        // 36500 * 0.1% / 365 = 0.1 BNB
        assertEq(_fee, 0.1 ether);
    }

    function test_calculateFee() public {
        uint256 _principal = 36500 ether; // 36500 BNB
        uint256 _profit = 1 ether; // 1 BNB
        uint256 _annualRate = 10000000; // 0.1%
        uint256 _synFee = 500000000; // 5%

        uint256 _fee = SLisLibrary.calculateFee(_principal, _profit, _annualRate, _synFee, decimals);
        // 0.1 BNB > 0.05 BNB
        assertEq(_fee, 0.1 ether);
    }

}