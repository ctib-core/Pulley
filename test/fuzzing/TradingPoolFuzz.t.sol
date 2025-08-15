//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TradingPool} from "../../src/Pool/TradingPool.sol";
import {PulleyToken} from "../../src/Token/PulleyToken.sol";
import {PulleyTokenEngine} from "../../src/Token/pulleyEngine.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Permission Manager for testing
contract MockPermissionManager {
    function hasPermissions(address, bytes4) external pure returns (bool) {
        return true;
    }

    function owner() external view returns (address) {
        return msg.sender;
    }
}

contract TradingPoolFuzzTest is Test {
    TradingPool public tradingPool;
    PulleyToken public pulleyToken;
    PulleyTokenEngine public pulleyTokenEngine;
    MockERC20 public mockUSDC;
    MockERC20 public mockUSDT;
    MockPermissionManager public permissionManager;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public trader = makeAddr("trader");

    function setUp() public {
        mockUSDC = new MockERC20("Mock USDC", "mUSDC");
        mockUSDT = new MockERC20("Mock USDT", "mUSDT");
        permissionManager = new MockPermissionManager();

        pulleyToken = new PulleyToken("Pulley Token", "PULL", address(permissionManager));

        address[] memory allowedAssets = new address[](2);
        allowedAssets[0] = address(mockUSDC);
        allowedAssets[1] = address(mockUSDT);

        pulleyTokenEngine = new PulleyTokenEngine(address(pulleyToken), allowedAssets, address(permissionManager));

        tradingPool = new TradingPool(address(pulleyTokenEngine), allowedAssets, address(permissionManager));

        pulleyToken.setPulleyTokenEngine(address(pulleyTokenEngine));

        // Give users tokens for fuzzing
        mockUSDC.mint(user1, 100000 * 10 ** 18);
        mockUSDC.mint(user2, 100000 * 10 ** 18);
        mockUSDC.mint(trader, 100000 * 10 ** 18);

        mockUSDT.mint(user1, 100000 * 10 ** 18);
        mockUSDT.mint(user2, 100000 * 10 ** 18);
        mockUSDT.mint(trader, 100000 * 10 ** 18);
    }

    /// @dev Fuzz test for depositAsset function
    function testFuzz_DepositAsset(uint256 amount) public {
        amount = bound(amount, 1, 1e24);

        vm.startPrank(user1);

        if (mockUSDC.balanceOf(user1) < amount) {
            mockUSDC.mint(user1, amount);
        }

        uint256 initialPoolValue = tradingPool.getTotalPoolValue();
        uint256 initialAssetBalance = tradingPool.getAssetBalance(address(mockUSDC));

        mockUSDC.approve(address(tradingPool), amount);
        tradingPool.depositAsset(address(mockUSDC), amount);

        // Check invariants
        assertEq(
            tradingPool.getTotalPoolValue(), initialPoolValue + amount, "Pool value should increase by deposit amount"
        );
        assertEq(
            tradingPool.getAssetBalance(address(mockUSDC)),
            initialAssetBalance + amount,
            "Asset balance should increase"
        );

        vm.stopPrank();
    }

    /// @dev Fuzz test for withdrawAsset function
    function testFuzz_WithdrawAsset(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1000, 1e24);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        vm.startPrank(user1);

        // First deposit
        if (mockUSDC.balanceOf(user1) < depositAmount) {
            mockUSDC.mint(user1, depositAmount);
        }

        mockUSDC.approve(address(tradingPool), depositAmount);
        tradingPool.depositAsset(address(mockUSDC), depositAmount);

        uint256 initialUserBalance = mockUSDC.balanceOf(user1);
        uint256 initialPoolValue = tradingPool.getTotalPoolValue();

        // Withdraw
        tradingPool.withdrawAsset(address(mockUSDC), withdrawAmount, user1);

        // Check invariants
        assertEq(mockUSDC.balanceOf(user1), initialUserBalance + withdrawAmount, "User should receive withdrawn amount");
        assertEq(tradingPool.getTotalPoolValue(), initialPoolValue - withdrawAmount, "Pool value should decrease");

        vm.stopPrank();
    }

    /// @dev Fuzz test for recordTradingLoss function
    function testFuzz_RecordTradingLoss(uint256 depositAmount, uint256 lossAmount) public {
        depositAmount = bound(depositAmount, 10000, 1e24); // Minimum for loss calculations
        lossAmount = bound(lossAmount, 1, depositAmount);

        // Setup: deposit some assets first
        vm.startPrank(user1);
        if (mockUSDC.balanceOf(user1) < depositAmount) {
            mockUSDC.mint(user1, depositAmount);
        }
        mockUSDC.approve(address(tradingPool), depositAmount);
        tradingPool.depositAsset(address(mockUSDC), depositAmount);
        vm.stopPrank();

        // Setup PulleyTokenEngine with some liquidity for loss coverage
        vm.startPrank(user2);
        if (mockUSDC.balanceOf(user2) < depositAmount) {
            mockUSDC.mint(user2, depositAmount);
        }
        mockUSDC.approve(address(pulleyTokenEngine), depositAmount);
        pulleyTokenEngine.provideLiquidity(address(mockUSDC), depositAmount);
        vm.stopPrank();

        uint256 initialTotalLosses = tradingPool.totalTradingLosses();
        uint256 initialPoolValue = tradingPool.getTotalPoolValue();

        // Record trading loss
        tradingPool.recordTradingLoss(lossAmount);

        // Check invariants
        assertEq(tradingPool.totalTradingLosses(), initialTotalLosses + lossAmount, "Total losses should increase");

        // Pool value should decrease unless covered by PulleyToken
        if (lossAmount <= (initialPoolValue * 5) / 100) {
            // Small loss, might be covered
            assertLe(tradingPool.getTotalPoolValue(), initialPoolValue, "Pool value should not increase");
        } else {
            // Large loss, should reduce pool value
            assertLt(tradingPool.getTotalPoolValue(), initialPoolValue, "Pool value should decrease for large losses");
        }
    }

    /// @dev Fuzz test for recordTradingProfit function
    function testFuzz_RecordTradingProfit(uint256 depositAmount, uint256 profitAmount) public {
        depositAmount = bound(depositAmount, 1000, 1e24);
        profitAmount = bound(profitAmount, 1, depositAmount);

        // Setup: deposit some assets first
        vm.startPrank(user1);
        if (mockUSDC.balanceOf(user1) < depositAmount) {
            mockUSDC.mint(user1, depositAmount);
        }
        mockUSDC.approve(address(tradingPool), depositAmount);
        tradingPool.depositAsset(address(mockUSDC), depositAmount);
        vm.stopPrank();

        uint256 initialTotalProfits = tradingPool.totalTradingProfits();
        uint256 initialPoolValue = tradingPool.getTotalPoolValue();
        uint256 initialPendingDistribution = tradingPool.getPendingProfitDistribution();

        // Record trading profit
        tradingPool.recordTradingProfit(profitAmount);

        // Check invariants
        assertEq(tradingPool.totalTradingProfits(), initialTotalProfits + profitAmount, "Total profits should increase");
        assertEq(tradingPool.getTotalPoolValue(), initialPoolValue + profitAmount, "Pool value should increase");
        assertEq(
            tradingPool.getPendingProfitDistribution(),
            initialPendingDistribution + profitAmount,
            "Pending distribution should increase"
        );
    }

    /// @dev Fuzz test for distributeProfits function
    function testFuzz_DistributeProfits(uint256 profitAmount) public {
        profitAmount = bound(profitAmount, 1000, 1e24);

        // Setup: record some profits first
        vm.startPrank(user1);
        if (mockUSDC.balanceOf(user1) < profitAmount * 2) {
            mockUSDC.mint(user1, profitAmount * 2);
        }
        mockUSDC.approve(address(tradingPool), profitAmount);
        tradingPool.depositAsset(address(mockUSDC), profitAmount);
        vm.stopPrank();

        // Record profit
        tradingPool.recordTradingProfit(profitAmount);

        uint256 initialPendingDistribution = tradingPool.getPendingProfitDistribution();

        // Distribute profits
        (uint256 pulleyShare, uint256 poolShare) = tradingPool.distributeProfits();

        // Check invariants
        assertEq(
            tradingPool.getPendingProfitDistribution(), 0, "Pending distribution should be zero after distribution"
        );
        assertEq(pulleyShare + poolShare, initialPendingDistribution, "Shares should sum to total distribution");

        // If no losses were covered by PulleyToken, all profits should go to pool
        if (tradingPool.totalLossesCoveredByPulley() == 0) {
            assertEq(pulleyShare, 0, "Pulley share should be zero if no losses covered");
            assertEq(poolShare, initialPendingDistribution, "Pool should get all profits");
        }
    }

    /// @dev Fuzz test for multiple asset deposits
    function testFuzz_MultiAssetDeposits(uint256 usdcAmount, uint256 usdtAmount) public {
        usdcAmount = bound(usdcAmount, 100, 1e20);
        usdtAmount = bound(usdtAmount, 100, 1e20);

        vm.startPrank(user1);

        // Deposit USDC
        if (mockUSDC.balanceOf(user1) < usdcAmount) {
            mockUSDC.mint(user1, usdcAmount);
        }
        mockUSDC.approve(address(tradingPool), usdcAmount);
        tradingPool.depositAsset(address(mockUSDC), usdcAmount);

        // Deposit USDT
        if (mockUSDT.balanceOf(user1) < usdtAmount) {
            mockUSDT.mint(user1, usdtAmount);
        }
        mockUSDT.approve(address(tradingPool), usdtAmount);
        tradingPool.depositAsset(address(mockUSDT), usdtAmount);

        // Check invariants
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), usdcAmount, "USDC balance should be correct");
        assertEq(tradingPool.getAssetBalance(address(mockUSDT)), usdtAmount, "USDT balance should be correct");
        assertEq(tradingPool.getTotalPoolValue(), usdcAmount + usdtAmount, "Total pool value should be sum of deposits");

        vm.stopPrank();
    }

    /// @dev Fuzz test for profit sharing ratio updates
    function testFuzz_ProfitSharingRatio(uint256 totalLoss, uint256 coveredLoss) public {
        totalLoss = bound(totalLoss, 1000, 1e24);
        coveredLoss = bound(coveredLoss, 0, totalLoss);

        // Simulate losses and coverage
        vm.startPrank(user1);
        if (mockUSDC.balanceOf(user1) < totalLoss * 2) {
            mockUSDC.mint(user1, totalLoss * 2);
        }
        mockUSDC.approve(address(tradingPool), totalLoss);
        tradingPool.depositAsset(address(mockUSDC), totalLoss);
        vm.stopPrank();

        // Setup PulleyTokenEngine with liquidity
        vm.startPrank(user2);
        if (mockUSDC.balanceOf(user2) < coveredLoss) {
            mockUSDC.mint(user2, coveredLoss);
        }
        mockUSDC.approve(address(pulleyTokenEngine), coveredLoss);
        pulleyTokenEngine.provideLiquidity(address(mockUSDC), coveredLoss);
        vm.stopPrank();

        uint256 initialProfitShare = tradingPool.pulleyTokenProfitShare();

        // Record loss (this should trigger profit sharing ratio update)
        tradingPool.recordTradingLoss(totalLoss);

        uint256 finalProfitShare = tradingPool.pulleyTokenProfitShare();

        // Check that profit share is within expected bounds (20% to 80%)
        assertGe(finalProfitShare, 20, "Profit share should be at least 20%");
        assertLe(finalProfitShare, 80, "Profit share should be at most 80%");
    }

    /// @dev Fuzz test for edge case with zero amounts (should revert)
    function testFuzz_ZeroAmountReverts(address asset) public {
        vm.assume(asset == address(mockUSDC) || asset == address(mockUSDT));

        vm.startPrank(user1);

        // All these should revert with zero amount
        vm.expectRevert();
        tradingPool.depositAsset(asset, 0);

        vm.expectRevert();
        tradingPool.withdrawAsset(asset, 0, user1);

        vm.expectRevert();
        tradingPool.recordTradingLoss(0);

        vm.expectRevert();
        tradingPool.recordTradingProfit(0);

        vm.stopPrank();
    }
}
