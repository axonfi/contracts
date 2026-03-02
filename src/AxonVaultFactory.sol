// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./AxonVault.sol";

/// @title AxonVaultFactory
/// @notice Deploys AxonVault instances for Owners.
///         One factory is deployed per chain by Axon. All vaults on this chain
///         share the same AxonRegistry (immutably set in each vault at deploy time).
///         The factory stores a record of all deployed vaults for indexing and admin tooling.
contract AxonVaultFactory is Ownable2Step {
    /// @notice The AxonRegistry address used by all vaults deployed from this factory.
    address public immutable axonRegistry;

    /// @notice All vaults ever deployed from this factory, in order of deployment.
    address[] public allVaults;

    /// @notice Vaults deployed by each Owner address.
    mapping(address => address[]) public ownerVaults;

    event VaultDeployed(
        address indexed owner, address indexed vault, uint16 version, address axonRegistry, bool trackUsedIntents
    );

    error ZeroAddress();

    constructor(address _axonRegistry, address factoryOwner) Ownable(factoryOwner) {
        if (_axonRegistry == address(0)) revert ZeroAddress();
        axonRegistry = _axonRegistry;
    }

    /// @notice Deploy a new AxonVault for the caller (the Owner).
    ///         The vault is owned by msg.sender and uses this factory's AxonRegistry.
    /// @param trackUsedIntents If true, the vault tracks used intent hashes to prevent duplicates.
    ///                         Set to false only for extreme high-frequency trading bots.
    function deployVault(bool trackUsedIntents) external returns (address vault) {
        AxonVault newVault = new AxonVault(msg.sender, axonRegistry, trackUsedIntents);
        vault = address(newVault);

        allVaults.push(vault);
        ownerVaults[msg.sender].push(vault);

        emit VaultDeployed(msg.sender, vault, newVault.VERSION(), axonRegistry, trackUsedIntents);
    }

    /// @notice Total number of vaults deployed from this factory.
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Number of vaults deployed by a specific Owner.
    function ownerVaultCount(address owner) external view returns (uint256) {
        return ownerVaults[owner].length;
    }
}
