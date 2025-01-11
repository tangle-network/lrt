// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "dependencies/forge-std-1.9.5/src/Test.sol";
import {ERC20} from "dependencies/solmate-6.8.0/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "dependencies/solmate-6.8.0/src/utils/FixedPointMathLib.sol";

import {TangleLiquidRestakingVault} from "../src/TangleLiquidRestakingVault.sol";
import {MultiAssetDelegation} from "../src/MultiAssetDelegation.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MockMultiAssetDelegation} from "./mock/MockMultiAssetDelegation.sol";
import {MockERC20} from "./mock/MockERC20.sol";

contract TangleLiquidRestakingVaultTest is Test {
    using FixedPointMathLib for uint256;

    // Constants for reward index calculations
    uint256 constant PERIOD2_INDEX_DELTA = 33333333333333333;
    uint256 constant PERIOD3_INDEX_DELTA = 28571428571428571;
    uint256 constant PERIOD4_INDEX_DELTA = 66666666666666666;

    TangleLiquidRestakingVault public vault;
    MockERC20 public baseToken;
    MockERC20 public rewardToken1;
    MockERC20 public rewardToken2;
    MockMultiAssetDelegation public mockMADS;

    bytes32 public constant OPERATOR = bytes32(uint256(1));
    uint64[] public blueprintSelection;
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    uint256 public constant INITIAL_DEPOSIT = 100e18;
    uint256 public constant REWARD_AMOUNT = 10e18;

    event RewardTokenAdded(address indexed token);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event CheckpointCreated(
        address indexed user, address indexed token, uint256 index, uint256 timestamp, uint256 rewardIndex
    );

    function setUp() public {
        // Deploy mock contracts
        baseToken = new MockERC20("Base Token", "BASE", 18);
        rewardToken1 = new MockERC20("Reward Token 1", "RWD1", 18);
        rewardToken2 = new MockERC20("Reward Token 2", "RWD2", 18);
        mockMADS = new MockMultiAssetDelegation();
        blueprintSelection = new uint64[](1);
        blueprintSelection[0] = 1;

        // Deploy vault
        vault = new TangleLiquidRestakingVault(
            address(baseToken), OPERATOR, blueprintSelection, address(mockMADS), "Tangle Liquid Restaking Token", "tLRT"
        );

        // Fund test accounts
        baseToken.mint(alice, 1000e18);
        baseToken.mint(bob, 1000e18);
        baseToken.mint(charlie, 1000e18);

        vm.startPrank(alice);
        baseToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        baseToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        baseToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /* ============ Basic Functionality Tests ============ */

    function test_InitialDeposit() public {
        vm.startPrank(alice);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, alice);
        assertEq(shares, INITIAL_DEPOSIT, "Initial shares should equal deposit");
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT, "Share balance incorrect");
        vm.stopPrank();
    }

    /* ============ Reward Token Tests ============ */

    function test_AddRewardToken() public {
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        (,, bool isValid,,) = vault.getRewardData(address(rewardToken1));
        assertTrue(isValid, "Reward token should be valid");
        assertEq(vault.rewardTokens(0), address(rewardToken1));
        vm.stopPrank();
    }

    function test_RevertWhen_AddingInvalidRewardToken() public {
        vm.startPrank(alice);
        vm.expectRevert(TangleLiquidRestakingVault.InvalidRewardToken.selector);
        vault.addRewardToken(address(0));

        vm.expectRevert(TangleLiquidRestakingVault.InvalidRewardToken.selector);
        vault.addRewardToken(address(baseToken));
        vm.stopPrank();
    }

    function test_RevertWhen_AddingDuplicateRewardToken() public {
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));

        vm.expectRevert(TangleLiquidRestakingVault.RewardTokenAlreadyAdded.selector);
        vault.addRewardToken(address(rewardToken1));
        vm.stopPrank();
    }

    function test_RevertWhen_UnauthorizedClaim() public {
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Add rewards
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Try to claim as Bob for Alice
        vm.startPrank(bob);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.expectRevert(TangleLiquidRestakingVault.Unauthorized.selector);
        vault.claimRewards(alice, tokens);
        vm.stopPrank();
    }

    /* ============ Checkpoint Tests ============ */

    function test_CheckpointCreation() public {
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));

        // Initial deposit creates checkpoint
        vm.expectEmit(true, true, true, true);
        emit CheckpointCreated(alice, address(rewardToken1), 0, block.timestamp, 0);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Verify checkpoint data
        (uint256 rewardIndex,, uint256 shareBalance, uint256 lastRewardIndex, uint256 pendingRewards) =
            vault.userCheckpoints(alice, address(rewardToken1));

        assertEq(rewardIndex, 0, "Initial reward index should be 0");
        assertEq(shareBalance, INITIAL_DEPOSIT, "Share balance in checkpoint incorrect");
        assertEq(lastRewardIndex, 0, "Initial lastRewardIndex should be 0");
        assertEq(pendingRewards, 0, "Initial pending rewards should be 0");
        vm.stopPrank();
    }

    /* ============ Reward Distribution Tests ============ */

    function test_RewardDistribution_SingleUser() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Add rewards
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Claim rewards
        vm.startPrank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);

        assertEq(rewards[0], REWARD_AMOUNT, "Should receive all rewards");
        assertEq(rewardToken1.balanceOf(alice), REWARD_AMOUNT, "Reward balance incorrect");
        vm.stopPrank();
    }

    function test_RewardDistribution_MultipleUsers() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit(INITIAL_DEPOSIT, bob);
        vm.stopPrank();

        // Add rewards
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Both users claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.startPrank(alice);
        uint256[] memory aliceRewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory bobRewards = vault.claimRewards(bob, tokens);
        vm.stopPrank();

        assertEq(aliceRewards[0], REWARD_AMOUNT / 2, "Alice should get half");
        assertEq(bobRewards[0], REWARD_AMOUNT / 2, "Bob should get half");
    }

    function test_RewardDistribution_AfterTransfer() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Add first reward
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Transfer shares to Bob
        vm.startPrank(alice);
        vault.transfer(bob, INITIAL_DEPOSIT / 2);
        vm.stopPrank();

        // Add second reward
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Both claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.startPrank(alice);
        uint256[] memory aliceRewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory bobRewards = vault.claimRewards(bob, tokens);
        vm.stopPrank();

        // Alice should get all of first reward and half of second
        uint256 expectedAlice = REWARD_AMOUNT + (REWARD_AMOUNT / 2);
        // Bob should get half of second reward only
        uint256 expectedBob = REWARD_AMOUNT / 2;

        assertEq(aliceRewards[0], expectedAlice, "Alice rewards incorrect");
        assertEq(bobRewards[0], expectedBob, "Bob rewards incorrect");
    }

    function test_NoHistoricalRewards_ForNewMint() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Add rewards
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // New user deposits
        vm.startPrank(bob);
        vault.deposit(INITIAL_DEPOSIT, bob);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(bob, tokens);

        assertEq(rewards[0], 0, "New depositor should not get historical rewards");
        vm.stopPrank();
    }

    function test_RewardClaim_RequiresShares() public {
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);

        assertEq(rewards[0], 0, "Should not get rewards without shares");
        vm.stopPrank();
    }

    /* ============ Edge Cases ============ */

    function test_ZeroRewards() public {
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);

        assertEq(rewards[0], 0, "Should handle zero rewards gracefully");
        vm.stopPrank();
    }

    function test_MultipleRewardTokens() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.addRewardToken(address(rewardToken2));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Add different rewards
        rewardToken1.mint(address(vault), REWARD_AMOUNT);
        rewardToken2.mint(address(vault), REWARD_AMOUNT * 1e12); // Adjust for decimals

        // Claim both
        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardToken1);
        tokens[1] = address(rewardToken2);

        vm.startPrank(alice);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        assertEq(rewards[0], REWARD_AMOUNT, "First reward incorrect");
        assertEq(rewards[1], REWARD_AMOUNT * 1e12, "Second reward incorrect");
    }

    function test_RewardDistribution_MultipleRewardPeriods() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // First reward period
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Second reward period
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Third reward period
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Claim all rewards
        vm.startPrank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        assertEq(rewards[0], REWARD_AMOUNT * 3, "Should receive all rewards from all periods");
    }

    function test_RewardDistribution_TransferBetweenRewards() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // First reward period
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Transfer half shares to Bob
        vm.startPrank(alice);
        vault.transfer(bob, INITIAL_DEPOSIT / 2);
        vm.stopPrank();

        // Second reward period
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Both claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.startPrank(alice);
        uint256[] memory aliceRewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory bobRewards = vault.claimRewards(bob, tokens);
        vm.stopPrank();

        assertEq(
            aliceRewards[0], REWARD_AMOUNT + (REWARD_AMOUNT / 2), "Alice should get full first + half second reward"
        );
        assertEq(bobRewards[0], REWARD_AMOUNT / 2, "Bob should get half of second reward");
    }

    function test_RewardDistribution_MultipleTransfers() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // First reward
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Transfer 1/4 to Bob
        vm.startPrank(alice);
        vault.transfer(bob, INITIAL_DEPOSIT / 4);
        vm.stopPrank();

        // Second reward
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Transfer 1/4 to Charlie
        vm.startPrank(alice);
        vault.transfer(charlie, INITIAL_DEPOSIT / 4);
        vm.stopPrank();

        // Third reward
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // All claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.startPrank(alice);
        uint256[] memory aliceRewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory bobRewards = vault.claimRewards(bob, tokens);
        vm.stopPrank();

        vm.startPrank(charlie);
        uint256[] memory charlieRewards = vault.claimRewards(charlie, tokens);
        vm.stopPrank();

        // Alice: Full first reward + 3/4 second reward + 1/2 third reward
        uint256 expectedAlice = REWARD_AMOUNT + ((REWARD_AMOUNT * 3) / 4) + (REWARD_AMOUNT / 2);
        // Bob: 1/4 second reward + 1/4 third reward
        uint256 expectedBob = (REWARD_AMOUNT / 4) + (REWARD_AMOUNT / 4);
        // Charlie: 1/4 third reward
        uint256 expectedCharlie = REWARD_AMOUNT / 4;

        assertEq(aliceRewards[0], expectedAlice, "Alice rewards incorrect");
        assertEq(bobRewards[0], expectedBob, "Bob rewards incorrect");
        assertEq(charlieRewards[0], expectedCharlie, "Charlie rewards incorrect");
    }

    function test_RewardDistribution_WithdrawAndDeposit() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);

        // First reward - full amount since Alice has all shares
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18

        // Schedule and execute unstake for half
        vault.scheduleUnstake(INITIAL_DEPOSIT / 2);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();

        // Schedule and execute withdraw
        vault.scheduleWithdraw(INITIAL_DEPOSIT / 2);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.withdraw(INITIAL_DEPOSIT / 2, alice, alice);

        // Second reward - half amount since Alice has half shares
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 (but Alice gets 5e18)

        // Deposit again
        vault.deposit(INITIAL_DEPOSIT / 2, alice);

        // Third reward - full amount since Alice has all shares again
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);

        // Should get:
        // - First reward: 10e18 (full amount)
        // - Second reward: 10e18 (full amount since no other holders)
        // - Third reward: 10e18 (full amount)
        // Total: 30e18
        assertEq(rewards[0], 30e18, "Rewards after withdraw/deposit incorrect");
        vm.stopPrank();
    }

    function test_ComplexRewardScenario() public {
        // Setup initial state
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice); // Alice: 100e18 shares
        vm.stopPrank();

        // First reward period - only Alice
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 rewards

        // Bob joins with double Alice's deposit
        vm.startPrank(bob);
        vault.deposit(INITIAL_DEPOSIT * 2, bob); // Bob: 200e18 shares
        vm.stopPrank();

        // Second reward period - Alice (1/3) and Bob (2/3)
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 rewards

        // Alice schedules and executes unstake for half
        vm.startPrank(alice);
        vault.scheduleUnstake(INITIAL_DEPOSIT / 2);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();

        // Schedule and execute withdraw
        vault.scheduleWithdraw(INITIAL_DEPOSIT / 2);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.withdraw(INITIAL_DEPOSIT / 2, alice, alice);
        vm.stopPrank();

        // Charlie joins with same as Alice's original
        vm.startPrank(charlie);
        vault.deposit(INITIAL_DEPOSIT, charlie); // Charlie: 100e18 shares
        vm.stopPrank();

        // Third reward period - Alice (1/7), Bob (4/7), Charlie (2/7)
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 rewards

        // Bob schedules and executes unstake for everything
        vm.startPrank(bob);
        vault.scheduleUnstake(INITIAL_DEPOSIT * 2);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();

        // Schedule and execute withdraw
        vault.scheduleWithdraw(INITIAL_DEPOSIT * 2);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.withdraw(INITIAL_DEPOSIT * 2, bob, bob);
        vm.stopPrank();

        // Fourth reward period - Alice (1/3), Charlie (2/3)
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 rewards

        // Everyone claims
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.startPrank(alice);
        uint256[] memory aliceRewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory bobRewards = vault.claimRewards(bob, tokens);
        vm.stopPrank();

        vm.startPrank(charlie);
        uint256[] memory charlieRewards = vault.claimRewards(charlie, tokens);
        vm.stopPrank();

        // Expected rewards calculations remain the same...
        uint256 expectedAlice = REWARD_AMOUNT // Period 1
            + ((INITIAL_DEPOSIT * PERIOD2_INDEX_DELTA) / 1e18) // Period 2
            + ((INITIAL_DEPOSIT / 2 * PERIOD3_INDEX_DELTA) / 1e18) // Period 3
            + ((INITIAL_DEPOSIT / 2 * PERIOD4_INDEX_DELTA) / 1e18); // Period 4

        uint256 expectedBob = ((INITIAL_DEPOSIT * 2 * PERIOD2_INDEX_DELTA) / 1e18) // Period 2
            + ((INITIAL_DEPOSIT * 2 * PERIOD3_INDEX_DELTA) / 1e18); // Period 3

        uint256 expectedCharlie = ((INITIAL_DEPOSIT * PERIOD3_INDEX_DELTA) / 1e18) // Period 3
            + ((INITIAL_DEPOSIT * PERIOD4_INDEX_DELTA) / 1e18); // Period 4

        assertEq(aliceRewards[0], expectedAlice, "Alice rewards incorrect");
        assertEq(bobRewards[0], expectedBob, "Bob rewards incorrect");
        assertEq(charlieRewards[0], expectedCharlie, "Charlie rewards incorrect");

        // Verify total rewards distributed equals total rewards added
        assertApproxEqAbs(
            aliceRewards[0] + bobRewards[0] + charlieRewards[0],
            REWARD_AMOUNT * 4,
            1000, // Allow for rounding errors up to 1000 wei
            "Total rewards mismatch"
        );
    }

    function test_RewardPreservation_OnTransfer() public {
        // Setup
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice); // Alice: 100e18 shares
        vm.stopPrank();

        // First reward period - only Alice
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 rewards

        // Bob deposits and gets his own rewards
        vm.startPrank(bob);
        vault.deposit(INITIAL_DEPOSIT, bob); // Bob: 100e18 shares
        vm.stopPrank();

        // Second reward period - Alice and Bob
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 rewards

        // Alice transfers half her shares to Bob
        vm.startPrank(alice);
        vault.transfer(bob, INITIAL_DEPOSIT / 2); // Alice: 50e18, Bob: 150e18
        vm.stopPrank();

        // Third reward period
        rewardToken1.mint(address(vault), REWARD_AMOUNT); // 10e18 rewards

        // Both claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.startPrank(alice);
        uint256[] memory aliceRewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory bobRewards = vault.claimRewards(bob, tokens);
        vm.stopPrank();

        // Calculate expected rewards using the same math as the contract:

        // First period - Alice alone (total supply = 100e18)
        uint256 period1RewardPerShare = REWARD_AMOUNT.mulDivDown(1e18, INITIAL_DEPOSIT); // 0.1e18
        uint256 alicePeriod1 = INITIAL_DEPOSIT.mulDivDown(period1RewardPerShare, 1e18); // 10e18

        // Second period - Alice and Bob split (total supply = 200e18)
        uint256 period2RewardPerShare = REWARD_AMOUNT.mulDivDown(1e18, INITIAL_DEPOSIT * 2); // 0.05e18
        uint256 alicePeriod2 = INITIAL_DEPOSIT.mulDivDown(period2RewardPerShare, 1e18); // 5e18
        uint256 bobPeriod2 = INITIAL_DEPOSIT.mulDivDown(period2RewardPerShare, 1e18); // 5e18

        // Third period - Alice 50e18, Bob 150e18 (total supply = 200e18)
        uint256 period3RewardPerShare = REWARD_AMOUNT.mulDivDown(1e18, INITIAL_DEPOSIT * 2); // 0.05e18
        uint256 alicePeriod3 = (INITIAL_DEPOSIT / 2).mulDivDown(period3RewardPerShare, 1e18); // 2.5e18
        uint256 bobPeriod3 = (INITIAL_DEPOSIT * 3 / 2).mulDivDown(period3RewardPerShare, 1e18); // 7.5e18

        uint256 expectedAlice = alicePeriod1 + alicePeriod2 + alicePeriod3;
        uint256 expectedBob = bobPeriod2 + bobPeriod3;

        assertEq(aliceRewards[0], expectedAlice, "Alice rewards incorrect");
        assertEq(bobRewards[0], expectedBob, "Bob rewards incorrect");
        assertEq(aliceRewards[0] + bobRewards[0], REWARD_AMOUNT * 3, "Total rewards mismatch");
    }

    function test_ScheduleAndCancelUnstake() public {
        // Setup
        uint256 depositAmount = 100e18;
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        baseToken.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // Schedule unstake
        vault.scheduleUnstake(50e18);
        assertEq(vault.scheduledUnstakeAmount(alice), 50e18, "Initial scheduled amount incorrect");

        // Add rewards to test reward tracking
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Cancel partial unstake
        vault.cancelUnstake(20e18);
        assertEq(vault.scheduledUnstakeAmount(alice), 30e18, "Remaining scheduled amount incorrect");

        // Cancel remaining unstake
        vault.cancelUnstake(30e18);
        assertEq(vault.scheduledUnstakeAmount(alice), 0, "Final scheduled amount should be 0");

        // Verify rewards resumed for cancelled amount
        rewardToken1.mint(address(vault), REWARD_AMOUNT);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);
        assertGt(rewards[0], 0, "Should earn rewards after cancel");
        vm.stopPrank();
    }

    function test_ScheduleAndCancelWithdraw() public {
        // Setup
        uint256 depositAmount = 100e18;
        vm.startPrank(alice);
        baseToken.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // First schedule and execute unstake
        vault.scheduleUnstake(50e18);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();
        assertEq(vault.unstakeAmount(alice), 50e18, "Unstake amount incorrect");

        // Schedule withdraw
        vault.scheduleWithdraw(30e18);
        assertEq(vault.scheduledWithdrawAmount(alice), 30e18, "Initial scheduled withdraw incorrect");
        assertEq(vault.unstakeAmount(alice), 20e18, "Remaining unstake amount incorrect");

        // Cancel partial withdraw
        vault.cancelWithdraw(10e18);
        assertEq(vault.scheduledWithdrawAmount(alice), 20e18, "Remaining scheduled withdraw incorrect");
        assertEq(vault.unstakeAmount(alice), 30e18, "Updated unstake amount incorrect");

        // Cancel remaining withdraw
        vault.cancelWithdraw(20e18);
        assertEq(vault.scheduledWithdrawAmount(alice), 0, "Final scheduled withdraw should be 0");
        assertEq(vault.unstakeAmount(alice), 50e18, "Final unstake amount incorrect");
        vm.stopPrank();
    }

    function test_RevertWhen_CancellingMoreThanScheduled() public {
        // Setup
        uint256 depositAmount = 100e18;
        vm.startPrank(alice);
        baseToken.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // Schedule unstake
        vault.scheduleUnstake(50e18);

        // Try to cancel more than scheduled
        vm.expectRevert(TangleLiquidRestakingVault.InsufficientScheduledAmount.selector);
        vault.cancelUnstake(60e18);

        // Execute unstake
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();

        // Schedule withdraw
        vault.scheduleWithdraw(30e18);

        // Try to cancel more than scheduled
        vm.expectRevert(TangleLiquidRestakingVault.InsufficientScheduledAmount.selector);
        vault.cancelWithdraw(40e18);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawingWithoutUnstake() public {
        // Setup
        uint256 depositAmount = 100e18;
        vm.startPrank(alice);
        baseToken.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // Try to schedule withdraw without unstaking
        vm.expectRevert(TangleLiquidRestakingVault.WithdrawalNotUnstaked.selector);
        vault.scheduleWithdraw(50e18);
        vm.stopPrank();
    }

    function test_ScheduleUnstake() public {
        // Initial deposit from Alice
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Schedule unstake
        vault.scheduleUnstake(50e18);

        // Verify scheduled amount in vault
        assertEq(vault.scheduledUnstakeAmount(alice), 50e18, "Scheduled amount in vault incorrect");

        // Verify scheduled amount in MADS
        (uint256 amount, uint256 timestamp) = mockMADS.getScheduledUnstake(address(vault), alice);
        assertEq(amount, 50e18, "Scheduled amount in MADS incorrect");
        assertEq(timestamp, block.timestamp + 1 weeks, "Scheduled timestamp incorrect");

        vm.stopPrank();
    }

    function test_CancelUnstake() public {
        // Initial deposit from Alice
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Schedule and then cancel unstake
        vault.scheduleUnstake(50e18);
        vault.cancelUnstake(50e18);

        // Verify cancelled (amount should be 0)
        (uint256 amount,) = mockMADS.getScheduledUnstake(address(baseToken), alice);
        assertEq(amount, 0);

        vm.stopPrank();
    }

    function test_ScheduleWithdraw() public {
        // Initial deposit from Alice
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Schedule and execute unstake first
        vault.scheduleUnstake(50e18);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();
        assertEq(vault.unstakeAmount(alice), 50e18);

        // Schedule withdraw
        vault.scheduleWithdraw(50e18);

        // Verify scheduled amount
        assertEq(vault.scheduledWithdrawAmount(alice), 50e18);
        assertEq(vault.unstakeAmount(alice), 0);

        vm.stopPrank();
    }

    function test_CancelWithdraw() public {
        // Initial deposit from Alice
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Schedule and execute unstake first
        vault.scheduleUnstake(50e18);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();
        assertEq(vault.unstakeAmount(alice), 50e18);

        // Schedule and then cancel withdraw
        vault.scheduleWithdraw(50e18);
        vault.cancelWithdraw(50e18);

        // Verify cancelled (amount should be 0)
        assertEq(vault.scheduledWithdrawAmount(alice), 0);
        assertEq(vault.unstakeAmount(alice), 50e18);

        vm.stopPrank();
    }

    function test_ExecuteUnstake() public {
        // Initial deposit from Alice
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Schedule unstake
        vault.scheduleUnstake(50e18);
        assertEq(vault.scheduledUnstakeAmount(alice), 50e18, "Initial scheduled amount incorrect");

        // Warp time forward past delay
        vm.warp(block.timestamp + 1 weeks + 1);

        // Execute unstake
        vault.executeUnstake();

        // Verify unstake executed
        assertEq(vault.scheduledUnstakeAmount(alice), 0, "Scheduled amount should be cleared");
        assertEq(vault.unstakeAmount(alice), 50e18, "Unstaked amount should be updated");

        vm.stopPrank();
    }

    function test_ExecuteWithdraw() public {
        // Setup
        uint256 depositAmount = 100e18;
        vm.startPrank(alice);
        baseToken.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // Schedule and execute unstake
        vault.scheduleUnstake(50e18);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();
        assertEq(vault.unstakeAmount(alice), 50e18, "Unstake amount incorrect");

        // Schedule withdraw
        vault.scheduleWithdraw(30e18);
        assertEq(vault.scheduledWithdrawAmount(alice), 30e18, "Scheduled withdraw amount incorrect");
        assertEq(vault.unstakeAmount(alice), 20e18, "Remaining unstake amount incorrect");

        // Wait for withdraw delay
        vm.warp(block.timestamp + 1 weeks + 1);

        // Execute withdraw
        uint256 balanceBefore = baseToken.balanceOf(alice);
        vault.withdraw(30e18, alice, alice);
        uint256 balanceAfter = baseToken.balanceOf(alice);

        // Verify withdraw executed
        assertEq(balanceAfter - balanceBefore, 30e18, "Withdraw amount incorrect");
        assertEq(vault.scheduledWithdrawAmount(alice), 0, "Scheduled withdraw should be cleared");
        assertEq(vault.unstakeAmount(alice), 20e18, "Remaining unstake amount incorrect");
        vm.stopPrank();
    }

    function test_RevertWhen_ExecutingUnstakeBeforeDelay() public {
        // Initial deposit from Alice
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Schedule unstake
        vault.scheduleUnstake(50e18);
        assertEq(vault.scheduledUnstakeAmount(alice), 50e18, "Scheduled amount incorrect");

        // Try to execute before delay
        vm.expectRevert(MockMultiAssetDelegation.DelayNotElapsed.selector);
        vault.executeUnstake();

        vm.stopPrank();
    }

    function test_RevertWhen_ExecutingWithdrawBeforeDelay() public {
        // Setup
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        // Schedule and execute unstake
        vault.scheduleUnstake(50e18);
        vm.warp(block.timestamp + 1 weeks + 1);
        vault.executeUnstake();
        assertEq(vault.unstakeAmount(alice), 50e18, "Unstake amount incorrect");

        // Schedule withdraw
        vault.scheduleWithdraw(50e18);
        assertEq(vault.scheduledWithdrawAmount(alice), 50e18, "Scheduled withdraw amount incorrect");
        assertEq(vault.unstakeAmount(alice), 0, "Unstake amount should be 0");

        // Try to withdraw before delay
        vm.expectRevert(MockMultiAssetDelegation.DelayNotElapsed.selector);
        vault.withdraw(50e18, alice, alice);

        vm.stopPrank();
    }

    function test_RevertWhen_CancellingNonExistentUnstake() public {
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        vm.expectRevert(TangleLiquidRestakingVault.InsufficientScheduledAmount.selector);
        vault.cancelUnstake(50e18);

        vm.stopPrank();
    }

    function test_RevertWhen_CancellingNonExistentWithdraw() public {
        vm.startPrank(alice);
        vault.deposit(INITIAL_DEPOSIT, alice);

        vm.expectRevert(TangleLiquidRestakingVault.InsufficientScheduledAmount.selector);
        vault.cancelWithdraw(50e18);

        vm.stopPrank();
    }

    function test_RevertWhen_SchedulingWithdrawBeforeUnstake() public {
        // Setup
        uint256 depositAmount = 100e18;
        vm.startPrank(alice);
        baseToken.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // Try to schedule withdraw without unstaking first
        vm.expectRevert(TangleLiquidRestakingVault.WithdrawalNotUnstaked.selector);
        vault.scheduleWithdraw(50e18);

        vm.stopPrank();
    }
}
