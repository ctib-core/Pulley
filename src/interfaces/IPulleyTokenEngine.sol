//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

interface IPulleyTokenEngine {
    function provideLiquidity(address asset, uint256 amount) external;
    
    function insuranceBackingMinter(address asset, uint256 amount)external;
    function withdrawLiquidity(address asset, uint256 pulleyTokensToRedeem) external;
    function coverTradingLoss(uint256 lossAmountUSD) external returns (bool);
    function distributeProfits(uint256 profitAmount) external;
    function setAssetAllowed(address asset, bool allowed) external;
    function getReserveBalance() external view returns (uint256);
    function isAssetAllowed(address asset) external view returns (bool);
    function getProvider(address provider) external view returns (uint256 assetsDeposited, uint256 pulleyTokensOwned, uint256 depositTime);
    function getSystemMetrics() external view returns (uint256 totalBacking, uint256 totalLosses, uint256 reserveRatio, uint256 providerCount);
    function getAssetReserve(address asset) external view returns (uint256);
}
