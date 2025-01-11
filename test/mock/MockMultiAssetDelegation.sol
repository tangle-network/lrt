// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MultiAssetDelegation} from "../../src/MultiAssetDelegation.sol";

contract MockMultiAssetDelegation is MultiAssetDelegation {
    // Structs to track scheduling state
    struct ScheduleState {
        uint256 amount;
        uint256 timestamp;
    }

    // 1 week delay for schedule actions
    uint256 public constant SCHEDULE_DELAY = 1 weeks;

    // Simple mapping of user => scheduled state
    mapping(address => ScheduleState) public scheduledUnstakes;
    mapping(address => ScheduleState) public scheduledWithdraws;
    mapping(address => uint256) public delegatedAmounts;

    // Events
    event Delegated(
        address indexed token, address indexed user, uint256 amount, bytes32 operator, uint64[] blueprintSelection
    );
    event UnstakeScheduled(address indexed token, address indexed user, uint256 amount, uint256 timestamp);
    event WithdrawScheduled(address indexed token, address indexed user, uint256 amount, uint256 timestamp);
    event UnstakeCancelled(address indexed token, address indexed user, uint256 amount);
    event WithdrawCancelled(address indexed token, address indexed user, uint256 amount);
    event UnstakeExecuted(address indexed user, uint256 amount);
    event WithdrawExecuted(address indexed user, uint256 amount);

    error InsufficientDelegatedBalance();
    error InsufficientScheduledAmount();
    error NoScheduledAmount();
    error DelayNotElapsed();

    // Operator functions (empty implementations)
    function joinOperators(uint256) external {}
    function scheduleLeaveOperators() external {}
    function cancelLeaveOperators() external {}
    function executeLeaveOperators() external {}
    function operatorBondMore(uint256) external {}
    function scheduleOperatorUnstake(uint256) external {}
    function executeOperatorUnstake() external {}
    function cancelOperatorUnstake() external {}
    function goOffline() external {}
    function goOnline() external {}

    // Delegate function - track amount and emit event
    function delegate(bytes32 operator, uint256, address, uint256 amount, uint64[] memory blueprintSelection)
        external
    {
        delegatedAmounts[msg.sender] += amount;
        emit Delegated(address(0), msg.sender, amount, operator, blueprintSelection);
    }

    // Deposit function - just track delegated amount
    function deposit(uint256, address, uint256 amount, uint8) external {
        delegatedAmounts[msg.sender] += amount;
        emit Delegated(address(0), msg.sender, amount, bytes32(0), new uint64[](0));
    }

    // Schedule withdraw - just track amount and timestamp
    function scheduleWithdraw(uint256, address, uint256 amount) external {
        ScheduleState storage state = scheduledWithdraws[msg.sender];
        state.amount = state.amount + amount;
        state.timestamp = block.timestamp + SCHEDULE_DELAY;
        emit WithdrawScheduled(address(0), msg.sender, amount, state.timestamp);
    }

    // Execute withdraw - check delay and clear state
    function executeWithdraw() external {
        ScheduleState storage state = scheduledWithdraws[msg.sender];
        if (state.amount == 0) revert NoScheduledAmount();
        if (block.timestamp < state.timestamp) revert DelayNotElapsed();

        uint256 amount = state.amount;
        state.amount = 0;
        state.timestamp = 0;
        emit WithdrawExecuted(msg.sender, amount);
    }

    // Cancel withdraw - just reduce amount
    function cancelWithdraw(uint256, address token, uint256 amount) external {
        ScheduleState storage state = scheduledWithdraws[msg.sender];
        if (state.amount < amount) revert InsufficientScheduledAmount();
        state.amount = state.amount - amount;
        emit WithdrawCancelled(token, msg.sender, amount);
    }

    // Schedule unstake - check delegated balance and track schedule
    function scheduleDelegatorUnstake(bytes32, uint256, address tokenAddress, uint256 amount) external {
        if (delegatedAmounts[msg.sender] < amount) revert InsufficientDelegatedBalance();

        ScheduleState storage state = scheduledUnstakes[msg.sender];
        state.amount = state.amount + amount;
        state.timestamp = block.timestamp + SCHEDULE_DELAY;
        delegatedAmounts[msg.sender] = delegatedAmounts[msg.sender] - amount;

        emit UnstakeScheduled(tokenAddress, msg.sender, amount, state.timestamp);
    }

    // Execute unstake - check delay and clear state
    function executeDelegatorUnstake() external {
        ScheduleState storage state = scheduledUnstakes[msg.sender];
        if (state.amount == 0) revert NoScheduledAmount();
        if (block.timestamp < state.timestamp) revert DelayNotElapsed();

        uint256 amount = state.amount;
        state.amount = 0;
        state.timestamp = 0;
        emit UnstakeExecuted(msg.sender, amount);
    }

    // Cancel unstake - restore delegated amount
    function cancelDelegatorUnstake(bytes32, uint256, address tokenAddress, uint256 amount) external {
        ScheduleState storage state = scheduledUnstakes[msg.sender];
        if (state.amount < amount) revert InsufficientScheduledAmount();

        state.amount = state.amount - amount;
        delegatedAmounts[msg.sender] = delegatedAmounts[msg.sender] + amount;
        emit UnstakeCancelled(tokenAddress, msg.sender, amount);
    }

    // View functions
    function getDelegation(address tokenAddress, address user)
        external
        view
        returns (uint256 amount, bytes32, uint64[] memory)
    {
        return (delegatedAmounts[user], bytes32(0), new uint64[](0));
    }

    function getDelegatedAmount(address tokenAddress, address user) external view returns (uint256) {
        return delegatedAmounts[user];
    }

    function getScheduledUnstake(address tokenAddress, address user)
        external
        view
        returns (uint256 amount, uint256 timestamp)
    {
        // Return the scheduled amount for the caller (vault), not the end user
        ScheduleState storage state = scheduledUnstakes[tokenAddress];
        return (state.amount, state.timestamp);
    }

    function getScheduledWithdraw(address tokenAddress, address user)
        external
        view
        returns (uint256 amount, uint256 timestamp)
    {
        // Return the scheduled amount for the caller (vault), not the end user
        ScheduleState storage state = scheduledWithdraws[tokenAddress];
        return (state.amount, state.timestamp);
    }
}
