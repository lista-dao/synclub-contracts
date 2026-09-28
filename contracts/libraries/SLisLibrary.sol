//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

import {IStakeManager} from "../interfaces/IStakeManager.sol";
import {IStakeCredit} from "../interfaces/IStakeCredit.sol";
import {ErrorsLib} from "./ErrorsLib.sol";
import {ISubStaker} from "../interfaces/ISubStaker.sol";

library SLisLibrary {
    function calculateFeeFromDailyProfit(
        uint256 _profit,
        uint256 _synFee,
        uint256 _decimals // 1e10
    ) public returns (uint256 _fee) {
        _fee = (_profit * _synFee) / _decimals;
    }

    function calculateFeeFromAPY(
        uint256 _principal,
        uint256 _annualRate,
        uint256 _decimals // 1e10
    ) public returns (uint256 _fee) {
        _fee = (_principal * _annualRate) / 365 / _decimals;
    }

    function calculateFee(uint256 _principal, uint256 _profit, uint256 _annualRate, uint256 _synFee, uint256 _decimals)
        public
        returns (uint256 _fee)
    {
        uint256 _feeFromAPY = calculateFeeFromAPY(_principal, _annualRate, _decimals);
        uint256 _feeFromProfit = calculateFeeFromDailyProfit(_profit, _synFee, _decimals);

        _fee = _feeFromAPY > _feeFromProfit ? _feeFromAPY : _feeFromProfit;
    }



    /**
     * @dev Reverts unless `_next` may be bound as the manager's SubStaker
     * @param _creditContracts - Every StakeCredit the pool has ever delegated through
     * @param _current - The currently bound SubStaker, or the zero address
     * @param _next - The candidate
     * @param _manager - The ListaStakeManager doing the binding
     * @notice Swapping the address strands whatever the old account holds - the manager stops
     *         counting it, stops routing to it, and cannot unwind it - so shares, the unbonding
     *         queue and the BNB balance must all be clear. Rebinding the same address is a no-op.
     */
    function requireBindable(address[] storage _creditContracts, address _current, address _next, address _manager)
        public
        view
    {
        if (_next == address(0)) revert ErrorsLib.ZeroAddress();
        if (ISubStaker(_next).stakeManager() != _manager) revert ErrorsLib.InvalidAddress();
        // Nothing bound yet, or a no-op rebind. The zero address is tested explicitly because it
        // is not empty on BSC - burned BNB lands there - so a balance test would block the first bind.
        if (_current == _next || _current == address(0)) return;

        if (_current.balance != 0) revert ErrorsLib.SubStakerNotDrained();

        uint256 length = _creditContracts.length;
        for (uint256 i = 0; i < length; ++i) {
            IStakeCredit credit = IStakeCredit(_creditContracts[i]);
            if (credit.balanceOf(_current) != 0 || credit.lockedBNBs(_current, 0) != 0) {
                revert ErrorsLib.SubStakerNotDrained();
            }
        }
    }

    /**
     * @dev BNB the bot still has to undelegate to cover the pending withdrawal queue
     * @notice Lives here for bytecode budget; the manager forwards to it.
     */
    function amountToUndelegate(
        IStakeManager.UserRequest[] storage withdrawalQueue,
        mapping(uint256 => uint256) storage requestIndexMap,
        uint256 nextConfirmedRequestUUID,
        uint256 unbondingBnb,
        uint256 undelegatedQuota
    ) public view returns (uint256 _amountToUndelegate) {
        if (withdrawalQueue.length == 0 || withdrawalQueue[withdrawalQueue.length - 1].uuid < nextConfirmedRequestUUID)
        {
            return 0;
        }

        uint256 nextIndex = requestIndexMap[nextConfirmedRequestUUID];
        uint256 totalAmountToWithdraw = withdrawalQueue[withdrawalQueue.length - 1].totalAmount
            - withdrawalQueue[nextIndex].totalAmount + withdrawalQueue[nextIndex].amount;

        _amountToUndelegate = totalAmountToWithdraw > unbondingBnb ? totalAmountToWithdraw - unbondingBnb : 0;

        return _amountToUndelegate >= undelegatedQuota ? _amountToUndelegate - undelegatedQuota : 0;
    }

    /**
     * @dev Highest queue index whose cumulative payout still fits in `_bnbAmount`
     * @notice Lives here for bytecode budget; the manager forwards to it.
     */
    function binarySearchCoveredMaxIndex(
        IStakeManager.UserRequest[] storage withdrawalQueue,
        mapping(uint256 => uint256) storage requestIndexMap,
        uint256 nextConfirmedRequestUUID,
        uint256 _bnbAmount
    ) public view returns (uint256) {
        require(
            withdrawalQueue.length != 0 && withdrawalQueue[0].uuid <= nextConfirmedRequestUUID,
            "No new requests or old requests have not been fully covered"
        );
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
            if (mid < endIndex) {
                nextAmount = withdrawalQueue[mid + 1].totalAmount - startTotalAmount + startAmount;
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
}
