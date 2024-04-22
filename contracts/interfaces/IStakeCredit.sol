// SPDX-License-Identifier: GPL-3.0-or-later
//pragma solidity 0.8.17;
pragma solidity ^0.8.0;

interface IStakeCredit {
    struct UnbondRequest {
        uint256 shares;
        uint256 bnbAmount;
        uint256 unlockTime;
    }

    function getPooledBNBByShares(
        uint256 shares
    ) external view returns (uint256);
    function getSharesByPooledBNB(
        uint256 bnbAmount
    ) external view returns (uint256);
    function unbond(
        address delegator,
        uint256 shares
    ) external returns (uint256);
    function distributeReward(uint64 commissionRate) external payable;
    function rewardRecord(uint256 dayIndex) external view returns (uint256);
    function totalPooledBNBRecord(
        uint256 dayIndex
    ) external view returns (uint256);
    function balanceOf(address delegator) external view returns (uint256);
    function unbondRequest(
        address delegator,
        uint256 _index
    ) external view returns (UnbondRequest memory);
    function claimableUnbondRequest(
        address delegator
    ) external view returns (uint256);
    function getPooledBNB(address account) external view returns (uint256);

    function lockedBNBs(address delegator, uint256 number) external view returns (uint256);
}
