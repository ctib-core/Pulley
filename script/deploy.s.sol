// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


import {Script} from "forge-std/src/Script.sol";
import {PulleyTokenEngine} from "../src/Token/pulleyEngine.sol";
import {PulleyToken} from "../src/Token/pulleyToken.sol";
import {CrossChainController} from "../src/cross_chain/cross_chain_controller.sol";
import {Gateway} from "../src/Gateway.sol";
contract DeployScript is Script {
  // deploy on coredao

  PulleyTokenEngine pulley;
  PulleyToken pToken;
  PermissionManager permissionManager;
  CrossChainController controller;
  address[] allowedAssetsList;
  address baseEndpoint;
  address owner;
  TradingPool tradingPool;
  address[] supportedAssets;
  Gateway gateway;


  function setUp() {
    controller = new CrossChainController(baseEndpoint, owner);
    pToken = new PulleyToken("PulleyToken", "PULL");
    pulley = new PulleyTokenEngine(address(ptoken), allowedAssetsList, address(permissionManager));
    tradingPool = new TradingPool(address(pulley), supportedAssets, address(permissionManager));
    gateway = new Gateway(address(pToken), address(pulley), address(tradingPool), address(controller), address(permissionManager));

  }


}