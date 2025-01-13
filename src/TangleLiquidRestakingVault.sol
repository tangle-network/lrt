// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC4626} from "dependencies/solmate-6.8.0/src/tokens/ERC4626.sol";
import {ERC20} from "dependencies/solmate-6.8.0/src/tokens/ERC20.sol";
import {SafeTransferLib} from "dependencies/solmate-6.8.0/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "dependencies/solmate-6.8.0/src/utils/FixedPointMathLib.sol";
import {Owned} from "dependencies/solmate-6.8.0/src/auth/Owned.sol";
import {TangleMultiAssetDelegationWrapper} from "./TangleMultiAssetDelegationWrapper.sol";
import {MULTI_ASSET_DELEGATION_CONTRACT} from "./MultiAssetDelegation.sol";

/// @title TangleLiquidRestakingVault
/// @notice ERC4626-compliant vault that implements reward distribution with index-based accounting
/// @dev Key implementation details:
/// 1. Reward Distribution:
///    - Uses an index-based accounting system where each reward token has a global index
///    - Index increases proportionally to (reward amount / total supply) for each reward
///    - User checkpoints store the last seen index to calculate entitled rewards
/// 2. Share Transfers:
///    - Historical rewards always stay with the original holder
///    - New holders start earning from their entry index
///    - Transfers trigger checkpoints for both sender and receiver
/// 3. Precision & Math:
///    - Uses FixedPointMathLib for safe fixed-point calculations
///    - Reward index uses REWARD_FACTOR (1e18) as scale factor
///    - mulDivDown for index updates to prevent accumulating errors
///    - mulDivUp for final reward calculations to prevent dust
/// 4. Delegation:
///    - Deposits are automatically delegated to operator
///    - Curator can update blueprint selection
///    - Withdrawals require unstaking through Tangle runtime
contract TangleLiquidRestakingVault is ERC4626, Owned, TangleMultiAssetDelegationWrapper {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /* ============ Constants ============ */

    /// @notice Scale factor for reward index calculations
    /// @dev Used to maintain precision in reward/share calculations
    /// Index calculation: newRewards * REWARD_FACTOR / totalSupply
    /// Reward calculation: shareBalance * (currentIndex - checkpointIndex) / REWARD_FACTOR
    uint256 private constant REWARD_FACTOR = 1e18;

    /* ============ Events ============ */

    /// @notice Emitted when a new reward token is added
    event RewardTokenAdded(address indexed token);

    /// @notice Emitted when rewards are claimed by a user
    /// @param user The user claiming rewards
    /// @param token The reward token being claimed
    /// @param amount The amount of rewards claimed
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a new snapshot is created for a user
    /// @param user The user the snapshot is for
    /// @param token The reward token the snapshot is for
    /// @param index The global reward index at snapshot time
    /// @param timestamp When the snapshot was created
    /// @param rewardIndex The index in the rewardTimestamps array
    event RewardSnapshotCreated(
        address indexed user, address indexed token, uint256 index, uint256 timestamp, uint256 rewardIndex
    );

    /// @notice Emitted when the global reward index is updated
    /// @param token The reward token whose index was updated
    /// @param index The new global index value
    /// @param timestamp When the update occurred
    event RewardIndexUpdated(address indexed token, uint256 index, uint256 timestamp);

    /// @notice Emitted when an unstake request is cancelled
    event UnstakeCancelled(address indexed user, uint256 amount);

    /// @notice Emitted when a withdrawal request is cancelled
    event WithdrawalCancelled(address indexed user, uint256 amount);

    /* ============ Errors ============ */

    /// @notice Attempted to add an invalid reward token (zero address or base asset)
    error InvalidRewardToken();
    /// @notice Attempted to add a reward token that was already added
    error RewardTokenAlreadyAdded();
    /// @notice Attempted to claim rewards but none were available
    error NoRewardsToClaim();
    /// @notice Attempted operation by unauthorized caller
    error Unauthorized();
    /// @notice Attempted withdrawal without unstaking first
    error WithdrawalNotUnstaked();
    /// @notice Attempted to cancel more than scheduled
    error ExceedsScheduledAmount();
    /// @notice Attempted to cancel more than scheduled
    error InsufficientScheduledAmount();
    /// @notice No scheduled amount to execute
    error NoScheduledAmount();

    /* ============ Types ============ */

    /// @notice Tracks user's reward snapshot for a token
    /// @dev Used to calculate rewards between snapshot creation and current time
    /// Historical rewards are stored in pendingRewards to maintain claim integrity
    struct RewardSnapshot {
        uint256 rewardIndex; // Global index at snapshot creation
        uint256 timestamp; // When snapshot was created
        uint256 shareBalance; // User's share balance at snapshot
        uint256 lastRewardIndex; // Index in rewardTimestamps array
        uint256 pendingRewards; // Unclaimed rewards at snapshot
    }

    /// @notice Tracks global reward state for a token
    /// @dev Maintains reward distribution history and current index
    /// Index increases with each reward based on: newRewards * REWARD_FACTOR / totalSupply
    struct RewardData {
        uint256 index; // Current global reward index
        uint256 lastUpdateTime; // Last index update timestamp
        bool isValid; // Whether token is registered
        uint256[] rewardTimestamps; // When rewards were received
        uint256[] rewardAmounts; // Amount of each reward
    }

    /* ============ State Variables ============ */

    /// @notice List of registered reward tokens
    /// @dev Used to iterate all reward tokens for operations like checkpointing
    address[] public rewardTokens;

    /// @notice Reward accounting data per token
    /// @dev Tracks global indices and reward history
    mapping(address => RewardData) public rewardData;

    /// @notice User reward snapshots per token
    /// @dev Maps user => token => snapshot data
    mapping(address => mapping(address => RewardSnapshot)) public userSnapshots;

    /// @notice Tracks unstaking status for withdrawals
    mapping(address => uint256) public unstakeAmount;

    /// @notice Tracks scheduled unstake requests
    /// @dev Maps user => amount scheduled for unstake
    mapping(address => uint256) public scheduledUnstakeAmount;

    /// @notice Tracks scheduled withdraw requests
    /// @dev Maps user => amount scheduled for withdrawal
    mapping(address => uint256) public scheduledWithdrawAmount;

    /// @notice Operator address for delegation
    bytes32 public operator;

    /// @notice Blueprint selection for delegation and exposure
    uint64[] public blueprintSelection;

    /* ============ Constructor ============ */

    constructor(
        address _baseToken,
        bytes32 _operator,
        uint64[] memory _blueprintSelection,
        address _mads,
        string memory _name,
        string memory _symbol
    )
        ERC4626(ERC20(_baseToken), _name, _symbol)
        TangleMultiAssetDelegationWrapper(_baseToken, _mads)
        Owned(msg.sender)
    {
        operator = _operator;
        blueprintSelection = _blueprintSelection;
    }

    /* ============ External Functions ============ */

    /// @notice Register a new reward token
    /// @dev Initializes reward tracking for a new token
    /// Requirements:
    /// - Token must not be zero address or base asset
    /// - Token must not already be registered
    /// @param token Address of reward token to register
    function addRewardToken(address token) external {
        if (token == address(0) || token == address(asset)) {
            revert InvalidRewardToken();
        }
        if (rewardData[token].isValid) revert RewardTokenAlreadyAdded();

        rewardData[token] = RewardData({
            index: 0,
            lastUpdateTime: block.timestamp,
            isValid: true,
            rewardTimestamps: new uint256[](0),
            rewardAmounts: new uint256[](0)
        });
        rewardTokens.push(token);

        emit RewardTokenAdded(token);
    }

    /// @notice Claim accumulated rewards for specified tokens
    /// @dev Claims all pending rewards for given tokens
    /// For each token:
    /// 1. Updates global index to include any new rewards
    /// 2. Calculates user's entitled rewards since last snapshot
    /// 3. Transfers rewards and creates new snapshot
    /// Requirements:
    /// - Caller must be the user claiming rewards
    /// - Tokens must be valid reward tokens
    /// @param user Address to claim rewards for
    /// @param tokens Array of reward token addresses to claim
    /// @return rewards Array of claimed amounts per token
    function claimRewards(address user, address[] calldata tokens) external returns (uint256[] memory rewards) {
        if (msg.sender != user) revert Unauthorized();

        rewards = new uint256[](tokens.length);

        // Update all indices once at start
        _updateAllRewardIndices();

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (!rewardData[token].isValid) revert InvalidRewardToken();

            rewards[i] = _claimReward(user, token);
        }
    }

    /// @notice Transfer shares to another address
    /// @dev Overrides ERC20 transfer to handle reward snapshots
    /// Historical rewards stay with sender, recipient starts fresh
    /// @param to Recipient of the shares
    /// @param amount Number of shares to transfer
    /// @return success Whether transfer succeeded
    function transfer(address to, uint256 amount) public override returns (bool) {
        _processRewardSnapshots(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    /// @notice Transfer shares from one address to another
    /// @dev Overrides ERC20 transferFrom to handle reward snapshots
    /// Historical rewards stay with sender, recipient starts fresh
    /// @param from Sender of the shares
    /// @param to Recipient of the shares
    /// @param amount Number of shares to transfer
    /// @return success Whether transfer succeeded
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _processRewardSnapshots(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    /// @notice Deposit assets into vault and delegate
    /// @dev Overrides ERC4626 deposit to handle reward snapshots and delegation
    /// @param assets Amount of assets to deposit
    /// @param receiver Recipient of the shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        // Calculate shares before minting
        shares = previewDeposit(assets);

        // Process snapshots for new shares
        if (rewardTokens.length > 0) {
            _updateAllRewardIndices();
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];

                // Calculate rewards earned by existing shares
                uint256 existingRewards = _calculatePendingRewards(receiver, token);

                // Create new snapshot with existing rewards
                // New shares will start earning from current index
                _createSnapshot(receiver, token, balanceOf[receiver] + shares, existingRewards);
            }
        }

        // Complete deposit
        super.deposit(assets, receiver);

        // Deposit into the MADs system
        // _deposit(assets);
        MULTI_ASSET_DELEGATION_CONTRACT.deposit(0, address(asset), assets, 0);

        // Delegate deposited assets through wrapper
        MULTI_ASSET_DELEGATION_CONTRACT.delegate(operator, 0, address(asset), assets, blueprintSelection);
        // _delegate(operator, assets, blueprintSelection);
    }

    /// @notice Execute withdrawal after delay
    /// @dev Overrides ERC4626 withdraw to handle reward snapshots
    /// @param assets Amount of assets to withdraw
    /// @param receiver Recipient of the assets
    /// @param owner Owner of the shares
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        // Check that withdrawal has been scheduled
        if (scheduledWithdrawAmount[owner] < assets) revert NoScheduledAmount();

        // Check withdrawal delay through MADS
        _executeWithdraw();

        // Update tracking
        scheduledWithdrawAmount[owner] = scheduledWithdrawAmount[owner] - assets;

        // Calculate shares before burning
        shares = previewWithdraw(assets);

        // Process snapshots before burning shares
        if (rewardTokens.length > 0) {
            _updateAllRewardIndices();
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                // Calculate pending rewards before withdrawal
                uint256 pendingRewards = _calculatePendingRewards(owner, token);

                // Create snapshot with remaining shares and all pending rewards
                _createSnapshot(owner, token, balanceOf[owner] - shares, pendingRewards);
            }
        }

        // Complete withdrawal
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeem shares for assets
    /// @dev Overrides ERC4626 redeem to handle reward snapshots
    /// @param shares Amount of shares to redeem
    /// @param receiver Recipient of the assets
    /// @param owner Owner of the shares
    /// @return assets Amount of assets redeemed
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        // Calculate assets being redeemed
        assets = previewRedeem(shares);

        // Check that withdrawal has been scheduled
        if (scheduledWithdrawAmount[owner] < assets) revert NoScheduledAmount();

        // Check withdrawal delay through MADS
        _executeWithdraw();

        // Update tracking
        scheduledWithdrawAmount[owner] = scheduledWithdrawAmount[owner] - assets;

        // Process snapshots before burning shares
        if (rewardTokens.length > 0) {
            _updateAllRewardIndices();
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                // Calculate pending rewards before redemption
                uint256 pendingRewards = _calculatePendingRewards(owner, token);

                // Create snapshot with remaining shares and all pending rewards
                _createSnapshot(owner, token, balanceOf[owner] - shares, pendingRewards);
            }
        }

        // Complete redemption
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Schedule unstaking of assets
    /// @dev Must be called before withdrawal can be executed
    /// @param assets Amount of assets to unstake
    function scheduleUnstake(uint256 assets) external {
        uint256 shares = previewWithdraw(assets);
        require(balanceOf[msg.sender] >= shares, "Insufficient shares");

        // Track scheduled unstake
        scheduledUnstakeAmount[msg.sender] += assets;

        // Process snapshots to stop reward accrual for these shares
        _processRewardSnapshots(msg.sender, address(0), shares);

        // Schedule unstake through wrapper
        _scheduleUnstake(operator, assets);

        emit UnstakeScheduled(operator, assets);
    }

    /// @notice Execute the unstake
    /// @dev Must have previously scheduled the unstake
    function executeUnstake() external {
        uint256 scheduled = scheduledUnstakeAmount[msg.sender];
        if (scheduled == 0) revert NoScheduledAmount();

        // Execute unstake through wrapper
        _executeUnstake();

        // Update state tracking - move from scheduled to unstaked
        unstakeAmount[msg.sender] += scheduled;
        scheduledUnstakeAmount[msg.sender] = 0;
    }

    /// @notice Schedule withdrawal of assets
    /// @dev Must have previously unstaked the assets
    /// @param assets Amount of assets to withdraw
    function scheduleWithdraw(uint256 assets) external {
        // Verify caller has enough unstaked assets
        if (unstakeAmount[msg.sender] < assets) revert WithdrawalNotUnstaked();

        // Track scheduled withdrawal
        scheduledWithdrawAmount[msg.sender] += assets;
        unstakeAmount[msg.sender] -= assets;

        // Schedule withdraw through wrapper
        _scheduleWithdraw(assets);

        emit WithdrawalScheduled(assets);
    }

    /// @notice Cancel a scheduled withdrawal
    /// @param assets Amount of assets to cancel withdrawal
    function cancelWithdraw(uint256 assets) external {
        uint256 scheduled = scheduledWithdrawAmount[msg.sender];
        if (assets > scheduled) revert InsufficientScheduledAmount();

        // Update tracking - return to unstaked state
        scheduledWithdrawAmount[msg.sender] = scheduled - assets;
        unstakeAmount[msg.sender] += assets;

        // Cancel withdraw through wrapper
        _cancelWithdraw(assets);

        // Re-delegate the assets since they're back in the pool
        _delegate(operator, assets, blueprintSelection);

        emit WithdrawalCancelled(msg.sender, assets);
    }

    /// @notice Cancel a scheduled unstake
    /// @param assets Amount of assets to cancel unstaking
    function cancelUnstake(uint256 assets) external {
        uint256 scheduled = scheduledUnstakeAmount[msg.sender];
        if (assets > scheduled) revert InsufficientScheduledAmount();

        // Update tracking
        scheduledUnstakeAmount[msg.sender] = scheduled - assets;

        // Cancel unstake through wrapper
        _cancelUnstake(operator, assets);

        // Process snapshots to resume reward accrual
        uint256 shares = previewWithdraw(assets);
        _processRewardSnapshots(msg.sender, msg.sender, shares);

        emit UnstakeCancelled(msg.sender, assets);
    }

    /* ============ Internal Functions ============ */

    /// @notice Process reward snapshots for share transfers
    /// @dev Core reward accounting logic for transfers
    /// Key behaviors:
    /// 1. Updates indices to include new rewards
    /// 2. Sender keeps all historical rewards
    /// 3. Receiver keeps existing rewards, starts fresh with transferred shares
    /// @param from Sender address
    /// @param to Recipient address (or 0 for burns)
    /// @param amount Number of shares being transferred
    function _processRewardSnapshots(address from, address to, uint256 amount) internal {
        if (rewardTokens.length == 0) return;

        uint256 fromBalance = balanceOf[from];
        uint256 toBalance = balanceOf[to];

        // Update all indices first to capture any new rewards
        _updateAllRewardIndices();

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];

            // Calculate total pending rewards for sender
            uint256 pendingRewards = _calculatePendingRewards(from, token);

            // Original holder keeps all historical rewards
            _createSnapshot(from, token, fromBalance - amount, pendingRewards);

            if (to != address(0)) {
                // Calculate recipient's existing rewards
                uint256 recipientRewards = _calculatePendingRewards(to, token);

                // Recipient keeps their existing rewards and gets new balance
                _createSnapshot(to, token, toBalance + amount, recipientRewards);
            }
        }
    }

    /// @notice Create snapshot for user's reward state
    /// @dev Records user's share balance and pending rewards at current index
    /// Used to calculate future rewards from this point
    /// @param user User address
    /// @param token Reward token address
    /// @param newBalance User's new share balance
    /// @param pendingRewards Unclaimed rewards to store
    function _createSnapshot(address user, address token, uint256 newBalance, uint256 pendingRewards) internal {
        RewardData storage rData = rewardData[token];
        userSnapshots[user][token] = RewardSnapshot({
            rewardIndex: rData.index,
            timestamp: block.timestamp,
            shareBalance: newBalance,
            lastRewardIndex: rData.rewardTimestamps.length,
            pendingRewards: pendingRewards
        });

        emit RewardSnapshotCreated(user, token, rData.index, block.timestamp, rData.rewardTimestamps.length);
    }

    /// @notice Calculate pending rewards for a user
    /// @dev Calculates rewards earned since last snapshot
    /// Formula: (shareBalance * indexDelta / REWARD_FACTOR) + storedRewards
    /// Uses mulDivUp for final calculation to prevent dust
    /// @param user User address
    /// @param token Reward token address
    /// @return Total pending rewards
    function _calculatePendingRewards(address user, address token) internal view returns (uint256) {
        RewardSnapshot memory snapshot = userSnapshots[user][token];
        RewardData storage rData = rewardData[token];

        // Calculate rewards since last snapshot
        uint256 indexDelta = rData.index - snapshot.rewardIndex;
        // Use mulDivUp for final reward calculation to ensure no dust is left behind
        uint256 newRewards = snapshot.shareBalance.mulDivUp(indexDelta, REWARD_FACTOR);
        uint256 totalRewards = newRewards + snapshot.pendingRewards;

        return totalRewards;
    }

    /// @notice Claim rewards for a specific token
    /// @dev Internal implementation of reward claiming
    /// 1. Updates global index
    /// 2. Calculates entitled rewards
    /// 3. Creates new snapshot
    /// 4. Transfers rewards
    /// @param user User to claim for
    /// @param token Reward token to claim
    /// @return amount Amount of rewards claimed
    function _claimReward(address user, address token) internal returns (uint256) {
        // Update global reward index first
        _updateRewardIndex(token);

        // Calculate total pending rewards
        uint256 pendingRewards = _calculatePendingRewards(user, token);

        if (pendingRewards > 0) {
            // Reset snapshot with current index and zero pending rewards
            _createSnapshot(user, token, balanceOf[user], 0);

            ERC20(token).safeTransfer(user, pendingRewards);
            emit RewardsClaimed(user, token, pendingRewards);
        }

        return pendingRewards;
    }

    /// @notice Claim all pending rewards for a user
    /// @dev Helper to claim all registered reward tokens
    /// @param user User to claim for
    function _claimAllRewards(address user) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            _updateRewardIndex(token);
            _claimReward(user, token);
        }
    }

    /// @notice Update reward index for a token
    /// @dev Core reward distribution logic
    /// When new rewards arrive:
    /// 1. Calculate new rewards (current balance - last known balance)
    /// 2. Record reward in history
    /// 3. Increase global index by (newRewards * REWARD_FACTOR) / totalSupply
    /// Uses mulDivDown for index updates to prevent accumulating errors
    /// Reverts if index would overflow
    /// @param token Reward token to update
    function _updateRewardIndex(address token) internal {
        RewardData storage rData = rewardData[token];
        uint256 currentBalance = ERC20(token).balanceOf(address(this));
        uint256 lastKnownBalance = _getLastKnownBalance(token);

        if (currentBalance > lastKnownBalance) {
            uint256 newRewards = currentBalance - lastKnownBalance;

            // Record reward arrival
            rData.rewardTimestamps.push(block.timestamp);
            rData.rewardAmounts.push(newRewards);

            uint256 supply = totalSupply;
            if (supply > 0) {
                // Use mulDivDown for index updates to prevent accumulating errors
                uint256 rewardPerShare = newRewards.mulDivDown(REWARD_FACTOR, supply);
                rData.index += rewardPerShare;

                emit RewardIndexUpdated(token, rData.index, block.timestamp);
            }
        }

        rData.lastUpdateTime = block.timestamp;
    }

    /// @notice Get last known balance from recorded rewards
    /// @dev Sums all recorded reward amounts
    /// @param token Reward token to check
    /// @return total Total of all recorded rewards
    function _getLastKnownBalance(address token) internal view returns (uint256 total) {
        RewardData storage rData = rewardData[token];
        for (uint256 i = 0; i < rData.rewardAmounts.length; i++) {
            total += rData.rewardAmounts[i];
        }
    }

    /// @notice Update indices for all reward tokens
    /// @dev Helper to ensure all reward indices are current
    function _updateAllRewardIndices() internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateRewardIndex(rewardTokens[i]);
        }
    }

    /* ============ External View Functions ============ */

    /// @notice Get claimable rewards for a user and token
    /// @dev View function to check pending rewards
    /// @param user User address
    /// @param token Reward token address
    /// @return Claimable reward amount
    function getClaimableRewards(address user, address token) external view returns (uint256) {
        if (balanceOf[user] == 0) return 0;

        RewardSnapshot memory snapshot = userSnapshots[user][token];
        RewardData memory rData = rewardData[token];

        return snapshot.shareBalance.mulDivDown(rData.index - snapshot.rewardIndex, REWARD_FACTOR);
    }

    /// @notice Get all reward token addresses
    /// @return Array of reward token addresses
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /// @notice Calculate total vault value
    /// @dev Returns total base assets, excluding reward tokens
    /// @return Total value in terms of asset tokens
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Get reward data for a token
    /// @dev Returns full reward tracking state
    /// @param token Reward token address
    /// @return index Current reward index
    /// @return lastUpdateTime Last update timestamp
    /// @return isValid Whether token is valid
    /// @return rewardTimestamps Array of reward timestamps
    /// @return rewardAmounts Array of reward amounts
    function getRewardData(address token)
        external
        view
        returns (
            uint256 index,
            uint256 lastUpdateTime,
            bool isValid,
            uint256[] memory rewardTimestamps,
            uint256[] memory rewardAmounts
        )
    {
        RewardData storage data = rewardData[token];
        return (data.index, data.lastUpdateTime, data.isValid, data.rewardTimestamps, data.rewardAmounts);
    }
}
