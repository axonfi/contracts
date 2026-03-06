// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IAxonRegistry.sol";

/// @title AxonRegistry
/// @notice Axon-controlled registry of authorized relayers and approved swap routers.
///         All AxonVaults check against this registry before executing payments or swaps.
///         One registry is deployed per chain. Vaults store the registry address as immutable.
contract AxonRegistry is IAxonRegistry, Ownable2Step {
    uint256 public constant VERSION = 1;

    mapping(address => bool) private _authorizedRelayers;
    mapping(address => bool) private _approvedSwapRouters;

    // Oracle config — used by vaults for on-chain TWAP price lookups
    address private _uniswapV3Factory;
    address private _usdcAddress;
    address private _wethAddress;

    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event SwapRouterAdded(address indexed router);
    event SwapRouterRemoved(address indexed router);
    event OracleConfigUpdated(address uniswapV3Factory, address usdc, address weth);

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

    // =========================================================================
    // Oracle config (TWAP price lookups)
    // =========================================================================

    /// @notice Set the oracle config for on-chain TWAP price lookups.
    ///         Must be called after deployment for non-USDC maxPerTxAmount checks to work.
    function setOracleConfig(address uniV3Factory, address usdc, address weth) external onlyOwner {
        if (uniV3Factory == address(0) || usdc == address(0) || weth == address(0)) revert ZeroAddress();
        _uniswapV3Factory = uniV3Factory;
        _usdcAddress = usdc;
        _wethAddress = weth;
        emit OracleConfigUpdated(uniV3Factory, usdc, weth);
    }

    /// @notice Uniswap V3 factory for TWAP pool lookups.
    function uniswapV3Factory() external view override returns (address) {
        return _uniswapV3Factory;
    }

    /// @notice USDC address on this chain (base denomination for maxPerTxAmount).
    function usdcAddress() external view override returns (address) {
        return _usdcAddress;
    }

    /// @notice WETH address on this chain (used for multi-hop TWAP pricing).
    function wethAddress() external view override returns (address) {
        return _wethAddress;
    }
}
