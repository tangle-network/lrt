// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {MultiAssetDelegation} from "./MultiAssetDelegation.sol";
import {ERC20} from "../dependencies/solmate-6.8.0/src/tokens/ERC20.sol";

/// @title TangleMultiAssetDelegationWrapper
/// @notice Base contract for interacting with Tangle's MultiAssetDelegation system
/// @dev Provides delegation lifecycle management for a specific ERC20 token
abstract contract TangleMultiAssetDelegationWrapper {
    /* ============ Events ============ */

    /// @notice Emitted when delegation occurs
    event Delegated(bytes32 indexed operator, uint256 amount, uint64[] blueprintSelection);

    /// @notice Emitted when unstake is scheduled
    event UnstakeScheduled(bytes32 indexed operator, uint256 amount);

    /// @notice Emitted when unstake is cancelled
    event UnstakeCancelled(bytes32 indexed operator, uint256 amount);

    /// @notice Emitted when withdrawal is scheduled
    event WithdrawalScheduled(uint256 amount);

    /// @notice Emitted when withdrawal is cancelled
    event WithdrawalCancelled(uint256 amount);

    /// @notice Emitted when assets are deposited
    event Deposited(uint256 amount);

    /* ============ State Variables ============ */

    /// @notice The ERC20 token being delegated
    ERC20 public immutable token;

    /// @notice The MultiAssetDelegation implementation
    MultiAssetDelegation public immutable mads;

    /* ============ Constructor ============ */

    constructor(address _token, address _mads) {
        token = ERC20(_token);
        mads = MultiAssetDelegation(_mads);
    }

    /* ============ Internal Functions ============ */

    /// @notice Get the current balance of the delegator
    /// @param delegator The delegator to get the balance for
    /// @return The balance of the delegator
    function _balanceOf(address delegator) internal view returns (uint256) {
        return mads.balanceOf(delegator, 0, address(token));
    }

    /// @notice Deposit assets into the delegation system
    /// @param amount Amount of assets to deposit
    function _deposit(uint256 amount) internal {
        mads.deposit(
            0,
            address(token),
            amount,
            0 // Lock multiplier
        );

        emit Deposited(amount);
    }

    /// @notice Delegate assets to an operator
    /// @param operator The operator to delegate to
    /// @param amount Amount of assets to delegate
    /// @param blueprintSelection Blueprint selection for delegation
    function _delegate(bytes32 operator, uint256 amount, uint64[] memory blueprintSelection) internal {
        mads.delegate(operator, 0, address(token), amount, blueprintSelection);

        emit Delegated(operator, amount, blueprintSelection);
    }

    /// @notice Schedule unstaking of assets
    /// @param operator The operator to unstake from
    /// @param amount Amount of assets to unstake
    function _scheduleUnstake(bytes32 operator, uint256 amount) internal {
        mads.scheduleDelegatorUnstake(operator, 0, address(token), amount);

        emit UnstakeScheduled(operator, amount);
    }

    /// @notice Cancel a scheduled unstake
    /// @param operator The operator to cancel unstake from
    /// @param amount Amount of assets to cancel unstaking
    function _cancelUnstake(bytes32 operator, uint256 amount) internal {
        mads.cancelDelegatorUnstake(operator, 0, address(token), amount);

        emit UnstakeCancelled(operator, amount);
    }

    /// @notice Execute pending unstake
    function _executeUnstake() internal {
        mads.executeDelegatorUnstake();
    }

    /// @notice Schedule withdrawal of assets
    /// @param amount Amount of assets to withdraw
    function _scheduleWithdraw(uint256 amount) internal {
        mads.scheduleWithdraw(0, address(token), amount);

        emit WithdrawalScheduled(amount);
    }

    /// @notice Cancel a scheduled withdrawal
    /// @param amount Amount of assets to cancel withdrawal
    function _cancelWithdraw(uint256 amount) internal {
        mads.cancelWithdraw(0, address(token), amount);

        emit WithdrawalCancelled(amount);
    }

    /// @notice Execute pending withdrawal
    function _executeWithdraw() internal {
        mads.executeWithdraw();
    }
}
