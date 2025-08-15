//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

interface ITradingPool {
    function depositAsset(address asset, uint256 amount) external;
    function withdrawAsset(address asset, uint256 amount, address recipient) external;
    function recordTradingLoss(uint256 lossAmountUSD) external;
    function recordTradingProfit(uint256 profitAmountUSD) external;
    function distributeProfits() external returns (uint256 pulleyShare, uint256 poolShare);
    function updateAssetSupport(address asset, bool supported) external;
    function updatePulleyTokenEngine(address _pulleyTokenEngine) external;
    function getTotalPoolValue() external view returns (uint256);
    function getPoolMetrics() external view returns (uint256 totalValue, uint256 totalLosses, uint256 totalProfits);
    function getAssetBalance(address asset) external view returns (uint256);
    function getSupportedAssets() external view returns (address[] memory);
    function getPendingProfitDistribution() external view returns (uint256);
    function getLossCoverageMetrics()
        external
        view
        returns (uint256 totalLosses, uint256 coveredByPulley, uint256 currentProfitShare);
}
