//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Gateway} from "../../src/Gateway.sol";
import {PulleyToken} from "../../src/Token/PulleyToken.sol";
import {PulleyTokenEngine} from "../../src/Token/pulleyEngine.sol";
import {TradingPool} from "../../src/Pool/TradingPool.sol";
import {CrossChainController} from "../../src/cross_chain/cross_chain_controller.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18); // Large supply for invariant testing
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Permission Manager for testing
contract MockPermissionManager {
    function hasPermissions(address, bytes4) external pure returns (bool) {
        return true; // Allow all for invariant testing
    }

    function owner() external view returns (address) {
        return msg.sender;
    }
}

// Handler contract for invariant testing
contract PulleyEcosystemHandler is Test {
    Gateway public gateway;
    PulleyToken public pulleyToken;
    PulleyTokenEngine public pulleyTokenEngine;
    TradingPool public tradingPool;
    MockERC20 public mockUSDC;

    address[] public actors;
    uint256 public constant NUM_ACTORS = 3;

    // Ghost variables for tracking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalTokensMinted;
    uint256 public ghost_totalTokensBurned;
    uint256 public ghost_totalProfitsRecorded;
    uint256 public ghost_totalLossesRecorded;

    modifier useActor(uint256 actorIndexSeed) {
        address currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        Gateway _gateway,
        PulleyToken _pulleyToken,
        PulleyTokenEngine _pulleyTokenEngine,
        TradingPool _tradingPool,
        MockERC20 _mockUSDC
    ) {
        gateway = _gateway;
        pulleyToken = _pulleyToken;
        pulleyTokenEngine = _pulleyTokenEngine;
        tradingPool = _tradingPool;
        mockUSDC = _mockUSDC;

        // Create actors
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);

            // Give each actor a large balance
            mockUSDC.mint(actor, 100000 * 10 ** 18);
        }
    }

    function buyPulleyTokens(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1, 1e20);

        mockUSDC.approve(address(gateway), amount);
        gateway.buyPulleyTokens(address(mockUSDC), amount);

        ghost_totalTokensMinted += amount;
    }

    function depositToTradingPool(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1, 1e20);

        mockUSDC.approve(address(gateway), amount);
        gateway.depositToTradingPool(address(mockUSDC), amount);

        ghost_totalDeposited += amount;
    }

    function buyTokensAndDeposit(uint256 actorSeed, uint256 tokenAmount, uint256 tradingAmount)
        public
        useActor(actorSeed)
    {
        tokenAmount = bound(tokenAmount, 0, 1e20);
        tradingAmount = bound(tradingAmount, 0, 1e20);

        if (tokenAmount + tradingAmount == 0) return;

        mockUSDC.approve(address(gateway), tokenAmount + tradingAmount);
        gateway.buyTokensAndDeposit(address(mockUSDC), tokenAmount, tradingAmount);

        ghost_totalTokensMinted += tokenAmount;
        ghost_totalDeposited += tradingAmount;
    }

    function withdrawFromTradingPool(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        uint256 maxWithdraw = tradingPool.getAssetBalance(address(mockUSDC));
        if (maxWithdraw == 0) return;

        amount = bound(amount, 1, maxWithdraw);

        gateway.withdrawFromTradingPool(address(mockUSDC), amount);
        ghost_totalWithdrawn += amount;
    }

    function withdrawPulleyLiquidity(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 maxTokens = pulleyToken.balanceOf(actor);
        if (maxTokens == 0) return;

        amount = bound(amount, 1, maxTokens);

        gateway.withdrawPulleyLiquidity(address(mockUSDC), amount);
        ghost_totalTokensBurned += amount;
    }

    function recordTradingProfit(uint256 amount) public {
        amount = bound(amount, 1, 1e20);

        tradingPool.recordTradingProfit(amount);
        ghost_totalProfitsRecorded += amount;
    }

    function recordTradingLoss(uint256 amount) public {
        uint256 maxLoss = tradingPool.getTotalPoolValue();
        if (maxLoss == 0) return;

        amount = bound(amount, 1, maxLoss);

        tradingPool.recordTradingLoss(amount);
        ghost_totalLossesRecorded += amount;
    }

    function distributeProfits() public {
        if (tradingPool.getPendingProfitDistribution() > 0) {
            tradingPool.distributeProfits();
        }
    }
}

contract PulleyEcosystemInvariantTest is StdInvariant, Test {
    PulleyEcosystemHandler public handler;
    Gateway public gateway;
    PulleyToken public pulleyToken;
    PulleyTokenEngine public pulleyTokenEngine;
    TradingPool public tradingPool;
    MockERC20 public mockUSDC;
    MockPermissionManager public permissionManager;

    function setUp() public {
        mockUSDC = new MockERC20("Mock USDC", "mUSDC");
        permissionManager = new MockPermissionManager();

        pulleyToken = new PulleyToken("Pulley Token", "PULL", address(permissionManager));

        address[] memory allowedAssets = new address[](1);
        allowedAssets[0] = address(mockUSDC);

        pulleyTokenEngine = new PulleyTokenEngine(address(pulleyToken), allowedAssets, address(permissionManager));

        tradingPool = new TradingPool(address(pulleyTokenEngine), allowedAssets, address(permissionManager));

        gateway = new Gateway(
            address(pulleyToken),
            address(pulleyTokenEngine),
            address(tradingPool),
            makeAddr("mockCrossChain"), // Mock cross-chain address
            address(permissionManager)
        );

        pulleyToken.setPulleyTokenEngine(address(pulleyTokenEngine));

        handler = new PulleyEcosystemHandler(gateway, pulleyToken, pulleyTokenEngine, tradingPool, mockUSDC);

        // Set the handler as the target contract
        targetContract(address(handler));

        // Target specific functions for invariant testing
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = PulleyEcosystemHandler.buyPulleyTokens.selector;
        selectors[1] = PulleyEcosystemHandler.depositToTradingPool.selector;
        selectors[2] = PulleyEcosystemHandler.buyTokensAndDeposit.selector;
        selectors[3] = PulleyEcosystemHandler.withdrawFromTradingPool.selector;
        selectors[4] = PulleyEcosystemHandler.withdrawPulleyLiquidity.selector;
        selectors[5] = PulleyEcosystemHandler.recordTradingProfit.selector;
        selectors[6] = PulleyEcosystemHandler.recordTradingLoss.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Invariant: PulleyToken total supply should equal reserve fund
    function invariant_PulleyTokenSupplyEqualsReserveFund() public view {
        assertEq(
            pulleyToken.totalSupply(), pulleyToken.reserveFund(), "PulleyToken total supply should equal reserve fund"
        );
    }

    /// @dev Invariant: PulleyTokenEngine asset reserves should back all minted tokens
    function invariant_AssetReservesBackTokens() public view {
        uint256 totalReserves = pulleyTokenEngine.getAssetReserve(address(mockUSDC));
        uint256 totalSupply = pulleyToken.totalSupply();

        // Reserves should be at least equal to total supply (1:1 backing ratio)
        assertGe(totalReserves, totalSupply, "Asset reserves should back all minted tokens");
    }

    /// @dev Invariant: Trading pool total value should be consistent with asset balances
    function invariant_TradingPoolValueConsistency() public view {
        uint256 reportedTotalValue = tradingPool.getTotalPoolValue();
        uint256 actualAssetBalance = tradingPool.getAssetBalance(address(mockUSDC));

        // For single asset, these should be equal (assuming 1:1 USD ratio)
        assertEq(reportedTotalValue, actualAssetBalance, "Trading pool total value should match asset balances");
    }

    /// @dev Invariant: Total profits minus total losses should equal net pool change
    function invariant_ProfitLossConsistency() public view {
        uint256 totalProfits = tradingPool.totalTradingProfits();
        uint256 totalLosses = tradingPool.totalTradingLosses();

        // Ghost variables should track the same values
        assertEq(totalProfits, handler.ghost_totalProfitsRecorded(), "Recorded profits should match ghost variable");

        assertEq(totalLosses, handler.ghost_totalLossesRecorded(), "Recorded losses should match ghost variable");
    }

    /// @dev Invariant: Pending profit distribution should not exceed total profits
    function invariant_PendingDistributionBounds() public view {
        uint256 pendingDistribution = tradingPool.getPendingProfitDistribution();
        uint256 totalProfits = tradingPool.totalTradingProfits();

        assertLe(pendingDistribution, totalProfits, "Pending distribution should not exceed total profits");
    }

    /// @dev Invariant: PulleyToken profit share should be within bounds
    function invariant_ProfitShareBounds() public view {
        uint256 profitShare = tradingPool.pulleyTokenProfitShare();

        assertGe(profitShare, 20, "Profit share should be at least 20%");
        assertLe(profitShare, 80, "Profit share should be at most 80%");
    }

    /// @dev Invariant: Insurance funds should not exceed total supply
    function invariant_InsuranceFundsBounds() public view {
        uint256 insuranceFunds = pulleyToken.insuranceFunds();
        uint256 totalSupply = pulleyToken.totalSupply();

        assertLe(insuranceFunds, totalSupply, "Insurance funds should not exceed total supply");
    }

    /// @dev Invariant: Total backing value should equal sum of individual provider deposits
    function invariant_TotalBackingConsistency() public view {
        uint256 reportedTotalBacking = pulleyTokenEngine.totalBackingValue();

        // This should equal the total asset reserves
        uint256 totalReserves = pulleyTokenEngine.getAssetReserve(address(mockUSDC));

        assertEq(reportedTotalBacking, totalReserves, "Total backing should equal asset reserves");
    }

    /// @dev Invariant: Sum of all user balances should equal total supply
    function invariant_UserBalancesSumToTotalSupply() public view {
        uint256 totalSupply = pulleyToken.totalSupply();
        uint256 sumOfBalances = 0;

        // Sum balances of all actors
        for (uint256 i = 0; i < handler.NUM_ACTORS(); i++) {
            address actor = handler.actors(i);
            sumOfBalances += pulleyToken.balanceOf(actor);
        }

        assertEq(sumOfBalances, totalSupply, "Sum of user balances should equal total supply");
    }

    /// @dev Invariant: Contract should never hold more tokens than it has backing for
    function invariant_NoUnbackedTokens() public view {
        uint256 totalSupply = pulleyToken.totalSupply();
        uint256 totalBacking = pulleyTokenEngine.totalBackingValue();

        assertGe(totalBacking, totalSupply, "All tokens should be backed by assets");
    }

    /// @dev Invariant: Ghost variables should be consistent with actual state
    function invariant_GhostVariableConsistency() public view {
        // Check that our tracking variables make sense
        uint256 netDeposits = handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn();
        uint256 actualPoolBalance = tradingPool.getAssetBalance(address(mockUSDC));

        // The actual pool balance should be at least the net deposits
        // (it could be more due to profits)
        assertGe(
            actualPoolBalance + handler.ghost_totalLossesRecorded(),
            netDeposits,
            "Pool balance should reflect net deposits (accounting for losses)"
        );
    }

    /// @dev Invariant: System should maintain solvency
    function invariant_SystemSolvency() public view {
        // Total assets in the system should be sufficient to cover all liabilities
        uint256 totalAssets = mockUSDC.balanceOf(address(pulleyTokenEngine)) + mockUSDC.balanceOf(address(tradingPool));

        uint256 totalLiabilities = pulleyToken.totalSupply() + tradingPool.getTotalPoolValue();

        // We allow some flexibility due to profits/losses
        // The key is that we should never have negative equity
        assertGe(
            totalAssets + handler.ghost_totalProfitsRecorded(), totalLiabilities, "System should maintain solvency"
        );
    }
}
