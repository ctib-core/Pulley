//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPulleyToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function burnForCoverage(uint256 amount) external;
    function canCoverLoss(uint256 lossAmount) external view returns (bool);
    function getReserveFund() external view returns (uint256);
    function getTotalSupply() external view returns (uint256);
    function updateReserveFund(uint256 amount, bool increase) external;
}
