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

    struct UserRequest {
        uint256 uuid;
        uint256 amount;
        uint256 amountInSlisBnb;
        uint256 totalAmount;
        uint256 totalAmountInSlisBnb;
    }

    function initialize(
        address _slisBnb,
        address _admin,
        address _manager,
        address _bot,
        uint256 _feeBps,
        address _revenuePool,
        address _validator
    ) external;

    function deposit() external payable;

    function delegateTo(address validator, uint256 amount)
        external;

    function redelegate(address srcValidator, address dstValidator, uint256 shares)
        external;

    function requestWithdraw(uint256 _amountInSnBnb) external;

    function claimWithdraw(uint256 _idx) external;

    function claimWithdrawFor(address _user, uint256 _idx) external;

    function undelegate()
        external
        returns (uint256 _uuid, uint256 _shares);

    function undelegateFrom(address _operator, uint256 _amount)
        external
        returns (uint256 _actualBnbAmount);

    function claimUndelegated(address _validator) external returns (uint256, uint256);

    function delegateVoteTo(address _delegateTo) external;

    function binarySearchCoveredMaxIndex(uint256 _bnbAmount) external returns (uint256);

    function depositReserve() external payable;

    function withdrawReserve(uint256) external;

    function setReserveAmount(uint256) external;

    function proposeNewManager(address _address) external;

    function acceptNewManager() external;

    function setBotRole(address _address) external;

    function revokeBotRole(address _address) external;

    function setBSCValidator(address _address) external;

    function setSynFee(uint256 _synFee) external;

    function setAnnualRate(uint256 _annualRate) external;

    function setRevenuePool(address _address) external;

    function setMinBnb(uint256 _minBnb) external;

    function getTotalPooledBnb() external view returns (uint256);

    function setRedirectAddress(address _address) external;

    function whitelistValidator(address _address) external;

    function disableValidator(address _address) external;

    function removeValidator(address _address) external;

    function getContracts()
        external
        view
        returns (
            address _manager,
            address _snBnb,
            address _bcValidator
        );

    function getBotUndelegateRequest(uint256 _uuid)
        external
        view
        returns (BotUndelegateRequest memory);

    function getUserWithdrawalRequests(address _address)
        external
        view
        returns (WithdrawalRequest[] memory);

    function getUserRequestStatus(address _user, uint256 _idx)
        external
        view
        returns (bool _isClaimable, uint256 _amount);

    function getSlisBnbWithdrawLimit()
        external
        view
        returns (uint256 _slisBnbWithdrawLimit);

    function getAmountToUndelegate() external view returns (uint256);

    function getDelegated(address validator) external view returns (uint256);

    function convertSharesToBnb(address _operator, uint256 _shares) external view returns (uint256);

    function convertBnbToShares(address _operator, uint256 _bnbAmount) external view returns (uint256);

    function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);

    function convertSnBnbToBnb(uint256 _amountInSlisBnb)
        external
        view
        returns (uint256);

    function getClaimableAmount(address _validator)
        external
        view
        returns (uint256 _amount);

    function compoundRewards() external;

    function getTotalBnbInValidators() external returns (uint256);

    function getRedelegateFee(uint256 bnbAmount)
        external
        view
        returns (uint256);

    event Deposit(address _src, uint256 _amount);
    event Delegate(uint256 _amount);
    event DelegateTo(address _validator, uint256 _amount, bool _delegateVotePower);
    event ReDelegate(address _src, address _dest, uint256 _amount);
    event RequestWithdraw(address indexed _account, uint256 _amountInSlisBnb);
    event ClaimWithdrawal(
        address indexed _account,
        uint256 _idx,
        uint256 _amount
    );
    event ClaimAllWithdrawals(address indexed _account, uint256 _amount);
    event Undelegate(uint256 _nextUndelegatedRequestIndex, uint256 _bnbAmount, uint256 _shares);
    event UndelegateFrom(address indexed _operator, uint256 _bnbAmount, uint256 _shares);
    event Redelegate(uint256 _rewardsId, uint256 _amount);
    event SetManager(address indexed _address);
    event ProposeManager(address indexed _address);
    event SetSynFee(uint256 _synFee);
    event SetAnnualRate(uint256 _annualRate);
    event SetRedirectAddress(address indexed _address);
    event SetBSCValidator(address indexed _address);
    event SetRevenuePool(address indexed _address);
    event RewardsCompounded(uint256 _amount);
    event UndelegateReserve(uint256 _amount);
    event SetReserveAmount(uint256 _amount);
    event ClaimUndelegated(uint256 _uuid, uint256 _amount);
    event ClaimUndelegatedFrom(address indexed _validator, uint256 _uuid, uint256 _amount);
    event WhitelistValidator(address indexed _address);
    event DisableValidator(address indexed _address);
    event RemoveValidator(address indexed _address);
    event SyncCreditContract(address indexed _validator, address _credit, bool toRemove);
    event SetMinBnb(uint256 _minBnb);
    event DelegateVoteTo(address _delegateTo, uint256 _votesChange);
    event RefundCommission(uint256 _bnbAmount, uint256 _dailySlisBnb, uint256 _days, uint256 _remainingSlisBnb);
}
