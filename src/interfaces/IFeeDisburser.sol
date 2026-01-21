// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

/// @notice Interface for Base's FeeDisburser contract on L2.
interface IFeeDisburser {
    /// @notice Returns the address of the Optimism wallet that receives Optimism's revenue share.
    function OPTIMISM_WALLET() external view returns (address payable);

    /// @notice Returns the address of the L1 wallet that receives the chain runner's share of fees.
    function L1_WALLET() external view returns (address);

    /// @notice Returns the minimum amount of time in seconds that must pass between fee disbursals.
    function FEE_DISBURSEMENT_INTERVAL() external view returns (uint256);

    /// @notice Returns the timestamp of the last disbursal.
    function lastDisbursementTime() external view returns (uint256);

    /// @notice Returns the aggregate net fee revenue.
    function netFeeRevenue() external view returns (uint256);

    /// @notice Withdraws funds from FeeVaults, sends Optimism their revenue share, and withdraws remaining funds to L1.
    function disburseFees() external;
}
