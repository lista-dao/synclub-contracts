//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IStaking} from "../interfaces/INativeStaking.sol";

contract MockNativeStaking is IStaking {

  function delegate(address validator, uint256 amount) external payable override {
  }

  function undelegate(address validator, uint256 amount) external payable override {}

  function redelegate(address validatorSrc, address validatorDst, uint256 amount) external payable override {}

  function claimReward() external override returns(uint256) {}

  function claimUndelegated() external override returns(uint256) {}

  function getDelegated(address delegator, address validator) external override view returns(uint256) {}

  function getTotalDelegated(address delegator) external view override returns(uint256) {}

  function getDistributedReward(address delegator) external view override returns(uint256) {}

  function getPendingRedelegateTime(address delegator, address valSrc, address valDst) external view override returns(uint256) {}

  function getUndelegated(address delegator) external view override returns(uint256){}

  function getPendingUndelegateTime(address delegator, address validator) external view override returns(uint256) {}

  function getRelayerFee() external view override returns(uint256) {
      return 16000000000000000;
  }

  function getMinDelegation() external view override returns(uint256) {}

  function getRequestInFly(address delegator) external view override returns(uint256[3] memory) {}
}
