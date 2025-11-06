// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

interface IFeeVault {
    function initialize(address _recipient, uint256 _minWithdrawalAmount, uint8 _withdrawalNetwork) external;
    function setRecipient(address _recipient) external;
    function setMinWithdrawalAmount(uint256 _minWithdrawalAmount) external;
    function setWithdrawalNetwork(uint8 _withdrawalNetwork) external;
}
