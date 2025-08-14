//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Gateway} from "../src/Gateway.sol";
import {PulleyToken} from "../src/Token/PulleyToken.sol";
import {PulleyTokenEngine} from "../src/Token/pulleyEngine.sol";
import {TradingPool} from "../src/Pool/TradingPool.sol";
import {CrossChainController} from "../src/cross_chain/cross_chain_controller.sol";

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

contract PulleyEcosystemTest is Test {
    Gateway public gateway;
    PulleyToken public pulleyToken;
    PulleyTokenEngine public pulleyTokenEngine;
    TradingPool public tradingPool;
    MockERC20 public mockUSDC;
    MockPermissionManager public permissionManager;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    function setUp() public {
        // Deploy mock tokens and permission manager
        mockUSDC = new MockERC20("Mock USDC", "mUSDC");
        permissionManager = new MockPermissionManager();

        // Deploy core contracts
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

        // Set up permissions
        _setupPermissions();

        // Set PulleyTokenEngine in PulleyToken
        pulleyToken.setPulleyTokenEngine(address(pulleyTokenEngine));

        // Deploy Gateway (CrossChainController address set to zero for testing)
        gateway = new Gateway(
            address(pulleyToken),
            address(pulleyTokenEngine),
            address(tradingPool),
            address(0), // crossChainController
            address(permissionManager)
        );

        // Give users some tokens
        mockUSDC.mint(user1, 10000 * 10**18);
        mockUSDC.mint(user2, 10000 * 10**18);
    }

    function _setupPermissions() internal {
        // Grant permissions to contracts
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyToken.setPulleyTokenEngine.selector);
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyTokenEngine.provideLiquidity.selector);
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyTokenEngine.withdrawLiquidity.selector);
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyTokenEngine.coverTradingLoss.selector);
        permissionManager.grantPermission(address(pulleyTokenEngine), pulleyTokenEngine.distributeProfits.selector);
        
        permissionManager.grantPermission(address(tradingPool), tradingPool.depositAsset.selector);
        permissionManager.grantPermission(address(tradingPool), tradingPool.withdrawAsset.selector);
        permissionManager.grantPermission(address(tradingPool), tradingPool.recordTradingLoss.selector);
        permissionManager.grantPermission(address(tradingPool), tradingPool.recordTradingProfit.selector);
    }

    function testUserFlowBuyTokens() public {
        uint256 depositAmount = 1000 * 10**18;

        vm.startPrank(user1);
        
        // Approve and buy Pulley tokens
        mockUSDC.approve(address(gateway), depositAmount);
        gateway.buyPulleyTokens(address(mockUSDC), depositAmount);

        // Check that user received Pulley tokens
        assertEq(pulleyToken.balanceOf(user1), depositAmount);
        
        // Check that PulleyTokenEngine has the backing assets
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), depositAmount);

        vm.stopPrank();
    }

    function testUserFlowDepositToTrading() public {
        uint256 depositAmount = 1000 * 10**18;

        vm.startPrank(user1);
        
        // Approve and deposit to trading pool
        mockUSDC.approve(address(gateway), depositAmount);
        gateway.depositToTradingPool(address(mockUSDC), depositAmount);

        // Check that trading pool has the assets
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), depositAmount);
        
        vm.stopPrank();
    }

    function testCombinedUserFlow() public {
        uint256 tokenAmount = 500 * 10**18;
        uint256 tradingAmount = 1500 * 10**18;

        vm.startPrank(user1);
        
        // Approve total amount
        mockUSDC.approve(address(gateway), tokenAmount + tradingAmount);
        
        // Buy tokens and deposit to trading in one transaction
        gateway.buyTokensAndDeposit(address(mockUSDC), tokenAmount, tradingAmount);

        // Verify results
        assertEq(pulleyToken.balanceOf(user1), tokenAmount);
        assertEq(tradingPool.getAssetBalance(address(mockUSDC)), tradingAmount);
        assertEq(pulleyTokenEngine.getAssetReserve(address(mockUSDC)), tokenAmount);

        vm.stopPrank();
    }

    function testTradingPoolMetrics() public {
        // Set up some initial state
        testCombinedUserFlow();

        // Check metrics
        (uint256 totalValue, uint256 totalLosses, uint256 totalProfits) = gateway.getTradingPoolMetrics();
        
        assertEq(totalValue, 1500 * 10**18); // Trading amount from previous test
        assertEq(totalLosses, 0);
        assertEq(totalProfits, 0);
    }

    function testPulleyTokenInfo() public {
        testUserFlowBuyTokens();

        (uint256 assetsDeposited, uint256 pulleyTokensOwned, uint256 depositTime) = 
            gateway.getPulleyTokenInfo(user1);

        assertEq(assetsDeposited, 1000 * 10**18);
        assertEq(pulleyTokensOwned, 1000 * 10**18);
        assertGt(depositTime, 0);
    }
}



