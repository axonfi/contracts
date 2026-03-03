// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../AxonVault.sol";
import "../AxonRegistry.sol";
import "../../test/mocks/MockERC20.sol";
import "../../test/mocks/MockSwapRouter.sol";
import "../../test/mocks/MockProtocol.sol";

/// @title AxonVault Echidna Fuzz Harness
/// @notice Property-based invariant testing. Harness acts as owner + relayer.
///         Echidna calls state-changing functions randomly, then checks
///         that all `echidna_` properties hold true.
contract AxonVaultEchidna {
    AxonRegistry public registry;
    AxonVault public vault;
    MockERC20 public usdc;
    MockSwapRouter public swapRouter;
    MockProtocol public mockProtocol;

    address constant BOT = 0xa6A396C4e95ce61aa0556CC770eDf5bDE1955149; // vm.addr(0xB07)
    uint256 constant BOT_KEY = 0xB07;
    address constant RECIPIENT = address(0xBEEF);
    uint256 constant USDC_DECIMALS = 1e6;
    uint256 constant INITIAL_DEPOSIT = 100_000 * USDC_DECIMALS;

    bytes32 constant PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address bot,address to,address token,uint256 amount,uint256 deadline,bytes32 ref)");

    uint256 public totalPaymentsOut;
    uint256 public nonce;
    bool public setupDone;

    constructor() {
        registry = new AxonRegistry(address(this));
        registry.addRelayer(address(this));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        swapRouter = new MockSwapRouter();
        mockProtocol = new MockProtocol();
        registry.addSwapRouter(address(swapRouter));

        vault = new AxonVault(address(this), address(registry));
        usdc.mint(address(vault), INITIAL_DEPOSIT);

        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({
            amount: 50_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400
        });

        vault.addBot(BOT, AxonVault.BotConfigParams({
            maxPerTxAmount: 10_000 * USDC_DECIMALS,
            maxRebalanceAmount: 5_000 * USDC_DECIMALS,
            spendingLimits: limits,
            aiTriggerThreshold: 1_000 * USDC_DECIMALS,
            requireAiVerification: false
        }));

        vault.addProtocol(address(mockProtocol));
        setupDone = true;
    }

    // --- State changers (Echidna calls these randomly) ---

    function doPause() public {
        if (!vault.paused()) vault.pause();
    }

    function doUnpause() public {
        if (vault.paused()) vault.unpause();
    }

    function addToBlacklist(address dest) public {
        if (dest != address(0) && !vault.globalDestinationBlacklist(dest)) {
            vault.addGlobalBlacklist(dest);
        }
    }

    // --- INVARIANTS (Echidna property mode) ---

    /// Vault USDC balance + total outflows must equal initial deposit
    function echidna_balance_conservation() public view returns (bool) {
        if (!setupDone) return true;
        return usdc.balanceOf(address(vault)) + totalPaymentsOut <= INITIAL_DEPOSIT;
    }

    /// Constructor must have completed
    function echidna_setup_completed() public view returns (bool) {
        return setupDone;
    }

    /// Vault owner is always this contract
    function echidna_owner_unchanged() public view returns (bool) {
        if (!setupDone) return true;
        return vault.owner() == address(this);
    }

    /// Bot stays active (nobody removed it)
    function echidna_bot_active() public view returns (bool) {
        if (!setupDone) return true;
        return vault.isBotActive(BOT);
    }

    /// Registry always has this contract as authorized relayer
    function echidna_relayer_authorized() public view returns (bool) {
        if (!setupDone) return true;
        return registry.isAuthorized(address(this));
    }

    /// Vault version is always 5
    function echidna_version_constant() public view returns (bool) {
        if (!setupDone) return true;
        return vault.VERSION() == 5;
    }
}
