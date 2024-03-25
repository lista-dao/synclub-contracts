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
import {IStaking} from "./interfaces/INativeStaking.sol";

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
    address private bcValidator;

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

    address private constant NATIVE_STAKING = 0x0000000000000000000000000000000000002001;

    mapping(address => bool) public validators;

    uint256 private pendingUndelegatedQuota; // the amount Bnb to be used in the next `undelegateFrom`
    uint256 private undelegatedQuota; // the amount Bnb received but not claimable yet
    uint256 public nextUndelegatedRequestIndex; // the index of next request to be delegated in queue
    UserRequest[] internal withdrawalQueue; // queue for requested withdrawals

    mapping(uint256 => uint256) public requestIndexMap; // uuid => index in withdrawalQueue

    uint256 private slisBnbToBurnQuota; // the amount of slisBnb has been undelgated but not burned yet

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
        bcValidator = _validator;
        synFee = _synFee;
        revenuePool = _revenuePool;

        emit SetManager(_manager);
        emit SetBCValidator(bcValidator);
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
     * @dev Allows bot to delegate users' funds to native staking contract without reserved BNB
     * @return _amount - Amount of funds transferred for staking
     * @notice The amount should be greater than minimum delegation on native staking contract
     */
    function delegate()
        external
        payable
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _amount)
    {
        uint256 relayFee = IStaking(NATIVE_STAKING).getRelayerFee();
        uint256 relayFeeReceived = msg.value;
        _amount = amountToDelegate - (amountToDelegate % TEN_DECIMALS);

        require(relayFeeReceived == relayFee, "Insufficient RelayFee");
        require(_amount >= IStaking(NATIVE_STAKING).getMinDelegation(), "Insufficient Deposit Amount");

        amountToDelegate = amountToDelegate - _amount;
        totalDelegated += _amount;

        // delegate through native staking contract
        IStaking(NATIVE_STAKING).delegate{value: _amount + msg.value}(bcValidator, _amount);

        emit Delegate(_amount);
    }

    /**
     * @dev Allows bot to delegate users' funds + reserved BNB to native staking contract
     * @return _amount - Amount of funds transferred for staking
     * @notice The amount should be greater than minimum delegation on native staking contract
     */
    function delegateWithReserve()
        external
        payable
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _amount)
    {
        uint256 relayFee = IStaking(NATIVE_STAKING).getRelayerFee();
        uint256 relayFeeReceived = msg.value;
        _amount = amountToDelegate - (amountToDelegate % TEN_DECIMALS);

        require(relayFeeReceived == relayFee, "Insufficient RelayFee");
        require(totalReserveAmount >= reserveAmount, "Insufficient Reserve Amount");
        require(_amount + reserveAmount >= IStaking(NATIVE_STAKING).getMinDelegation(), "Insufficient Deposit Amount");

        amountToDelegate = amountToDelegate - _amount;
        totalDelegated += _amount;

        // delegate through native staking contract
        IStaking(NATIVE_STAKING).delegate{value: _amount + msg.value + reserveAmount}(bcValidator, _amount + reserveAmount);

        emit Delegate(_amount);
        emit DelegateReserve(reserveAmount);
    }

    /**
     * @dev Allows bot to delegate users' funds to native staking contract without reserved BNB
     * @param _validator - Address of the validator to delegate to
     * @param _amt - Amount of BNB to delegate
     * @notice The amount should be greater than minimum delegation on native staking contract
     */
    function delegateTo(address _validator, uint256 _amt)
        external
        payable
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _amount)
    {
        require(amountToDelegate >= _amt, "Not enough BNB to delegate");
        uint256 relayFee = IStaking(NATIVE_STAKING).getRelayerFee();
        uint256 relayFeeReceived = msg.value;
        _amount = _amt - (_amt % TEN_DECIMALS);

        require(validators[_validator] == true, "Inactive validator");
        require(relayFeeReceived == relayFee, "Insufficient RelayFee");
        require(_amount >= IStaking(NATIVE_STAKING).getMinDelegation(), "Insufficient Deposit Amount");

        amountToDelegate = amountToDelegate - _amount;
        totalDelegated += _amount;

        // delegate through native staking contract
        IStaking(NATIVE_STAKING).delegate{value: _amount + msg.value}(_validator, _amount);

        emit DelegateTo(_validator, _amount);
    }

    function redelegate(address srcValidator, address dstValidator, uint256 amount)
        external
        payable
        override
        whenNotPaused
        onlyManager
        returns (uint256 _amount)
    {
        uint256 relayFee = IStaking(NATIVE_STAKING).getRelayerFee();
        uint256 relayFeeReceived = msg.value;

        require(srcValidator != dstValidator, "Invalid Redelegation");
        require(validators[dstValidator], "Inactive dst validator");
        require(relayFeeReceived == relayFee, "Insufficient RelayFee");
        require(amount >= IStaking(NATIVE_STAKING).getMinDelegation(), "Insufficient Deposit Amount");

        // redelegate through native staking contract
        IStaking(NATIVE_STAKING).redelegate{value: msg.value}(srcValidator, dstValidator, amount);

        emit ReDelegate(srcValidator, dstValidator, amount);

        return amount;
    }

    /**
     * @dev Allows bot to compound rewards
     */
    function compoundRewards()
        external
        override
        whenNotPaused
        onlyRole(BOT)
    {
        require(totalDelegated > 0, "No funds delegated");

        uint256 amount = IStaking(NATIVE_STAKING).claimReward();

        if (synFee > 0) {
            uint256 fee = amount * synFee / TEN_DECIMALS;
            require(revenuePool != address(0x0), "revenue pool not set");
            AddressUpgradeable.sendValue(payable(revenuePool), fee);
            amount -= fee;
        }

        amountToDelegate += amount;

        emit RewardsCompounded(amount);
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
        UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];
        uint256 amount;
        if (request.uuid != 0) {
            // new logic
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

    function claimAllWithdrawals() external override whenNotPaused {
        address user = msg.sender;
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[user];

        uint256 amount = 0;

        require(userRequests.length > 0, "no request claimable");
        uint256 count =userRequests.length;
        while (count != 0) { // iterate from end to head
            uint256 idx_ = count - 1;
            WithdrawalRequest storage withdrawRequest = userRequests[idx_];
            uint256 uuid = withdrawRequest.uuid;
            UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];

            if ((request.uuid == 0 && uuidToBotUndelegateRequestMap[uuid].endTime == 0)
                || (request.uuid != 0 && uuid >= nextConfirmedRequestUUID)) {
                count -= 1;
                continue; // Skip requests which are Not claimable yet
            }

            if (request.uuid != 0) {
                amount += request.amount;
            } else {
                // old logic
                uint256 amountInSlisBnb = withdrawRequest.amountInSnBnb;
                BotUndelegateRequest
                    storage botUndelegateRequest = uuidToBotUndelegateRequestMap[uuid];

                uint256 totalBnbToWithdraw_ = botUndelegateRequest.amount;
                uint256 totalSlisBnbToBurn_ = botUndelegateRequest.amountInSnBnb;
                uint256 _amount = (totalBnbToWithdraw_ * amountInSlisBnb) /
                    totalSlisBnbToBurn_;
                amount += _amount;
            }

            count -= 1;
            userRequests[idx_] = userRequests[userRequests.length - 1];
            userRequests.pop();
        }

        require(amount > 0, "nothing to claim");
        AddressUpgradeable.sendValue(payable(user), amount);

        emit ClaimAllWithdrawals(user, amount);
    }

    /**
     * @dev Bot uses this function to get amount of BNB to withdraw
     * @return _uuid - unique id against which this Undelegation event was logged
     * @return _amount - Amount of funds required to Unstake
     */
    function undelegate()
        external
        payable
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount)
    {
        require(totalSnBnbToBurn > 0, "Nothing to undelegate");

        uint256 relayFee = IStaking(NATIVE_STAKING).getRelayerFee();
        uint256 relayFeeReceived = msg.value;
        require(relayFeeReceived == relayFee, "Insufficient RelayFee");

        // old logic, handle history data
	require(withdrawalQueue.length > 0, "No request received");
        _uuid = withdrawalQueue[0].uuid > 0 ? withdrawalQueue[0].uuid - 1 : requestUUID;
        uint256 totalSlisBnbToBurn_ = totalSnBnbToBurn; // To avoid Reentrancy attack
        _amount = convertSnBnbToBnb(totalSlisBnbToBurn_);
        _amount -= _amount % TEN_DECIMALS;

        require(
            _amount + reserveAmount >= IStaking(NATIVE_STAKING).getMinDelegation(),
            "Insufficient Withdraw Amount"
        );

        uuidToBotUndelegateRequestMap[_uuid] = BotUndelegateRequest({
            startTime: block.timestamp,
            endTime: 0,
            amount: _amount,
            amountInSnBnb: totalSlisBnbToBurn_
        });

        totalDelegated -= _amount;
        totalSnBnbToBurn = 0;

        ISLisBNB(slisBnb).burn(address(this), totalSlisBnbToBurn_);

        // undelegate through native staking contract
        IStaking(NATIVE_STAKING).undelegate{value: msg.value}(bcValidator, _amount + reserveAmount);

        emit UndelegateReserve(reserveAmount);
    }

    /**
     * @dev Bot uses this function to get amount of BNB to withdraw
     * @param _validator - Validator to undelegate from
     * @param _amt - Amount of BNB to undelegate
     * @return _nextUndelegatedRequestIndex - the next request index to be undelegated
     * @return _amount - Amount of funds required to Unstake
     */
    function undelegateFrom(address _validator, uint256 _amt)
        external
        payable
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _nextUndelegatedRequestIndex, uint256 _amount)
    {
        require(totalDelegated >= _amt, "Not enough BNB to undelegate");
        uint256 relayFee = IStaking(NATIVE_STAKING).getRelayerFee();
        uint256 relayFeeReceived = msg.value;

        require(relayFeeReceived == relayFee, "Insufficient RelayFee");
        // old requests need to be processed by undelegate first
        require(totalSnBnbToBurn == 0, "Not able to undelegate yet");

        _amount = _amt - _amt % TEN_DECIMALS;
        require(
            _amount >= IStaking(NATIVE_STAKING).getMinDelegation(),
            "Insufficient Withdraw Amount"
        );

        // calculate the amount of SnBnb to burn
        uint256 totalSnBnbToBurn_ = 0;
        pendingUndelegatedQuota += _amount;
        for (uint256 i = nextUndelegatedRequestIndex; i < withdrawalQueue.length; ++i) {
            UserRequest storage req = withdrawalQueue[i];
            if (req.amount > pendingUndelegatedQuota) {
                break;
            }
            pendingUndelegatedQuota -= req.amount;
            totalSnBnbToBurn_ += req.amountInSlisBnb;
            ++nextUndelegatedRequestIndex;
        }

        // sisBnbToBurnQuota = real total supply - total supply to burn - (total pooled bnb * exchange rate)
        slisBnbToBurnQuota = ISLisBNB(slisBnb).totalSupply() - totalSnBnbToBurn_ - convertBnbToSnBnb(getTotalPooledBnb() - _amount);
        totalDelegated -= _amount;

        if (totalSnBnbToBurn_ > 0) {
            ISLisBNB(slisBnb).burn(address(this), totalSnBnbToBurn_);
        }

        // undelegate through native staking contract
        IStaking(NATIVE_STAKING).undelegate{value: msg.value}(_validator, _amount);
        _nextUndelegatedRequestIndex = nextUndelegatedRequestIndex;

        emit Undelegate(nextUndelegatedRequestIndex, _amount);
    }

    function claimUndelegated()
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount)
    {
        // Bot only can claim after undelegated all old requests
        require(totalSnBnbToBurn == 0, "Not able to claim yet");
        uint256 undelegatedAmount = IStaking(NATIVE_STAKING).claimUndelegated();
        require(undelegatedAmount > 0 && withdrawalQueue.length > 0, "Nothing to claim");
        undelegatedQuota += undelegatedAmount;

        uint256 oldLastUUID = withdrawalQueue[0].uuid > 0 ? withdrawalQueue[0].uuid - 1 : requestUUID;
        for (uint256 i = nextConfirmedRequestUUID; i <= oldLastUUID; ++i) {
            BotUndelegateRequest storage botRequest = uuidToBotUndelegateRequestMap[i];
            if (undelegatedQuota < botRequest.amount) {
                return (0, 0);
            }
            botRequest.endTime = block.timestamp;
            undelegatedQuota -= botRequest.amount;
            ++nextConfirmedRequestUUID;
        }

        // new logic
        for (uint256 i = nextConfirmedRequestUUID; i <= requestUUID; ++i) {
            UserRequest storage req = withdrawalQueue[requestIndexMap[i]];
            if (req.uuid == 0 || req.amount > undelegatedQuota) {
                break;
            }
            undelegatedQuota -= req.amount;
            ++nextConfirmedRequestUUID;
        }

        _uuid = nextConfirmedRequestUUID;
        _amount = undelegatedAmount;

        emit ClaimUndelegated(_uuid, _amount);
    }

    function claimFailedDelegation(bool withReserve)
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _amount)
    {
        uint256 failedAmount = IStaking(NATIVE_STAKING).claimUndelegated();
        if (withReserve) {
            require(failedAmount >= reserveAmount, "Wrong reserve amount for delegation");
            amountToDelegate += failedAmount - reserveAmount;
            totalDelegated -= failedAmount -reserveAmount;
        } else {
            amountToDelegate += failedAmount;
            totalDelegated -= failedAmount;
        }

        emit ClaimFailedDelegation(failedAmount, withReserve);
        return failedAmount;
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

    /// @param _address - Beck32 decoding of Address of Validator Wallet on Beacon Chain with `0x` prefix
    function setBCValidator(address _address)
        external
        override
        onlyManager
    {
        require(bcValidator != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        bcValidator = _address;

        emit SetBCValidator(_address);
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
            address _bcValidator
        )
    {
        _manager = manager;
        _slisBnb = slisBnb;
        _bcValidator = bcValidator;
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
        _isClaimable = uuid < nextConfirmedRequestUUID;

        UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];
        if (request.uuid != 0) {
            // new logic
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
     * @return relayFee required by Native Staking contract
     */
    function getRelayFee() public view override returns (uint256) {
        return IStaking(NATIVE_STAKING).getRelayerFee();
    }

    /**
     * @return the timestamp to be able to invole `undelegate`
     */
    function getPendingUndelegateTime(address validator) external view override returns (uint256) {
        return IStaking(NATIVE_STAKING).getPendingUndelegateTime(address(this), validator);
    }

    /**
     * @return delegated amount to given validator
     */
    function getDelegated(address validator) public view override returns (uint256) {
        return IStaking(NATIVE_STAKING).getDelegated(address(this), validator);
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
         _amount -= pendingUndelegatedQuota;
    }

    /**
    * @dev Returns the total supply of slisBNB
    */
    function totalShares() public view override returns (uint256) {
        return ISLisBNB(slisBnb).totalSupply() - slisBnbToBurnQuota;
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
        uint256 _totalShares = totalShares();
        _totalShares = _totalShares == 0 ? 1 : _totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInSlisBnb = (_amount * _totalShares) / totalPooledBnb;

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
        uint256 _totalShares = totalShares();
        _totalShares = _totalShares == 0 ? 1 : _totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInBnb = (_amountInSlisBnb * totalPooledBnb) / _totalShares;

        return amountInBnb;
    }

    /**
     * @dev Add the existing BC validator to whitelist
     */
    function whitelistBcValidator()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!validators[bcValidator], "BC Validator whitelisted");
        require(bcValidator != address(0), "zero address provided");

        validators[bcValidator] = true;

        emit WhitelistValidator(bcValidator);
    }

    /**
     * @dev Flips the pause state
     */
    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }

    receive() external payable {
        if (msg.sender != NATIVE_STAKING && msg.sender != redirectAddress) {
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
