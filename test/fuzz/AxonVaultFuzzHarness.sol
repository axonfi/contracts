// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/AxonVault.sol";
import "../../src/AxonRegistry.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockSwapRouter.sol";
import "../mocks/MockProtocol.sol";

/// @title AxonVault Medusa Fuzz Harness
/// @notice Property-based fuzz testing for AxonVault invariants.
///         Harness is both vault owner and authorized relayer.
///         Uses Medusa's `property_` prefix convention.
contract AxonVaultFuzzHarness {
    AxonRegistry public registry;
    AxonVault public vault;
    MockERC20 public usdc;
    MockSwapRouter public swapRouter;
    MockProtocol public mockProtocol;

    // Pre-computed: address for private key 0xB07
    address constant BOT = 0xa6A396C4e95ce61aa0556CC770eDf5bDE1955149;
    uint256 constant BOT_KEY = 0xB07;
    address constant RECIPIENT = address(0xBEEF);
    uint256 constant USDC_DECIMALS = 1e6;
    uint256 constant INITIAL_DEPOSIT = 100_000 * USDC_DECIMALS;

    bytes32 constant PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address bot,address to,address token,uint256 amount,uint256 deadline,bytes32 ref)");

    // Foundry VM at well-known address
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public totalPaymentsOut;
    uint256 public nonce;

    constructor() {
        // This contract = owner + relayer
        registry = new AxonRegistry(address(this));
        registry.addRelayer(address(this));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        swapRouter = new MockSwapRouter();
        mockProtocol = new MockProtocol();
        registry.addSwapRouter(address(swapRouter));

        vault = new AxonVault(address(this), address(registry));
        usdc.mint(address(vault), INITIAL_DEPOSIT);

        // Register bot with $10k per-tx cap
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({
            amount: 50_000 * USDC_DECIMALS,
            maxCount: 0,
            windowSeconds: 86400
        });

        vault.addBot(BOT, AxonVault.BotConfigParams({
            maxPerTxAmount: 10_000 * USDC_DECIMALS,
            maxRebalanceAmount: 5_000 * USDC_DECIMALS,
            spendingLimits: limits,
            aiTriggerThreshold: 1_000 * USDC_DECIMALS,
            requireAiVerification: false
        }));

        vault.addProtocol(address(mockProtocol));
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _signPayment(AxonVault.PaymentIntent memory intent) internal returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(PAYMENT_INTENT_TYPEHASH, intent.bot, intent.to, intent.token, intent.amount, intent.deadline, intent.ref)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOT_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _uniqueRef() internal returns (bytes32) {
        return keccak256(abi.encodePacked("fuzz", nonce++));
    }

    // =====================================================================
    // State changers — Medusa calls these to build interesting sequences
    // =====================================================================

    function makePayment(uint256 amount) public {
        if (amount == 0 || amount > usdc.balanceOf(address(vault))) return;
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: RECIPIENT, token: address(usdc),
            amount: amount, deadline: block.timestamp + 300, ref: _uniqueRef()
        });
        bytes memory sig = _signPayment(intent);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        if (ok) totalPaymentsOut += amount;
    }

    function doPause() public {
        if (!vault.paused()) vault.pause();
    }

    function doUnpause() public {
        if (vault.paused()) vault.unpause();
    }

    function addToBlacklist(address dest) public {
        if (dest == address(0)) return;
        if (!vault.globalDestinationBlacklist(dest)) {
            vault.addGlobalBlacklist(dest);
        }
    }

    // =====================================================================
    // PROPERTIES — all must return true for the fuzzer to pass
    // =====================================================================

    /// Balance conservation: vault balance + outflows <= initial deposit
    function property_balance_conservation() public view returns (bool) {
        return usdc.balanceOf(address(vault)) + totalPaymentsOut <= INITIAL_DEPOSIT;
    }

    /// Paused vault blocks execution
    function property_paused_blocks_execution() public returns (bool) {
        if (!vault.paused()) return true;
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: RECIPIENT, token: address(usdc),
            amount: 1 * USDC_DECIMALS, deadline: block.timestamp + 300, ref: _uniqueRef()
        });
        bytes memory sig = _signPayment(intent);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok;
    }

    /// Expired deadlines always revert
    function property_expired_deadline_reverts() public returns (bool) {
        if (block.timestamp == 0) return true;
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: RECIPIENT, token: address(usdc),
            amount: 1 * USDC_DECIMALS, deadline: block.timestamp - 1, ref: _uniqueRef()
        });
        bytes memory sig = _signPayment(intent);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok;
    }

    /// Self-payment to vault address is blocked
    function property_self_payment_blocked() public returns (bool) {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: address(vault), token: address(usdc),
            amount: 1 * USDC_DECIMALS, deadline: block.timestamp + 300, ref: _uniqueRef()
        });
        bytes memory sig = _signPayment(intent);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok;
    }

    /// Zero-amount payment is blocked
    function property_zero_amount_blocked() public returns (bool) {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: RECIPIENT, token: address(usdc),
            amount: 0, deadline: block.timestamp + 300, ref: _uniqueRef()
        });
        bytes memory sig = _signPayment(intent);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok;
    }

    /// Payment to address(0) is blocked
    function property_zero_address_blocked() public returns (bool) {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: address(0), token: address(usdc),
            amount: 1 * USDC_DECIMALS, deadline: block.timestamp + 300, ref: _uniqueRef()
        });
        bytes memory sig = _signPayment(intent);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok;
    }

    /// Duplicate intent replay is blocked
    function property_replay_protection() public returns (bool) {
        bytes32 ref = keccak256("replay-check");
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: RECIPIENT, token: address(usdc),
            amount: 1 * USDC_DECIMALS, deadline: block.timestamp + 300, ref: ref
        });
        bytes memory sig = _signPayment(intent);

        (bool ok1,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        if (!ok1) return true; // already used
        totalPaymentsOut += 1 * USDC_DECIMALS;

        // Second attempt MUST fail
        (bool ok2,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok2;
    }

    /// Only owner can withdraw
    function property_only_owner_withdraws(address caller) public returns (bool) {
        if (caller == address(this)) return true;
        vm.prank(caller);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.withdraw.selector, address(usdc), 1 * USDC_DECIMALS, caller)
        );
        return !ok;
    }

    /// Blacklisted destinations are blocked
    function property_blacklist_enforced(address dest) public returns (bool) {
        if (!vault.globalDestinationBlacklist(dest)) return true;
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: dest, token: address(usdc),
            amount: 1 * USDC_DECIMALS, deadline: block.timestamp + 300, ref: _uniqueRef()
        });
        bytes memory sig = _signPayment(intent);
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok;
    }

    /// Inactive bot payments are rejected
    function property_inactive_bot_rejected(uint256 fakeBotPk) public returns (bool) {
        if (fakeBotPk == 0 || fakeBotPk == BOT_KEY) return true;
        if (fakeBotPk >= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) return true;

        address fakeBot = vm.addr(fakeBotPk);
        if (vault.isBotActive(fakeBot)) return true;

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: fakeBot, to: RECIPIENT, token: address(usdc),
            amount: 1 * USDC_DECIMALS, deadline: block.timestamp + 300, ref: _uniqueRef()
        });

        bytes32 structHash = keccak256(
            abi.encode(PAYMENT_INTENT_TYPEHASH, intent.bot, intent.to, intent.token, intent.amount, intent.deadline, intent.ref)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakeBotPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, sig, address(0), 0, address(0), "")
        );
        return !ok;
    }
}

// Minimal Vm interface for cheatcodes
interface Vm {
    function addr(uint256 pk) external pure returns (address);
    function sign(uint256 pk, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
    function prank(address sender) external;
}
