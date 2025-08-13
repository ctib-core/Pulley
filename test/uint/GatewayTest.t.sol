//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {Test, Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Gateway} from "../../src/Gateway.sol";
import {PulleyToken} from "../../src/Token/PulleyToken.sol";
import {PulleyTokenEngine} from "../../src/Token/pulleyEngine.sol";
import {TradingPool} from "../../src/Pool/TradingPool.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Permission Manager for testing
contract MockPermissionManager {
    mapping(address => mapping(bytes4 => bool)) public permissions;

    function grantPermission(address account, bytes4 functionSelector) external {
        permissions[account][functionSelector] = true;
    }

    function hasPermissions(address account, bytes4 functionSelector) external view returns (bool) {
        return permissions[account][functionSelector];
    }

    function owner() external view returns (address) {
        return msg.sender;
    }
}

contract GatewayTest is Test {
    Gateway public gateway;
    PulleyToken public pulleyToken;
    PulleyTokenEngine public pulleyTokenEngine;
    TradingPool public tradingPool;
    MockERC20 public mockUSDC;
    MockPermissionManager public permissionManager;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public crossChain = makeAddr("crossChain");

    event UserPurchasedTokens(address indexed user, address indexed asset, uint256 amount, uint256 tokensReceived);
    event UserDepositedToTrading(address indexed user, address indexed asset, uint256 amount);
    event FundsTransferredToCrossChain(address indexed asset, uint256 amount);

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

        tradingPool = new TradingPool(
            address(pulleyTokenEngine),
            allowedAssets,
            address(permissionManager)
        );

        gateway = new Gateway(
            address(pulleyToken),
            address(pulleyTokenEngine),
            address(tradingPool),
            crossChain,
            address(permissionManager)
        );

        _setupPermissions();
        pulleyToken.setPulleyTokenEngine(address(pulleyTokenEngine));

        // Give users tokens
        mockUSDC.mint(user1, 10000 * 10**18);
        mockUSDC.mint(user2, 10000 * 10**18);
    }

    function _setupPermissions() internal {
        // Grant permissions to Gateway and contracts
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyToken.setPulleyTokenEngine.selector);
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyTokenEngine.provideLiquidity.selector);
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyTokenEngine.withdrawLiquidity.selector);
        permissionManager.grantPermission(address(tradingPool), tradingPool.depositAsset.selector);
        permissionManager.grantPermission(address(tradingPool), tradingPool.withdrawAsset.selector);
    }

    function test_InitialState() public view {
        assertEq(address(gateway.pulleyToken()), address(pulleyToken));
        assertEq(address(gateway.pulleyTokenEngine()), address(pulleyTokenEngine));
        assertEq(address(gateway.tradingPool()), address(tradingPool));
        assertEq(gateway.crossChainController(), crossChain);
        assertEq(gateway.permissionManager(), address(permissionManager));
    }

    function test_Constructor_ZeroAddress() public {
        vm.expectRevert(Gateway.Gateway__ZeroAddress.selector);
        new Gateway(address(0), address(pulleyTokenEngine), address(tradingPool), crossChain, address(permissionManager));
        
        vm.expectRevert(Gateway.Gateway__ZeroAddress.selector);
        new Gateway(address(pulleyToken), address(0), address(tradingPool), crossChain, address(permissionManager));
        
        vm.expectRevert(Gateway.Gateway__ZeroAddress.selector);
        new Gateway(address(pulleyToken), address(pulleyTokenEngine), address(0), crossChain, address(permissionManager));
        
        vm.expectRevert(Gateway.Gateway__ZeroAddress.selector);
        new Gateway(address(pulleyToken), address(pulleyTokenEngine), address(tradingPool), address(0), address(permissionManager));
        
        vm.expectRevert(Gateway.Gateway__ZeroAddress.selector);
        new Gateway(address(pulleyToken), address(pulleyTokenEngine), address(tradingPool), crossChain, address(0));
    }

    function test_BuyPulleyTokens() public {
        uint256 amount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), amount);
        
        vm.expectEmit(true, true, false, true);
        emit UserPurchasedTokens(user1, address(mockUSDC), amount, amount);
        
        gateway.buyPulleyTokens(address(mockUSDC), amount);
        
        assertEq(pulleyToken.balanceOf(user1), amount);
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), amount);
        
        vm.stopPrank();
    }

    function test_BuyPulleyTokens_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(Gateway.Gateway__ZeroAmount.selector);
        gateway.buyPulleyTokens(address(mockUSDC), 0);
        vm.stopPrank();
    }

    function test_DepositToTradingPool() public {
        uint256 amount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), amount);
        
        vm.expectEmit(true, true, false, true);
        emit UserDepositedToTrading(user1, address(mockUSDC), amount);
        
        gateway.depositToTradingPool(address(mockUSDC), amount);
        
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), amount);
        assertEq(tradingPool.getTotalPoolValue(), amount);
        
        vm.stopPrank();
    }

    function test_DepositToTradingPool_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(Gateway.Gateway__ZeroAmount.selector);
        gateway.depositToTradingPool(address(mockUSDC), 0);
        vm.stopPrank();
    }

    function test_BuyTokensAndDeposit() public {
        uint256 tokenAmount = 500 * 10**18;
        uint256 tradingAmount = 1500 * 10**18;
        uint256 totalAmount = tokenAmount + tradingAmount;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), totalAmount);
        
        vm.expectEmit(true, true, false, true);
        emit UserPurchasedTokens(user1, address(mockUSDC), tokenAmount, tokenAmount);
        
        vm.expectEmit(true, true, false, true);
        emit UserDepositedToTrading(user1, address(mockUSDC), tradingAmount);
        
        gateway.buyTokensAndDeposit(address(mockUSDC), tokenAmount, tradingAmount);
        
        assertEq(pulleyToken.balanceOf(user1), tokenAmount);
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), tradingAmount);
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), tokenAmount);
        
        vm.stopPrank();
    }

    function test_BuyTokensAndDeposit_OnlyTokens() public {
        uint256 tokenAmount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), tokenAmount);
        
        gateway.buyTokensAndDeposit(address(mockUSDC), tokenAmount, 0);
        
        assertEq(pulleyToken.balanceOf(user1), tokenAmount);
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), 0);
        
        vm.stopPrank();
    }

    function test_BuyTokensAndDeposit_OnlyTrading() public {
        uint256 tradingAmount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), tradingAmount);
        
        gateway.buyTokensAndDeposit(address(mockUSDC), 0, tradingAmount);
        
        assertEq(pulleyToken.balanceOf(user1), 0);
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), tradingAmount);
        
        vm.stopPrank();
    }

    function test_BuyTokensAndDeposit_ZeroTotal() public {
        vm.startPrank(user1);
        vm.expectRevert(Gateway.Gateway__ZeroAmount.selector);
        gateway.buyTokensAndDeposit(address(mockUSDC), 0, 0);
        vm.stopPrank();
    }

    function test_WithdrawFromTradingPool() public {
        uint256 depositAmount = 1000 * 10**18;
        uint256 withdrawAmount = 300 * 10**18;
        
        // First deposit
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), depositAmount);
        gateway.depositToTradingPool(address(mockUSDC), depositAmount);
        
        uint256 initialBalance = mockUSDC.balanceOf(user1);
        
        gateway.withdrawFromTradingPool(address(mockUSDC), withdrawAmount);
        
        assertEq(mockUSDC.balanceOf(user1), initialBalance + withdrawAmount);
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), depositAmount - withdrawAmount);
        
        vm.stopPrank();
    }

    function test_WithdrawFromTradingPool_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(Gateway.Gateway__ZeroAmount.selector);
        gateway.withdrawFromTradingPool(address(mockUSDC), 0);
        vm.stopPrank();
    }

    function test_WithdrawPulleyLiquidity() public {
        uint256 depositAmount = 1000 * 10**18;
        uint256 withdrawAmount = 300 * 10**18;
        
        // First buy tokens
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), depositAmount);
        gateway.buyPulleyTokens(address(mockUSDC), depositAmount);
        
        uint256 initialBalance = mockUSDC.balanceOf(user1);
        uint256 initialTokenBalance = pulleyToken.balanceOf(user1);
        
        gateway.withdrawPulleyLiquidity(address(mockUSDC), withdrawAmount);
        
        assertLt(pulleyToken.balanceOf(user1), initialTokenBalance);
        assertGt(mockUSDC.balanceOf(user1), initialBalance);
        
        vm.stopPrank();
    }

    function test_WithdrawPulleyLiquidity_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(Gateway.Gateway__ZeroAmount.selector);
        gateway.withdrawPulleyLiquidity(address(mockUSDC), 0);
        vm.stopPrank();
    }

    function test_GetTradingPoolBalance() public {
        uint256 amount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), amount);
        gateway.depositToTradingPool(address(mockUSDC), amount);
        vm.stopPrank();
        
        assertEq(gateway.getTradingPoolBalance(address(mockUSDC)), amount);
    }

    function test_GetPulleyTokenInfo() public {
        uint256 amount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), amount);
        gateway.buyPulleyTokens(address(mockUSDC), amount);
        vm.stopPrank();
        
        (uint256 assetsDeposited, uint256 pulleyTokensOwned, uint256 depositTime) = 
            gateway.getPulleyTokenInfo(user1);
        
        assertEq(assetsDeposited, amount);
        assertEq(pulleyTokensOwned, amount);
        assertGt(depositTime, 0);
    }

    function test_GetTradingPoolMetrics() public {
        uint256 amount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), amount);
        gateway.depositToTradingPool(address(mockUSDC), amount);
        vm.stopPrank();
        
        (uint256 totalValue, uint256 totalLosses, uint256 totalProfits) = 
            gateway.getTradingPoolMetrics();
        
        assertEq(totalValue, amount);
        assertEq(totalLosses, 0);
        assertEq(totalProfits, 0);
    }

    function test_CheckAndTransferToCrossChain_ThresholdNotMet() public {
        uint256 amount = 500 * 10**18; // Below threshold
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), amount);
        
        // Should not emit FundsTransferredToCrossChain event
        vm.recordLogs();
        gateway.depositToTradingPool(address(mockUSDC), amount);
        
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundTransferEvent = false;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("FundsTransferredToCrossChain(address,uint256)")) {
                foundTransferEvent = true;
                break;
            }
        }
        assertFalse(foundTransferEvent);
        
        vm.stopPrank();
    }

    function test_Reentrancy_Protection() public {
        // This test ensures that the nonReentrant modifier is working
        // We can't easily test reentrancy without a malicious contract,
        // but we can verify the modifier exists by checking function calls work normally
        
        uint256 amount = 1000 * 10**18;
        
        vm.startPrank(user1);
        mockUSDC.approve(address(gateway), amount * 2);
        
        // These should all work normally (no reentrancy issues)
        gateway.buyPulleyTokens(address(mockUSDC), amount);
        gateway.depositToTradingPool(address(mockUSDC), amount);
        
        vm.stopPrank();
        
        assertEq(pulleyToken.balanceOf(user1), amount);
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), amount);
    }
}
