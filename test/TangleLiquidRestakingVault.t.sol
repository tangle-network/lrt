// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {TangleLiquidRestakingVault} from "../src/TangleLiquidRestakingVault.sol";
import {MultiAssetDelegation} from "../src/MultiAssetDelegation.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ERC20} from "dependencies/solmate-6.8.0/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "dependencies/solmate-6.8.0/src/utils/FixedPointMathLib.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol, uint8 _decimals) 
        ERC20(name, symbol, _decimals) {
        _mint(msg.sender, 1000000 * (10 ** _decimals));
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TangleLiquidRestakingVaultTest is Test {
    using FixedPointMathLib for uint256;

    // Constants for reward index calculations
    uint256 constant PERIOD2_INDEX_DELTA = 33333333333333333;
    uint256 constant PERIOD3_INDEX_DELTA = 28571428571428571;
    uint256 constant PERIOD4_INDEX_DELTA = 66666666666666666;

    TangleLiquidRestakingVault public vault;
    MockToken public baseToken;
    MockToken public rewardToken1;
    MockToken public rewardToken2;
    
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
        address indexed user,
        address indexed token,
        uint256 index,
        uint256 timestamp,
        uint256 rewardIndex
    );

    function setUp() public {
        // Deploy tokens with different decimals
        baseToken = new MockToken("Base Token", "BASE", 18);
        rewardToken1 = new MockToken("Reward Token 1", "RWD1", 18);
        rewardToken2 = new MockToken("Reward Token 2", "RWD2", 6);
        
        // Setup blueprint selection
        blueprintSelection.push(1);
        
        // Deploy vault
        vault = new TangleLiquidRestakingVault(
            address(baseToken),
            "Tangle Liquid Staked Token",
            "tLST"
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
        emit CheckpointCreated(
            alice,
            address(rewardToken1),
            0,
            block.timestamp,
            0
        );
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

        assertEq(aliceRewards[0], REWARD_AMOUNT + (REWARD_AMOUNT / 2), "Alice should get full first + half second reward");
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
        vm.stopPrank();

        // First reward
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Withdraw half
        vm.startPrank(alice);
        vault.withdraw(INITIAL_DEPOSIT / 2, alice, alice);

        // Second reward
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Deposit again
        vault.deposit(INITIAL_DEPOSIT / 2, alice);
        vm.stopPrank();

        // Third reward
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);

        // Claim
        vm.startPrank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        uint256[] memory rewards = vault.claimRewards(alice, tokens);
        vm.stopPrank();

        // Should get: full first reward + full second reward + full third reward
        // Because Alice is the only holder throughout, even with half shares
        uint256 expected = REWARD_AMOUNT * 3;
        assertEq(rewards[0], expected, "Rewards after withdraw/deposit incorrect");
    }

    function test_ComplexRewardScenario() public {
        // Setup initial state
        vm.startPrank(alice);
        vault.addRewardToken(address(rewardToken1));
        vault.deposit(INITIAL_DEPOSIT, alice);  // Alice: 100e18 shares
        vm.stopPrank();

        // First reward period - only Alice
        rewardToken1.mint(address(vault), REWARD_AMOUNT);  // 10e18 rewards
        
        // Bob joins with double Alice's deposit
        vm.startPrank(bob);
        vault.deposit(INITIAL_DEPOSIT * 2, bob);  // Bob: 200e18 shares
        vm.stopPrank();

        // Second reward period - Alice (1/3) and Bob (2/3)
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);  // 10e18 rewards

        // Alice withdraws half
        vm.startPrank(alice);
        vault.withdraw(INITIAL_DEPOSIT / 2, alice, alice);  // Alice: 50e18 shares
        vm.stopPrank();

        // Charlie joins with same as Alice's original
        vm.startPrank(charlie);
        vault.deposit(INITIAL_DEPOSIT, charlie);  // Charlie: 100e18 shares
        vm.stopPrank();

        // Third reward period - Alice (1/7), Bob (4/7), Charlie (2/7)
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);  // 10e18 rewards

        // Bob withdraws everything
        vm.startPrank(bob);
        vault.withdraw(INITIAL_DEPOSIT * 2, bob, bob);  // Bob: 0 shares
        vm.stopPrank();

        // Fourth reward period - Alice (1/3), Charlie (2/3)
        vm.warp(block.timestamp + 1 days);
        rewardToken1.mint(address(vault), REWARD_AMOUNT);  // 10e18 rewards

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

        // Expected rewards:
        // Alice: 
        // - Period 1: 10e18 (full)
        // - Period 2: 10e18 * 1/3
        // - Period 3: 10e18 * 1/7
        // - Period 4: 10e18 * 1/3
        uint256 expectedAlice = REWARD_AMOUNT + // Period 1
            ((INITIAL_DEPOSIT * PERIOD2_INDEX_DELTA) / 1e18) + // Period 2
            ((INITIAL_DEPOSIT / 2 * PERIOD3_INDEX_DELTA) / 1e18) + // Period 3
            ((INITIAL_DEPOSIT / 2 * PERIOD4_INDEX_DELTA) / 1e18); // Period 4

        // Bob:
        // - Period 2: 10e18 * 2/3
        // - Period 3: 10e18 * 4/7
        uint256 expectedBob = 
            ((INITIAL_DEPOSIT * 2 * PERIOD2_INDEX_DELTA) / 1e18) + // Period 2
            ((INITIAL_DEPOSIT * 2 * PERIOD3_INDEX_DELTA) / 1e18); // Period 3

        // Charlie:
        // - Period 3: 10e18 * 2/7
        // - Period 4: 10e18 * 2/3
        uint256 expectedCharlie = 
            ((INITIAL_DEPOSIT * PERIOD3_INDEX_DELTA) / 1e18) + // Period 3
            ((INITIAL_DEPOSIT * PERIOD4_INDEX_DELTA) / 1e18); // Period 4

        assertEq(aliceRewards[0], expectedAlice, "Alice rewards incorrect");
        assertEq(bobRewards[0], expectedBob, "Bob rewards incorrect");
        assertEq(charlieRewards[0], expectedCharlie, "Charlie rewards incorrect");

        // Verify total rewards distributed equals total rewards added, allowing for small rounding errors
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
        vault.deposit(INITIAL_DEPOSIT, alice);  // Alice: 100e18 shares
        vm.stopPrank();

        // First reward period - only Alice
        rewardToken1.mint(address(vault), REWARD_AMOUNT);  // 10e18 rewards

        // Bob deposits and gets his own rewards
        vm.startPrank(bob);
        vault.deposit(INITIAL_DEPOSIT, bob);  // Bob: 100e18 shares
        vm.stopPrank();

        // Second reward period - Alice and Bob
        rewardToken1.mint(address(vault), REWARD_AMOUNT);  // 10e18 rewards

        // Alice transfers half her shares to Bob
        vm.startPrank(alice);
        vault.transfer(bob, INITIAL_DEPOSIT / 2);  // Alice: 50e18, Bob: 150e18
        vm.stopPrank();

        // Third reward period
        rewardToken1.mint(address(vault), REWARD_AMOUNT);  // 10e18 rewards

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
} 