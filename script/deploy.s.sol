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

  address public deployer; 

  address public INTERGRATIONWALLET = 0xf0830060f836B8d54bF02049E5905F619487989e;
  address public STRATEGY = 0xf0830060f836B8d54bF02049E5905F619487989e ;
  address public LIMIT_ORDER = 0xf0830060f836B8d54bF02049E5905F619487989e ;

  address public usdc =  0xf0830060f836B8d54bF02049E5905F619487989e ;
  address public coreToken = 0xf0830060f836B8d54bF02049E5905F619487989e ;
  address public ethereum =  0xf0830060f836B8d54bF02049E5905F619487989e;


  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        vm.createSelectFork(vm.rpcUrl("ethereum"));
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying contracts to ETH network...");
        console.log("Deployer address:", deployer);

        deploy();
        grantPermission(deployer);
        setConfig();
        grantPermission(deployer); 
        logAddress();

        vm.stopBroadcast();
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

   pToken.setCrossChainContract(address(controller));
   pToken.setPulleyTokenEngine(address(pulley));
  tradingPool.setCrossChainController(address(controller));
  controller.setProfitThreshold(1);
  controller.setContractAddress(STRATEGY, LIMIT_ORDER, address(permissionManager), address(pToken),address(tradingPool));
      setAsset();   
}

function setAsset() internal {
   

  
   pulley.setAssetAllowed(address(pToken), true);
    pulley.setAssetAllowed(address(usdc), true);
     pulley.setAssetAllowed(address(coreToken), true);
     pulley.setAssetAllowed(address(ethereum ), true);

}



function grantPermission(address _account) internal {
   bytes4[] memory permissions = new bytes4[](11);

   permissions[0] = controller.emergencyWithdraw.selector;
   permissions[1] = controller.deployToNestVault.selector;
   permissions[2] = controller.executeLimitOrder.selector;
   permissions[3] = controller.setContractAddress.selector;
   permissions[4] = controller.setSupportedAsset.selector;
  
  
   permissions[5] = tradingPool.updatePulleyTokenEngine.selector;
   permissions[6] = tradingPool.setCrossChainController.selector;
   permissions[7] = tradingPool.updateAssetSupport.selector;
   permissions[8] = pToken.setCrossChainContract.selector;
   permissions[9] = pToken.setPulleyTokenEngine.selector;
   permissions[10] = pulley.setAssetAllowed.selector;
   permissions[11] = controller.setProfitThreshold.selector;

  IPermissionManager(PermissionManager).grantBatchPermission(_account, _functionSelector);
  IPermissionManager(PermissionManager).grantBatchPermission(INTERGRATIONWALLET, _functionSelector);

}

function logAddress() internal {

  console.log("PULLEY TOKEN WAS DEPLOYED AT ADDRESS",pToken);
    console.log("PULLEY ENGINE WAS DEPLOYED AT ADDRESS", pulley);
      console.log("PERMISSION WAS DEPLOYED AT ADDRESS",permissionManager);
        console.log("TRADING WAS DEPLOYED AT ADDRESS",tradingPool);
          console.log("GATEWAY WAS DEPLOYED AT ADDRESS",gateway);
            console.log("CROSS-CHAIN  WAS DEPLOYED AT ADDRESS",controller);
}

}

