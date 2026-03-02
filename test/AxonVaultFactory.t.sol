// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AxonVaultFactory.sol";
import "../src/AxonVault.sol";
import "../src/AxonRegistry.sol";

contract AxonVaultFactoryTest is Test {
    AxonVaultFactory factory;
    AxonRegistry registry;

    address axonDeployer = makeAddr("axonDeployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public {
        registry = new AxonRegistry(axonDeployer);
        factory = new AxonVaultFactory(address(registry), axonDeployer);
    }

    // =========================================================================
    // Deployment
    // =========================================================================

    function test_factory_owner_is_axon() public view {
        assertEq(factory.owner(), axonDeployer);
    }

    function test_factory_axonRegistry_immutable() public view {
        assertEq(factory.axonRegistry(), address(registry));
    }

    function test_factory_reverts_zero_registry() public {
        vm.expectRevert(AxonVaultFactory.ZeroAddress.selector);
        new AxonVaultFactory(address(0), axonDeployer);
    }

    // =========================================================================
    // deployVault
    // =========================================================================

    function test_deployVault_returns_vault_address() public {
        vm.prank(alice);
        address vault = factory.deployVault(true);
        assertNotEq(vault, address(0));
    }

    function test_deployVault_owner_is_caller() public {
        vm.prank(alice);
        address vault = factory.deployVault(true);
        assertEq(AxonVault(payable(vault)).owner(), alice);
    }

    function test_deployVault_uses_factory_registry() public {
        vm.prank(alice);
        address vault = factory.deployVault(true);
        assertEq(AxonVault(payable(vault)).axonRegistry(), address(registry));
    }

    function test_deployVault_trackUsedIntents_true() public {
        vm.prank(alice);
        address vault = factory.deployVault(true);
        assertTrue(AxonVault(payable(vault)).trackUsedIntents());
    }

    function test_deployVault_trackUsedIntents_false() public {
        vm.prank(alice);
        address vault = factory.deployVault(false);
        assertFalse(AxonVault(payable(vault)).trackUsedIntents());
    }

    function test_deployVault_emits_event() public {
        vm.prank(alice);

        // We don't know the vault address upfront, so check non-indexed fields
        vm.expectEmit(true, false, false, true);
        emit AxonVaultFactory.VaultDeployed(alice, address(0), 4, address(registry), true);

        factory.deployVault(true);
    }

    function test_deployVault_version_is_4() public {
        vm.prank(alice);
        address vault = factory.deployVault(true);
        assertEq(AxonVault(payable(vault)).VERSION(), 4);
    }

    // =========================================================================
    // Tracking
    // =========================================================================

    function test_vaultCount_increments() public {
        assertEq(factory.vaultCount(), 0);

        vm.prank(alice);
        factory.deployVault(true);
        assertEq(factory.vaultCount(), 1);

        vm.prank(bob);
        factory.deployVault(true);
        assertEq(factory.vaultCount(), 2);
    }

    function test_allVaults_records_deployments() public {
        vm.prank(alice);
        address vault1 = factory.deployVault(true);

        vm.prank(bob);
        address vault2 = factory.deployVault(false);

        assertEq(factory.allVaults(0), vault1);
        assertEq(factory.allVaults(1), vault2);
    }

    function test_ownerVaultCount_per_owner() public {
        vm.prank(alice);
        factory.deployVault(true);

        vm.prank(alice);
        factory.deployVault(false); // alice deploys a second vault

        vm.prank(bob);
        factory.deployVault(true);

        assertEq(factory.ownerVaultCount(alice), 2);
        assertEq(factory.ownerVaultCount(bob), 1);
        assertEq(factory.ownerVaultCount(attacker), 0);
    }

    function test_ownerVaults_records_correct_addresses() public {
        vm.prank(alice);
        address vault1 = factory.deployVault(true);

        vm.prank(alice);
        address vault2 = factory.deployVault(false);

        assertEq(factory.ownerVaults(alice, 0), vault1);
        assertEq(factory.ownerVaults(alice, 1), vault2);
    }

    function test_multiple_owners_independent_vaults() public {
        vm.prank(alice);
        address aliceVault = factory.deployVault(true);

        vm.prank(bob);
        address bobVault = factory.deployVault(true);

        assertNotEq(aliceVault, bobVault);
        assertEq(AxonVault(payable(aliceVault)).owner(), alice);
        assertEq(AxonVault(payable(bobVault)).owner(), bob);
    }

    // =========================================================================
    // Swap routers are managed globally via AxonRegistry
    // =========================================================================

    function test_vault_uses_registry_for_swap_routers() public {
        address uniswap = makeAddr("uniswap");

        // Approve router on registry (not per-vault)
        vm.prank(axonDeployer);
        registry.addSwapRouter(uniswap);

        vm.prank(alice);
        address vault = factory.deployVault(true);

        // Vault can query the registry via its axonRegistry reference
        assertEq(AxonVault(payable(vault)).axonRegistry(), address(registry));
    }

    // =========================================================================
    // Factory ownership (Ownable2Step)
    // =========================================================================

    function test_factory_ownership_transfer_two_step() public {
        address newAxon = makeAddr("newAxon");

        vm.prank(axonDeployer);
        factory.transferOwnership(newAxon);
        assertEq(factory.owner(), axonDeployer); // not yet

        vm.prank(newAxon);
        factory.acceptOwnership();
        assertEq(factory.owner(), newAxon);
    }
}
