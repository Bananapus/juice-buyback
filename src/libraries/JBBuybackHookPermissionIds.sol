// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Permission IDs for use in `JBPermissions`, for the buyback hook.
library JBBuybackHookPermissionIds {
    // [0..18] - JBPermissionIds
    // 19 - JBOperations2 (ENS/Handle)
    // 20 - JBUriOperations (Set token URI)
    // [21..23] - JB721Operations

    uint256 public constant SET_POOL_PARAMS = 24;
    uint256 public constant CHANGE_POOL = 25;
}
