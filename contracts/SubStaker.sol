//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/IAccessControlUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {ISubStaker} from "./interfaces/ISubStaker.sol";
import {IStakeHub} from "./interfaces/IStakeHub.sol";
import {IStakeCredit} from "./interfaces/IStakeCredit.sol";

/**
 * @title SubStaker
 * @author Lista DAO
 * @notice A second BNB delegator identity owned by ListaStakeManager.
 *
 * @dev govBNB is ERC20Votes: one delegatee per account, and neither govBNB nor StakeCredit shares
 *      can be transferred, so splitting Lista's voting power needs a second account that stakes in
 *      its own name. It holds the validators marked `subValidator` on the manager.
 *
 *      Two invariants make it safe to hand pool funds to: `stakeManager` is the only caller of
 *      every state-changing function, and the only address BNB can be sent to (see `_send`).
 *
 *      Entry points mirror `IStakeHub`'s signatures, so the manager has one call site.
 */
contract SubStaker is ISubStaker, Initializable, UUPSUpgradeable {
    address private constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    address private constant GOV_BNB = 0x0000000000000000000000000000000000002005;

    // Owner of the manager proxy's ProxyAdmin; see ListaStakeManager.TIMELOCK
    address private constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

    // The ListaStakeManager that owns this contract
    address public override stakeManager;

    error NotStakeManager();
    error NotAdmin();
    error ZeroAddress();
    error TransferFailed();
    error NothingToClaim();

    modifier onlyStakeManager() {
        if (msg.sender != stakeManager) revert NotStakeManager();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _stakeManager - Address of the ListaStakeManager proxy
     */
    function initialize(address _stakeManager) external override initializer {
        if (_stakeManager == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();

        stakeManager = _stakeManager;
    }

    /**
     * @dev Delegates the BNB sent along with the call to `_validator`
     * @param _validator - Operator address of the BSC validator node
     * @notice The vote power flag is hardcoded false; only `setVoteDelegatee` moves voting power
     */
    function delegate(address _validator, bool) external payable onlyStakeManager {
        IStakeHub(STAKE_HUB).delegate{value: msg.value}(_validator, false);
    }

    /**
     * @param _validator - Operator address of the BSC validator node
     * @param _shares - Amount of StakeCredit shares to undelegate
     */
    function undelegate(address _validator, uint256 _shares) external onlyStakeManager {
        IStakeHub(STAKE_HUB).undelegate(_validator, _shares);
    }

    /**
     * @dev Claims matured unbond requests and forwards the exact proceeds to the manager
     * @param _validator - Operator address of the BSC validator node
     * @param _requestNumber - Number of unbond requests to claim; 0 means all
     * @notice Only the claimed amount is forwarded, so a donation cannot be read as proceeds
     */
    function claim(address _validator, uint256 _requestNumber) external onlyStakeManager {
        uint256 balanceBefore = address(this).balance;
        IStakeHub(STAKE_HUB).claim(_validator, _requestNumber);
        uint256 amount = address(this).balance - balanceBefore;
        if (amount == 0) revert NothingToClaim();

        _send(amount);
    }

    /**
     * @dev Moves a position between validators within this account; no unbonding period
     * @param _srcValidator - Operator address to move away from
     * @param _dstValidator - Operator address to move to
     * @param _shares - Amount of StakeCredit shares to move
     */
    function redelegate(address _srcValidator, address _dstValidator, uint256 _shares, bool) external onlyStakeManager {
        IStakeHub(STAKE_HUB).redelegate(_srcValidator, _dstValidator, _shares, false);
    }

    /**
     * @dev Points this account's entire govBNB balance at `_delegatee`
     * @param _delegatee - Address to receive the voting power
     * @notice Callable by the manager's DEFAULT_ADMIN_ROLE. Moves voting power, never BNB
     */
    function setVoteDelegatee(address _delegatee) external override {
        if (!IAccessControlUpgradeable(stakeManager).hasRole(0x00, msg.sender)) revert NotAdmin();

        IVotesUpgradeable(GOV_BNB).delegate(_delegatee);

        emit VoteDelegateeSet(_delegatee);
    }

    /// @dev Sends stranded BNB home; open to anyone because the destination is fixed
    function sweep() external override {
        uint256 amount = address(this).balance;
        _send(amount);

        emit Swept(amount);
    }

    /**
     * @param _validator - Operator address of the BSC validator node
     * @return pooled - Delegated BNB including rewards
     * @return locked - BNB currently unbonding
     * @return shares - StakeCredit shares held
     * @return claimable - BNB of matured unbond requests
     */
    function position(address _validator)
        external
        view
        override
        returns (uint256 pooled, uint256 locked, uint256 shares, uint256 claimable)
    {
        IStakeCredit credit = IStakeCredit(IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator));

        pooled = credit.getPooledBNB(address(this));
        locked = credit.lockedBNBs(address(this), 0);
        shares = credit.balanceOf(address(this));

        uint256 count = credit.claimableUnbondRequest(address(this));
        for (uint256 i = 0; i < count; ++i) {
            claimable += credit.unbondRequest(address(this), i).bnbAmount;
        }
    }

    /// @return The address this account's voting power currently points at
    function voteDelegatee() external view override returns (address) {
        return IVotesUpgradeable(GOV_BNB).delegates(address(this));
    }

    /// @return The govBNB balance of this account
    function govVotes() external view override returns (uint256) {
        return IERC20Upgradeable(GOV_BNB).balanceOf(address(this));
    }

    /// @dev The only place BNB leaves this contract, and the destination is not a parameter
    function _send(uint256 _amount) private {
        if (_amount == 0) return;

        (bool success,) = stakeManager.call{value: _amount}("");
        if (!success) revert TransferFailed();
    }

    /// @dev An upgrade can redirect staked BNB, so this sits with the timelock, not DEFAULT_ADMIN
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != TIMELOCK) revert NotAdmin();
    }

    /// @dev StakeCredit pays out with `call{gas: transferGasLimit}`, 5000 on BSC today. Must
    ///      stay empty - one SSTORE here makes every `claim` revert.
    receive() external payable {}

    uint256[49] private __gap;
}
