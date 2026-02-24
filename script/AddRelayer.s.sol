// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AxonRegistry.sol";

/// @notice Authorizes a relayer address in the AxonRegistry.
///         Must be called by the registry owner.
///
/// Environment variables:
///   PRIVATE_KEY       — owner's private key (must be registry owner)
///   REGISTRY_ADDRESS  — deployed AxonRegistry address
///   RELAYER_ADDRESS   — relayer hot wallet address to authorize
///
/// Usage:
///   REGISTRY_ADDRESS=0x... RELAYER_ADDRESS=0x... \
///   forge script script/AddRelayer.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --broadcast \
///     -vvvv
contract AddRelayer is Script {
    function run() external {
        uint256 ownerKey      = vm.envUint("PRIVATE_KEY");
        address registryAddr  = vm.envAddress("REGISTRY_ADDRESS");
        address relayerAddr   = vm.envAddress("RELAYER_ADDRESS");

        AxonRegistry registry = AxonRegistry(registryAddr);

        console2.log("=== AddRelayer ===");
        console2.log("Registry :", registryAddr);
        console2.log("Relayer  :", relayerAddr);
        console2.log("Authorized before:", registry.isAuthorized(relayerAddr));

        vm.startBroadcast(ownerKey);
        registry.addRelayer(relayerAddr);
        vm.stopBroadcast();

        console2.log("Authorized after :", registry.isAuthorized(relayerAddr));
    }
}
