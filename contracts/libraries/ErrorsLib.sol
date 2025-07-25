//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

library ErrorsLib {
    error ZeroAddress();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidSlisBnbAmount();
    error InactiveValidator();
    error AlreadyActive();
    error NotEnoughBnb();
    error NotEnoughFee();
    error AmountTooSmall();
    error AmountTooLarge();
    error InvalidSynFee();
    error UnclaimableRequest();
}
