// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title IOracle
/// @notice Interface for price oracle implementations
interface IOracle {
    /// @notice Get the current price for a token
    /// @param token Address of token to get price for
    /// @return price Current price in USD terms with 18 decimals (1e18 = $1.00)
    function getPrice(address token) external view returns (uint256);
}
