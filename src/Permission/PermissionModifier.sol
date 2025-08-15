//SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IPermissionManager} from "./interface/IPermissionManager.sol";

/**
 * @title PermissionModifiers
 * @dev Library containing permission-related modifiers for access control
 * @author 0xodeili Lee
 */
library PermissionModifiers {
    /**
     * @dev Check if an account has permission for a specific function selector
     * @param permissionManager The permission manager contract address
     * @param account The account to check
     * @param functionSelector The function selector to check
     */
    function hasPermission(address permissionManager, address account, bytes4 functionSelector)
        internal
        view
        returns (bool)
    {
        return IPermissionManager(permissionManager).hasPermissions(account, functionSelector);
    }

    /**
     * @dev Require that an account has permission for a specific function selector
     * @param permissionManager The permission manager contract address
     * @param account The account to check
     * @param functionSelector The function selector to check
     */
    function requirePermission(address permissionManager, address account, bytes4 functionSelector) internal view {
        require(
            IPermissionManager(permissionManager).hasPermissions(account, functionSelector),
            "PermissionModifiers: Account does not have required permission"
        );
    }
}
