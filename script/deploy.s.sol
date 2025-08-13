// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


import {Script} from "forge-std/Script.sol";
import {PulleyTokenEngine} from "../src/Token/pulleyEngine.sol";
import {PulleyToken} from "../src/Token/pulleyToken.sol";
import {CrossChainController} from "../src/cross_chain/cross_chain_controller.sol";
import {Gateway} from "../src/Gateway.sol";
import {PermissionManager} from "../src/PermissionManager.sol";
import {TradingPool} from "../src/Pool/TradingPool.sol";
import{IPermissionManager} from "../src/permission/IpermissionManager.sol";
contract DeployScript is Script {
  // deploy on coredao

  PulleyTokenEngine pulley;
  PulleyToken pToken;
  PermissionManager permissionManager;
  CrossChainController controller;
  address[] allowedAssetsList;
  address baseEndpoint;
  address owner = address(0x11);
  TradingPool tradingPool;
  address[] supportedAssets;
  Gateway gateway;


  function run() public {
   
  }



function deploy()internal {
   permissionManager = new PermissionManager();
    controller = new CrossChainController(baseEndpoint, owner);
    pToken = new PulleyToken("PulleyToken", "PK", address(permissionManager));
    pulley = new PulleyTokenEngine(address(pToken), allowedAssetsList, address(permissionManager));
    tradingPool = new TradingPool(address(pulley), supportedAssets, address(permissionManager));
    gateway = new Gateway(address(pToken), address(pulley), address(tradingPool), address(controller), address(permissionManager));

}

function setConfig() internal{

}

function grantPermission() internal {
   bytes4[] memory permissions = new bytes4[](2);
  IPermissionManager(PermissionManager).grantBatchPermission(_account, _functionSelector);

}

}