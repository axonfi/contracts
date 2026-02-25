// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IAxonRegistry.sol";

/// @title AxonRegistry
/// @notice Axon-controlled registry of authorized relayers and approved swap routers.
///         All AxonVaults check against this registry before executing payments or swaps.
///         One registry is deployed per chain. Vaults store the registry address as immutable.
contract AxonRegistry is IAxonRegistry, Ownable2Step {
    mapping(address => bool) private _authorizedRelayers;
    mapping(address => bool) private _approvedSwapRouters;

    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event SwapRouterAdded(address indexed router);
    event SwapRouterRemoved(address indexed router);

    error ZeroAddress();
    error AlreadyAuthorized();
    error NotAuthorized();
    error AlreadyApproved();
    error NotApproved();

    constructor(address initialOwner) Ownable(initialOwner) { }

    // =========================================================================
    // Relayer management
    // =========================================================================

    /// @notice Authorize a relayer address. Only callable by Axon (owner).
    function addRelayer(address relayer) external onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        if (_authorizedRelayers[relayer]) revert AlreadyAuthorized();
        _authorizedRelayers[relayer] = true;
        emit RelayerAdded(relayer);
    }

    /// @notice Revoke a relayer address. Only callable by Axon (owner).
    function removeRelayer(address relayer) external onlyOwner {
        if (!_authorizedRelayers[relayer]) revert NotAuthorized();
        _authorizedRelayers[relayer] = false;
        emit RelayerRemoved(relayer);
    }

    /// @notice Returns true if the address is an authorized Axon relayer.
    function isAuthorized(address relayer) external view override returns (bool) {
        return _authorizedRelayers[relayer];
    }

    // =========================================================================
    // Swap router management
    // =========================================================================

    /// @notice Approve a swap router (e.g. Uniswap, 1inch). Only callable by Axon (owner).
    function addSwapRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        if (_approvedSwapRouters[router]) revert AlreadyApproved();
        _approvedSwapRouters[router] = true;
        emit SwapRouterAdded(router);
    }

    /// @notice Revoke a swap router. Only callable by Axon (owner).
    function removeSwapRouter(address router) external onlyOwner {
        if (!_approvedSwapRouters[router]) revert NotApproved();
        _approvedSwapRouters[router] = false;
        emit SwapRouterRemoved(router);
    }

    /// @notice Returns true if the address is an approved swap router.
    function isApprovedSwapRouter(address router) external view override returns (bool) {
        return _approvedSwapRouters[router];
    }
}
