//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

interface IStakeManager {
    struct BotUndelegateRequest {
        uint256 startTime;
        uint256 endTime;
        uint256 amount;
        uint256 amountInSnBnb;
    }

    struct WithdrawalRequest {
        uint256 uuid;
        uint256 amountInSnBnb;
        uint256 startTime;
    }

    function initialize(
        address _snBnb,
        address _admin,
        address _manager,
        address _bot,
        uint256 _feeBps,
        address _revenuePool,
        address _validator
    ) external;

    function deposit() external payable;

    function delegate() external payable returns (uint256 _amount);

    function redelegate(address srcValidator, address dstValidator, uint256 amount)
        external
        payable
        returns (uint256 _amount);

    function requestWithdraw(uint256 _amountInSnBnb) external;

    function claimWithdraw(uint256 _idx) external;

    function undelegate() external payable returns (uint256 _uuid, uint256 _amount);

    function undelegateAll() external payable returns (uint256 _uuid, uint256 _amount);

    function claimUndelegated() external returns (uint256, uint256);

    function claimUndelegatedAll() external returns (uint256 _uuid, uint256 _amount);

    function claimFailedDelegation(bool) external returns (uint256);

    function compoundRewards() external;

    function depositReserve() external payable;

    function withdrawReserve(uint256) external;

    function setReserveAmount(uint256) external;

    function proposeNewManager(address _address) external;

    function acceptNewManager() external;

    function setBotRole(address _address) external;

    function revokeBotRole(address _address) external;

    function setBCValidator(address _address) external;

    function setSynFee(uint256 _synFee) external;

    function setRevenuePool(address _address) external;

    function setRedirectAddress(address _address) external;

    function getTotalPooledBnb() external view returns (uint256);

    function getContracts() external view returns (address _manager, address _snBnb, address _bcValidator);

    function getBotUndelegateRequest(uint256 _uuid) external view returns (BotUndelegateRequest memory);

    function getUserWithdrawalRequests(address _address) external view returns (WithdrawalRequest[] memory);

    function getUserRequestStatus(address _user, uint256 _idx)
        external
        view
        returns (bool _isClaimable, uint256 _amount);

    function getSnBnbWithdrawLimit() external view returns (uint256 _bnbXWithdrawLimit);

    function getTokenHubRelayFee() external view returns (uint256);

    function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);

    function convertSnBnbToBnb(uint256 _amountInBnbX) external view returns (uint256);

    event Deposit(address _src, uint256 _amount);
    event Delegate(uint256 _amount);
    event DelegateTo(address indexed _validator, uint256 _amount, bool _delegateVotePower);
    event ReDelegate(address _src, address _dest, uint256 _amount);
    event RequestWithdraw(address indexed _account, uint256 _amountInBnbX);
    event ClaimWithdrawal(address indexed _account, uint256 _idx, uint256 _amount);
    event Undelegate(uint256 _uuid, uint256 _amount);
    event UndelegateAll(uint256 _allAmount, uint256 _amount);
    event Redelegate(uint256 _rewardsId, uint256 _amount);
    event SetManager(address indexed _address);
    event ProposeManager(address indexed _address);
    event SetSynFee(uint256 _synFee);
    event SetRedirectAddress(address indexed _address);
    event SetBCValidator(address indexed _address);
    event SetRevenuePool(address indexed _address);
    event RewardsCompounded(uint256 _amount);
    event DelegateReserve(uint256 _amount);
    event UndelegateReserve(uint256 _amount);
    event SetReserveAmount(uint256 _amount);
    event ClaimUndelegated(uint256 _uuid, uint256 _amount);
    event ClaimFailedDelegation(uint256 _amount, bool _withReserve);
}
