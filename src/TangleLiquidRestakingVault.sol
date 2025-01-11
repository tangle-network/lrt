// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {ERC4626} from "../dependencies/solmate-6.8.0/src/tokens/ERC4626.sol";
import {ERC20} from "../dependencies/solmate-6.8.0/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../dependencies/solmate-6.8.0/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../dependencies/solmate-6.8.0/src/utils/FixedPointMathLib.sol";
import {MultiAssetDelegation, MULTI_ASSET_DELEGATION_CONTRACT} from "./MultiAssetDelegation.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TangleLiquidRestakingVault
/// @notice A vault implementation for liquid restaking that delegates to Tangle operators
/// @dev Implements base asset shares with separate reward tracking using checkpoints
contract TangleLiquidRestakingVault is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /* ============ Constants ============ */

    /// @notice Scalar for reward index calculations
    uint256 private constant REWARD_FACTOR = 1e18;

    /* ============ Events ============ */
    
    event RewardTokenAdded(address indexed token);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event CheckpointCreated(
        address indexed user,
        address indexed token,
        uint256 index,
        uint256 timestamp,
        uint256 rewardIndex
    );
    event RewardIndexUpdated(address indexed token, uint256 index, uint256 timestamp);

    /* ============ Errors ============ */
    
    error InvalidRewardToken();
    error RewardTokenAlreadyAdded();
    error NoRewardsToClaim();
    error Unauthorized();

    /* ============ Types ============ */

    /// @notice Tracks user's reward checkpoint for a token
    struct Checkpoint {
        uint256 rewardIndex;    // Global index at checkpoint
        uint256 timestamp;      // When checkpoint was created
        uint256 shareBalance;   // User's share balance at checkpoint
        uint256 lastRewardIndex; // Index in rewardTimestamps array
        uint256 pendingRewards;  // Pending rewards at checkpoint
    }

    /// @notice Tracks reward accrual for a token
    struct RewardData {
        uint256 index;          // Global reward index
        uint256 lastUpdateTime; // Last time rewards were updated
        bool isValid;           // Whether this is a valid reward token
        uint256[] rewardTimestamps; // Timestamps when rewards arrived
        uint256[] rewardAmounts;    // Amount of rewards at each timestamp
    }

    /* ============ State Variables ============ */

    /// @notice List of reward tokens
    address[] public rewardTokens;

    /// @notice Reward token information
    mapping(address => RewardData) public rewardData;

    /// @notice User checkpoints per token
    mapping(address => mapping(address => Checkpoint)) public userCheckpoints;

    /* ============ Constructor ============ */

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(ERC20(_asset), _name, _symbol) {}

    /* ============ External Functions ============ */

    /// @notice Add a new reward token
    /// @param token Address of reward token to add
    function addRewardToken(address token) external {
        if (token == address(0) || token == address(asset)) revert InvalidRewardToken();
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

    /// @notice Claim rewards for specified tokens
    /// @param user Address to claim rewards for
    /// @param tokens Array of reward token addresses
    /// @return rewards Array of claimed amounts
    function claimRewards(
        address user,
        address[] calldata tokens
    ) external returns (uint256[] memory rewards) {
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

    function transfer(address to, uint256 amount) public override returns (bool) {
        _processRewardCheckpoints(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _processRewardCheckpoints(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        // Calculate shares before burning
        shares = previewWithdraw(assets);
        
        // Process checkpoints before burning shares
        if (rewardTokens.length > 0) {
            _updateAllRewardIndices();
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                // Calculate pending rewards before withdrawal
                uint256 pendingRewards = _calculatePendingRewards(owner, token);
                
                // Create checkpoint with remaining shares and all pending rewards
                _createCheckpoint(
                    owner,
                    token,
                    balanceOf[owner] - shares,
                    pendingRewards
                );
                
                console.log("Withdraw - Pending Rewards:", pendingRewards);
                console.log("Withdraw - Remaining Shares:", balanceOf[owner] - shares);
            }
        }
        
        // Complete withdrawal
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        _processRewardCheckpoints(owner, address(0), shares);
        assets = super.redeem(shares, receiver, owner);
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 shares) {
        // Calculate shares before minting
        shares = previewDeposit(assets);
        
        // Process checkpoints for new shares
        if (rewardTokens.length > 0) {
            _updateAllRewardIndices();
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                RewardData storage rData = rewardData[token];
                
                // Calculate rewards earned by existing shares
                uint256 existingRewards = _calculatePendingRewards(receiver, token);
                
                // Create new checkpoint with existing rewards
                // New shares will start earning from current index
                _createCheckpoint(
                    receiver,
                    token,
                    balanceOf[receiver] + shares,
                    existingRewards
                );
                
                console.log("Deposit - Token:", token);
                console.log("Deposit - Current Index:", rData.index);
                console.log("Deposit - Existing Rewards:", existingRewards);
                console.log("Deposit - New Share Balance:", balanceOf[receiver] + shares);
            }
        }
        
        // Complete deposit
        return super.deposit(assets, receiver);
    }

    /* ============ Internal Functions ============ */

    /// @notice Process reward checkpoints for share transfers
    /// @dev When shares are transferred:
    /// 1. Update global indices for any new rewards
    /// 2. Calculate sender's pending rewards
    /// 3. Split pending rewards proportionally:
    ///    - Sender keeps (remainingShares/totalShares) * pendingRewards
    ///    - Receiver gets (transferredShares/totalShares) * pendingRewards
    /// 4. Create new checkpoints for both parties
    function _processRewardCheckpoints(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (rewardTokens.length == 0) return;

        uint256 fromBalance = balanceOf[from];
        uint256 toBalance = balanceOf[to];
        
        console.log("Process Reward Checkpoints");
        console.log("From:", from);
        console.log("To:", to);
        console.log("Transfer Amount:", amount);
        console.log("From Balance:", fromBalance);
        console.log("To Balance:", toBalance);

        // Update all indices first to capture any new rewards
        _updateAllRewardIndices();

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            
            // Calculate total pending rewards for sender
            uint256 pendingRewards = _calculatePendingRewards(from, token);
            
            console.log("Token:", token);
            console.log("Sender Pending Rewards:", pendingRewards);
            
            // Original holder keeps all historical rewards
            _createCheckpoint(from, token, fromBalance - amount, pendingRewards);
            
            if (to != address(0)) {
                // Calculate recipient's existing rewards
                uint256 recipientRewards = _calculatePendingRewards(to, token);
                console.log("Recipient Existing Rewards:", recipientRewards);
                
                // Recipient keeps their existing rewards and gets new balance
                _createCheckpoint(to, token, toBalance + amount, recipientRewards);
                console.log("Recipient new balance:", toBalance + amount);
            }
        }
    }

    /// @notice Create checkpoint for user's reward state
    /// @param user User address
    /// @param token Reward token
    /// @param newBalance New share balance after transfer
    /// @param pendingRewards Pending rewards to store in checkpoint
    function _createCheckpoint(
        address user,
        address token,
        uint256 newBalance,
        uint256 pendingRewards
    ) internal {
        RewardData storage rData = rewardData[token];
        userCheckpoints[user][token] = Checkpoint({
            rewardIndex: rData.index,
            timestamp: block.timestamp,
            shareBalance: newBalance,
            lastRewardIndex: rData.rewardTimestamps.length,
            pendingRewards: pendingRewards
        });

        emit CheckpointCreated(
            user,
            token,
            rData.index,
            block.timestamp,
            rData.rewardTimestamps.length
        );
    }

    /// @notice Calculate pending rewards for a user
    /// @dev Rewards are calculated as:
    /// 1. New rewards = shareBalance * (currentIndex - checkpointIndex) / REWARD_FACTOR
    /// 2. Total pending = newRewards + storedPendingRewards
    /// @param user User address
    /// @param token Reward token address
    /// @return Total pending rewards for the user
    function _calculatePendingRewards(
        address user,
        address token
    ) internal view returns (uint256) {
        Checkpoint memory checkpoint = userCheckpoints[user][token];
        RewardData storage rData = rewardData[token];

        // Calculate rewards since last checkpoint
        uint256 indexDelta = rData.index - checkpoint.rewardIndex;
        // Use mulDivUp for final reward calculation to ensure no dust is left behind
        uint256 newRewards = checkpoint.shareBalance.mulDivUp(indexDelta, REWARD_FACTOR);
        uint256 totalRewards = newRewards + checkpoint.pendingRewards;
        
        console.log("Calculate Pending Rewards");
        console.log("User:", user);
        console.log("Share Balance:", checkpoint.shareBalance);
        console.log("Current Index:", rData.index);
        console.log("Last Index:", checkpoint.rewardIndex);
        console.log("Index Delta:", indexDelta);
        console.log("New Rewards:", newRewards);
        console.log("Stored Pending:", checkpoint.pendingRewards);
        console.log("Total Pending:", totalRewards);
        
        return totalRewards;
    }

    /// @notice Claim rewards for a specific token
    /// @param user Address to claim for
    /// @param token Reward token address
    /// @return amount Amount of rewards claimed
    function _claimReward(
        address user,
        address token
    ) internal returns (uint256) {
        // Update global reward index first
        _updateRewardIndex(token);
        
        // Calculate total pending rewards
        uint256 pendingRewards = _calculatePendingRewards(user, token);
        
        console.log("Claim Reward");
        console.log("User:", user);
        console.log("Token:", token);
        console.log("Pending Rewards:", pendingRewards);
        
        if (pendingRewards > 0) {
            // Reset checkpoint with current index and zero pending rewards
            _createCheckpoint(user, token, balanceOf[user], 0);
            
            // Transfer rewards using SafeERC20
            SafeERC20.safeTransfer(IERC20(token), user, pendingRewards);
            emit RewardsClaimed(user, token, pendingRewards);
            
            console.log("Claimed Amount:", pendingRewards);
        }
        
        return pendingRewards;
    }

    /// @notice Claim all pending rewards for a user
    /// @param user Address to claim for
    function _claimAllRewards(address user) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            _updateRewardIndex(token);
            _claimReward(user, token);
        }
    }

    /// @notice Update reward index for a token
    /// @dev When new rewards arrive:
    /// 1. Calculate new rewards as current balance - last known balance
    /// 2. Record reward arrival timestamp and amount
    /// 3. Increase global index by (newRewards * REWARD_FACTOR) / totalSupply
    /// This ensures rewards are distributed proportionally to all share holders
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
                
                console.log("Update Reward Index");
                console.log("Token:", token);
                console.log("Current Balance:", currentBalance);
                console.log("Last Known Balance:", lastKnownBalance);
                console.log("New Rewards:", newRewards);
                console.log("Total Supply:", supply);
                console.log("Reward Per Share:", rewardPerShare);
                console.log("New Global Index:", rData.index);
                
                emit RewardIndexUpdated(token, rData.index, block.timestamp);
            }
        }
        
        rData.lastUpdateTime = block.timestamp;
    }

    /// @notice Get last known balance from recorded rewards
    function _getLastKnownBalance(address token) internal view returns (uint256 total) {
        RewardData storage rData = rewardData[token];
        for (uint256 i = 0; i < rData.rewardAmounts.length; i++) {
            total += rData.rewardAmounts[i];
        }
    }

    /// @notice Update indices for all reward tokens
    function _updateAllRewardIndices() internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateRewardIndex(rewardTokens[i]);
        }
    }

    /* ============ External View Functions ============ */

    /// @notice Get claimable rewards for a user and token
    /// @param user User address
    /// @param token Reward token address
    /// @return Claimable reward amount
    function getClaimableRewards(
        address user,
        address token
    ) external view returns (uint256) {
        if (balanceOf[user] == 0) return 0;

        Checkpoint memory checkpoint = userCheckpoints[user][token];
        RewardData memory rData = rewardData[token];

        return checkpoint.shareBalance.mulDivDown(rData.index - checkpoint.rewardIndex, REWARD_FACTOR);
    }

    /// @notice Get all reward token addresses
    /// @return Array of reward token addresses
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /// @notice Calculate total vault value (base assets only)
    /// @return Total value in terms of asset tokens
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Get reward data for a token
    /// @param token Reward token address
    /// @return index Current reward index
    /// @return lastUpdateTime Last update timestamp
    /// @return isValid Whether token is valid
    /// @return rewardTimestamps Array of reward timestamps
    /// @return rewardAmounts Array of reward amounts
    function getRewardData(address token) external view returns (
        uint256 index,
        uint256 lastUpdateTime,
        bool isValid,
        uint256[] memory rewardTimestamps,
        uint256[] memory rewardAmounts
    ) {
        RewardData storage data = rewardData[token];
        return (
            data.index,
            data.lastUpdateTime,
            data.isValid,
            data.rewardTimestamps,
            data.rewardAmounts
        );
    }
} 