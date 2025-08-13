// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OAppOptionsType3 } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import{ PermissionModifiers} from "../Permission/PermissionModifier.sol";
import{ IPulleyTokenEngine} from "../interfaces/IPulleyTokenEngine.sol";
import{IPermissionManager} from "../Permission/interface/IPermissionManager.sol";

/// @title CrossChainController - Manages cross-chain fund allocation and operations
/// @notice Controls fund distribution: 10% insurance, 45% Nest vault, 45% limit orders
contract CrossChainController is OApp, OAppOptionsType3, ReentrancyGuard {
    using PermissionModifiers for *;
    using SafeERC20 for IERC20;

    // ============ Contract Addresses ============
    address public STRATEGY_CONTRACT;
    address public LIMITORDER_CONTRACT;
    address public IPERMISSION;
    address public PULLEY_STABLECOIN_ADDRESS;
    address public TRADING_POOL_ADDRESS;
    address public PULLEY_TOKEN_ENGINE_ADDRESS;

    // ============ Fund Allocation Constants ============
    uint256 public constant INSURANCE_PERCENTAGE = 10; // 10%
    uint256 public constant NEST_VAULT_PERCENTAGE = 45; // 45%
    uint256 public constant LIMIT_ORDER_PERCENTAGE = 45; // 45%
    uint256 public constant PERCENTAGE_BASE = 100;
    
    // Profit distribution constants
    uint256 public constant INSURANCE_PROFIT_SHARE = 1; // 1%
    uint256 public constant TRADER_PROFIT_SHARE = 99; // 99%

    // ============ Thresholds ============
    uint256 public profitThreshold = 1000 * 1e18; // Threshold for profit recording
    uint256 public minimumGasBalance = 0.01 ether; // Minimum gas for operations

    /// @notice Modifier for permissioned actions
    modifier isAuthorized(bytes4 _functionSelector){
        require(IPermissionManager(IPERMISSION).hasPermissions(msg.sender, _functionSelector), "CrossChainController: not authorized");
        _;
    }

    // ============ State Variables ============

    // Asset tracking
    mapping(address => uint256) public insuranceAllocations;
    mapping(address => uint256) public nestVaultAllocations;
    mapping(address => uint256) public limitOrderAllocations;
    mapping(address => bool) public supportedAssets;
    address[] public assetList;

    // Profit tracking
    mapping(address => uint256) public nestVaultProfits;
    mapping(address => uint256) public limitOrderProfits;
    mapping(address => uint256) public totalInvested;
    mapping(bytes32 => bool) public processedRequests;

    // Cross-chain request tracking
    mapping(bytes32 => CrossChainRequest) public pendingRequests;
    uint256 public requestNonce;

    // ============ Message Types ============
    uint16 public constant DEPOSIT_REQUEST = 2;
    uint16 public constant STATE_RESPONSE = 4;
    uint16 public constant FILL_ORDER = 5;
    uint16 public constant FILL_ORDER_ARGS = 6;
    uint16 public constant FILL_CONTRACT_ORDER = 7;
    uint16 public constant CANCEL_ORDERS = 8;
    uint16 public constant PROFIT_CHECK_REQUEST = 9;

    // ============ Structs ============
    struct CrossChainRequest {
        bytes32 requestId;
        uint32 dstEid;
        uint16 msgType;
        address asset;
        uint256 amount;
        uint256 timestamp;
        bool processed;
    }

    struct FundAllocation {
        address asset;
        uint256 totalAmount;
        uint256 insuranceAmount;
        uint256 nestVaultAmount;
        uint256 limitOrderAmount;
    }

    struct StateResponse {
        bytes32 requestId;
        bool success;
        uint256 resultAmount;
        string errorMessage;
        uint32 dstEid;
        uint256 timestamp;
    }

    struct ProfitData {
        address asset;
        uint256 initialInvestment;
        uint256 currentValue;
        int256 profitLoss;
        uint256 timestamp;
    }

    // ============ Events ============
    event FundsReceived(address indexed asset, uint256 amount, address indexed from);
    event FundsAllocated(address indexed asset, uint256 insurance, uint256 nestVault, uint256 limitOrder);
    event CrossChainRequestSent(bytes32 indexed requestId, uint32 dstEid, uint16 msgType, address asset, uint256 amount);
    event StateResponseReceived(bytes32 indexed requestId, bool success, uint256 resultAmount, string errorMessage);
    event ProfitRecorded(address indexed asset, int256 profitLoss, uint256 insuranceShare, uint256 traderShare);
    event InsuranceUpdated(address indexed asset, uint256 amount, bool isIncrease);
    event ThresholdReached(address indexed asset, uint256 currentProfit, uint256 threshold);
    event AssetSupportUpdated(address indexed asset, bool supported);

    // ============ Errors ============
    error CrossChainController__ZeroAmount();
    error CrossChainController__UnsupportedAsset();
    error CrossChainController__InsufficientFunds();
    error CrossChainController__InvalidAllocation();
    error CrossChainController__RequestAlreadyProcessed();
    error CrossChainController__UnknownMessageType();
    error CrossChainController__InsufficientGasBalance();
    error CrossChainController__TransferFailed();

    /// @notice Initialize with Endpoint V2 and owner address
    /// @param _endpoint The local chain's LayerZero Endpoint V2 address
    /// @param _owner    The address permitted to configure this OApp
    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {
        // Initialize with minimum gas balance
        minimumGasBalance = 0.01 ether;
    }

    // ============ Fund Management Functions ============

    function receiveFundsFromTradingPool() 
        external 
        nonReentrant 
        
    {
      
        
        for(uint256 i = 0; i < assetList.length; i++) {
            address currentAsset = assetList[i];
            uint256 _amount = IERC20(currentAsset).balanceOf(address(this));
            
            if (_amount == 0) continue; // Skip if no balance
            if (!supportedAssets[currentAsset]) revert CrossChainController__UnsupportedAsset();

            // Allocate funds according to percentages
            FundAllocation memory allocation = _calculateAllocation(currentAsset, _amount);
            
            // Update allocations
            insuranceAllocations[currentAsset] += allocation.insuranceAmount;
            nestVaultAllocations[currentAsset] += allocation.nestVaultAmount;
            limitOrderAllocations[currentAsset] += allocation.limitOrderAmount;
            totalInvested[currentAsset] += _amount;

            // Send insurance portion to PulleyTokenEngine for insurance minting
            if (allocation.insuranceAmount > 0) {
                _sendToInsurance(currentAsset, allocation.insuranceAmount);
            }

            emit FundsReceived(currentAsset, _amount, msg.sender);
            emit FundsAllocated(currentAsset, allocation.insuranceAmount, allocation.nestVaultAmount, allocation.limitOrderAmount);
        }
    }

    /// @notice Calculate fund allocation based on percentages
    /// @param asset The asset to allocate
    /// @param totalAmount Total amount to allocate
    /// @return allocation FundAllocation struct with calculated amounts
    function _calculateAllocation(address asset, uint256 totalAmount) 
        internal 
        pure 
        returns (FundAllocation memory allocation) 
    {
        allocation.asset = asset;
        allocation.totalAmount = totalAmount;
        
        // Calculate allocations
        allocation.insuranceAmount = (totalAmount * INSURANCE_PERCENTAGE) / PERCENTAGE_BASE;
        allocation.nestVaultAmount = (totalAmount * NEST_VAULT_PERCENTAGE) / PERCENTAGE_BASE;
        allocation.limitOrderAmount = (totalAmount * LIMIT_ORDER_PERCENTAGE) / PERCENTAGE_BASE;
        
        // Handle rounding errors - add remainder to Nest vault
        uint256 allocated = allocation.insuranceAmount + allocation.nestVaultAmount + allocation.limitOrderAmount;
        if (allocated < totalAmount) {
            allocation.nestVaultAmount += (totalAmount - allocated);
        }
    }

    /// @notice Send insurance funds to Pulley TokenEngine for insurance minting
    /// @param asset The asset to send
    /// @param amount The amount to send
    function _sendToInsurance(address asset, uint256 amount) internal {
         require(amount > 0, "Cross_chain_controller: cannot perform zero mint");
         IERC20(asset).approve(PULLEY_TOKEN_ENGINE_ADDRESS, amount);
         IPulleyTokenEngine( PULLEY_TOKEN_ENGINE_ADDRESS).insuranceBackingMinter(asset,amount);
         emit InsuranceUpdated(asset, amount, true);
    }

    // ============ Cross-Chain Operations ============

    /// @notice Deploy funds to Nest vault on another chain
    /// @param dstEid Destination chain endpoint ID
    /// @param asset Asset to deposit
    /// @param amount Amount to deposit
    /// @param options LayerZero options
    function deployToNestVault(
        uint32 dstEid,
        address asset,
        uint256 amount,
        bytes calldata options
    ) external payable isAuthorized(this.deployToNestVault.selector) {
        if (amount == 0) revert CrossChainController__ZeroAmount();
        if (amount > nestVaultAllocations[asset]) revert CrossChainController__InsufficientFunds();

        // Generate unique request ID
        bytes32 requestId = _generateRequestId(dstEid, DEPOSIT_REQUEST, asset, amount);
        
        // Create deposit request structure (matching Strategy contract)
        bytes memory depositRequest = abi.encode(
            asset,           // depositAsset
            amount,          // depositAmount  
            amount * 95 / 100, // minimumMint (95% of amount as safety)
            false,           // iswithpermit
            "",              // permitData (empty)
            address(this),   // requester
            requestId        // requestId
        );

        bytes memory message = abi.encode(DEPOSIT_REQUEST, depositRequest);
        
        // Store pending request
        pendingRequests[requestId] = CrossChainRequest({
            requestId: requestId,
            dstEid: dstEid,
            msgType: DEPOSIT_REQUEST,
            asset: asset,
            amount: amount,
            timestamp: block.timestamp,
            processed: false
        });

        // Update allocation
        nestVaultAllocations[asset] -= amount;

        // Send cross-chain message
        _lzSend(
            dstEid,
            message,
            combineOptions(dstEid, DEPOSIT_REQUEST, options),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit CrossChainRequestSent(requestId, dstEid, DEPOSIT_REQUEST, asset, amount);
    }

    /// @notice Execute limit order on another chain
    /// @param dstEid Destination chain endpoint ID
    /// @param orderData Encoded order data for 1inch limit order
    /// @param msgType Type of order message (FILL_ORDER, FILL_ORDER_ARGS, etc.)
    /// @param options LayerZero options
    function executeLimitOrder(
        uint32 dstEid,
        bytes calldata orderData,
        uint16 msgType,
        bytes calldata options
    ) external payable isAuthorized(this.executeLimitOrder.selector) {
        // Validate message type
        require(
            msgType == FILL_ORDER || 
            msgType == FILL_ORDER_ARGS || 
            msgType == FILL_CONTRACT_ORDER || 
            msgType == CANCEL_ORDERS,
            "CrossChainController: Invalid order message type"
        );

        // Generate unique request ID
        bytes32 requestId = _generateRequestId(dstEid, msgType, address(0), 0);
        
        bytes memory message = abi.encode(msgType, orderData);
        
        // Store pending request
        pendingRequests[requestId] = CrossChainRequest({
            requestId: requestId,
            dstEid: dstEid,
            msgType: msgType,
            asset: address(0), // Orders can involve multiple assets
            amount: 0,
            timestamp: block.timestamp,
            processed: false
        });

        // Send cross-chain message
        _lzSend(
            dstEid,
            message,
            combineOptions(dstEid, msgType, options),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit CrossChainRequestSent(requestId, dstEid, msgType, address(0), 0);
    }

    /// @notice Check profit status on remote chains
    /// @param dstEid Destination chain endpoint ID
    /// @param contractType 1 for Nest vault, 2 for limit orders
    /// @param options LayerZero options
    function checkRemoteProfit(
        uint32 dstEid,
        uint8 contractType,
        bytes calldata options
    ) external payable  {
        bytes32 requestId = _generateRequestId(dstEid, PROFIT_CHECK_REQUEST, address(0), contractType);
        
        bytes memory profitRequest = abi.encode(contractType, block.timestamp);
        bytes memory message = abi.encode(PROFIT_CHECK_REQUEST, profitRequest);
        
        // Store pending request
        pendingRequests[requestId] = CrossChainRequest({
            requestId: requestId,
            dstEid: dstEid,
            msgType: PROFIT_CHECK_REQUEST,
            asset: address(0),
            amount: contractType,
            timestamp: block.timestamp,
            processed: false
        });

        // Send cross-chain message
        _lzSend(
            dstEid,
            message,
            combineOptions(dstEid, PROFIT_CHECK_REQUEST, options),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit CrossChainRequestSent(requestId, dstEid, PROFIT_CHECK_REQUEST, address(0), contractType);
    }

    /// @notice Generate unique request ID
    /// @param dstEid Destination endpoint ID
    /// @param msgType Message type
    /// @param asset Asset address (can be zero)
    /// @param amount Amount or other data
    /// @return requestId Unique request identifier
    function _generateRequestId(
        uint32 dstEid,
        uint16 msgType,
        address asset,
        uint256 amount
    ) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(
            address(this),
            dstEid,
            msgType,
            asset,
            amount,
            requestNonce++,
            block.timestamp
        ));
    }

    // ============ LayerZero Message Handling ============

    /// @notice Handle incoming LayerZero messages
    /// @param _origin Origin metadata from LayerZero
    /// @param _message ABI-encoded message data
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        // Decode message type and data
        (uint16 msgType, bytes memory data) = abi.decode(_message, (uint16, bytes));

        if (msgType == STATE_RESPONSE) {
            // Handle state response from cross-chain operations
            _handleStateResponse(_origin, data);
        } else {
            revert CrossChainController__UnknownMessageType();
        }
    }

    /// @notice Handle state response from cross-chain operations
    /// @param _origin Origin metadata from LayerZero
    /// @param _data Encoded StateResponse data
    function _handleStateResponse(Origin calldata _origin, bytes memory _data) internal {
        StateResponse memory response = abi.decode(_data, (StateResponse));
        
        // Prevent replay attacks
        if (processedRequests[response.requestId]) {
            revert CrossChainController__RequestAlreadyProcessed();
        }
        processedRequests[response.requestId] = true;

        // Get the original request
        CrossChainRequest storage request = pendingRequests[response.requestId];
        require(request.dstEid == _origin.srcEid, "CrossChainController: Invalid response origin");
        
        // Mark request as processed
        request.processed = true;

        // Handle response based on original request type
        if (request.msgType == DEPOSIT_REQUEST) {
            _handleNestVaultResponse(request, response);
        } else if (
            request.msgType == FILL_ORDER || 
            request.msgType == FILL_ORDER_ARGS || 
            request.msgType == FILL_CONTRACT_ORDER
        ) {
            _handleLimitOrderResponse(request, response);
        } else if (request.msgType == PROFIT_CHECK_REQUEST) {
            _handleProfitCheckResponse(request, response);
        }

        // Report profit/loss back to trading pool
        _reportToTradingPool(response.resultAmount > 0 ? int256(response.resultAmount) : -int256(response.resultAmount));

        emit StateResponseReceived(response.requestId, response.success, response.resultAmount, response.errorMessage);
    }

    /// @notice Handle Nest vault operation response
    /// @param request Original request data
    /// @param response State response from Nest vault
    function _handleNestVaultResponse(
        CrossChainRequest memory request,
        StateResponse memory response
    ) internal {
        if (response.success) {
            // Update profit tracking for successful deposit
            nestVaultProfits[request.asset] += response.resultAmount;
            
            // Check if profit threshold is reached
            _checkProfitThreshold(request.asset, nestVaultProfits[request.asset], 1);
        } else {
            // Handle failed deposit - restore allocation
            nestVaultAllocations[request.asset] += request.amount;
        }
    }

    /// @notice Handle limit order response
    /// @param request Original request data
    /// @param response State response from limit order
    function _handleLimitOrderResponse(
        CrossChainRequest memory request,
        StateResponse memory response
    ) internal {
        if (response.success) {
            // For limit orders, resultAmount represents profit/loss
            // Positive means profit, handle accordingly
            limitOrderProfits[address(0)] += response.resultAmount; // Use zero address for general tracking
            
            // Check if profit threshold is reached
            _checkProfitThreshold(address(0), limitOrderProfits[address(0)], 2);
        }
        // Note: Failed orders don't need special handling as funds weren't moved
    }

    /// @notice Handle profit check response
    /// @param request Original request data
    /// @param response Profit data response
    function _handleProfitCheckResponse(
        CrossChainRequest memory request,
        StateResponse memory response
    ) internal {
        uint8 contractType = uint8(request.amount); // contractType was stored in amount field
        
        if (response.success) {
            // Response.resultAmount contains current profit/loss
            int256 profitLoss = int256(response.resultAmount);
            
            if (contractType == 1) {
                // Nest vault profit
                _processProfitDistribution(address(0), profitLoss, 1);
            } else if (contractType == 2) {
                // Limit order profit
                _processProfitDistribution(address(0), profitLoss, 2);
            }
        }
    }

    // ============ Profit Tracking & Distribution ============

    /// @notice Check if profit threshold is reached and trigger distribution
    /// @param asset Asset address (zero address for general tracking)
    /// @param currentProfit Current profit amount
    /// @param contractType 1 for Nest vault, 2 for limit orders
    function _checkProfitThreshold(address asset, uint256 currentProfit, uint8 contractType) internal {
        if (currentProfit >= profitThreshold) {
            emit ThresholdReached(asset, currentProfit, profitThreshold);
            
            // Trigger profit distribution
            _processProfitDistribution(asset, int256(currentProfit), contractType);
            
            // Reset profit counter after distribution
            if (contractType == 1) {
                nestVaultProfits[asset] = 0;
            } else if (contractType == 2) {
                limitOrderProfits[asset] = 0;
            }
        }
    }

    /// @notice Process profit distribution: 1% to insurance, 99% to traders
    /// @param asset Asset involved in profit (zero address for general)
    /// @param profitLoss Profit or loss amount (negative for loss)
    /// @param contractType 1 for Nest vault, 2 for limit orders
    function _processProfitDistribution(address asset, int256 profitLoss, uint8 contractType) internal {
        if (profitLoss > 0) {
            // Profit case: 1% to insurance, 99% to traders
            uint256 profit = uint256(profitLoss);
            uint256 insuranceShare = (profit * INSURANCE_PROFIT_SHARE) / PERCENTAGE_BASE;
            uint256 traderShare = profit - insuranceShare;
            
            // Send insurance share to Pulley StableCoin
            if (insuranceShare > 0 && PULLEY_STABLECOIN_ADDRESS != address(0)) {
                // For cross-chain profits, we need to handle this differently
                // Here we just track it for now
                insuranceAllocations[asset] += insuranceShare;
                emit InsuranceUpdated(asset, insuranceShare, true);
            }
            
            // Send trader share back to trading pool
            if (traderShare > 0 && TRADING_POOL_ADDRESS != address(0)) {
                // Track trader rewards - in practice this would trigger distribution
                emit ProfitRecorded(asset, profitLoss, insuranceShare, traderShare);
            }
            
        } else if (profitLoss < 0) {
            // Loss case: Use insurance to cover if available
            uint256 loss = uint256(-profitLoss);
            
            if (insuranceAllocations[asset] >= loss) {
                // Insurance covers the full loss
                insuranceAllocations[asset] -= loss;
                emit InsuranceUpdated(asset, loss, false);
                emit ProfitRecorded(asset, profitLoss, loss, 0);
            } else {
                // Insurance partially covers or doesn't cover
                uint256 coveredByInsurance = insuranceAllocations[asset];
                insuranceAllocations[asset] = 0;
                
                if (coveredByInsurance > 0) {
                    emit InsuranceUpdated(asset, coveredByInsurance, false);
                }
                
                emit ProfitRecorded(asset, profitLoss, coveredByInsurance, 0);
            }
        }
    }

    /// @notice Automated profit threshold checking (can be called by anyone)
    /// @dev Implements threshold-based profit distribution logic
    function thresholdCryptographyUseCase() external {
        _performAutomatedProfitCheck();
    }

    /// @notice Check all assets for profit thresholds and trigger distributions
    function _performAutomatedProfitCheck() internal {
        for (uint256 i = 0; i < assetList.length; i++) {
            address asset = assetList[i];
            
            // Check Nest vault profits
            if (nestVaultProfits[asset] >= profitThreshold) {
                _checkProfitThreshold(asset, nestVaultProfits[asset], 1);
            }
            
            // Check limit order profits  
            if (limitOrderProfits[asset] >= profitThreshold) {
                _checkProfitThreshold(asset, limitOrderProfits[asset], 2);
            }
        }
    }

    // ============ Administrative Functions ============

    /// @notice Automatic profit recording from cross-chain responses
    /// @dev This function is now only called internally from cross-chain responses
    /// @param asset Asset address
    /// @param profitLoss Profit or loss amount
    /// @param contractType Contract type (1 = Nest vault, 2 = Limit orders)
    function _recordProfitFromResponse(
        address asset,
        int256 profitLoss,
        uint8 contractType
    ) internal {
        _processProfitDistribution(asset, profitLoss, contractType);
    }

    /// @notice Add or remove supported asset
    function setSupportedAsset(address asset, bool supported) 
        external 
        isAuthorized(this.setSupportedAsset.selector) 
    {
        if (supported && !supportedAssets[asset]) {
            supportedAssets[asset] = true;
            assetList.push(asset);
        } else if (!supported && supportedAssets[asset]) {
            supportedAssets[asset] = false;
            // Remove from asset list
            for (uint256 i = 0; i < assetList.length; i++) {
                if (assetList[i] == asset) {
                    assetList[i] = assetList[assetList.length - 1];
                    assetList.pop();
                    break;
                }
            }
        }
        
        emit AssetSupportUpdated(asset, supported);
    }

    /// @notice Update profit threshold
    function setProfitThreshold(uint256 newThreshold) 
        external 
        isAuthorized(this.setProfitThreshold.selector) 
    {
        profitThreshold = newThreshold;
    }

    /// @notice Set contract addresses
    function setContractAddress(
        address _strategyaddress, 
        address limitOrder, 
        address permission,
        address pulleyStablecoin,
        address tradingPool
    ) external isAuthorized(this.setContractAddress.selector) {
        STRATEGY_CONTRACT = _strategyaddress;
        LIMITORDER_CONTRACT = limitOrder;
        IPERMISSION = permission;
        PULLEY_STABLECOIN_ADDRESS = pulleyStablecoin;
        TRADING_POOL_ADDRESS = tradingPool;
    }

    // ============ View Functions ============

    /// @notice Get fund allocation for an asset
    function getFundAllocation(address asset) 
        external 
        view 
        returns (uint256 insurance, uint256 nestVault, uint256 limitOrder) 
    {
        return (
            insuranceAllocations[asset],
            nestVaultAllocations[asset], 
            limitOrderAllocations[asset]
        );
    }

    /// @notice Get profit data for an asset
    function getProfitData(address asset) 
        external 
        view 
        returns (uint256 nestProfit, uint256 limitProfit, uint256 totalInvestedAmount) 
    {
        return (
            nestVaultProfits[asset],
            limitOrderProfits[asset],
            totalInvested[asset]
        );
    }

    /// @notice Get supported assets list
    function getSupportedAssets() external view returns (address[] memory assets) {
        return assetList;
    }

    // ============ Utility Functions ============

    /// @notice Emergency withdraw function (admin only)
    function emergencyWithdraw(address asset, uint256 amount, address to) 
        external 
        isAuthorized(this.emergencyWithdraw.selector) 
    {
        if (asset == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    /// @notice Report profit/loss back to trading pool
    /// @param profitLoss Positive for profit, negative for loss
    function _reportToTradingPool(int256 profitLoss) internal {
        if (TRADING_POOL_ADDRESS == address(0)) return;
        
        if (profitLoss > 0) {
            // Report profit to trading pool
            (bool success,) = TRADING_POOL_ADDRESS.call(
                abi.encodeWithSignature("recordTradingProfit(uint256)", uint256(profitLoss))
            );
            require(success, "CrossChainController: Failed to report profit");
        } else if (profitLoss < 0) {
            // Report loss to trading pool
            (bool success,) = TRADING_POOL_ADDRESS.call(
                abi.encodeWithSignature("recordTradingLoss(uint256)", uint256(-profitLoss))
            );
            require(success, "CrossChainController: Failed to report loss");
        }
    }

    /// @notice Allow contract to receive native tokens for gas fees
    receive() external payable {}
}
