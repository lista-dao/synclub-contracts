//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import "./libraries/SLisLibrary.sol";

import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {ISLisBNB} from "./interfaces/ISLisBNB.sol";
import {IStakeHub} from "./interfaces/IStakeHub.sol";
import {IStakeCredit} from "./interfaces/IStakeCredit.sol";

/**
 * @title Stake Manager Contract
 * @author Lista
 * @notice This contract handles the liquid staking of BNB on BSC through the native StakeHub contract
 */
contract ListaStakeManager is
    IStakeManager,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Deprecated variable
    uint256 public placeholder;

    // Total delegations including unbonding BNB
    uint256 public totalDelegated;

    // Total available BNB for the next delegation
    uint256 public amountToDelegate;

    // Global UUID for each withdrawal request
    uint256 public requestUUID;

    // UUID for the next confirmed request; req whose uuid < nextConfirmedRequestUUID is claimable
    uint256 public nextConfirmedRequestUUID;

    // Buffer amount for undelegation
    uint256 public reserveAmount;

    // Reserved BNB amount from redirect address
    uint256 public totalReserveAmount;

    // Address of SlisBnb Token
    address private slisBnb;

    // Deprecated variable; the initial BSC validator funds will be migrated to
    address private bscValidator;

    // Deprecated variable
    mapping(uint256 => BotUndelegateRequest) private uuidToBotUndelegateRequestMap;

    // User's address => WithdrawalRequest[]
    mapping(address => WithdrawalRequest[]) private userWithdrawalRequests;

    uint256 public constant TEN_DECIMALS = 1e10;
    bytes32 public constant BOT = keccak256("BOT");

    // Guardian role can pause the contract
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    address private manager;
    address private proposedManager;

    // Protocol fee rate charged on staking rewards; range {0-10_000_000_000}
    // 5% as of Oct 2024
    uint256 public synFee;

    address public revenuePool;
    address public redirectAddress;

    address private constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    address private constant GOV_BNB = 0x0000000000000000000000000000000000002005;

    // Validators are whitelisted or not
    // The operator address of the validator => true/false
    mapping(address => bool) public validators;

    // Whether to delegate voting power to validator or not on delegation and re-delegation
    bool public delegateVotePower;

    // The amount Bnb received but not claimable yet
    uint256 public undelegatedQuota;

    // The queue for requested withdrawals
    UserRequest[] internal withdrawalQueue;

    // The mapping used to find the index in withdrawalQueue by uuid
    // uuid => index in withdrawalQueue
    mapping(uint256 => uint256) public requestIndexMap;

    // Address of the credit contracts
    address[] public creditContracts;

    // States of credit contracts; use mapping to reduce gas of `receive()`
    // credit contract address => true/false
    mapping(address => bool) public creditStates;

    // The amount of BNB unbonding in fly; precise bnb amount
    uint256 public unbondingBnb;

    // The minimum amount of BNB required for a withdrawal
    uint256 public minBnb;

    // principal * annualRate / 365; range {0-10_000_000_000}
    // 0.1% as of Oct 2024
    uint256 public annualRate;

    // ListaDao validator commission refund
    Refund public refund;

    // manager role to refund commission
    bytes32 public constant MANAGER = keccak256("MANAGER");

    struct Refund {
        uint256 dailySlisBnb; // daily slisBnb to be burned
        uint256 remainingSlisBnb; // remaining slisBnb amount to be burned
        uint256 lastBurnTime; // last burn time
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _slisBnb - Address of SlisBnb Token on BNB Smart Chain
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
     * @dev Allows user to deposit Bnb and mint SlisBnb
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
     * @dev Allows bot to delegate users' funds to given BSC validator
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

        IStakeHub(STAKE_HUB).delegate{value: _amount}(_validator, delegateVotePower);

        emit DelegateTo(_validator, _amount, delegateVotePower);
    }

    /**
     * @param srcValidator the operator address of the validator to be redelegated from
     * @param dstValidator the operator address of the validator to be redelegated to
     * @param _amount the bnb amount to be redelegated
     */
    function redelegate(address srcValidator, address dstValidator, uint256 _amount)
        external
        override
        whenNotPaused
        onlyRole(BOT)
    {
        require(srcValidator != dstValidator, "Invalid Redelegation");
        require(validators[dstValidator], "Inactive dst validator");

        uint256 shares = convertBnbToShares(srcValidator, _amount);

        // redelegate through native staking contract
        IStakeHub(STAKE_HUB).redelegate(srcValidator, dstValidator, shares, delegateVotePower);

        emit ReDelegate(srcValidator, dstValidator, shares);
    }

    /**
     * @dev Allow users to request to unstake BNB.
     * @param _amountInSlisBnb - Amount of SlisBnb to swap for withdraw
     * @notice User must have approved this contract to spend SlisBnb
     */
    function requestWithdraw(uint256 _amountInSlisBnb)
        external
        override
        whenNotPaused
    {
        require(_amountInSlisBnb > 0, "Invalid slisBnb Amount");

        uint256 bnbToWithdraw = convertSnBnbToBnb(_amountInSlisBnb);
        require(bnbToWithdraw > minBnb, "Bnb amount is too small to withdraw");

        uint256 totalAmount = bnbToWithdraw;
        uint256 totalAmountInSlisBnb = _amountInSlisBnb;
        if (withdrawalQueue.length != 0) {
            totalAmount += withdrawalQueue[requestIndexMap[requestUUID]].totalAmount;
            totalAmountInSlisBnb += withdrawalQueue[requestIndexMap[requestUUID]].totalAmountInSlisBnb;
        }

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
                amountInSlisBnb: _amountInSlisBnb,
                totalAmount: totalAmount,
                totalAmountInSlisBnb: totalAmountInSlisBnb
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

    /**
     * @dev Users use this function to claim the requested withdrawals
     * @param _idx - The index of the request in the array returns by getUserWithdrawalRequests()
     */
    function claimWithdraw(uint256 _idx) external override whenNotPaused {
        _claimWithdrawFor(msg.sender, _idx);
    }

    /**
     * @dev This function allows to claim the requested withdrawals for other users; only bot can call this function
     * @param _user - The address of the user who raised WithdrawRequest
     * @param _idx - The index of the request in the array returns by getUserWithdrawalRequests()
     */
    function claimWithdrawFor(address _user, uint256 _idx) external override whenNotPaused onlyRole(BOT) {
        _claimWithdrawFor(_user, _idx);
    }

    function _claimWithdrawFor(address _user, uint256 _idx) private {
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[_user];

        require(_idx < userRequests.length, "Invalid index");

        WithdrawalRequest storage withdrawRequest = userRequests[_idx];
        uint256 uuid = withdrawRequest.uuid;
        uint256 amount;

        // 1. queue.length == 0 => old request
        // 2. queue.length > 0 && uuid < queue[0].uuid => old request
        // 3. queue.length > 0 && uuid >= queue[0].uuid => new request

        if (withdrawalQueue.length != 0 && uuid >= withdrawalQueue[0].uuid) {
            // new request
            UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];
            require(uuid < nextConfirmedRequestUUID, "Not able to claim yet");
            amount = request.amount;
        } else {
            // old request
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

        AddressUpgradeable.sendValue(payable(_user), amount);

        emit ClaimWithdrawal(_user, _idx, amount);
    }

    /**
     * @dev Deprecated after fusion
     */
    function undelegate() external override whenNotPaused onlyRole(BOT) returns (uint256 _uuid, uint256 _amount) {
        revert("not supported");
    }

    /**
     * @dev Bot uses this function to undelegate BNB from a validator
     * @param _operator - Operator address of validator to undelegate from
     * @param _amount - Amount of bnb to undelegate
     * @return _actualBnbAmount - the actual amount of BNB to be undelegated
     */
    function undelegateFrom(address _operator, uint256 _amount)
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _actualBnbAmount)
    {
        require(_amount <= (getAmountToUndelegate() + reserveAmount), "Given bnb amount is too large");
        uint256 _shares = convertBnbToShares(_operator, _amount);
        _actualBnbAmount = convertSharesToBnb(_operator, _shares);

        unbondingBnb += _actualBnbAmount;
        IStakeHub(STAKE_HUB).undelegate(_operator, _shares);

        emit UndelegateFrom(_operator, _actualBnbAmount, _shares);
    }

    /**
     * @dev Bot uses this function to claim unbonded BNB and rewards from a validator
     * @param _validator - The operator address of the validator
     * @return _uuid - the next confirmed request uuid
     * @return _amount - the amount of BNB claimed, staking rewards included
     */
    function claimUndelegated(address _validator)
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount)
    {
        uint256 balanceBefore = address(this).balance;
        IStakeHub(STAKE_HUB).claim(_validator, 0);
        require(address(this).balance > balanceBefore, "Nothing to claim");
        uint256 undelegatedAmount = address(this).balance - balanceBefore;

        undelegatedQuota += undelegatedAmount;
        unbondingBnb -= undelegatedAmount;

        uint256 coveredAmount = 0;
        uint256 coveredSlisBnbAmount = 0;

        if (withdrawalQueue.length != 0 && withdrawalQueue[withdrawalQueue.length - 1].uuid >= nextConfirmedRequestUUID) {
            uint256 startIndex = requestIndexMap[nextConfirmedRequestUUID];
            uint256 coveredMaxIndex = binarySearchCoveredMaxIndex(undelegatedQuota);
            uint256 totalAmount = withdrawalQueue[coveredMaxIndex].totalAmount - withdrawalQueue[startIndex].totalAmount + withdrawalQueue[startIndex].amount;
            uint256 totalAmountInSlisBnb = withdrawalQueue[coveredMaxIndex].totalAmountInSlisBnb - withdrawalQueue[startIndex].totalAmountInSlisBnb + withdrawalQueue[startIndex].amountInSlisBnb;
            // may not have covered any requests when coveredMaxIndex == startIndex
            if (totalAmount <= undelegatedQuota) {
                undelegatedQuota -= totalAmount;
                coveredAmount += totalAmount;
                coveredSlisBnbAmount += totalAmountInSlisBnb;
                nextConfirmedRequestUUID = withdrawalQueue[coveredMaxIndex].uuid + 1;
            }
        }

        totalDelegated -= coveredAmount;
        if (coveredSlisBnbAmount > 0) {
            ISLisBNB(slisBnb).burn(address(this), coveredSlisBnbAmount);
        }

        _uuid = nextConfirmedRequestUUID;
        _amount = undelegatedAmount;

        emit ClaimUndelegatedFrom(_validator, _uuid, _amount);
    }

    /**
     * @dev To prevent DOS attack caused by the large number of requests in the withdrawalQueue.
     *      Use binary search algorithm to find the maximum index
     *      that might be covered in the withdrawalQueue by the given BNB amount
     * @return the maximum index that might be covered in the withdrawalQueue by the given BNB amount
     * @param _bnbAmount - the amount of BNB used to cover withdrawal requests
     */
    function binarySearchCoveredMaxIndex(uint256 _bnbAmount) public view override returns(uint256) {
        require(withdrawalQueue.length != 0 && withdrawalQueue[0].uuid <= nextConfirmedRequestUUID, "No new requests or old requests have not been fully covered");
        if (nextConfirmedRequestUUID > withdrawalQueue[withdrawalQueue.length - 1].uuid) {
            // all requests have been covered
            return 0;
        }
        uint256 startIndex = requestIndexMap[nextConfirmedRequestUUID];
        uint256 endIndex = withdrawalQueue.length - 1;
        uint256 startAmount = withdrawalQueue[startIndex].amount;
        uint256 startTotalAmount = withdrawalQueue[startIndex].totalAmount;

        // covered all requests, which is the common scenario
        if (withdrawalQueue[endIndex].totalAmount - startTotalAmount + startAmount <= _bnbAmount) {
            return endIndex;
        }

        uint256 start = startIndex;
        uint256 end = endIndex;
        while (start <= end) {
            uint256 mid = (start + end) / 2; // startIndex <= mid <= endIndex

            uint256 nextAmount;
            if(mid < endIndex) {
                nextAmount = withdrawalQueue[mid+1].totalAmount - startTotalAmount + startAmount;
            } else {
                // mid == endIndex
                nextAmount = withdrawalQueue[endIndex].totalAmount - startTotalAmount + startAmount;
            }
            uint256 currentAmount = withdrawalQueue[mid].totalAmount - startTotalAmount + startAmount;

            if (nextAmount > _bnbAmount && currentAmount <= _bnbAmount) {
                return mid;
            } else if (nextAmount <= _bnbAmount) {
                if (mid >= endIndex) {
                    return endIndex;
                }
                start = mid + 1;
            } else {
                if (mid <= startIndex) {
                    return startIndex;
                }
                end = mid - 1;
            }
        }

        return startIndex;
    }

    /**
     * @dev Allows to delegate all voting power to a specific address; Need to delegate to stake manager itself to track its voting power
     * @param _delegateTo - Address to delegate voting power to; cancel delegation if address is this contract
     */
    function delegateVoteTo(address _delegateTo) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_delegateTo != address(0), "Invalid Address");

        IVotesUpgradeable govToken = IVotesUpgradeable(GOV_BNB);

        address currentDelegatee = govToken.delegates(address(this));
        require(currentDelegatee != _delegateTo, "Already Delegated");

        uint256 balance = IERC20Upgradeable(GOV_BNB).balanceOf(address(this));

        uint256 newVotePower = govToken.getVotes(_delegateTo);
        uint256 currentVotePower = govToken.getVotes(currentDelegatee);
        govToken.delegate(_delegateTo);
        require(govToken.delegates(address(this)) == _delegateTo, "Delegation Failed");

        // Check voting power moved correctly
        if (_delegateTo != address(this)) {
            require(govToken.getVotes(address(this)) == 0, "Invalid Delegation");
            uint256 currDelegateeChange = currentVotePower - govToken.getVotes(currentDelegatee);
            uint256 newDelegateeChange = govToken.getVotes(_delegateTo) - newVotePower;

            require(currDelegateeChange == newDelegateeChange && balance == currDelegateeChange, "Invalid Change");
        } else {
            require(govToken.getVotes(address(this)) == balance, "Self-delegation Failed");
        }

        emit DelegateVoteTo(_delegateTo, balance);
    }

    /**
     * @dev Used by Redirect Address to deposit reserved funds
     */
    function depositReserve() external payable override whenNotPaused onlyRedirectAddress {
        uint256 amount = msg.value;
        require(amount > 0, "Invalid Amount");

        totalReserveAmount += amount;
    }

    /**
     * @dev Used by Redirect Address to withdraw reserved funds
     * @param amount - Amount of BNB to withdraw
     */
    function withdrawReserve(uint256 amount) external override whenNotPaused onlyRedirectAddress{
        require(amount <= totalReserveAmount, "Insufficient Balance");
        totalReserveAmount -= amount;
        AddressUpgradeable.sendValue(payable(msg.sender), amount);
    }

    /**
     * @dev Adjust reserve amount. `reserveAmount` is the buffer for undelegation.
     *      Since the actual undelegate amount is slightly smaller than the Bot requested amount due to precision loss,
     *      Bot will add some extra BNB when calling undelegateFrom for the first time, in order to cover the last request.
     * @param amount - Amount of Bnb
     */
    function setReserveAmount(uint256 amount) external override onlyManager {
        reserveAmount = amount;
        emit SetReserveAmount(amount);
    }

    function proposeNewManager(address _address) external override onlyManager {
        require(manager != _address && _address != address(0), "Invalid Address");
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
        require(_address != address(0), "Zero address provided");
        grantRole(BOT, _address);
    }

    function revokeBotRole(address _address) external override {
        require(_address != address(0), "Zero address provided");
        revokeRole(BOT, _address);
    }

    /**
     * @dev Sync the credit contract of a validator and store in the contract
     * @param _validator - the operator address of the validator
     * @param toRemove - if true, remove the credit contract; false to add if non-existent
     */
    function syncCredits(address _validator, bool toRemove) internal {
        address credit = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        if (toRemove) {
            delete creditStates[credit];

            for (uint256 i = 0; i < creditContracts.length; i++) {
                if (creditContracts[i] == credit) {
                    creditContracts[i] = creditContracts[creditContracts.length - 1];
                    creditContracts.pop();
                    break;
                }
            }
            emit SyncCreditContract(_validator, credit, toRemove);
            return;
        } else if (creditStates[credit]) {
            // do nothing if credit already exists
            return;
        }

        creditStates[credit] = true;
        creditContracts.push(credit);

        emit SyncCreditContract(_validator, credit, toRemove);
    }

    /**
     * @dev Sets the operator address of the BSC validator initially delegated to. Call this function after 2nd upgrade done
     * @param _address - the operator address of BSC validator
     */
    function setBSCValidator(address _address)
        external
        override
        onlyManager
    {
        require(bscValidator != _address && _address != address(0), "Invalid Address");

        bscValidator = _address;
        syncCredits(bscValidator, false);

        emit SetBSCValidator(_address);
    }

    /**
     * @dev Sets the protocol fee to be charged on staking rewards
     * @param _synFee - the fee to be charged on rewards; 500_000_000 (5%)
     */
    function setSynFee(uint256 _synFee)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_synFee <= TEN_DECIMALS, "_synFee must not exceed 10000000000 (100%)");
        synFee = _synFee;

        emit SetSynFee(_synFee);
    }

    /**
     * @dev Sets the rate for the protocol fee to be charged on total staked amount
     * @param _annualRate - the rate to be charged on total staked amount; 10_000_000 (0.1%) by default
     */
    function setAnnualRate(uint256 _annualRate)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_annualRate <= TEN_DECIMALS, "_annualRate must not exceed 10000000000 (100%)");
        annualRate = _annualRate;

        emit SetAnnualRate(_annualRate);
    }

    /**
     * @dev Sets the minimum amount of BNB required for a withdrawal
     * @param _amount - the minimum amount of BNB required for a withdrawal
     */
    function setMinBnb(uint256 _amount)
        external
        override
        onlyManager
    {
        require(_amount != minBnb, "Invalid Amount");
        minBnb = _amount;
        emit SetMinBnb(_amount);
    }

    function setRedirectAddress(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(redirectAddress != _address && _address != address(0), "Invalid Address");
        redirectAddress = _address;
        emit SetRedirectAddress(_address);
    }

    function setRevenuePool(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(revenuePool != _address && _address != address(0), "Invalid Address");
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
        syncCredits(_address, false);

        emit WhitelistValidator(_address);
    }

    /**
     * @dev Disables a validator from the contract.
     *      Upon disabled, bot can only undelegete the funds, delegation is not allowed
     * @param _address - the operator address of the validator
     */
    function disableValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(validators[_address], "Validator is not active");
        validators[_address] = false;
        emit DisableValidator(_address);
    }

    /**
     * @dev Removes a disabled validator from the contract
     * @param _address - the operator address of the validator
     */
    function removeValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!validators[_address], "Validator should be inactive");
        require(getDelegated(_address) == 0, "Balance is not zero");

        syncCredits(_address, true);
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

    /**
     * @dev Retrieves the old undelegate request initiated by Bot
     * @param _uuid - UUID of the request; should be uuid of the old stake manager version
     */
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
     * @param _address - Address of the requester
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
            // old requests are always claimable since the migration from BC to BSC has done
            _isClaimable = true;
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
            convertBnbToSnBnb(totalDelegated - amountToUndelegate - unbondingBnb);
    }

    /**
     * @param _validator - the operator address of the validator
     * @return the total amount of BNB staked and reward
     */
    function getDelegated(address _validator) public view override returns (uint256) {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        return IStakeCredit(creditContract).getPooledBNB(address(this)) + IStakeCredit(creditContract).lockedBNBs(address(this), 0);
    }

    /**
     * @dev Bot use this method to get the amount of BNB to call undelegateFrom
     * @return _amountToUndelegate Bnb amount to be undelegated by bot
     */
    function getAmountToUndelegate() public view override returns (uint256 _amountToUndelegate) {
        if (withdrawalQueue.length == 0 || withdrawalQueue[withdrawalQueue.length - 1].uuid < nextConfirmedRequestUUID) {
            return 0;
        }

        uint256 nextIndex = requestIndexMap[nextConfirmedRequestUUID];
        uint256 totalAmountToWithdraw = withdrawalQueue[withdrawalQueue.length - 1].totalAmount - withdrawalQueue[nextIndex].totalAmount + withdrawalQueue[nextIndex].amount;

        _amountToUndelegate = totalAmountToWithdraw > unbondingBnb ? totalAmountToWithdraw - unbondingBnb : 0;

        return _amountToUndelegate >= undelegatedQuota ? _amountToUndelegate - undelegatedQuota : 0;
    }

    /**
     * @dev Query the claimable amount of BNB of a validator
     * @param _validator - the operator address of the validator
     * @return _amount - the amount of BNB claimable
     */
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
     * @dev Calculates amount of Bnb for _shares
     * @param _operator - the operator address of the validator
     * @param _shares - the amount of shares
     * @return the amount of BNB for given shares
     */
    function convertSharesToBnb(address _operator, uint256 _shares)
        public
        view
        override
        returns (uint256)
    {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_operator);
        return IStakeCredit(creditContract).getPooledBNBByShares(_shares);
    }

    /**
     * @dev Calculates amount of shares for _bnbAmount
     * @param _operator - the operator address of the validator
     * @param _bnbAmount - the amount of BNB
     * @return the amount of shares for given BNB
     */
    function convertBnbToShares(address _operator, uint256 _bnbAmount)
        public
        view
        override
        returns (uint256)
    {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_operator);
        return IStakeCredit(creditContract).getSharesByPooledBNB(_bnbAmount);
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

    function getRedelegateFee(uint256 _amount)
        public
        view
        override
        returns (uint256)
    {
        IStakeHub stakeHub = IStakeHub(STAKE_HUB);
        return _amount * stakeHub.redelegateFeeRate() / stakeHub.REDELEGATE_FEE_RATE_BASE();
    }

    /**
     * @dev Flips the pause state by Admin
     */
    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }

    /**
     * @dev Pauses the contract by Guardian
     */
    function pause() external onlyRole(GUARDIAN) {
        _pause();
    }

    /**
     * @dev Flips the vote power flag
     */
    function toggleVote() external onlyRole(DEFAULT_ADMIN_ROLE) {
        delegateVotePower = !delegateVotePower;
    }

    receive() external payable {
        if ((!creditStates[msg.sender]) && msg.sender != redirectAddress) {
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

    /**
     * @dev Allows bot to compound rewards
     */
    function compoundRewards() external override whenNotPaused onlyRole(BOT)
    {
        require(totalDelegated > 0, "No funds delegated");

        uint256 totalBNBInValidators = getTotalBnbInValidators();
        require(totalBNBInValidators + undelegatedQuota > totalDelegated, "No new fee to compound");
        uint256 totalProfit = totalBNBInValidators + undelegatedQuota - totalDelegated;

        uint256 fee = SLisLibrary.calculateFee(totalDelegated, totalProfit, annualRate, synFee, TEN_DECIMALS);

        totalDelegated += totalProfit;
        uint256 slisBNBAmount = convertBnbToSnBnb(fee);
        if (slisBNBAmount > 0) {
            ISLisBNB(slisBnb).mint(revenuePool, slisBNBAmount);
        }

        _burnRefundSlisBnb();
        emit RewardsCompounded(fee);
    }

    function _burnRefundSlisBnb() private {
        if (refund.remainingSlisBnb == 0) return;
        if (block.timestamp / 1 days < (refund.lastBurnTime / 1 days + 1)) return; // burn once a day

        uint256 burnAmount = refund.dailySlisBnb;
        if (burnAmount > refund.remainingSlisBnb) {
            burnAmount = refund.remainingSlisBnb;
            refund.remainingSlisBnb = 0;
            refund.dailySlisBnb = 0;
        } else {
            refund.remainingSlisBnb -= burnAmount;
        }

        refund.lastBurnTime = block.timestamp;
        ISLisBNB(slisBnb).burn(address(this), burnAmount);
    }

    /**
     * @dev Allows manager to refund Lista Dao validator's commission to this contract
     * @param _days - Number of days to split the refund
     */
    function refundCommission(uint256 _days) external payable whenNotPaused onlyRole(MANAGER) {
        require(msg.value > 0 && _days > 0, "Invalid Amount or Days");

        uint256 refundSlisBnb = convertBnbToSnBnb(msg.value);
        uint256 slisBnbAmount = refundSlisBnb + refund.remainingSlisBnb;
        uint256 dailySlisBnb = slisBnbAmount / _days;
        require(dailySlisBnb > 0, "Invalid Daily SlisBnb");

        amountToDelegate += msg.value; // stake the refund amount
        ISLisBNB(slisBnb).mint(address(this), refundSlisBnb); // mint slisBnb then burn daily proportion

        refund.dailySlisBnb = dailySlisBnb;
        refund.remainingSlisBnb = slisBnbAmount;

        emit RefundCommission(msg.value, dailySlisBnb, _days, slisBnbAmount);
    }

    /**
     * @dev Returns the total amount of BNB in all validators
     */
    function getTotalBnbInValidators() public view override returns (uint256) {
        uint256 totalBnb = 0;
        for (uint256 i = 0; i < creditContracts.length; i++) {
            IStakeCredit credit = IStakeCredit(creditContracts[i]);
            if (creditStates[address(credit)]) {
                totalBnb += credit.getPooledBNB(address(this)) + credit.lockedBNBs(address(this), 0);
            }
        }
        return totalBnb;
    }
}
