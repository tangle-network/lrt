// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "dependencies/solmate-6.8.0/src/tokens/ERC20.sol";
import {Rewards} from "../../src/Rewards.sol";

contract MockRewards is Rewards {
    ERC20 public immutable baseToken;
    uint256 public rewardAmount;
    bool public shouldFail;

    error InvalidAssetId();

    constructor(ERC20 _baseToken) {
        baseToken = _baseToken;
    }

    function setRewardAmount(uint256 _rewardAmount) external {
        rewardAmount = _rewardAmount;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function claimRewards(uint256 assetId, address tokenAddress) external override {
        if (assetId != 0) {
            revert InvalidAssetId();
        }

        if (shouldFail) {
            shouldFail = false;
            revert("MockRewards: Forced failure");
        }

        ERC20(tokenAddress).transfer(msg.sender, rewardAmount);
    }
}
