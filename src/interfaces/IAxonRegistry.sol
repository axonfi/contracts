// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAxonRegistry {
    function isAuthorized(address relayer) external view returns (bool);
    function isApprovedSwapRouter(address router) external view returns (bool);
}
