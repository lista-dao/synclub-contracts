//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {ISLisBNB} from "./interfaces/ISLisBNB.sol";
import {IStakeHub} from "./interfaces/IStakeHub.sol";
import {IStakeCredit} from "./interfaces/IStakeCredit.sol";

/**
 * @title Stake Manager Contract
 * @dev Handles Staking of BNB on BSC
 */
contract ListaStakeManager is
    IStakeManager,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public totalSnBnbToBurn; // received User withdraw requests; no use in new logic

    uint256 public totalDelegated; // total BNB delegated
    uint256 public amountToDelegate; // total BNB to delegate for next batch; (User deposits + rewards  - delegated)

    uint256 public requestUUID; // global UUID for each user withdrawal request
    uint256 public nextConfirmedRequestUUID; // next confirmed UUID for user withdrawal requests

    uint256 public reserveAmount; // will be used to adjust minThreshold delegate/undelegate for natvie staking
    uint256 public totalReserveAmount;

    address private slisBnb;
    address private bscValidator; // the initial BSC validator funds will be migrated to

    mapping(uint256 => BotUndelegateRequest)
        private uuidToBotUndelegateRequestMap; // no use in new logic
    mapping(address => WithdrawalRequest[]) private userWithdrawalRequests;

    uint256 public constant TEN_DECIMALS = 1e10;
    bytes32 public constant BOT = keccak256("BOT");

    address private manager;
    address private proposedManager;
    uint256 public synFee; // range {0-10_000_000_000}

    address public revenuePool;
    address public redirectAddress;

    address private constant STAKE_HUB = 0x0000000000000000000000000000000000002002;

    mapping(address => bool) public validators;
    bool internal delegateVotePower;

    uint256 private undelegatedQuota; // the amount Bnb received but not claimable yet
    uint256 public nextUndelegatedRequestIndex; // the index of next request to be delegated in queue
    UserRequest[] internal withdrawalQueue; // queue for requested withdrawals

    mapping(uint256 => uint256) public requestIndexMap; // uuid => index in withdrawalQueue

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _slisBnb - Address of SlisBnb Token on Binance Smart Chain
     * @param _admin - Address of the admin
     * @param _manager - Address of the manager
     * @param _bot - Address of the Bot
     * @param _synFee - Rewards fee to revenue pool
     * @param _revenuePool - Revenue pool to receive rewards
     * @param _validator - Validator to delegate BNB
     */
    function initialize(
        address _slisBnb,
        address _admin,
        address _manager,
        address _bot,
        uint256 _synFee,
        address _revenuePool,
        address _validator
    ) external override initializer {
        __AccessControl_init();
        __Pausable_init();

        require(
            ((_slisBnb != address(0)) &&
                (_admin != address(0)) &&
                (_manager != address(0)) &&
                (_validator != address(0)) &&
                (_revenuePool != address(0)) &&
                (_bot != address(0))),
            "zero address provided"
        );
        require(_synFee <= TEN_DECIMALS, "_synFee must not exceed (100%)");

        _setRoleAdmin(BOT, DEFAULT_ADMIN_ROLE);
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(BOT, _bot);

        manager = _manager;
        slisBnb = _slisBnb;
        bscValidator = _validator;
        synFee = _synFee;
        revenuePool = _revenuePool;

        emit SetManager(_manager);
        emit SetBSCValidator(bscValidator);
        emit SetRevenuePool(revenuePool);
        emit SetSynFee(_synFee);
    }

    /**
     * @dev Allows user to deposit Bnb at BSC and mints SlisBnb for the user
     */
    function deposit() external payable override whenNotPaused {
        uint256 amount = msg.value;
        require(amount > 0, "Invalid Amount");

        uint256 slisBnbToMint = convertBnbToSnBnb(amount);
        require(slisBnbToMint > 0, "Invalid SlisBnb Amount");
        amountToDelegate += amount;

        ISLisBNB(slisBnb).mint(msg.sender, slisBnbToMint);

        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @dev Allows bot to delegate users' funds to bscValidator
     * @notice The amount should be greater than minimum delegation on native staking contract
     */
    function delegate()
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _amount)
    {
        _amount = amountToDelegate;
        require(_amount >= IStakeHub(STAKE_HUB).minDelegationBNBChange(), "Insufficient Deposit Amount");

        amountToDelegate = amountToDelegate - _amount;
        totalDelegated += _amount;

        // delegate through native staking contract
        IStakeHub(STAKE_HUB).delegate{value: _amount}(bscValidator, delegateVotePower);

        emit Delegate(_amount);
    }

    /**
     * @dev Allows bot to delegate users' funds to BSC validator
     * @param _validator - Operator address of the BSC validator to delegate to
     * @param _amount - Amount of BNB to delegate
     * @notice The amount should be greater than minimum delegation
     */
    function delegateTo(address _validator, uint256 _amount)
        external
        override
        whenNotPaused
        onlyRole(BOT)
    {
        require(amountToDelegate >= _amount, "Not enough BNB to delegate");

        require(validators[_validator] == true, "Inactive validator");
        require(_amount >= IStakeHub(STAKE_HUB).minDelegationBNBChange(), "Insufficient Delegation Amount");

        amountToDelegate -= _amount;
        totalDelegated += _amount;

        // delegate through StakeHub contract
        IStakeHub(STAKE_HUB).delegate{value: _amount}(_validator, delegateVotePower);

        emit DelegateTo(_validator, _amount, delegateVotePower);
    }

    /**
     * @param srcValidator the operator address of the validator to be redelegated from
     * @param dstValidator the operator address of the validator to be redelegated to
     * @param shares the shares to be redelegated
     */
    function redelegate(address srcValidator, address dstValidator, uint256 shares)
        external
        override
        whenNotPaused
        onlyManager
    {
        require(srcValidator != dstValidator, "Invalid Redelegation");
        require(validators[dstValidator], "Inactive dst validator");

        // redelegate through native staking contract
        IStakeHub(STAKE_HUB).redelegate(srcValidator, dstValidator, shares, delegateVotePower);

        emit ReDelegate(srcValidator, dstValidator, shares);
    }

    /**
     * @dev Allows user to request for unstake/withdraw funds
     * @param _amountInSlisBnb - Amount of SlisBnb to swap for withdraw
     * @notice User must have approved this contract to spend SlisBnb
     */
    function requestWithdraw(uint256 _amountInSlisBnb)
        external
        override
        whenNotPaused
    {
        require(_amountInSlisBnb > 0, "Invalid Amount");

        uint256 bnbToWithdraw = convertSnBnbToBnb(_amountInSlisBnb);
        bnbToWithdraw -= (bnbToWithdraw % TEN_DECIMALS);
        require(bnbToWithdraw > 0, "Bnb amount is too small");

        requestUUID++;
        userWithdrawalRequests[msg.sender].push(
            WithdrawalRequest({
                uuid: requestUUID,
                amountInSnBnb: _amountInSlisBnb,
                startTime: block.timestamp
            })
        );

        withdrawalQueue.push(
            UserRequest({
                uuid: requestUUID,
                amount: bnbToWithdraw,
                amountInSlisBnb: _amountInSlisBnb
            })
        );
        requestIndexMap[requestUUID] = withdrawalQueue.length - 1;

        IERC20Upgradeable(slisBnb).safeTransferFrom(
            msg.sender,
            address(this),
            _amountInSlisBnb
        );
        emit RequestWithdraw(msg.sender, _amountInSlisBnb);
    }

    function claimWithdraw(uint256 _idx) external override whenNotPaused {
        address user = msg.sender;
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[user];

        require(_idx < userRequests.length, "Invalid index");

        WithdrawalRequest storage withdrawRequest = userRequests[_idx];
        uint256 uuid = withdrawRequest.uuid;
        uint256 amount;

        // 1. queue.length == 0 => old logic
        // 2. queue.length > 0 && uuid < queue[0].uuid => old logic
        // 3. queue.length > 0 && uuid >= queue[0].uuid => new logic

        if (withdrawalQueue.length != 0 && uuid >= withdrawalQueue[0].uuid) {
            // new logic
            UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];
            require(uuid < nextConfirmedRequestUUID, "Not able to claim yet");
            amount = request.amount;
        } else {
            // old logic
            uint256 amountInSlisBnb = withdrawRequest.amountInSnBnb;
            BotUndelegateRequest
                storage botUndelegateRequest = uuidToBotUndelegateRequestMap[uuid];
            require(botUndelegateRequest.endTime != 0, "Not able to claim yet");
            uint256 totalBnbToWithdraw_ = botUndelegateRequest.amount;
            uint256 totalSlisBnbToBurn_ = botUndelegateRequest.amountInSnBnb;
            amount = (totalBnbToWithdraw_ * amountInSlisBnb) /
            totalSlisBnbToBurn_;
        }

        userRequests[_idx] = userRequests[userRequests.length - 1];
        userRequests.pop();

        AddressUpgradeable.sendValue(payable(user), amount);

        emit ClaimWithdrawal(user, _idx, amount);
    }


    /**
     * @dev Undelegate the BNB amount equivalent to `totalSnBnbToBurn`(withdrawals between 4.16 ~ the 2nd upgrade) from the bscValidator.
     *      Process the withdrawal requests happened before multi-validator upgrade
     * @return _uuid - unique id against which this Undelegation event was logged
     * @return _shares - Amount of stTokens to be returned to the validator
     */
    function undelegate()
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _shares)
    {
        require(totalSnBnbToBurn > 0, "Nothing to undelegate");
        _uuid = requestUUID++; // nextUndelegateUUID renamed to requestUUID

        uint256 totalSlisBnbToBurn_ = totalSnBnbToBurn; // To avoid Reentrancy attack
        uint256 bnbAmount = convertSnBnbToBnb(totalSlisBnbToBurn_);

        uuidToBotUndelegateRequestMap[_uuid] = BotUndelegateRequest({
            startTime: block.timestamp,
            endTime: 0,
            amount: bnbAmount,
            amountInSnBnb: totalSlisBnbToBurn_
        });

        totalDelegated -= bnbAmount;
        totalSnBnbToBurn = 0;

        ISLisBNB(slisBnb).burn(address(this), totalSlisBnbToBurn_);

        // calculate the amount of stToken
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(bscValidator);
        _shares = IStakeCredit(creditContract).getSharesByPooledBNB(bnbAmount);
        // undelegate through stake hub contract
        IStakeHub(STAKE_HUB).undelegate(bscValidator, _shares);

        emit UndelegateReserve(reserveAmount);
    }

    /**
     * @dev Bot uses this function to get amount of BNB to withdraw
     * @param _validator - Validator to undelegate from
     * @param _amount - Amount of BNB to undelegate, the amount must cover complete requests in queue
     * @return _nextUndelegatedRequestIndex - the next request index to be undelegated
     * @return _shares - Amount of stToken returned to validator
     */
    function undelegateFrom(address _validator, uint256 _amount)
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _nextUndelegatedRequestIndex, uint256 _shares)
    {
        require(totalDelegated >= _amount, "Not enough BNB to undelegate");
        // old requests need to be processed by undelegate first
        require(totalSnBnbToBurn == 0, "Not able to undelegate yet");

        uint256 reminder = _amount;
        uint256 totalSnBnbToBurn_ = 0;
        for (uint256 i = nextUndelegatedRequestIndex; i < withdrawalQueue.length; ++i) {
            if (reminder == 0) {
                break;
            }
            UserRequest storage req = withdrawalQueue[i];
            require(reminder >= req.amount, "Amount should cover complete request");
            reminder -= req.amount;
            totalSnBnbToBurn_ += req.amountInSlisBnb;
            ++nextUndelegatedRequestIndex;
        }

        require(reminder == 0 && totalSnBnbToBurn_ > 0, "Invalid Amount");
        totalDelegated -= _amount;

        ISLisBNB(slisBnb).burn(address(this), totalSnBnbToBurn_);

        // calculate the amount of stToken
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        _shares = IStakeCredit(creditContract).getSharesByPooledBNB(_amount);
        // undelegate through StakeHub contract, will revert if shares are not enough
        IStakeHub(STAKE_HUB).undelegate(_validator, _shares);
        _nextUndelegatedRequestIndex = nextUndelegatedRequestIndex;

        emit UndelegateFrom(nextUndelegatedRequestIndex, _amount, _shares);
    }

    function getClaimableAmount(address _validator)
        public
        view
        override
        returns (uint256 _amount)
    {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        uint256 count = IStakeCredit(creditContract).claimableUnbondRequest(address(this));
        uint256 index = 0;

        while(count != 0) {
            IStakeCredit.UnbondRequest memory req = IStakeCredit(creditContract).unbondRequest(address(this), index);
            _amount += req.bnbAmount;
            --count;
            ++index;
        }
    }

    /**
     * @dev Claim unbond BNB and rewards from the validator
     * @param _validator - The operator address of the validator
     */
    function claimUndelegated(address _validator)
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount)
    {
        // Bot only can claim after undelegated all old requests
        require(totalSnBnbToBurn == 0, "Not able to claim yet");
        uint256 undelegatedAmount = getClaimableAmount(_validator);
        require(undelegatedAmount > 0, "Nothing to claim");


        IStakeHub(STAKE_HUB).claim(_validator, 0);
        undelegatedQuota += undelegatedAmount;

        uint256 oldLastUUID = requestUUID;

        if (withdrawalQueue.length != 0) {
            oldLastUUID = withdrawalQueue[0].uuid - 1;
        }

        uint256 rewards = undelegatedAmount;
        for (uint256 i = nextConfirmedRequestUUID; i <= oldLastUUID; ++i) {
            BotUndelegateRequest storage botRequest = uuidToBotUndelegateRequestMap[i];
            if (undelegatedQuota < botRequest.amount) {
                return (0, 0);
            }
            botRequest.endTime = block.timestamp;
            undelegatedQuota -= botRequest.amount;
            rewards -= botRequest.amount;
            ++nextConfirmedRequestUUID;
        }

        // new logic
        for (uint256 i = nextConfirmedRequestUUID; i <= requestUUID; ++i) {
            UserRequest storage req = withdrawalQueue[requestIndexMap[i]];
            if (req.uuid == 0 || req.amount > undelegatedQuota) {
                break;
            }
            undelegatedQuota -= req.amount;
            rewards -= req.amount;
            ++nextConfirmedRequestUUID;
        }

        // compound rewards
        if (synFee > 0 && rewards > 0) {
            uint256 fee = rewards * synFee / TEN_DECIMALS;
            require(revenuePool != address(0x0), "revenue pool not set");
            AddressUpgradeable.sendValue(payable(revenuePool), fee);
            rewards -= fee;
            amountToDelegate += rewards;
            emit RewardsCompounded(rewards);
        }

        _uuid = nextConfirmedRequestUUID;
        _amount = undelegatedAmount;

        emit ClaimUndelegated(_uuid, _amount);
    }

    /**
     * @dev Deposit reserved funds to the contract
     */
    function depositReserve() external payable override whenNotPaused onlyRedirectAddress{
        uint256 amount = msg.value;
        require(amount > 0, "Invalid Amount");

        totalReserveAmount += amount;
    }

    function withdrawReserve(uint256 amount) external override whenNotPaused onlyRedirectAddress{
        require(amount <= totalReserveAmount, "Insufficient Balance");
        totalReserveAmount -= amount;
        AddressUpgradeable.sendValue(payable(msg.sender), amount);
    }

    function setReserveAmount(uint256 amount) external override onlyManager {
        reserveAmount = amount;
        emit SetReserveAmount(amount);
    }

    function proposeNewManager(address _address) external override onlyManager {
        require(manager != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        proposedManager = _address;

        emit ProposeManager(_address);
    }

    function acceptNewManager() external override {
        require(
            msg.sender == proposedManager,
            "Accessible only by Proposed Manager"
        );

        manager = proposedManager;
        proposedManager = address(0);

        emit SetManager(manager);
    }

    function setBotRole(address _address) external override {
        require(_address != address(0), "zero address provided");

        grantRole(BOT, _address);

    }

    function revokeBotRole(address _address) external override {
        require(_address != address(0), "zero address provided");

        revokeRole(BOT, _address);

    }

    /// @param _address - the operator address of BSC validator
    function setBSCValidator(address _address)
        external
        override
        onlyManager
    {
        require(bscValidator != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        bscValidator = _address;

        emit SetBSCValidator(_address);
    }

    function setSynFee(uint256 _synFee)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_synFee <= TEN_DECIMALS, "_synFee must not exceed 10000 (100%)");
        synFee = _synFee;

        emit SetSynFee(_synFee);
    }

    function setRedirectAddress(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(redirectAddress != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        redirectAddress = _address;

        emit SetRedirectAddress(_address);
    }


    function setRevenuePool(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(revenuePool != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        revenuePool = _address;

        emit SetRevenuePool(_address);
    }

    function whitelistValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!validators[_address], "Validator should be inactive");
        require(_address != address(0), "zero address provided");

        validators[_address] = true;

        emit WhitelistValidator(_address);
    }

    function disableValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(validators[_address], "Validator is not active");

        validators[_address] = false;

        emit DisableValidator(_address);
    }

    function removeValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!validators[_address], "Validator is should be inactive");
	require(getDelegated(_address) == 0, "Balance is not zero");

        delete validators[_address];

        emit RemoveValidator(_address);
    }

    function getTotalPooledBnb() public view override returns (uint256) {
        return (amountToDelegate + totalDelegated);
    }

    function getContracts()
        external
        view
        override
        returns (
            address _manager,
            address _slisBnb,
            address _bscValidator
        )
    {
        _manager = manager;
        _slisBnb = slisBnb;
        _bscValidator = bscValidator;
    }


    function getBotUndelegateRequest(uint256 _uuid)
        external
        view
        override
        returns (BotUndelegateRequest memory)
    {
        return uuidToBotUndelegateRequestMap[_uuid];
    }

    /**
     * @dev Retrieves all withdrawal requests initiated by the given address
     * @param _address - Address of an user
     * @return userWithdrawalRequests array of user withdrawal requests
     */
    function getUserWithdrawalRequests(address _address)
        external
        view
        override
        returns (WithdrawalRequest[] memory)
    {
        return userWithdrawalRequests[_address];
    }

    /**
     * @dev Checks if the withdrawRequest is ready to claim
     * @param _user - Address of the user who raised WithdrawRequest
     * @param _idx - index of request in UserWithdrawls Array
     * @return _isClaimable - if the withdraw is ready to claim yet
     * @return _amount - Amount of BNB user would receive on withdraw claim
     * @notice Use `getUserWithdrawalRequests` to get the userWithdrawlRequests Array
     */
    function getUserRequestStatus(address _user, uint256 _idx)
        external
        view
        override
        returns (bool _isClaimable, uint256 _amount)
    {
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[
            _user
        ];

        require(_idx < userRequests.length, "Invalid index");

        WithdrawalRequest storage withdrawRequest = userRequests[_idx];
        uint256 uuid = withdrawRequest.uuid;

        if (withdrawalQueue.length != 0 && uuid >= withdrawalQueue[0].uuid) {
            // new logic
            UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];
            _isClaimable = uuid < nextConfirmedRequestUUID;
            _amount = request.amount;
        } else {
            // old logic
            uint256 amountInSnBnb = withdrawRequest.amountInSnBnb;
            BotUndelegateRequest storage botUndelegateRequest = uuidToBotUndelegateRequestMap[uuid];

            // bot has triggered startUndelegation
            if (botUndelegateRequest.amount > 0) {
                uint256 totalBnbToWithdraw_ = botUndelegateRequest.amount;
                uint256 totalSnBnbToBurn_ = botUndelegateRequest.amountInSnBnb;
                _amount = (totalBnbToWithdraw_ * amountInSnBnb) / totalSnBnbToBurn_;
            } else {
                _amount = convertSnBnbToBnb(amountInSnBnb);
            }
            _isClaimable = (botUndelegateRequest.endTime != 0);
        }
    }

    function getSlisBnbWithdrawLimit()
        external
        view
        override
        returns (uint256 _slisBnbWithdrawLimit)
    {
        uint256 amountToUndelegate = getAmountToUndelegate();

        _slisBnbWithdrawLimit =
            convertBnbToSnBnb(totalDelegated - amountToUndelegate) - totalSnBnbToBurn;
    }

    /**
     * @return the total amount of BNB staked and reward
     */
    function getDelegated(address _validator) public view override returns (uint256) {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        return IStakeCredit(creditContract).getPooledBNB(address(this));
    }

    /**
     * @return _amount Bnb amount to be undelegated by bot
     */
    function getAmountToUndelegate() public view override returns (uint256 _amount) {
        if (nextUndelegatedRequestIndex == withdrawalQueue.length) {
            return 0;
        }
        for (uint256 i = nextUndelegatedRequestIndex; i < withdrawalQueue.length; ++i) {
            UserRequest storage req = withdrawalQueue[i];
            uint256 amount = req.amount;
            _amount += amount;
        }
    }

    /**
     * @dev Calculates amount of SlisBnb for `_amount` Bnb
     */
    function convertBnbToSnBnb(uint256 _amount)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalShares = ISLisBNB(slisBnb).totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInSlisBnb = (_amount * totalShares) / totalPooledBnb;

        return amountInSlisBnb;
    }

    /**
     * @dev Calculates amount of Bnb for `_amountInSlisBnb` SlisBnb
     */
    function convertSnBnbToBnb(uint256 _amountInSlisBnb)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalShares = ISLisBNB(slisBnb).totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInBnb = (_amountInSlisBnb * totalPooledBnb) / totalShares;

        return amountInBnb;
    }

    /**
     * @dev Flips the pause state
     */
    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }

    /**
     * @dev Flips the vote power flag
     */
    function toggleVote() external onlyRole(DEFAULT_ADMIN_ROLE) {
        delegateVotePower = !delegateVotePower;
    }

    receive() external payable {
        if (msg.sender != STAKE_HUB && msg.sender != redirectAddress) {
            AddressUpgradeable.sendValue(payable(redirectAddress), msg.value);
        }
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Accessible only by Manager");
        _;
    }

    modifier onlyRedirectAddress() {
        require(msg.sender == redirectAddress, "Accessible only by RedirectAddress");
        _;
    }
}
