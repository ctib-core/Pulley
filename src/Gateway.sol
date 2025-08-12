//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPulleyToken} from "./interfaces/IPulleyToken.sol";
import {IPulleyTokenEngine} from "./interfaces/IPulleyTokenEngine.sol";
import {ITradingPool} from "./interfaces/ITradingPool.sol";
import {IPermissionManager} from "./Permission/interface/IPermissionManager.sol";
import {PermissionModifiers} from "./Permission/PermissionModifier.sol";

/**
 * @title Gateway
 * @author Core-Connect Team
 * @notice Main entry point for users to interact with the Pulley ecosystem
 * @dev Handles user flow: buy tokens → deposit → cross-chain → profit/loss reporting
 */
contract Gateway is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PermissionModifiers for *;

    // Contract addresses
    IPulleyToken public immutable pulleyToken;
    IPulleyTokenEngine public immutable pulleyTokenEngine;
    ITradingPool public immutable tradingPool;
    address public immutable crossChainController;
    address public immutable permissionManager;

    // Events
    event UserPurchasedTokens(address indexed user, address indexed asset, uint256 amount, uint256 tokensReceived);
    event UserDepositedToTrading(address indexed user, address indexed asset, uint256 amount);
    event FundsTransferredToCrossChain(address indexed asset, uint256 amount);

    // Errors
    error Gateway__ZeroAmount();
    error Gateway__ZeroAddress();
    error Gateway__TransferFailed();

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert Gateway__ZeroAmount();
        }
        _;
    }

    constructor(
        address _pulleyToken,
        address _pulleyTokenEngine,
        address _tradingPool,
        address _crossChainController,
        address _permissionManager
    ) {
        if (_pulleyToken == address(0) || 
            _pulleyTokenEngine == address(0) || 
            _tradingPool == address(0) || 
            _crossChainController == address(0) ||
            _permissionManager == address(0)) {
            revert Gateway__ZeroAddress();
        }

        pulleyToken = IPulleyToken(_pulleyToken);
        pulleyTokenEngine = IPulleyTokenEngine(_pulleyTokenEngine);
        tradingPool = ITradingPool(_tradingPool);
        crossChainController = _crossChainController;
        permissionManager = _permissionManager;
    }

    /**
     * @notice Buy Pulley tokens by providing liquidity
     * @dev User flow step 1: Enter contract and buy pulley tokens
     * @param asset Asset to deposit for Pulley tokens
     * @param amount Amount of asset to deposit
     */
    function buyPulleyTokens(address asset, uint256 amount)
        external
        moreThanZero(amount)
        nonReentrant
    {
        // Transfer asset from user to this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve PulleyTokenEngine to spend the asset
        IERC20(asset).approve(address(pulleyTokenEngine), amount);

        // Call PulleyTokenEngine to provide liquidity and mint tokens
        pulleyTokenEngine.provideLiquidity(asset, amount);

        emit UserPurchasedTokens(msg.sender, asset, amount, amount); // 1:1 ratio assumed
    }

    /**
     * @notice Deposit assets into the trading pool
     * @dev User flow step 2: Enter contract and deposit into trading pool
     * @param asset Asset to deposit
     * @param amount Amount to deposit
     */
    function depositToTradingPool(address asset, uint256 amount)
        external
        moreThanZero(amount)
        nonReentrant
    {
        // Transfer asset from user to this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve TradingPool to spend the asset
        IERC20(asset).approve(address(tradingPool), amount);

        // Deposit into trading pool
        tradingPool.depositAsset(asset, amount);

        emit UserDepositedToTrading(msg.sender, asset, amount);

        // Check if threshold is met to transfer to cross-chain
        _checkAndTransferToCrossChain(asset);
    }

    /**
     * @notice Combined function: Buy tokens AND deposit to trading pool
     * @dev Complete user flow in one transaction
     * @param asset Asset to use
     * @param tokenAmount Amount for buying Pulley tokens
     * @param tradingAmount Amount for trading pool deposit
     */
    function buyTokensAndDeposit(
        address asset,
        uint256 tokenAmount,
        uint256 tradingAmount
    ) external nonReentrant {
        uint256 totalAmount = tokenAmount + tradingAmount;
        if (totalAmount == 0) revert Gateway__ZeroAmount();

        // Transfer total amount from user
        IERC20(asset).safeTransferFrom(msg.sender, address(this), totalAmount);

        // Buy Pulley tokens if requested
        if (tokenAmount > 0) {
            IERC20(asset).approve(address(pulleyTokenEngine), tokenAmount);
            pulleyTokenEngine.provideLiquidity(asset, tokenAmount);
            emit UserPurchasedTokens(msg.sender, asset, tokenAmount, tokenAmount);
        }

        // Deposit to trading pool if requested
        if (tradingAmount > 0) {
            IERC20(asset).approve(address(tradingPool), tradingAmount);
            tradingPool.depositAsset(asset, tradingAmount);
            emit UserDepositedToTrading(msg.sender, asset, tradingAmount);
            _checkAndTransferToCrossChain(asset);
        }
    }

    /**
     * @notice Check if enough funds accumulated to transfer to cross-chain
     * @param asset Asset to check
     */
    function _checkAndTransferToCrossChain(address asset) internal {
        uint256 poolBalance = tradingPool.getAssetBalance(asset);
        
        // Transfer to cross-chain when pool reaches a certain threshold
        // This threshold should be configurable in a real implementation
        uint256 transferThreshold = 1000 * 1e18; // 1000 tokens threshold
        
        if (poolBalance >= transferThreshold) {
            // Call cross-chain controller to receive funds from trading pool
            // This will trigger the fund allocation: 10% insurance, 45% Nest vault, 45% limit orders
            (bool success,) = crossChainController.call(
                abi.encodeWithSignature("receiveFundsFromTradingPool()")
            );
            
            if (success) {
                emit FundsTransferredToCrossChain(asset, poolBalance);
            }
        }
    }

    /**
     * @notice Withdraw assets from trading pool (with profit/loss check)
     * @param asset Asset to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawFromTradingPool(address asset, uint256 amount)
        external
        moreThanZero(amount)
        nonReentrant
    {
        // This will internally check for profit/loss before withdrawal
        tradingPool.withdrawAsset(asset, amount, msg.sender);
    }

    /**
     * @notice Withdraw Pulley token liquidity
     * @param asset Asset to withdraw
     * @param pulleyTokenAmount Amount of Pulley tokens to redeem
     */
    function withdrawPulleyLiquidity(address asset, uint256 pulleyTokenAmount)
        external
        moreThanZero(pulleyTokenAmount)
        nonReentrant
    {
        pulleyTokenEngine.withdrawLiquidity(asset, pulleyTokenAmount);
    }

    /**
     * @notice Get user's trading pool balance for an asset
     * @param asset Asset address
     * @return Balance in the trading pool
     */
    function getTradingPoolBalance(address asset) external view returns (uint256) {
        return tradingPool.getAssetBalance(asset);
    }

    /**
     * @notice Get user's Pulley token information
     * @param user User address
     * @return assetsDeposited Amount deposited
     * @return pulleyTokensOwned Pulley tokens owned
     * @return depositTime Deposit timestamp
     */
    function getPulleyTokenInfo(address user) 
        external 
        view 
        returns (uint256 assetsDeposited, uint256 pulleyTokensOwned, uint256 depositTime) 
    {
        return pulleyTokenEngine.getProvider(user);
    }

    /**
     * @notice Get trading pool metrics
     * @return totalValue Total pool value
     * @return totalLosses Total losses
     * @return totalProfits Total profits
     */
    function getTradingPoolMetrics() 
        external 
        view 
        returns (uint256 totalValue, uint256 totalLosses, uint256 totalProfits) 
    {
        return tradingPool.getPoolMetrics();
    }
}
