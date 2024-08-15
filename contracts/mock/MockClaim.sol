// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Firstly, we implement a mock emulating the actual precompile behavior
// Inject the mock into the precompile Stake Hub contract
contract ClaimMock {
    CreditMock public creditMock;

    function setCreditMock(address _creditMock) public {
        creditMock = CreditMock(_creditMock);
    }

    function claim(address _validator, uint256 _count) public {
        creditMock._claim();
    }
}
// Inject the mock into the Credit contract
contract CreditMock {
    address public stakeManager;
    uint256 public amount = 100 ether;

    function setStakeManager(address _stakeManager) public {
        stakeManager = _stakeManager;
    }

    function setAmount(uint256 _amount) public {
        amount = _amount;
    }

    function _claim() public {
        stakeManager.call{ value: amount }("");
    }
}
