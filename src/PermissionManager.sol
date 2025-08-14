//SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IPermissionManager} from "./permission/IpermissionManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PermissionManager
 * @dev This contract is a placeholder for managing permissions within the system.
 * It is designed to give permission to admin functionality using function selectors.
 * This means that only addresses with the correct function selector can execute certain functions.
 * @author 0xodeili Lee
 */
contract PermissionManager is Ownable {
    // Events
    event PermissionGranted(
        address _account,
        bytes4 _functionSelector,
        bool _isActive,
        uint40 _time
    );
    event PermissionRevoked(
        address _account,
        bytes4 _functionSelector,
        bool _isActive,
        uint40 _timestamp
    );
    struct Permission {
        address account;
        bytes4 functionSelector;
        bool isActive;
        uint40 grantedAt;
    }

    // Variables

    constructor() Ownable(msg.sender) {}

    // Mappings
    mapping(address => mapping(bytes4 => Permission)) private _permissions;
    mapping(address => bytes4[]) private _accountFunctionSelectors;
    mapping(bytes4 => address[]) private _functionAccounts;

    // Modifiers
    modifier validAccount(address _account) {
        require(
            _account != address(0),
            "PermissionManager: Cannot be zero address"
        );
        _;
    }

    //  modifier onlyOwner() {
    //      require(msg.sender == owner, "PermissionManager: not authorized");
    //      _;
    //  }

    /**
     * @dev Calls the internal permission grant logic to give permission
     * @notice _account the account to receive the permission
     * @notice the function selector to grant permission for
     */
    function grantPermission(
        address _account,
        bytes4 _functionSelector
    ) external onlyOwner validAccount(_account) {
        _grantPermission(_account, _functionSelector);
    }

    /**
     * @dev Grants batch permission to an account
     * @notice _account the account to receive the permission
     * @notice the function selectors to grant permission for
     */
    function grantBatchPermission(
        address _account,
        bytes4[] calldata _functionSelector
    ) external onlyOwner validAccount(_account) {
        for (uint256 i = 0; i < _functionSelector.length; i++) {
            _grantPermission(_account, _functionSelector[i]);
        }
    }

    // /**
    //  * @dev Function to revoke permission of an account
    //  * @notice _account the account to revoke the permission
    //  * @notice the function selector to revoke permission for
    //  */
    // function revokePermision(
    //     address _account,
    //     bytes4 _functionSelector
    // ) external onlyOwner validAccount(_account) {
    //     _revokePermission(_account, _functionSelector);
    // }

    // /**
    //  * @dev Function to batch revoke permission of an account
    //  * @notice _account the account to revoke the permission
    //  * @notice the function selectors to revoke permission for
    //  */
    // function batchRevokePermission(
    //     address _account,
    //     bytes4[] calldata _functionSelector
    // ) external onlyOwner validAccount(_account) {
    //     for (uint256 i = 0; i < _functionSelector.length; i++) {
    //         _revokePermission(_account, _functionSelector[i]);
    //     }
    // }

    /**
     * @dev Internal function to grant permission to an account
     * @notice _account the account to receive the permission
     * @notice the function selector to grant permission for
     */
    function _grantPermission(
        address _account,
        bytes4 functionSelector
    ) internal {
        Permission storage permission = _permissions[_account][
            functionSelector
        ];

        if (!permission.isActive) {
            _accountFunctionSelectors[_account].push(functionSelector);
            _functionAccounts[functionSelector].push(_account);
        }

        permission.account = _account;
        permission.functionSelector = functionSelector;
        permission.isActive = true;
        permission.grantedAt = uint40(block.timestamp);

        emit PermissionGranted(
            _account,
            functionSelector,
            true,
            uint40(block.timestamp)
        );
    }

    // /**
    //  * @dev Internal function to revoke permission of an account
    //  * @notice _account the account to revoke the permission
    //  * @notice the function selector to revoke permission for
    //  */
    // function _revokePermission(
    //     address _account,
    //     bytes4 _functionSelector
    // ) internal {
    //     Permission storage permission = _permissions[_account][
    //         _functionSelector
    //     ];

    //     if (permission.isActive) {
    //         permission.isActive = false;
    //     }

    //     emit PermissionRevoked(
    //         _account,
    //         _functionSelector,
    //         false,
    //         uint40(block.timestamp)
    //     );
    // }

    function hasPermissions(
        address _account,
        bytes4 _functionSelector
    ) public view returns (bool) {
        Permission storage permission = _permissions[_account][
            _functionSelector
        ];
        return permission.isActive;
    }

    function setNewPermissionManager(
        address _newowner
    ) public onlyOwner validAccount(_newowner) {
        transferOwnership(_newowner);
    }

   
}
