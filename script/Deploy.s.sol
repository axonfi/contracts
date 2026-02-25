// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AxonRegistry.sol";
import "../src/AxonVaultFactory.sol";

/// @notice Deploys AxonRegistry and AxonVaultFactory, then registers default swap routers.
///
/// Environment variables:
///   PRIVATE_KEY   — deployer's private key (testnet only; use --ledger on mainnet)
///   OWNER_ADDRESS — address that will own both contracts (defaults to deployer if not set)
///                   On mainnet this should be a Safe multisig address.
///
/// Usage:
///   # Testnet (Base Sepolia)
///   forge script script/Deploy.s.sol \
///     --rpc-url base_sepolia \
///     --broadcast \
///     --verify \
///     -vvvv
///
///   # Mainnet with hardware wallet
///   forge script script/Deploy.s.sol \
///     --rpc-url base \
///     --broadcast \
///     --ledger \
///     --verify \
///     -vvvv
contract Deploy is Script {
    function run() external {
        // ── Deployer key ─────────────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // ── Owner address ─────────────────────────────────────────────────────
        // On testnet this is typically the deployer itself.
        // On mainnet set OWNER_ADDRESS to your Safe multisig so ownership
        // lands directly on the multisig — no transfer step needed.
        address owner = vm.envOr("OWNER_ADDRESS", deployer);

        // ── Pre-flight log ────────────────────────────────────────────────────
        console2.log("=== Axon Deployment ===");
        console2.log("Chain ID   :", block.chainid);
        console2.log("Deployer   :", deployer);
        console2.log("Owner      :", owner);
        console2.log("  (owner == deployer:", owner == deployer, ")");

        // ── Deploy ────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        AxonRegistry registry = new AxonRegistry(owner);
        AxonVaultFactory factory = new AxonVaultFactory(address(registry), owner);

        // ── Register default swap routers ─────────────────────────────────────
        // Uniswap V3 SwapRouter02 — the primary swap router for all chains.
        // These are added to the global registry so all vaults can swap immediately.
        if (block.chainid == 8453) {
            // Base mainnet
            registry.addSwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
        } else if (block.chainid == 84532) {
            // Base Sepolia
            registry.addSwapRouter(0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4);
        } else if (block.chainid == 42161) {
            // Arbitrum One
            registry.addSwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
        }

        vm.stopBroadcast();

        // ── Post-deployment log ───────────────────────────────────────────────
        console2.log("");
        console2.log("=== Deployed Addresses ===");
        console2.log("AxonRegistry    :", address(registry));
        console2.log("AxonVaultFactory:", address(factory));
        console2.log("");
        console2.log("=== Verification ===");
        console2.log("registry.owner()         :", registry.owner());
        console2.log("factory.owner()          :", factory.owner());
        console2.log("factory.axonRegistry()   :", factory.axonRegistry());
        console2.log("factory.vaultCount()     :", factory.vaultCount());
    }
}
