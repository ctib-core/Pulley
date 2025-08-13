//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PulleyToken} from "../../src/Token/PulleyToken.sol";

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

contract PulleyTokenTest is Test {
    PulleyToken public pulleyToken;
    MockPermissionManager public permissionManager;

    address public engine = makeAddr("engine");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public crossChain = makeAddr("crossChain");

    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event ReserveFundUpdated(uint256 newAmount);
    event LossCovered(uint256 lossAmount, uint256 tokensUsed);
    event PulleyTokenEngineUpdated(address indexed oldEngine, address indexed newEngine);

    function setUp() public {
        permissionManager = new MockPermissionManager();
        pulleyToken = new PulleyToken("Pulley Token", "PULL", address(permissionManager));

        // Grant permissions
        permissionManager.grantPermission(address(this), pulleyToken.setPulleyTokenEngine.selector);
        permissionManager.grantPermission(engine, pulleyToken.mint.selector);
        permissionManager.grantPermission(engine, pulleyToken.burn.selector);
        permissionManager.grantPermission(engine, pulleyToken.burnForCoverage.selector);
        permissionManager.grantPermission(engine, pulleyToken.updateReserveFund.selector);
        permissionManager.grantPermission(address(this), pulleyToken.setCrossChainContract.selector);

        pulleyToken.setPulleyTokenEngine(engine);
        pulleyToken.setCrossChainContract(crossChain);
    }

    function test_InitialState() public view {
        assertEq(pulleyToken.name(), "Pulley Token");
        assertEq(pulleyToken.symbol(), "PULL");
        assertEq(pulleyToken.decimals(), 18);
        assertEq(pulleyToken.totalSupply(), 0);
        assertEq(pulleyToken.reserveFund(), 0);
        assertEq(pulleyToken.insuranceFunds(), 0);
        assertEq(pulleyToken.pulleyTokenEngine(), engine);
        assertEq(pulleyToken.CROSS_CHAIN_CONTRACT(), crossChain);
    }

    function test_SetPulleyTokenEngine() public {
        address newEngine = makeAddr("newEngine");
        
        vm.expectEmit(true, true, false, true);
        emit PulleyTokenEngineUpdated(engine, newEngine);
        
        pulleyToken.setPulleyTokenEngine(newEngine);
        assertEq(pulleyToken.pulleyTokenEngine(), newEngine);
    }

    function test_SetPulleyTokenEngine_ZeroAddress() public {
        vm.expectRevert(PulleyToken.PulleyToken__ZeroAddress.selector);
        pulleyToken.setPulleyTokenEngine(address(0));
    }

    function test_SetPulleyTokenEngine_NotPermitted() public {
        vm.prank(user1);
        vm.expectRevert("PulleyToken: not permitted");
        pulleyToken.setPulleyTokenEngine(makeAddr("newEngine"));
    }

    function test_Mint() public {
        uint256 amount = 1000 * 10**18;
        
        vm.expectEmit(true, false, false, true);
        emit TokensMinted(user1, amount);
        
        vm.expectEmit(false, false, false, true);
        emit ReserveFundUpdated(amount);
        
        vm.prank(engine);
        pulleyToken.mint(user1, amount);
        
        assertEq(pulleyToken.balanceOf(user1), amount);
        assertEq(pulleyToken.totalSupply(), amount);
        assertEq(pulleyToken.reserveFund(), amount);
        assertEq(pulleyToken.insuranceFunds(), 0);
    }

    function test_Mint_FromCrossChain() public {
        uint256 amount = 1000 * 10**18;
        
        // Set crossChain as engine for this test
        pulleyToken.setPulleyTokenEngine(crossChain);
        
        vm.prank(crossChain);
        pulleyToken.mint(user1, amount);
        
        assertEq(pulleyToken.balanceOf(user1), amount);
        assertEq(pulleyToken.insuranceFunds(), amount);
        assertEq(pulleyToken.reserveFund(), amount);
    }

    function test_Mint_ZeroAddress() public {
        vm.prank(engine);
        vm.expectRevert(PulleyToken.PulleyToken__ZeroAddress.selector);
        pulleyToken.mint(address(0), 1000);
    }

    function test_Mint_ZeroAmount() public {
        vm.prank(engine);
        vm.expectRevert(PulleyToken.PulleyToken__ZeroAmount.selector);
        pulleyToken.mint(user1, 0);
    }

    function test_Mint_OnlyEngine() public {
        vm.prank(user1);
        vm.expectRevert(PulleyToken.PulleyToken__OnlyEngine.selector);
        pulleyToken.mint(user1, 1000);
    }

    function test_Burn() public {
        uint256 mintAmount = 1000 * 10**18;
        uint256 burnAmount = 300 * 10**18;
        
        // First mint some tokens
        vm.prank(engine);
        pulleyToken.mint(user1, mintAmount);
        
        vm.expectEmit(true, false, false, true);
        emit TokensBurned(user1, burnAmount);
        
        vm.expectEmit(false, false, false, true);
        emit ReserveFundUpdated(mintAmount - burnAmount);
        
        vm.prank(engine);
        pulleyToken.burn(user1, burnAmount);
        
        assertEq(pulleyToken.balanceOf(user1), mintAmount - burnAmount);
        assertEq(pulleyToken.totalSupply(), mintAmount - burnAmount);
        assertEq(pulleyToken.reserveFund(), mintAmount - burnAmount);
    }

    function test_Burn_FromCrossChain() public {
        uint256 mintAmount = 1000 * 10**18;
        uint256 burnAmount = 300 * 10**18;
        
        // Set crossChain as engine to allow minting/burning
        pulleyToken.setPulleyTokenEngine(crossChain);
        
        // First mint from cross chain
        vm.prank(crossChain);
        pulleyToken.mint(user1, mintAmount);
        
        // Then burn from cross chain
        vm.prank(crossChain);
        pulleyToken.burn(user1, burnAmount);
        
        assertEq(pulleyToken.insuranceFunds(), mintAmount - burnAmount);
    }

    function test_Burn_ZeroAmount() public {
        vm.prank(engine);
        vm.expectRevert(PulleyToken.PulleyToken__ZeroAmount.selector);
        pulleyToken.burn(user1, 0);
    }

    function test_BurnForCoverage() public {
        uint256 mintAmount = 1000 * 10**18;
        uint256 coverageAmount = 300 * 10**18;
        
        // Setup: Set crossChain as engine temporarily to mint insurance funds
        pulleyToken.setPulleyTokenEngine(crossChain);
        
        vm.prank(crossChain);
        pulleyToken.mint(user1, mintAmount);
        
        vm.expectEmit(false, false, false, true);
        emit LossCovered(coverageAmount, coverageAmount);
        
        vm.prank(crossChain);
        pulleyToken.burnForCoverage(coverageAmount);
        
        assertEq(pulleyToken.insuranceFunds(), mintAmount - coverageAmount);
        assertEq(pulleyToken.reserveFund(), mintAmount - coverageAmount);
    }

    function test_BurnForCoverage_InsufficientFunds() public {
        uint256 coverageAmount = 300 * 10**18;
        
        vm.prank(engine);
        vm.expectRevert(PulleyToken.PulleyToken__InsufficientReserveFund.selector);
        pulleyToken.burnForCoverage(coverageAmount);
    }

    function test_CanCoverLoss() public {
        uint256 mintAmount = 1000 * 10**18;
        uint256 lossAmount = 300 * 10**18;
        
        // Initially should not be able to cover
        assertFalse(pulleyToken.canCoverLoss(lossAmount));
        
        // Set crossChain as engine to allow minting
        pulleyToken.setPulleyTokenEngine(crossChain);
        
        // After minting from cross chain, should be able to cover
        vm.prank(crossChain);
        pulleyToken.mint(user1, mintAmount);
        
        assertTrue(pulleyToken.canCoverLoss(lossAmount));
        assertFalse(pulleyToken.canCoverLoss(mintAmount + 1));
    }

    function test_UpdateReserveFund_Increase() public {
        uint256 initialAmount = 1000 * 10**18;
        uint256 increaseAmount = 500 * 10**18;
        
        // Setup initial reserve
        vm.prank(engine);
        pulleyToken.mint(user1, initialAmount);
        
        vm.expectEmit(false, false, false, true);
        emit ReserveFundUpdated(initialAmount + increaseAmount);
        
        vm.prank(engine);
        pulleyToken.updateReserveFund(increaseAmount, true);
        
        assertEq(pulleyToken.reserveFund(), initialAmount + increaseAmount);
    }

    function test_UpdateReserveFund_Decrease() public {
        uint256 initialAmount = 1000 * 10**18;
        uint256 decreaseAmount = 300 * 10**18;
        
        // Setup initial reserve
        vm.prank(engine);
        pulleyToken.mint(user1, initialAmount);
        
        vm.expectEmit(false, false, false, true);
        emit ReserveFundUpdated(initialAmount - decreaseAmount);
        
        vm.prank(engine);
        pulleyToken.updateReserveFund(decreaseAmount, false);
        
        assertEq(pulleyToken.reserveFund(), initialAmount - decreaseAmount);
    }

    function test_UpdateReserveFund_DecreaseMoreThanAvailable() public {
        uint256 initialAmount = 1000 * 10**18;
        uint256 decreaseAmount = 1500 * 10**18;
        
        // Setup initial reserve
        vm.prank(engine);
        pulleyToken.mint(user1, initialAmount);
        
        vm.prank(engine);
        pulleyToken.updateReserveFund(decreaseAmount, false);
        
        assertEq(pulleyToken.reserveFund(), 0);
    }

    function test_SetCrossChainContract() public {
        address newCrossChain = makeAddr("newCrossChain");
        
        pulleyToken.setCrossChainContract(newCrossChain);
        assertEq(pulleyToken.CROSS_CHAIN_CONTRACT(), newCrossChain);
    }

    function test_GetTotalSupply() public {
        uint256 amount = 1000 * 10**18;
        
        vm.prank(engine);
        pulleyToken.mint(user1, amount);
        
        assertEq(pulleyToken.getTotalSupply(), amount);
        assertEq(pulleyToken.getTotalSupply(), pulleyToken.totalSupply());
    }

    function test_GetReserveFund() public {
        uint256 amount = 1000 * 10**18;
        
        vm.prank(engine);
        pulleyToken.mint(user1, amount);
        
        assertEq(pulleyToken.getReserveFund(), amount);
        assertEq(pulleyToken.getReserveFund(), pulleyToken.reserveFund());
    }
}
