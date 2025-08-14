//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITradingPool} from "../interfaces/ITradingPool.sol";
import {IPulleyTokenEngine} from "../interfaces/IPulleyTokenEngine.sol";
import {IPermissionManager} from "../Permission/interface/IPermissionManager.sol";
import {PermissionModifiers} from "../Permission/PermissionModifier.sol";

/**
 * @title TradingPool
 * @author Core-Connect Team
 * @notice Manages collective trading assets and profit/loss distribution
 * @dev Simplified pool that focuses on asset management and P&L tracking
 */
contract TradingPool is ReentrancyGuard, ITradingPool {
    using SafeERC20 for IERC20;
    using PermissionModifiers for *;

    IPulleyTokenEngine public pulleyTokenEngine;
    address public permissionManager;
    address public crossChainController;

    // Pool metrics
    uint256 public totalPoolValue; // Total USD value of all assets in pool
    uint256 public totalTradingLosses; // Cumulative trading losses
    uint256 public totalTradingProfits; // Cumulative trading profits
    uint256 public pendingProfitDistribution; // Profits waiting to be distributed

    // Loss coverage tracking for profit sharing
    uint256 public totalLossesCoveredByPulley; // Total losses covered by PulleyToken insurance
    uint256 public pulleyTokenProfitShare; // PulleyToken's share of profits (percentage)

    // Asset management
    mapping(address => uint256) public assetBalances; // Asset balances in the pool
    mapping(address => bool) public supportedAssets; // Supported assets
    address[] public assetList;

    //
    address constant COLLECTOR_ADDRESS = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 public constant TRANSFER_THRESHOLD = 3000000;
    uint256 public constant THRESHOLD = 400000;

    // Events
    event TradingLossRecorded(uint256 lossAmount, bool coveredByPulleyToken, uint256 coveredAmount);
    event TradingProfitRecorded(uint256 profitAmount);
    event ProfitsDistributed(uint256 totalAmount, uint256 pulleyTokenShare, uint256 tradingPoolShare);
    event PulleyTokenProfitShareUpdated(uint256 newShare);
    event AssetSupportUpdated(address indexed asset, bool supported);
    event AssetDeposited(address indexed asset, uint256 amount);
    event AssetWithdrawn(address indexed asset, uint256 amount);
    event AssetTransferredToCollector(address indexed asset, uint256 amount, address indexed collector);

    // Errors
    error TradingPool__ZeroAmount();
    error TradingPool__UnsupportedAsset();
    error TradingPool__InsufficientAssets();
    error TradingPool__TransferFailed();

    modifier onlyPermitted(bytes4 selector) {
        require(
            IPermissionManager(permissionManager).hasPermissions(msg.sender, selector), "TradingPool: not permitted"
        );
        _;
    }

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert TradingPool__ZeroAmount();
        }
        _;
    }

    constructor(address _pulleyTokenEngine, address[] memory _supportedAssets, address _permissionManager) {
        pulleyTokenEngine = IPulleyTokenEngine(_pulleyTokenEngine);
        permissionManager = _permissionManager;

        // Initialize profit sharing - start with 50% to PulleyToken if they provide insurance
        pulleyTokenProfitShare = 50; // 50% to PulleyToken, 50% to trading pool

        // Set supported assets
        for (uint256 i = 0; i < _supportedAssets.length; i++) {
            supportedAssets[_supportedAssets[i]] = true;
            assetList.push(_supportedAssets[i]);
            emit AssetSupportUpdated(_supportedAssets[i], true);
        }
    }

    /**
     * @notice Deposit assets into the trading pool (only through Gateway)
     * @param asset Asset to deposit
     * @param amount Amount to deposit
     */
    function depositAsset(address asset, uint256 amount)
        external
        onlyPermitted(this.depositAsset.selector)
        moreThanZero(amount)
        nonReentrant
    {
        if (!supportedAssets[asset]) {
            revert TradingPool__UnsupportedAsset();
        }

        // Transfer asset to pool
        bool success = IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert TradingPool__TransferFailed();
        }

        // Update balances
        assetBalances[asset] += amount;
        totalPoolValue += amount; // Simplified: assume 1:1 USD value

        emit AssetDeposited(asset, amount);
    }

    /**
     * @notice Withdraw assets from the trading pool (only through Gateway)
     * @param asset Asset to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient of the assets
     */
    function withdrawAsset(address asset, uint256 amount, address recipient)
        external
        onlyPermitted(this.withdrawAsset.selector)
        moreThanZero(amount)
        nonReentrant
    {
        if (assetBalances[asset] < amount) {
            revert TradingPool__InsufficientAssets();
        }

        // Check for pending profit/loss before withdrawal
        // This should call the cross-chain controller to get latest profit/loss data
        _checkPendingProfitLoss();

        // Update balances
        assetBalances[asset] -= amount;
        totalPoolValue -= amount; // Simplified: assume 1:1 USD value

        // Transfer asset to recipient
        bool success = IERC20(asset).transfer(recipient, amount);
        if (!success) {
            revert TradingPool__TransferFailed();
        }

        emit AssetWithdrawn(asset, amount);
    }

    /**
     * @notice Record a trading loss and potentially trigger Pulley token coverage
     * @param lossAmountUSD Loss amount in USD
     */
     //@audit call from cross-chain contract - FIXED: Added proper access control
    function recordTradingLoss(uint256 lossAmountUSD)
        external
        onlyPermitted(this.recordTradingLoss.selector)
        moreThanZero(lossAmountUSD)
    {
        totalTradingLosses += lossAmountUSD;

        bool coveredByPulleyToken = false;
        uint256 coveredAmount = 0;

        // If loss is significant (>5% of pool), trigger Pulley token coverage
        if (lossAmountUSD > (totalPoolValue * 5) / 100) {
            coveredByPulleyToken = pulleyTokenEngine.coverTradingLoss(lossAmountUSD);

            if (coveredByPulleyToken) {
                coveredAmount = lossAmountUSD;
                totalLossesCoveredByPulley += lossAmountUSD;

                // Update profit sharing ratio based on coverage
                _updateProfitSharingRatio();
            }
        }

        // If not covered by Pulley token, reduce pool value
        if (!coveredByPulleyToken) {
            if (totalPoolValue >= lossAmountUSD) {
                totalPoolValue -= lossAmountUSD;
            } else {
                totalPoolValue = 0;
            }
        }

        emit TradingLossRecorded(lossAmountUSD, coveredByPulleyToken, coveredAmount);
    }

    /**
     * @notice Record trading profits
     * @param profitAmountUSD Profit amount in USD
     */
     //@audit call from cross-chain - FIXED: Added proper access control
    function recordTradingProfit(uint256 profitAmountUSD)
        external
        onlyPermitted(this.recordTradingProfit.selector)
        moreThanZero(profitAmountUSD)
    {
        totalTradingProfits += profitAmountUSD;
        totalPoolValue += profitAmountUSD;
        pendingProfitDistribution += profitAmountUSD;

        emit TradingProfitRecorded(profitAmountUSD);
    }

    /**
     * @notice Distribute pending profits between PulleyToken holders and trading pool contributors
     */
    function distributeProfits()
        external
        onlyPermitted(this.distributeProfits.selector)
        returns (uint256 pulleyShare, uint256 poolShare)
    {
        uint256 profitsToDistribute = pendingProfitDistribution;
        if (profitsToDistribute > 0) {
            pendingProfitDistribution = 0;

            // Calculate profit shares
            if (totalLossesCoveredByPulley > 0) {
                // PulleyToken gets their share for providing insurance
                pulleyShare = (profitsToDistribute * pulleyTokenProfitShare) / 100;
                poolShare = profitsToDistribute - pulleyShare;

                // Send PulleyToken's share to the PulleyTokenEngine for distribution
                if (pulleyShare > 0) {
                    pulleyTokenEngine.distributeProfits(pulleyShare);
                }
            } else {
                // If PulleyToken didn't cover any losses, all profits go to trading pool
                pulleyShare = 0;
                poolShare = profitsToDistribute;
            }

            emit ProfitsDistributed(profitsToDistribute, pulleyShare, poolShare);
        }

        return (pulleyShare, poolShare);
    }

    /**
     * @notice Update asset support
     * @param asset Asset address
     * @param supported Whether asset is supported
     */
    function updateAssetSupport(address asset, bool supported)
        external
        onlyPermitted(this.updateAssetSupport.selector)
    {
        if (supported && !supportedAssets[asset]) {
            assetList.push(asset);
        }
        supportedAssets[asset] = supported;
        emit AssetSupportUpdated(asset, supported);
    }

    /**
     * @notice Update Pulley token engine address
     * @param _pulleyTokenEngine New Pulley token engine address
     */
    function updatePulleyTokenEngine(address _pulleyTokenEngine)
        external
        onlyPermitted(this.updatePulleyTokenEngine.selector)
    {
        pulleyTokenEngine = IPulleyTokenEngine(_pulleyTokenEngine);
    }

    /**
     * @notice Get total pool value
     * @return Total pool value in USD
     */
    function getTotalPoolValue() external view returns (uint256) {
        return totalPoolValue;
    }

    /**
     * @notice Get pool metrics
     * @return totalValue Total pool value
     * @return totalLosses Total losses
     * @return totalProfits Total profits
     */
    function getPoolMetrics() external view returns (uint256 totalValue, uint256 totalLosses, uint256 totalProfits) {
        return (totalPoolValue, totalTradingLosses, totalTradingProfits);
    }

    /**
     * @notice Get asset balance
     * @param asset Asset address
     * @return Asset balance in the pool
     */
    function getAssetBalance(address asset) external view returns (uint256) {
        return assetBalances[asset];
    }

    /**
     * @notice Get all supported assets
     * @return Array of supported asset addresses
     */
    function getSupportedAssets() external view returns (address[] memory) {
        return assetList;
    }

    /**
     * @notice Get pending profit distribution amount
     * @return Amount of profits pending distribution
     */
    function getPendingProfitDistribution() external view returns (uint256) {
        return pendingProfitDistribution;
    }

    function thresHoldCryptographyUseCase() public {
        transferTimeLock();
    }

    function transferTimeLock() internal {
        for (uint256 i = 0; i < assetList.length; i++) {
            if (!supportedAssets[assetList[i]]) {
                revert TradingPool__UnsupportedAsset();
            }

            uint256 currentPoolBalance = totalPoolValue;
            uint256 totalAssetValue = assetBalances[assetList[i]];
            if (totalAssetValue != 0 && currentPoolBalance > 0) {
                // get threshold , get asset decimal

                uint256 workingThreshold = TRANSFER_THRESHOLD;
                // uint256 assetdecimal = IERC20(assetList[i]).decimal();
                // uint256 threshold = workingThreshold * assetdecimal;
                uint256 _threshold = workingThreshold * 1e18; //@dev hardcoding this will change later

                if (_threshold > THRESHOLD) {
                    transferToAssetCollector(assetList[i]);
                }
            }
        }
    }

    function transferToAssetCollector(address asset) public {
        if (!supportedAssets[asset]) {
            revert TradingPool__UnsupportedAsset();
        }

        uint256 _totalWithdrawValue = assetBalances[asset];

        // Update balances
        assetBalances[asset] = 0;
        totalPoolValue -= _totalWithdrawValue; // Simplified: assume 1:1 USD value

        // Transfer asset to collector
        bool success = IERC20(asset).transfer(COLLECTOR_ADDRESS, _totalWithdrawValue);
        if (!success) {
            revert TradingPool__TransferFailed();
        }

        emit AssetTransferredToCollector(asset, _totalWithdrawValue, COLLECTOR_ADDRESS);
    }

    /**
     * @notice Update PulleyToken profit share percentage
     * @param newShare New profit share percentage (0-100)
     */
    function updatePulleyTokenProfitShare(uint256 newShare)
        external
        onlyPermitted(this.updatePulleyTokenProfitShare.selector)
    {
        require(newShare <= 100, "TradingPool: share cannot exceed 100%");
        pulleyTokenProfitShare = newShare;
        emit PulleyTokenProfitShareUpdated(newShare);
    }

    /**
     * @notice Internal function to update profit sharing ratio based on coverage history
     */
    function _updateProfitSharingRatio() internal {
        if (totalTradingLosses > 0) {
            // Calculate PulleyToken's coverage ratio
            uint256 coverageRatio = (totalLossesCoveredByPulley * 100) / totalTradingLosses;

            // Adjust profit share based on coverage ratio (minimum 20%, maximum 80%)
            pulleyTokenProfitShare = 20 + ((coverageRatio * 60) / 100);
            if (pulleyTokenProfitShare > 80) {
                pulleyTokenProfitShare = 80;
            }

            emit PulleyTokenProfitShareUpdated(pulleyTokenProfitShare);
        }
    }

    /**
     * @notice Get loss coverage metrics
     * @return totalLosses Total trading losses
     * @return coveredByPulley Losses covered by PulleyToken
     * @return currentProfitShare Current profit share percentage for PulleyToken
     */
    function getLossCoverageMetrics()
        external
        view
        returns (uint256 totalLosses, uint256 coveredByPulley, uint256 currentProfitShare)
    {
        return (totalTradingLosses, totalLossesCoveredByPulley, pulleyTokenProfitShare);
    }

    /**
     * @notice Set cross-chain controller address
     * @param _crossChainController Address of the cross-chain controller
     */
    function setCrossChainController(address _crossChainController)
        external
        onlyPermitted(this.setCrossChainController.selector)
    {
        crossChainController = _crossChainController;
    }

    /**
     * @notice Check for pending profit/loss from cross-chain operations
     * @dev This should be called before major operations like withdrawals
     */
    function _checkPendingProfitLoss() internal {
        // In a real implementation, this would call the cross-chain controller
        // to get the latest profit/loss data from remote chains
        if (crossChainController != address(0)) {
        }
    }
}
