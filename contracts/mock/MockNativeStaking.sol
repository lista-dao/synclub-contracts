//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IStaking} from "../interfaces/INativeStaking.sol";

contract MockNativeStaking is IStaking {
  uint256 public constant FEE = 16000000000000000;
  uint256 public constant LOCK_TIME = 60 seconds;

  mapping(address => uint256) delegated; // delegator => totalAmount
  mapping(address => uint256) undelegated; // delegator => totalUndelegated
  mapping(address => mapping(address => uint256)) public delegatedOfValidator; // delegator => validator => amount
  mapping(address => mapping(address => uint256)) public pendingUndelegateTime; // delegator => validator => minTime

  function delegate(address validator, uint256 amount) external payable override {
      require(msg.value>=FEE);
      delegatedOfValidator[msg.sender][validator] += amount;
      delegated[msg.sender] += amount;
  }

  function undelegate(address validator, uint256 amount) external payable override {
      require(msg.value>=FEE);
      uint256 endTime = pendingUndelegateTime[msg.sender][validator];
      require(endTime <= block.timestamp, "not yet undelegatable");

      require(delegatedOfValidator[msg.sender][validator] >= amount, "not enought delegated bnb");
      delegatedOfValidator[msg.sender][validator] -= amount;
      pendingUndelegateTime[msg.sender][validator] = block.timestamp + LOCK_TIME;

      delegated[msg.sender] -= amount;
      undelegated[msg.sender] += amount;
  }

  function redelegate(address validatorSrc, address validatorDst, uint256 amount) external payable override {
      require(msg.value>=FEE);
      require(delegatedOfValidator[msg.sender][validatorSrc] >= amount, "not enought delegated bnb");
      delegatedOfValidator[msg.sender][validatorSrc] -= amount;
      delegatedOfValidator[msg.sender][validatorDst] += amount;
  }

  function claimReward() external override returns(uint256 amount) {
      amount = 20000000000000000; // 0.02 bnb
      (bool success,) = msg.sender.call{value: amount}("");
      require(success, "transfer failed");
  }

  function claimUndelegated() external override returns(uint256 amount) {
      amount = undelegated[msg.sender];
      require(amount > 0, "nothing to claim");
      undelegated[msg.sender] = 0;
      (bool success,) = msg.sender.call{value: amount}("");
      require(success, "transfer failed");
  }

  function getDelegated(address delegator, address validator) external override view returns(uint256) {
      return delegatedOfValidator[delegator][validator];
  }

  function getTotalDelegated(address delegator) external view override returns(uint256) {
      return delegated[delegator];
  }

  function getDistributedReward(address delegator) external view override returns(uint256) {
      return 0;
  }

  function getPendingRedelegateTime(address delegator, address valSrc, address valDst) external view override returns(uint256) {
      return 0;
  }

  function getUndelegated(address delegator) external view override returns(uint256){
      return undelegated[delegator];
  }

  function getPendingUndelegateTime(address delegator, address validator) external view override returns(uint256) {
      return pendingUndelegateTime[delegator][validator];
  }

  function getRelayerFee() external view override returns(uint256) {
      return FEE;
  }

  function getMinDelegation() external view override returns(uint256) {
      return 100000000000000000;
  }

  function getRequestInFly(address delegator) external view override returns(uint256[3] memory) {      
  }
}
