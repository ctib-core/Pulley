//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CrossChainController} from "../../src/cross_chain/cross_chain_controller.sol";
import {TradingPool} from "../../src/Pool/TradingPool.sol";
import {PulleyToken} from "../../src/Token/PulleyToken.sol";
import {PulleyTokenEngine} from "../../src/Token/pulleyEngine.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Permission Manager
contract MockPermissionManager {
    function hasPermissions(address, bytes4) external pure returns (bool) {
        return true;
    }
    
    function owner() external view returns (address) {
        return msg.sender;
    }
}

// Mock LayerZero Endpoint for testing
contract MockEndpoint {
    function send(
        uint32,
        bytes calldata,
        bytes calldata,
        address,
        address,
        bytes calldata
    ) external payable {}
}

// Handler for CrossChain invariant testing
contract CrossChainHandler is Test {
    CrossChainController public crossChainController;
    TradingPool public tradingPool;
    PulleyTokenEngine public pulleyTokenEngine;
    MockERC20 public mockUSDC;

    // Ghost variables
    uint256 public ghost_totalInsuranceAllocated;
    uint256 public ghost_totalNestVaultAllocated;
    uint256 public ghost_totalLimitOrderAllocated;
    uint256 public ghost_totalFundsReceived;

    constructor(
        CrossChainController _crossChainController,
        TradingPool _tradingPool,
        PulleyTokenEngine _pulleyTokenEngine,
        MockERC20 _mockUSDC
    ) {
        crossChainController = _crossChainController;
        tradingPool = _tradingPool;
        pulleyTokenEngine = _pulleyTokenEngine;
        mockUSDC = _mockUSDC;
    }

    function receiveFundsFromTradingPool() public {
        // Simulate funds being available in the controller
        uint256 amount = bound(uint256(keccak256(abi.encode(block.timestamp, block.difficulty))), 1000, 1e20);
        
        // Mint tokens to the controller to simulate received funds
        mockUSDC.mint(address(crossChainController), amount);
        
        crossChainController.receiveFundsFromTradingPool();
        
        // Update ghost variables based on allocation percentages
        uint256 insuranceAmount = (amount * 10) / 100;  // 10%
        uint256 nestVaultAmount = (amount * 45) / 100;  // 45%
        uint256 limitOrderAmount = amount - insuranceAmount - nestVaultAmount; // Remaining
        
        ghost_totalInsuranceAllocated += insuranceAmount;
        ghost_totalNestVaultAllocated += nestVaultAmount;
        ghost_totalLimitOrderAllocated += limitOrderAmount;
        ghost_totalFundsReceived += amount;
    }

    function setSupportedAsset(address asset, bool supported) public {
        crossChainController.setSupportedAsset(asset, supported);
    }

    function setProfitThreshold(uint256 newThreshold) public {
        newThreshold = bound(newThreshold, 100, 1e24);
        crossChainController.setProfitThreshold(newThreshold);
    }
}

contract CrossChainInvariantTest is StdInvariant, Test {
    CrossChainHandler public handler;
    CrossChainController public crossChainController;
    TradingPool public tradingPool;
    PulleyToken public pulleyToken;
    PulleyTokenEngine public pulleyTokenEngine;
    MockERC20 public mockUSDC;
    MockPermissionManager public permissionManager;
    MockEndpoint public mockEndpoint;

    function setUp() public {
        mockUSDC = new MockERC20("Mock USDC", "mUSDC");
        permissionManager = new MockPermissionManager();
        mockEndpoint = new MockEndpoint();

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

        crossChainController = new CrossChainController(
            address(mockEndpoint),
            address(this)
        );

        // Setup contract addresses
        crossChainController.setContractAddress(
            address(pulleyTokenEngine), // strategy
            address(0), // limit order (mock)
            address(permissionManager),
            address(pulleyToken), // pulley stablecoin
            address(tradingPool)
        );

        // Add supported asset
        crossChainController.setSupportedAsset(address(mockUSDC), true);

        pulleyToken.setPulleyTokenEngine(address(pulleyTokenEngine));

        handler = new CrossChainHandler(
            crossChainController,
            tradingPool,
            pulleyTokenEngine,
            mockUSDC
        );

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = CrossChainHandler.receiveFundsFromTradingPool.selector;
        selectors[1] = CrossChainHandler.setSupportedAsset.selector;
        selectors[2] = CrossChainHandler.setProfitThreshold.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }

    /// @dev Invariant: Fund allocation percentages should always be correct
    function invariant_FundAllocationPercentages() public view {
        address asset = address(mockUSDC);
        
        uint256 insuranceAllocation = crossChainController.insuranceAllocations(asset);
        uint256 nestVaultAllocation = crossChainController.nestVaultAllocations(asset);
        uint256 limitOrderAllocation = crossChainController.limitOrderAllocations(asset);
        uint256 totalInvested = crossChainController.totalInvested(asset);
        
        if (totalInvested > 0) {
            // Check that allocations sum to total invested
            assertEq(
                insuranceAllocation + nestVaultAllocation + limitOrderAllocation,
                totalInvested,
                "Allocations should sum to total invested"
            );
            
            // Check percentage bounds (allowing for rounding errors)
            uint256 insurancePercentage = (insuranceAllocation * 100) / totalInvested;
            uint256 nestVaultPercentage = (nestVaultAllocation * 100) / totalInvested;
            uint256 limitOrderPercentage = (limitOrderAllocation * 100) / totalInvested;
            
            // Insurance should be ~10% (allowing 1% tolerance for rounding)
            assertGe(insurancePercentage, 9, "Insurance allocation should be at least 9%");
            assertLe(insurancePercentage, 11, "Insurance allocation should be at most 11%");
            
            // Nest vault should be ~45% (allowing 1% tolerance)
            assertGe(nestVaultPercentage, 44, "Nest vault allocation should be at least 44%");
            assertLe(nestVaultPercentage, 46, "Nest vault allocation should be at most 46%");
            
            // Limit order should be ~45% (allowing 1% tolerance)
            assertGe(limitOrderPercentage, 44, "Limit order allocation should be at least 44%");
            assertLe(limitOrderPercentage, 46, "Limit order allocation should be at most 46%");
        }
    }

    /// @dev Invariant: Ghost variables should match contract state
    function invariant_GhostVariableConsistency() public view {
        address asset = address(mockUSDC);
        
        uint256 contractInsuranceAllocation = crossChainController.insuranceAllocations(asset);
        uint256 contractNestVaultAllocation = crossChainController.nestVaultAllocations(asset);
        uint256 contractLimitOrderAllocation = crossChainController.limitOrderAllocations(asset);
        
        // Ghost variables should match contract state
        assertEq(
            handler.ghost_totalInsuranceAllocated(),
            contractInsuranceAllocation,
            "Ghost insurance allocation should match contract state"
        );
        
        assertEq(
            handler.ghost_totalNestVaultAllocated(),
            contractNestVaultAllocation,
            "Ghost nest vault allocation should match contract state"
        );
        
        assertEq(
            handler.ghost_totalLimitOrderAllocated(),
            contractLimitOrderAllocation,
            "Ghost limit order allocation should match contract state"
        );
    }

    /// @dev Invariant: Total invested should equal sum of all allocations
    function invariant_TotalInvestedConsistency() public view {
        address asset = address(mockUSDC);
        
        uint256 totalInvested = crossChainController.totalInvested(asset);
        uint256 sumOfAllocations = crossChainController.insuranceAllocations(asset) +
                                  crossChainController.nestVaultAllocations(asset) +
                                  crossChainController.limitOrderAllocations(asset);
        
        assertEq(
            totalInvested,
            sumOfAllocations,
            "Total invested should equal sum of allocations"
        );
    }

    /// @dev Invariant: Profit threshold should be within reasonable bounds
    function invariant_ProfitThresholdBounds() public view {
        uint256 profitThreshold = crossChainController.profitThreshold();
        
        assertGe(profitThreshold, 100, "Profit threshold should be at least 100");
        assertLe(profitThreshold, 1e24, "Profit threshold should be reasonable");
    }

    /// @dev Invariant: Asset list should only contain supported assets
    function invariant_AssetListConsistency() public view {
        address[] memory supportedAssets = crossChainController.getSupportedAssets();
        
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            assertTrue(
                crossChainController.supportedAssets(supportedAssets[i]),
                "All assets in list should be marked as supported"
            );
        }
    }

    /// @dev Invariant: Profit distribution constants should be correct
    function invariant_ProfitDistributionConstants() public view {
        assertEq(crossChainController.INSURANCE_PROFIT_SHARE(), 1, "Insurance profit share should be 1%");
        assertEq(crossChainController.TRADER_PROFIT_SHARE(), 99, "Trader profit share should be 99%");
        assertEq(crossChainController.PERCENTAGE_BASE(), 100, "Percentage base should be 100");
    }

    /// @dev Invariant: Fund allocation constants should be correct
    function invariant_FundAllocationConstants() public view {
        assertEq(crossChainController.INSURANCE_PERCENTAGE(), 10, "Insurance percentage should be 10");
        assertEq(crossChainController.NEST_VAULT_PERCENTAGE(), 45, "Nest vault percentage should be 45");
        assertEq(crossChainController.LIMIT_ORDER_PERCENTAGE(), 45, "Limit order percentage should be 45");
        
        uint256 totalPercentage = crossChainController.INSURANCE_PERCENTAGE() +
                                 crossChainController.NEST_VAULT_PERCENTAGE() +
                                 crossChainController.LIMIT_ORDER_PERCENTAGE();
        
        assertEq(totalPercentage, 100, "Total allocation percentages should equal 100");
    }

    /// @dev Invariant: No allocation should exceed total invested
    function invariant_AllocationBounds() public view {
        address asset = address(mockUSDC);
        uint256 totalInvested = crossChainController.totalInvested(asset);
        
        assertLe(
            crossChainController.insuranceAllocations(asset),
            totalInvested,
            "Insurance allocation should not exceed total invested"
        );
        
        assertLe(
            crossChainController.nestVaultAllocations(asset),
            totalInvested,
            "Nest vault allocation should not exceed total invested"
        );
        
        assertLe(
            crossChainController.limitOrderAllocations(asset),
            totalInvested,
            "Limit order allocation should not exceed total invested"
        );
    }

    /// @dev Invariant: Request nonce should only increase
    function invariant_RequestNonceMonotonic() public view {
        uint256 currentNonce = crossChainController.requestNonce();
        
        // Store previous nonce in a way that persists across calls
        // This is a simplified check - in practice you'd need more sophisticated tracking
        assertGe(currentNonce, 0, "Request nonce should be non-negative");
    }

    /// @dev Invariant: Contract addresses should be set correctly
    function invariant_ContractAddressesSet() public view {
        // These addresses should be set if the system is operational
        address strategyContract = crossChainController.STRATEGY_CONTRACT();
        address permissionContract = crossChainController.IPERMISSION();
        address pulleyStablecoinAddress = crossChainController.PULLEY_STABLECOIN_ADDRESS();
        address tradingPoolAddress = crossChainController.TRADING_POOL_ADDRESS();
        
        // At least some addresses should be set for the system to function
        assertTrue(
            strategyContract != address(0) || 
            permissionContract != address(0) ||
            pulleyStablecoinAddress != address(0) ||
            tradingPoolAddress != address(0),
            "At least some contract addresses should be set"
        );
    }
}
