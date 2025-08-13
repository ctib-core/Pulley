//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PulleyToken} from "../../src/Token/PulleyToken.sol";
import {PulleyTokenEngine} from "../../src/Token/pulleyEngine.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18); // Large but reasonable supply
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Permission Manager for testing
contract MockPermissionManager {
    function hasPermissions(address, bytes4) external pure returns (bool) {
        return true; // Allow all for fuzzing
    }
    
    function owner() external view returns (address) {
        return msg.sender;
    }
}

contract PulleyTokenEngineFuzzTest is Test {
    PulleyToken public pulleyToken;
    PulleyTokenEngine public pulleyTokenEngine;
    MockERC20 public mockUSDC;
    MockPermissionManager public permissionManager;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    function setUp() public {
        mockUSDC = new MockERC20("Mock USDC", "mUSDC");
        permissionManager = new MockPermissionManager();

        pulleyToken = new PulleyToken("Pulley Token", "PULL", address(permissionManager));
        
        address[] memory allowedAssets = new address[](1);
        allowedAssets[0] = address(mockUSDC);
        
        pulleyTokenEngine = new PulleyTokenEngine(
            address(pulleyToken),
            allowedAssets,
            address(permissionManager)
        );

        pulleyToken.setPulleyTokenEngine(address(pulleyTokenEngine));

        // Give users tokens for fuzzing
        mockUSDC.mint(user1, 100000 * 10**18);
        mockUSDC.mint(user2, 100000 * 10**18);
        mockUSDC.mint(user3, 100000 * 10**18);
    }

    /// @dev Fuzz test for provideLiquidity function
    /// Tests that providing liquidity always maintains correct token balance relationships
    function testFuzz_ProvideLiquidity(uint256 amount) public {
        // Bound amount to reasonable range
        amount = bound(amount, 1, 1e24); // 1 wei to 1M tokens
        
        vm.startPrank(user1);
        
        // Ensure user has enough balance
        if (mockUSDC.balanceOf(user1) < amount) {
            mockUSDC.mint(user1, amount);
        }
        
        uint256 initialPulleyBalance = pulleyToken.balanceOf(user1);
        uint256 initialAssetReserve = pulleyTokenEngine.getAssetReserve(address(mockUSDC));
        uint256 initialTotalBacking = pulleyTokenEngine.totalBackingValue();
        
        mockUSDC.approve(address(pulleyTokenEngine), amount);
        pulleyTokenEngine.provideLiquidity(address(mockUSDC), amount);
        
        // Invariants to check
        assertEq(pulleyToken.balanceOf(user1), initialPulleyBalance + amount, "Pulley tokens should increase by amount");
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), initialAssetReserve + amount, "Asset reserves should increase by amount");
        assertEq(pulleyTokenEngine.totalBackingValue(), initialTotalBacking + amount, "Total backing should increase by amount");
        
        vm.stopPrank();
    }

    /// @dev Fuzz test for withdrawLiquidity function
    /// Tests that withdrawing liquidity maintains correct proportional relationships
    function testFuzz_WithdrawLiquidity(uint256 depositAmount, uint256 withdrawAmount) public {
        // Bound amounts to reasonable ranges
        depositAmount = bound(depositAmount, 1000, 1e24);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        
        vm.startPrank(user1);
        
        // Ensure user has enough balance
        if (mockUSDC.balanceOf(user1) < depositAmount) {
            mockUSDC.mint(user1, depositAmount);
        }
        
        // First provide liquidity
        mockUSDC.approve(address(pulleyTokenEngine), depositAmount);
        pulleyTokenEngine.provideLiquidity(address(mockUSDC), depositAmount);
        
        uint256 initialAssetReserve = pulleyTokenEngine.getAssetReserve(address(mockUSDC));
        uint256 initialPulleyBalance = pulleyToken.balanceOf(user1);
        uint256 initialUserAssetBalance = mockUSDC.balanceOf(user1);
        
        // Withdraw liquidity
        pulleyTokenEngine.withdrawLiquidity(address(mockUSDC), withdrawAmount);
        
        // Check invariants
        assertLe(pulleyToken.balanceOf(user1), initialPulleyBalance, "Pulley tokens should not increase");
        assertLe(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), initialAssetReserve, "Asset reserves should not increase");
        assertGe(mockUSDC.balanceOf(user1), initialUserAssetBalance, "User should receive assets back");
        
        vm.stopPrank();
    }

    /// @dev Fuzz test for coverTradingLoss function
    /// Tests that loss coverage maintains system invariants
    function testFuzz_CoverTradingLoss(uint256 depositAmount, uint256 lossAmount) public {
        // Bound amounts
        depositAmount = bound(depositAmount, 1000, 1e24);
        lossAmount = bound(lossAmount, 1, depositAmount / 2); // Loss should be reasonable
        
        vm.startPrank(user1);
        
        // Setup: provide liquidity first
        if (mockUSDC.balanceOf(user1) < depositAmount) {
            mockUSDC.mint(user1, depositAmount);
        }
        
        mockUSDC.approve(address(pulleyTokenEngine), depositAmount);
        pulleyTokenEngine.provideLiquidity(address(mockUSDC), depositAmount);
        
        // Add insurance funds
        mockUSDC.approve(address(pulleyTokenEngine), depositAmount / 2);
        pulleyTokenEngine.insuranceBackingMinter(address(mockUSDC), depositAmount / 2);
        
        vm.stopPrank();
        
        // Test loss coverage
        uint256 initialInsuranceFunds = pulleyToken.insuranceFunds();
        uint256 initialTotalLossesCovered = pulleyTokenEngine.totalLossesCovered();
        
        bool coverageResult = pulleyTokenEngine.coverTradingLoss(lossAmount);
        
        if (coverageResult) {
            // If coverage was successful, invariants should hold
            assertGe(pulleyTokenEngine.totalLossesCovered(), initialTotalLossesCovered, "Total losses covered should increase");
            assertLe(pulleyToken.insuranceFunds(), initialInsuranceFunds, "Insurance funds should decrease or stay same");
        }
    }

    /// @dev Fuzz test for multiple users providing liquidity simultaneously
    /// Tests system behavior under concurrent operations
    function testFuzz_MultiUserLiquidity(uint256 amount1, uint256 amount2, uint256 amount3) public {
        // Bound amounts
        amount1 = bound(amount1, 100, 1e20);
        amount2 = bound(amount2, 100, 1e20);
        amount3 = bound(amount3, 100, 1e20);
        
        address[3] memory users = [user1, user2, user3];
        uint256[3] memory amounts = [amount1, amount2, amount3];
        
        uint256 totalExpectedTokens = 0;
        uint256 totalExpectedReserves = 0;
        
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(users[i]);
            
            if (mockUSDC.balanceOf(users[i]) < amounts[i]) {
                mockUSDC.mint(users[i], amounts[i]);
            }
            
            mockUSDC.approve(address(pulleyTokenEngine), amounts[i]);
            pulleyTokenEngine.provideLiquidity(address(mockUSDC), amounts[i]);
            
            totalExpectedTokens += amounts[i];
            totalExpectedReserves += amounts[i];
            
            vm.stopPrank();
        }
        
        // Check system invariants after all operations
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), totalExpectedReserves, "Total reserves should match sum of deposits");
        assertEq(pulleyTokenEngine.totalBackingValue(), totalExpectedTokens, "Total backing should match sum of deposits");
        
        // Check individual balances
        for (uint256 i = 0; i < 3; i++) {
            assertEq(pulleyToken.balanceOf(users[i]), amounts[i], "Individual user balances should be correct");
        }
    }

    /// @dev Fuzz test for edge cases with very small amounts
    function testFuzz_SmallAmounts(uint256 amount) public {
        // Test with very small amounts
        amount = bound(amount, 1, 1000);
        
        vm.startPrank(user1);
        
        if (mockUSDC.balanceOf(user1) < amount) {
            mockUSDC.mint(user1, amount);
        }
        
        mockUSDC.approve(address(pulleyTokenEngine), amount);
        
        // Should not revert with small amounts
        pulleyTokenEngine.provideLiquidity(address(mockUSDC), amount);
        
        // Basic invariant checks
        assertEq(pulleyToken.balanceOf(user1), amount);
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), amount);
        
        vm.stopPrank();
    }

    /// @dev Fuzz test for insurance backing minter
    function testFuzz_InsuranceBackingMinter(uint256 amount) public {
        amount = bound(amount, 1, 1e24);
        
        vm.startPrank(user1);
        
        if (mockUSDC.balanceOf(user1) < amount) {
            mockUSDC.mint(user1, amount);
        }
        
        uint256 initialInsuranceBacking = pulleyTokenEngine.totalInsurancebacking();
        uint256 initialAssetReserve = pulleyTokenEngine.getAssetReserve(address(mockUSDC));
        
        mockUSDC.approve(address(pulleyTokenEngine), amount);
        pulleyTokenEngine.insuranceBackingMinter(address(mockUSDC), amount);
        
        // Check invariants
        assertEq(pulleyTokenEngine.totalInsurancebacking(), initialInsuranceBacking + amount, "Insurance backing should increase");
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), initialAssetReserve + amount, "Asset reserves should increase");
        assertEq(pulleyToken.balanceOf(user1), amount, "User should receive tokens");
        
        vm.stopPrank();
    }
}
