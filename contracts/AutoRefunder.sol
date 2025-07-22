//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IStakeManager} from "./interfaces/IStakeManager.sol";

/**
 * @title Commission Auto Refunder
 * @author Lista
 * @notice This contract is used to refund the commission to ListaStakeManager and send the rest to the vault
 */
contract AutoRefunder is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    /// @dev Address of the stakeManager contract to be refunded to
    address public stakeManager;

    /// @dev Address of the multisig vault to receive the rest of BNB
    address public vault;

    /// @dev Percentage of the refund that will be sent to stakeManager;
    /// The rest will be sent to the vault. The default is 60% to stakeManager and 40% to vault
    uint256 public refundRatio;

    /// @dev Number of days to split the refund BNB; The default is 30 days
    uint256 public refundDays;

    uint256 constant DENOMINATOR = 10000;

    bytes32 public constant MANAGER = keccak256("MANAGER");
    bytes32 public constant BOT = keccak256("BOT");
    bytes32 public constant PAUSER = keccak256("PAUSER");

    event AutoRefund(
        address indexed stakeManager,
        address indexed vault,
        uint256 refundAmount,
        uint256 vaultAmount,
        uint256 refundDays
    );
    event EmergencyWithdrawal(address to, uint256 bnbAmount);
    event RefundRatioChanged(uint256 newRatio);
    event RefundDaysChanged(uint256 newDays);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _admin Address of the admin
     * @param _manager Address of the manager
     * @param _bot Address of the bot
     * @param _pauser Address of the pauser
     * @param _stakeManager Address of ListaStakeManager
     * @param _vault Address of the multisig vault to receive the rest of the funds
     */
    function initialize(
        address _admin,
        address _manager,
        address _bot,
        address _pauser,
        address _stakeManager,
        address _vault
    ) external initializer {
        require(_admin != address(0), "Invalid admin address");
        require(_manager != address(0), "Invalid manager address");
        require(_bot != address(0), "Invalid bot address");
        require(_pauser != address(0), "Invalid pauser address");
        require(_stakeManager != address(0), "Invalid stake manager address");
        require(_vault != address(0), "Invalid vault address");

        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        stakeManager = _stakeManager;
        vault = _vault;
        refundRatio = 6000;
        refundDays = 30;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER, _manager);
        _grantRole(BOT, _bot);
        _grantRole(PAUSER, _pauser);
    }

    /// @dev bot calls this function to refund the commission to stakeManager and send the rest to the vault
    function autoRefund() external onlyRole(BOT) whenNotPaused {
        require(address(this).balance > 0, "No BNB to refund");
        uint256 refundAmount = (address(this).balance * refundRatio) / DENOMINATOR;
        uint256 vaultAmount = address(this).balance - refundAmount;

        if (refundAmount > 0) {
            IStakeManager(stakeManager).refundCommission{value: refundAmount}(refundDays);
        }

        if (vaultAmount > 0) {
            (bool success,) = vault.call{value: vaultAmount}("");
            require(success, "Transfer failed");
        }

        emit AutoRefund(stakeManager, vault, refundAmount, vaultAmount, refundDays);
    }

    /// @dev manager set the refund ratio
    function changeRefundRatio(uint256 _refundRatio) external whenNotPaused onlyRole(MANAGER) {
        require(_refundRatio > 0 && _refundRatio < DENOMINATOR, "Invalid refund ratio");
        require(_refundRatio != refundRatio, "Same refund ratio");
        refundRatio = _refundRatio;

        emit RefundRatioChanged(_refundRatio);
    }

    /// @dev manager can change the number of days to split the refund BNB
    function changeRefundDays(uint256 _refundDays) external whenNotPaused onlyRole(MANAGER) {
        require(_refundDays > 0 && _refundDays != refundDays, "Invalid refund days");
        refundDays = _refundDays;

        emit RefundDaysChanged(_refundDays);
    }

    /// @dev manager can withdraw all BNB from this contract in case of emergency
    function emergencyWithdraw() external onlyRole(MANAGER) {
        uint256 balance = address(this).balance;
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, "Transfer failed");

        emit EmergencyWithdrawal(msg.sender, balance);
    }

    /// @dev pause the contract
    function pause() external onlyRole(PAUSER) {
        _pause();
    }

    /// @dev unpause the contract
    function unpause() external onlyRole(MANAGER) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    receive() external payable {}
}
