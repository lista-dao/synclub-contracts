//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/// @dev The staking entry points are omitted on purpose: they mirror `IStakeHub` exactly, so
///      callers reach them through `IStakeHub(subStaker)` and need no second call site.
interface ISubStaker {
    event VoteDelegateeSet(address indexed delegatee);
    event Swept(uint256 amount);

    function initialize(address _stakeManager) external;

    function setVoteDelegatee(address _delegatee) external;

    function sweep() external;

    function stakeManager() external view returns (address);

    function voteDelegatee() external view returns (address);

    function govVotes() external view returns (uint256);

    function position(address _validator)
        external
        view
        returns (uint256 pooled, uint256 locked, uint256 shares, uint256 claimable);
}
