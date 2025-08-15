// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {PulleyTokenEngine} from "../src/Token/pulleyEngine.sol";
import {PulleyToken} from "../src/Token/PulleyToken.sol";
import {CrossChainController} from "../src/cross_chain/cross_chain_controller.sol";
import {Gateway} from "../src/Gateway.sol";
import {PermissionManager} from "../src/PermissionManager.sol";
import {TradingPool} from "../src/Pool/TradingPool.sol";
import {IPermissionManager} from "../src/permission/IpermissionManager.sol";

contract DeployScript is Script {
    PulleyTokenEngine pulley;
    PulleyToken pToken;
    PermissionManager permissionManager;
    CrossChainController controller;
    address[] allowedAssetsList;
    address baseEndpoint = 0x1a44076050125825900e736c501f859c50fE728c; //eth
   
    TradingPool tradingPool;
    address[] supportedAssets;
    Gateway gateway;
    uint256 public  threshold = 1;

    address public deployer;

    address public INTERGRATIONWALLET =
        0xf0830060f836B8d54bF02049E5905F619487989e;

    // address to add
    address public STRATEGY = 0xf0830060f836B8d54bF02049E5905F619487989e;
    address public LIMIT_ORDER = 0xf0830060f836B8d54bF02049E5905F619487989e;

    //token address
    address public usdc = 0xa4151B2B3e269645181dCcF2D426cE75fcbDeca9;
    address public coreToken = 0xb3a8f0f0da9ffc65318aa39e55079796093029ad;
    address public ethereum = 0xeAB3aC417c4d6dF6b143346a46fEe1B847B50296;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        vm.createSelectFork(vm.rpcUrl("corechainlocal"));
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying contracts to Core network...");
        console.log("Deployer address:", deployer);

        deploy();
        grantPermission(deployer);
        setConfig();
        logAddress();

        vm.stopBroadcast();
    }

    function deploy() internal {
        permissionManager = new PermissionManager();
         pToken = new PulleyToken(
            "PulleyToken",
            "PK",
            address(permissionManager)
        );
        controller = new CrossChainController(baseEndpoint, deployer);
       
        pulley = new PulleyTokenEngine(
            address(pToken),
            allowedAssetsList,
            address(permissionManager)
        );
        tradingPool = new TradingPool(
            address(pulley),
            supportedAssets,
            address(permissionManager)
        );
        gateway = new Gateway(
            address(pToken),
            address(pulley),
            address(tradingPool),
            address(controller),
            address(permissionManager)
        );
    }

    function setConfig() internal {
        pToken.setCrossChainContract(address(controller));
        pToken.setPulleyTokenEngine(address(pulley));
        tradingPool.setCrossChainController(address(controller));
      //  controller.setProfitThreshold( threshold);
        // controller.setContractAddress(
        //     STRATEGY,
        //     LIMIT_ORDER,
        //     address(permissionManager),
        //     address(pToken),
        //     address(tradingPool)
        // );
        setAsset();
    }

    function setAsset() internal {
      
        pulley.setAssetAllowed(address(pToken), true);
        pulley.setAssetAllowed(address(usdc), true);
        pulley.setAssetAllowed(address(coreToken), true);
        pulley.setAssetAllowed(address(ethereum), true);
    }

    function grantPermission(address _account) internal {
        bytes4[] memory permissions = new bytes4[](12);

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

        IPermissionManager(address(permissionManager)).grantBatchPermission(
            _account,
            permissions
        );
        IPermissionManager(address(permissionManager)).grantBatchPermission(
            INTERGRATIONWALLET,
            permissions
        );
    }

    function logAddress() internal view {
        console.log("PULLEY TOKEN WAS DEPLOYED AT ADDRESS", address(pToken));
        console.log("PULLEY ENGINE WAS DEPLOYED AT ADDRESS", address(pulley));
        console.log(
            "PERMISSION WAS DEPLOYED AT ADDRESS",
            address(permissionManager)
        );
        console.log("TRADING WAS DEPLOYED AT ADDRESS", address(tradingPool));
        console.log("GATEWAY WAS DEPLOYED AT ADDRESS", address(gateway));
        console.log(
            "CROSS-CHAIN  WAS DEPLOYED AT ADDRESS",
            address(controller)
        );
    }
}
