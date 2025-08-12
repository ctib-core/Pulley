//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPulleyToken} from "../interfaces/IPulleyToken.sol";
import {IPulleyTokenEngine} from "../interfaces/IPulleyTokenEngine.sol";
import {IPermissionManager} from "../Permission/interface/IPermissionManager.sol";
import {PermissionModifiers} from "../Permission/PermissionModifier.sol";

/**
 * @title PulleyTokenEngine
 * @author Core-Connect Team
 * @notice Engine for managing Pulley tokens that back trading pool losses
 * @dev Handles liquidity provision and maintains actual asset reserves for coverage
 */
contract PulleyTokenEngine is ReentrancyGuard, IPulleyTokenEngine {
    using SafeERC20 for IERC20;
    using PermissionModifiers for *;

    IPulleyToken public immutable i_pulleyToken;
    address public permissionManager;

    // Actual asset reserves held by this contract
    mapping(address asset => uint256 balance) public assetReserves;
    mapping(address asset => bool allowed) public allowedAssets;

    // Liquidity provider tracking
    struct Provider {
        uint256 assetsDeposited; // USD value deposited
        uint256 pulleyTokensOwned; // Pulley tokens they own
        uint256 depositTime; // When they deposited
    }

    mapping(address => Provider) public providers;
    address[] public providerList;

    // System metrics
    uint256 public totalBackingValue; // Total USD value backing pulley tokens
    uint256 public totalInsurancebacking;
    uint256 public totalLossesCovered; // Total losses covered

    // Events
    event LiquidityProvided(
        address indexed provider, address indexed asset, uint256 amount, uint256 pulleyTokensReceived
    );
    event LiquidityWithdrawn(
        address indexed provider, address indexed asset, uint256 amount, uint256 pulleyTokensBurned
    );
    event TradingLossCovered(address indexed requestor, uint256 lossAmount, bool successful);
    event AssetAllowed(address indexed asset, bool allowed);
    event AssetsTransferredForCoverage(address indexed asset, uint256 amount);
    event ProfitsDistributedToPulleyHolders(uint256 profitAmount, uint256 newTotalBackingValue);

    // Errors
    error PulleyTokenEngine__ZeroAmount();
    error PulleyTokenEngine__NotAllowedAsset();
    error PulleyTokenEngine__InsufficientPulleyTokens();
    error PulleyTokenEngine__InsufficientReserves();
    error PulleyTokenEngine__TransferFailed();

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert PulleyTokenEngine__ZeroAmount();
        }
        _;
    }

    modifier onlyPermitted(bytes4 selector) {
        require(
            IPermissionManager(permissionManager).hasPermissions(msg.sender, selector),
            "PulleyTokenEngine: not permitted"
        );
        _;
    }

    constructor(address pulleyTokenAddress, address[] memory allowedAssetsList, address _permissionManager) {
        i_pulleyToken = IPulleyToken(pulleyTokenAddress);
        permissionManager = _permissionManager;

        // Set allowed assets
        for (uint256 i = 0; i < allowedAssetsList.length; i++) {
            allowedAssets[allowedAssetsList[i]] = true;
            emit AssetAllowed(allowedAssetsList[i], true);
        }
    }

    /**
     * @notice Provide liquidity to back pulley tokens (only through Gateway)
     * @param asset Asset to deposit
     * @param amount Amount to deposit
     */
    function provideLiquidity(address asset, uint256 amount)
        external
        onlyPermitted(this.provideLiquidity.selector)
        moreThanZero(amount)
        nonReentrant
    {
        if (!allowedAssets[asset]) {
            revert PulleyTokenEngine__NotAllowedAsset();
        }

        // Transfer real assets to this contract (these back the pulley tokens)
        bool success = IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert PulleyTokenEngine__TransferFailed();
        }

        // Update asset reserves (actual backing)
        assetReserves[asset] += amount;

        // For simplicity, assume 1:1 USD ratio (in real system, you'd use price feeds)
        uint256 usdValue = amount;
        uint256 pulleyTokensToMint = usdValue; // 1:1 ratio for now

        // Update provider data
        if (providers[msg.sender].assetsDeposited == 0) {
            providerList.push(msg.sender);
        }

        providers[msg.sender].assetsDeposited += usdValue;
        providers[msg.sender].pulleyTokensOwned += pulleyTokensToMint;
        providers[msg.sender].depositTime = block.timestamp;

        // Update global state
        totalBackingValue += usdValue;

        // Mint pulley tokens to provider (this also increases reserve fund)
        i_pulleyToken.mint(msg.sender, pulleyTokensToMint);

        emit LiquidityProvided(msg.sender, asset, amount, pulleyTokensToMint);
    }

    function insuranceBackingMinter(address asset, uint256 amount) 
        public 
        moreThanZero(amount)
    {
        if (!allowedAssets[asset]) {
            revert PulleyTokenEngine__NotAllowedAsset();
        }

        // Transfer real assets to this contract (these back the pulley tokens)
        bool success = IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert PulleyTokenEngine__TransferFailed();
        }

        // Update asset reserves (actual backing)
        assetReserves[asset] += amount;

        // For simplicity, assume 1:1 USD ratio (in real system, you'd use price feeds)
        uint256 usdValue = amount;
        uint256 pulleyTokensToMint = usdValue; // 1:1 ratio for now

        // Update global state
        totalInsurancebacking += usdValue;

        // Mint pulley tokens to provider (this also increases reserve fund)
        i_pulleyToken.mint(msg.sender, pulleyTokensToMint);

        emit LiquidityProvided(msg.sender, asset, amount, pulleyTokensToMint);
    }

    /**
     * @notice Withdraw liquidity (only through Gateway)
     * @param asset Asset to withdraw
     * @param pulleyTokensToRedeem Amount of pulley tokens to burn
     */
    function withdrawLiquidity(address asset, uint256 pulleyTokensToRedeem)
        external
        onlyPermitted(this.withdrawLiquidity.selector)
        moreThanZero(pulleyTokensToRedeem)
        nonReentrant
    {
        if (!allowedAssets[asset]) {
            revert PulleyTokenEngine__NotAllowedAsset();
        }

        Provider storage provider = providers[msg.sender];
        if (provider.pulleyTokensOwned < pulleyTokensToRedeem) {
            revert PulleyTokenEngine__InsufficientPulleyTokens();
        }

        // Calculate asset amount to return (proportional)
        uint256 userShare = (pulleyTokensToRedeem * 1e18) / provider.pulleyTokensOwned;
        uint256 assetToReturn = (provider.assetsDeposited * userShare) / 1e18;

        // Check if we have enough asset reserves
        if (assetReserves[asset] < assetToReturn) {
            revert PulleyTokenEngine__InsufficientReserves();
        }

        // Update provider data
        provider.assetsDeposited -= assetToReturn;
        provider.pulleyTokensOwned -= pulleyTokensToRedeem;

        // Update reserves and global state
        assetReserves[asset] -= assetToReturn;
        totalBackingValue -= assetToReturn;

        // Burn pulley tokens (this also reduces reserve fund)
        i_pulleyToken.burn(msg.sender, pulleyTokensToRedeem);

        // Transfer real assets back to provider
        bool success = IERC20(asset).transfer(msg.sender, assetToReturn);
        if (!success) {
            revert PulleyTokenEngine__TransferFailed();
        }

        emit LiquidityWithdrawn(msg.sender, asset, assetToReturn, pulleyTokensToRedeem);
    }


//@audit only cross token - FIXED: Added proper access control for cross-chain calls
    /**
     * @notice Cover trading pool losses using pulley token reserves
     * @dev Only callable by authorized contracts (TradingPool or CrossChainController)
     * @param lossAmountUSD Loss amount to cover in USD
     * @return success Whether the loss was successfully covered
     */
    function coverTradingLoss(uint256 lossAmountUSD)
        external
        onlyPermitted(this.coverTradingLoss.selector)
        moreThanZero(lossAmountUSD)
        returns (bool)
    {
        // Check if pulley token has sufficient reserve fund
        if (!i_pulleyToken.canCoverLoss(lossAmountUSD)) {
            emit TradingLossCovered(msg.sender, lossAmountUSD, false);
            return false;
        }

        // Update loss tracking
        totalLossesCovered += lossAmountUSD;

        // Reduce our backing value since we're covering the loss
        totalInsurancebacking -= lossAmountUSD;

        // Use pulley tokens to cover loss (reduces reserve fund)
        i_pulleyToken.burnForCoverage(lossAmountUSD);

        // Note: The actual asset transfer to cover the loss would happen through
        // the transferAssetsForCoverage function if needed, but for now we just
        // absorb the loss through reduced backing value

        emit TradingLossCovered(msg.sender, lossAmountUSD, true);
        return true;
    }

    /**
     * @notice Distribute profits to Pulley token holders
     * @param profitAmount Amount of profit to distribute
     */
    function distributeProfits(uint256 profitAmount)
        external
        onlyPermitted(this.distributeProfits.selector)
        moreThanZero(profitAmount)
    {
        // Add profit to backing value
        totalBackingValue += profitAmount;
        
        // Update reserve fund in the token contract
        i_pulleyToken.updateReserveFund(profitAmount, true);
        
        emit ProfitsDistributedToPulleyHolders(profitAmount, totalBackingValue);
    }

    /**
     * @notice Set asset as allowed/disallowed for backing
     * @param asset Asset address
     * @param allowed Whether allowed
     */
    function setAssetAllowed(address asset, bool allowed) external onlyPermitted(this.setAssetAllowed.selector) {
        allowedAssets[asset] = allowed;
        emit AssetAllowed(asset, allowed);
    }

    /**
     * @notice Get reserve balance available for coverage
     * @return Total reserve balance
     */
    function getReserveBalance() external view returns (uint256) {
        return i_pulleyToken.getReserveFund();
    }

    /**
     * @notice Check if asset is allowed
     * @param asset Asset address
     * @return True if asset is allowed
     */
    function isAssetAllowed(address asset) external view returns (bool) {
        return allowedAssets[asset];
    }

    /**
     * @notice Get provider information
     * @param provider Provider address
     * @return assetsDeposited Amount of assets deposited
     * @return pulleyTokensOwned Amount of pulley tokens owned
     * @return depositTime Time of deposit
     */
    function getProvider(address provider) external view returns (uint256 assetsDeposited, uint256 pulleyTokensOwned, uint256 depositTime) {
        Provider memory p = providers[provider];
        return (p.assetsDeposited, p.pulleyTokensOwned, p.depositTime);
    }

    /**
     * @notice Get system metrics
     * @return totalBacking Total backing value
     * @return totalLosses Total losses covered
     * @return reserveRatio Reserve ratio percentage
     * @return providerCount Number of providers
     */
    function getSystemMetrics()
        external
        view
        returns (uint256 totalBacking, uint256 totalLosses, uint256 reserveRatio, uint256 providerCount)
    {
        uint256 totalSupply = i_pulleyToken.getTotalSupply();
        return (
            totalBackingValue,
            totalLossesCovered,
            totalSupply > 0 ? (totalBackingValue * 100) / totalSupply : 100,
            providerList.length
        );
    }

    /**
     * @notice Get asset reserve balance
     * @param asset Asset address
     * @return Reserve balance for the asset
     */
    function getAssetReserve(address asset) external view returns (uint256) {
        return assetReserves[asset];
    }

 
}
