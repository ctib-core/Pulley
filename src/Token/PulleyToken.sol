//SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPulleyToken} from "../interfaces/IPulleyToken.sol";
import {IPermissionManager} from "../Permission/interface/IPermissionManager.sol";
import {PermissionModifiers} from "../Permission/PermissionModifier.sol";

/**
 * @title PulleyToken
 * @author Core-Connect Team
 * @notice Stable coin that provides insurance backing for trading pool losses
 * @dev This token is backed by real assets and used to cover trading losses
 */
contract PulleyToken is ERC20, ERC20Permit, ReentrancyGuard, IPulleyToken {
    using PermissionModifiers for *;

    address public pulleyTokenEngine;
    address public permissionManager;

    // Reserve fund that actually holds assets for coverage
    uint256 public reserveFund;


    //insurance funds

    uint256 public insuranceFunds;
  


    // Events
    event PulleyTokenEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event LossCovered(uint256 lossAmount, uint256 tokensUsed);
    event ReserveFundUpdated(uint256 newAmount);

    // Errors
    error PulleyToken__OnlyEngine();
    error PulleyToken__ZeroAddress();
    error PulleyToken__ZeroAmount();
    error PulleyToken__InsufficientReserveFund();

    modifier onlyEngine() {
        if (msg.sender != pulleyTokenEngine) {
            revert PulleyToken__OnlyEngine();
        }
        _;
    }

    modifier onlyPermitted(bytes4 selector) {
        require(
            IPermissionManager(permissionManager).hasPermissions(msg.sender, selector), "PulleyToken: not permitted"
        );
        _;
    }

    constructor(string memory name, string memory symbol, address _permissionManager)
        ERC20(name, symbol)
        ERC20Permit(name)
    {
        if (_permissionManager == address(0)) {
            revert PulleyToken__ZeroAddress();
        }
        permissionManager = _permissionManager;
    }

    /**
     * @notice Sets the PulleyTokenEngine address
     * @param _pulleyTokenEngine Address of the PulleyTokenEngine contract
     */
    function setPulleyTokenEngine(address _pulleyTokenEngine)
        external
        onlyPermitted(this.setPulleyTokenEngine.selector)
    {
        if (_pulleyTokenEngine == address(0)) {
            revert PulleyToken__ZeroAddress();
        }

        address oldEngine = pulleyTokenEngine;
        pulleyTokenEngine = _pulleyTokenEngine;

        emit PulleyTokenEngineUpdated(oldEngine, _pulleyTokenEngine);
    }

    address public CROSS_CHAIN_CONTRACT;

    /**
     * @notice Mints tokens and adds to reserve fund
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyEngine {
        if (to == address(0)) {
            revert PulleyToken__ZeroAddress();
        }
        if (amount == 0) {
            revert PulleyToken__ZeroAmount();
        }
        // Add to insurance funds if this is from cross-chain
        if (msg.sender == CROSS_CHAIN_CONTRACT) {
            insuranceFunds += amount;
        }

        // Increase reserve fund when minting (backed by real assets)
        reserveFund += amount;

        _mint(to, amount);
        emit TokensMinted(to, amount);
        emit ReserveFundUpdated(reserveFund);
    }

    /**
     * @notice Burns tokens and reduces reserve fund
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyEngine {
        if (msg.sender == CROSS_CHAIN_CONTRACT && insuranceFunds >= amount) {
            insuranceFunds -= amount;
        }

        if (amount == 0) {
            revert PulleyToken__ZeroAmount();
        }

        // Reduce reserve fund when burning
        if (reserveFund >= amount) {
            reserveFund -= amount;
        } else {
            reserveFund = 0;
        }

        _burn(from, amount);
        emit TokensBurned(from, amount);
        emit ReserveFundUpdated(reserveFund);
    }

   
    /**
     * @notice Get total supply of PulleyTokens
     * @return Total supply of tokens
     */
    function getTotalSupply() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Get reserve fund amount available for coverage
     * @return Amount in reserve fund
     */
    function getReserveFund() external view returns (uint256) {
        return reserveFund;
    }

    /**
     * @notice Check if sufficient reserves exist for coverage
     * @param amount Amount to check
     * @return True if sufficient reserves exist
     */
    function canCoverLoss(uint256 amount) external view returns (bool) {
        return insuranceFunds >= amount;
    }

    /**
     * @notice Burn tokens specifically for loss coverage
     * @param amount Amount to burn for coverage
     */
    function burnForCoverage(uint256 amount) external onlyEngine {
        if (amount == 0) {
            revert PulleyToken__ZeroAmount();
        }
        if (insuranceFunds < amount) {
            revert PulleyToken__InsufficientReserveFund();
        }

        // Reduce insurance funds
        insuranceFunds -= amount;
        
        // Reduce reserve fund
        if (reserveFund >= amount) {
            reserveFund -= amount;
        } else {
            reserveFund = 0;
        }

        emit LossCovered(amount, amount);
        emit ReserveFundUpdated(reserveFund);
    }

    /**
     * @notice Update reserve fund (increase or decrease)
     * @param amount Amount to update
     * @param increase True to increase, false to decrease
     */
    function updateReserveFund(uint256 amount, bool increase) external onlyEngine {
        if (amount == 0) {
            revert PulleyToken__ZeroAmount();
        }

        if (increase) {
            reserveFund += amount;
        } else {
            if (reserveFund >= amount) {
                reserveFund -= amount;
            } else {
                reserveFund = 0;
            }
        }

        emit ReserveFundUpdated(reserveFund);
    }

    /**
     * @notice Set cross-chain contract address
     * @param _crossChainContract Address of cross-chain contract
     */
    function setCrossChainContract(address _crossChainContract) 
        external 
        onlyPermitted(this.setCrossChainContract.selector) 
    {
        CROSS_CHAIN_CONTRACT = _crossChainContract;
    }

    
}
