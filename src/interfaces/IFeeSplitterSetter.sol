// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

/// @notice Interface for FeeSplitter setter.
interface IFeeSplitterSetter {
    function setSharesCalculator(address _calculator) external;
}
