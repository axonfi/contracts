// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../AxonVault.sol";
import "../AxonRegistry.sol";
import "../../test/mocks/MockERC20.sol";
import "../../test/mocks/MockSwapRouter.sol";
import "../../test/mocks/MockProtocol.sol";

/// @title AxonVault Echidna/Medusa Fuzz Harness
/// @notice Property-based invariant testing. Harness acts as owner + relayer.
///         Fuzzers call state-changing functions (deposits, payments, swaps,
///         pause, blacklist) randomly, then check all invariants hold.
contract AxonVaultEchidna {
    AxonRegistry public registry;
    AxonVault public vault;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockSwapRouter public swapRouter;
    MockProtocol public mockProtocol;

    address constant BOT = 0xa6A396C4e95ce61aa0556CC770eDf5bDE1955149; // vm.addr(0xB07)
    uint256 constant BOT_KEY = 0xB07;
    address constant RECIPIENT = address(0xBEEF);
    uint256 constant USDC_DECIMALS = 1e6;
    uint256 constant WETH_DECIMALS = 1e18;
    uint256 constant INITIAL_DEPOSIT = 100_000 * USDC_DECIMALS;

    bytes32 constant PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address bot,address to,address token,uint256 amount,uint256 deadline,bytes32 ref)");
    bytes32 constant SWAP_INTENT_TYPEHASH =
        keccak256("SwapIntent(address bot,address toToken,uint256 minToAmount,uint256 deadline,bytes32 ref)");

    uint256 public totalDeposited;
    uint256 public totalPaymentsOut;
    uint256 public totalWithdrawn;
    uint256 public paymentCount;
    uint256 public depositCount;
    uint256 public swapCount;
    uint256 public nonce;
    bool public setupDone;

    // Pre-signed payment intents (built in constructor via cheatcode)
    // Medusa can't call vm.sign, so we pre-build a pool of signed intents
    uint256 constant PRESIGNED_COUNT = 50;
    bytes32[PRESIGNED_COUNT] private _intentHashes;
    bytes[PRESIGNED_COUNT] private _intentSigs;
    uint256[PRESIGNED_COUNT] private _intentAmounts;
    uint256 public nextIntent;

    // Foundry VM
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    constructor() {
        registry = new AxonRegistry(address(this));
        registry.addRelayer(address(this));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        swapRouter = new MockSwapRouter();
        mockProtocol = new MockProtocol();
        registry.addSwapRouter(address(swapRouter));

        vault = new AxonVault(address(this), address(registry));
        usdc.mint(address(vault), INITIAL_DEPOSIT);
        totalDeposited = INITIAL_DEPOSIT;

        // Fund swap router with WETH so swaps can deliver output
        weth.mint(address(swapRouter), 1_000 * WETH_DECIMALS);

        // Add WETH to rebalance whitelist
        vault.addRebalanceTokens(_toArray(address(weth)));

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

        // Pre-sign payment intents with varying amounts
        for (uint256 i = 0; i < PRESIGNED_COUNT; i++) {
            uint256 amount = ((i + 1) * 100) * USDC_DECIMALS; // $100, $200, ..., $5000
            bytes32 ref = keccak256(abi.encodePacked("presigned", i));
            AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
                bot: BOT, to: RECIPIENT, token: address(usdc),
                amount: amount, deadline: type(uint256).max, ref: ref
            });
            bytes32 structHash = keccak256(
                abi.encode(PAYMENT_INTENT_TYPEHASH, intent.bot, intent.to, intent.token, intent.amount, intent.deadline, intent.ref)
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOT_KEY, digest);
            _intentHashes[i] = digest;
            _intentSigs[i] = abi.encodePacked(r, s, v);
            _intentAmounts[i] = amount;
        }

        setupDone = true;
    }

    function _toArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // =====================================================================
    // State changers — fuzzers call these randomly to build sequences
    // =====================================================================

    /// Deposit more USDC into the vault (mints fresh — simulates external deposits)
    function doDeposit(uint256 amount) public {
        amount = _bound(amount, 1 * USDC_DECIMALS, 10_000 * USDC_DECIMALS);
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount, keccak256(abi.encodePacked("deposit", nonce++)));
        totalDeposited += amount;
        depositCount++;
    }

    /// Execute a pre-signed payment intent
    function doPayment() public {
        if (nextIntent >= PRESIGNED_COUNT) return;
        if (vault.paused()) return;

        uint256 idx = nextIntent;
        uint256 amount = _intentAmounts[idx];
        if (amount > usdc.balanceOf(address(vault))) return;

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: BOT, to: RECIPIENT, token: address(usdc),
            amount: amount, deadline: type(uint256).max,
            ref: keccak256(abi.encodePacked("presigned", idx))
        });

        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executePayment.selector, intent, _intentSigs[idx], address(0), 0, address(0), "")
        );
        if (ok) {
            totalPaymentsOut += amount;
            paymentCount++;
            nextIntent++;
        }
    }

    /// Execute an in-vault swap: USDC → WETH via MockSwapRouter
    function doSwap(uint256 usdcAmount, uint256 wethOut) public {
        usdcAmount = _bound(usdcAmount, 1 * USDC_DECIMALS, 5_000 * USDC_DECIMALS);
        wethOut = _bound(wethOut, 1, 10 * WETH_DECIMALS);
        if (vault.paused()) return;
        if (usdcAmount > usdc.balanceOf(address(vault))) return;

        bytes32 ref = keccak256(abi.encodePacked("swap", nonce++));
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: BOT, toToken: address(weth), minToAmount: wethOut, deadline: type(uint256).max, ref: ref
        });

        // Sign the swap intent
        bytes32 structHash = keccak256(
            abi.encode(SWAP_INTENT_TYPEHASH, intent.bot, intent.toToken, intent.minToAmount, intent.deadline, intent.ref)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOT_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Build swap calldata: vault calls swapRouter.swap(usdc, usdcAmount, weth, wethOut, vault)
        bytes memory swapCalldata = abi.encodeWithSelector(
            swapRouter.swap.selector, address(usdc), usdcAmount, address(weth), wethOut, address(vault)
        );

        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.executeSwap.selector, intent, sig, address(usdc), usdcAmount, address(swapRouter), swapCalldata)
        );
        if (ok) swapCount++;
    }

    /// Owner withdraws some USDC
    function doWithdraw(uint256 amount) public {
        amount = _bound(amount, 1 * USDC_DECIMALS, 1_000 * USDC_DECIMALS);
        if (amount > usdc.balanceOf(address(vault))) return;
        vault.withdraw(address(usdc), amount, address(this));
        totalWithdrawn += amount;
    }

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

    // =====================================================================
    // INVARIANTS — must hold after every fuzz sequence
    // =====================================================================

    /// USDC accounting: vault balance + outflows + withdrawals = total deposited
    function echidna_usdc_accounting() public view returns (bool) {
        if (!setupDone) return true;
        uint256 vaultBal = usdc.balanceOf(address(vault));
        // Swaps convert USDC to WETH, reducing USDC balance without outflow
        // So: vaultBal + totalPaymentsOut + totalWithdrawn <= totalDeposited
        return vaultBal + totalPaymentsOut + totalWithdrawn <= totalDeposited;
    }

    /// Vault WETH balance must be non-negative (implicit) and consistent with swaps
    function echidna_weth_non_negative() public view returns (bool) {
        if (!setupDone) return true;
        // WETH in vault came from swaps — should never exceed what router had
        return weth.balanceOf(address(vault)) <= 1_000 * WETH_DECIMALS;
    }

    /// Payment count matches nextIntent pointer
    function echidna_payment_count_consistent() public view returns (bool) {
        if (!setupDone) return true;
        return paymentCount <= nextIntent && nextIntent <= PRESIGNED_COUNT;
    }

    /// Vault owner is always this contract
    function echidna_owner_unchanged() public view returns (bool) {
        if (!setupDone) return true;
        return vault.owner() == address(this);
    }

    /// Bot stays active
    function echidna_bot_active() public view returns (bool) {
        if (!setupDone) return true;
        return vault.isBotActive(BOT);
    }

    /// Registry relayer stays authorized
    function echidna_relayer_authorized() public view returns (bool) {
        if (!setupDone) return true;
        return registry.isAuthorized(address(this));
    }

    /// Vault version constant
    function echidna_version_constant() public view returns (bool) {
        if (!setupDone) return true;
        return vault.VERSION() == 5;
    }

    /// Deposit count tracks correctly
    function echidna_deposit_tracking() public view returns (bool) {
        if (!setupDone) return true;
        return (depositCount > 0) == (totalDeposited > INITIAL_DEPOSIT);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _bound(uint256 val, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (val % (hi - lo + 1));
    }
}

interface Vm {
    function addr(uint256 pk) external pure returns (address);
    function sign(uint256 pk, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
    function prank(address sender) external;
}
