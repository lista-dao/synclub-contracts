//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

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
}
