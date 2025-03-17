// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./Rewards.sol";

/// @title TangleRewardsWrapper
/// @author The Tangle Team
/// @notice The interface through which solidity contracts will interact with the Rewards pallet
abstract contract TangleRewardsWrapper {
    Rewards public immutable rewardsContract;

    constructor(address _rewardsContractAddress) {
        rewardsContract = Rewards(_rewardsContractAddress);
    }

    /// @notice Claims rewards for a specific asset
    /// @param assetId The ID of the asset
    /// @param tokenAddress The EVM address of the token (zero for native assets)
    function _claimRewards(uint256 assetId, address tokenAddress) internal {
        rewardsContract.claimRewards(assetId, tokenAddress);
    }
}
