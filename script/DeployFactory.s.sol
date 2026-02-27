// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AxonVaultFactory.sol";

/// @notice Deploys a new AxonVaultFactory pointing to an existing AxonRegistry.
///         Use this when the vault bytecode has changed but the registry is unchanged.
///
/// Environment variables:
///   PRIVATE_KEY      — deployer's private key
///   REGISTRY_ADDRESS — existing AxonRegistry address (required)
///   OWNER_ADDRESS    — factory owner (defaults to deployer)
///
/// Usage:
///   REGISTRY_ADDRESS=0x... forge script script/DeployFactory.s.sol \
///     --rpc-url base_sepolia --broadcast --verify -vvvv
contract DeployFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address registry = vm.envAddress("REGISTRY_ADDRESS");

        console2.log("=== Factory Redeployment ===");
        console2.log("Chain ID   :", block.chainid);
        console2.log("Deployer   :", deployer);
        console2.log("Owner      :", owner);
        console2.log("Registry   :", registry);

        vm.startBroadcast(deployerKey);

        AxonVaultFactory factory = new AxonVaultFactory(registry, owner);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployed ===");
        console2.log("AxonVaultFactory:", address(factory));
        console2.log("  axonRegistry() :", factory.axonRegistry());
        console2.log("  owner()        :", factory.owner());
    }
}
