//SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IPermissionManager
 * @dev This contract is a placeholder for managing permissions within the system.
 * It is designed to give permission to admin functionality using function selectors.
 * This means that only addresses with the correct function selector can execute certain functions.
 * @author 0xodeili Lee
 */
interface IPermissionManager {
    struct Permission {
        address account;
        bytes4 functionSelector;
        bool isActive;
        uint40 grantedAt;
    }

    function grantPermission(address _account, bytes4 _functionSelector) external;
    function grantBatchPermission(address _account, bytes4[] calldata _functionSelector) external;
    function revokePermision(address _account, bytes4 _functionSelector) external;
    function batchRevokePermission(address _account, bytes4[] calldata _functionSelector) external;
    function getAccountFunctionSelectors(address _account) external view returns (bytes4[] memory);
    function hasPermissions(address _account, bytes4 _functionSelector) external view returns (bool);
    function setNewPermissionManager(address _newowner) external;
    function owner() external view returns (address);
}
