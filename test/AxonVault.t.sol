// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AxonVault.sol";
import "../src/AxonRegistry.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockSwapRouter.sol";
import "./mocks/MockProtocol.sol";

contract AxonVaultTest is Test {
    // =========================================================================
    // Actors
    // =========================================================================

    uint256 constant PRINCIPAL_KEY = 0xA11CE;
    uint256 constant OPERATOR_KEY = 0x0EA7;
    uint256 constant BOT_KEY = 0xB07;
    uint256 constant BOT2_KEY = 0xB072;

    address principal;
    address operator;
    address bot;
    address bot2;
    address relayer;
    address recipient;
    address attacker;

    // =========================================================================
    // Contracts
    // =========================================================================

    AxonRegistry registry;
    AxonVault vault;
    MockERC20 usdc;
    MockERC20 usdt;
    MockSwapRouter swapRouter;
    MockProtocol mockProtocol;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 constant USDC_DECIMALS = 1e6;
    uint256 constant VAULT_DEPOSIT = 100_000 * USDC_DECIMALS; // $100k
    uint256 constant DEADLINE_DELTA = 5 minutes;

    // EIP-712 type hashes — must match AxonVault exactly
    bytes32 constant PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address bot,address to,address token,uint256 amount,uint256 deadline,bytes32 ref)");
    bytes32 constant EXECUTE_INTENT_TYPEHASH = keccak256(
        "ExecuteIntent(address bot,address protocol,bytes32 calldataHash,address token,uint256 amount,uint256 deadline,bytes32 ref)"
    );
    bytes32 constant SWAP_INTENT_TYPEHASH =
        keccak256("SwapIntent(address bot,address toToken,uint256 minToAmount,uint256 deadline,bytes32 ref)");

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        principal = vm.addr(PRINCIPAL_KEY);
        operator = vm.addr(OPERATOR_KEY);
        bot = vm.addr(BOT_KEY);
        bot2 = vm.addr(BOT2_KEY);
        relayer = makeAddr("relayer");
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");

        // Deploy infrastructure
        registry = new AxonRegistry(address(this));
        registry.addRelayer(relayer);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        swapRouter = new MockSwapRouter();
        mockProtocol = new MockProtocol();

        // Approve swap router on the global registry
        registry.addSwapRouter(address(swapRouter));

        // Set oracle config — USDC address must match our mock so TWAP oracle
        // returns USDC amounts directly (no pool lookup needed for USDC tokens)
        address dummyWeth = makeAddr("weth");
        address dummyV3Factory = makeAddr("uniV3Factory");
        registry.setOracleConfig(dummyV3Factory, address(usdc), dummyWeth);

        // Deploy vault owned by principal
        vault = new AxonVault(principal, address(registry), true);

        // Fund vault
        usdc.mint(address(vault), VAULT_DEPOSIT);

        // Default operator ceilings (set by principal)
        AxonVault.OperatorCeilings memory ceilings = AxonVault.OperatorCeilings({
            maxPerTxAmount: 1_000 * USDC_DECIMALS, // $1k per tx ceiling
            maxBotDailyLimit: 5_000 * USDC_DECIMALS, // $5k/day ceiling
            maxOperatorBots: 5, // operator can add up to 5 bots
            vaultDailyAggregate: 10_000 * USDC_DECIMALS, // $10k/day total cap
            minAiTriggerFloor: 500 * USDC_DECIMALS // AI threshold can't exceed $500
        });
        vm.prank(principal);
        vault.setOperatorCeilings(ceilings);

        // Set operator
        vm.prank(principal);
        vault.setOperator(operator);

        // Add a default bot (by principal, unconstrained by operator ceilings)
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({ amount: 10_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400 });

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 0, // no per-tx cap by default; specific tests set their own
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 1_000 * USDC_DECIMALS,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(bot, params);

        // Approve mock protocol for executeProtocol tests
        vm.prank(principal);
        vault.addProtocol(address(mockProtocol));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _deadline() internal view returns (uint256) {
        return block.timestamp + DEADLINE_DELTA;
    }

    function _toArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _signPayment(uint256 privKey, AxonVault.PaymentIntent memory intent) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_INTENT_TYPEHASH, intent.bot, intent.to, intent.token, intent.amount, intent.deadline, intent.ref
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultIntent(uint256 amount) internal view returns (AxonVault.PaymentIntent memory) {
        return AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdc),
            amount: amount,
            deadline: _deadline(),
            ref: bytes32("test-ref-001")
        });
    }

    function _executePayment(AxonVault.PaymentIntent memory intent) internal {
        bytes memory sig = _signPayment(BOT_KEY, intent);
        vm.prank(relayer);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    // =========================================================================
    // Deployment
    // =========================================================================

    function test_version_is_4() public view {
        assertEq(vault.VERSION(), 4);
    }

    function test_axonRegistry_is_immutable() public view {
        assertEq(vault.axonRegistry(), address(registry));
    }

    function test_trackUsedIntents_set_at_deploy() public view {
        assertTrue(vault.trackUsedIntents());
    }

    function test_owner_is_principal() public view {
        assertEq(vault.owner(), principal);
    }

    function test_deploy_without_intent_tracking() public {
        AxonVault noTrack = new AxonVault(principal, address(registry), false);
        assertFalse(noTrack.trackUsedIntents());
    }

    function test_deploy_reverts_zero_registry() public {
        vm.expectRevert(AxonVault.ZeroAddress.selector);
        new AxonVault(principal, address(0), true);
    }

    // =========================================================================
    // Operator management
    // =========================================================================

    function test_setOperator_happy_path() public view {
        assertEq(vault.operator(), operator);
    }

    function test_setOperator_emits_event() public {
        address newOp = makeAddr("newOp");
        vm.expectEmit(true, true, false, false);
        emit AxonVault.OperatorSet(operator, newOp);

        vm.prank(principal);
        vault.setOperator(newOp);
    }

    function test_setOperator_to_zero_unsets_operator() public {
        vm.prank(principal);
        vault.setOperator(address(0));
        assertEq(vault.operator(), address(0));
    }

    function test_setOperator_reverts_if_same_as_owner() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.OperatorCannotBeOwner.selector);
        vault.setOperator(principal);
    }

    function test_setOperator_reverts_non_owner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setOperator(attacker);
    }

    function test_setOperatorCeilings_reverts_non_owner() public {
        AxonVault.OperatorCeilings memory c;
        vm.prank(attacker);
        vm.expectRevert();
        vault.setOperatorCeilings(c);
    }

    // =========================================================================
    // Bot management — owner
    // =========================================================================

    function test_addBot_by_owner_happy_path() public view {
        assertTrue(vault.isBotActive(bot));
    }

    function test_addBot_stores_config_correctly() public view {
        AxonVault.BotConfig memory config = vault.getBotConfig(bot);
        assertEq(config.maxPerTxAmount, 0); // default: no per-tx cap
        assertEq(config.aiTriggerThreshold, 1_000 * USDC_DECIMALS);
        assertFalse(config.requireAiVerification);
        assertEq(config.spendingLimits.length, 1);
        assertEq(config.spendingLimits[0].amount, 10_000 * USDC_DECIMALS);
        assertEq(config.spendingLimits[0].windowSeconds, 86400);
    }

    function test_addBot_sets_registeredAt() public view {
        AxonVault.BotConfig memory config = vault.getBotConfig(bot);
        assertGt(config.registeredAt, 0);
    }

    function test_addBot_reverts_zero_address() public {
        AxonVault.BotConfigParams memory params;
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAddress.selector);
        vault.addBot(address(0), params);
    }

    function test_addBot_reverts_already_exists() public {
        AxonVault.BotConfigParams memory params;
        vm.prank(principal);
        vm.expectRevert(AxonVault.BotAlreadyExists.selector);
        vault.addBot(bot, params);
    }

    function test_addBot_reverts_too_many_spending_limits() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](6); // MAX is 5
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 100 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        vm.expectRevert(AxonVault.TooManySpendingLimits.selector);
        vault.addBot(bot2, params);
    }

    function test_removeBot_by_owner() public {
        vm.prank(principal);
        vault.removeBot(bot);
        assertFalse(vault.isBotActive(bot));
    }

    function test_removeBot_emits_event() public {
        vm.expectEmit(true, true, false, false);
        emit AxonVault.BotRemoved(bot, principal);

        vm.prank(principal);
        vault.removeBot(bot);
    }

    function test_removeBot_reverts_not_exists() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.BotDoesNotExist.selector);
        vault.removeBot(bot2);
    }

    function test_updateBotConfig_by_owner() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({ amount: 20_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400 });

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 3_000 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 500 * USDC_DECIMALS,
            requireAiVerification: true
        });
        vm.prank(principal);
        vault.updateBotConfig(bot, params);

        AxonVault.BotConfig memory config = vault.getBotConfig(bot);
        assertEq(config.maxPerTxAmount, 3_000 * USDC_DECIMALS);
        assertTrue(config.requireAiVerification);
    }

    function test_updateBotConfig_reverts_non_existent_bot() public {
        AxonVault.BotConfigParams memory params;
        vm.prank(principal);
        vm.expectRevert(AxonVault.BotDoesNotExist.selector);
        vault.updateBotConfig(bot2, params);
    }

    function test_addBot_reverts_non_authorized() public {
        AxonVault.BotConfigParams memory params;
        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.addBot(bot2, params);
    }

    // =========================================================================
    // Bot management — operator within ceilings
    // =========================================================================

    function test_operator_addBot_within_ceilings() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({ amount: 4_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400 });

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 800 * USDC_DECIMALS, // below $1k ceiling
            maxRebalanceAmount: 0,
            spendingLimits: limits, // $4k/day, below $5k ceiling
            aiTriggerThreshold: 300 * USDC_DECIMALS, // below $500 floor
            requireAiVerification: false
        });
        vm.prank(operator);
        vault.addBot(bot2, params);

        assertTrue(vault.isBotActive(bot2));
        assertEq(vault.operatorBotCount(), 1);
    }

    function test_operator_addBot_tracked_separately() public {
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(operator);
        vault.addBot(bot2, params);

        assertTrue(vault.botAddedByOperator(bot2));
        assertEq(vault.operatorBotCount(), 1);
    }

    function test_operator_removeBot_decrements_count() public {
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(operator);
        vault.addBot(bot2, params);

        vm.prank(operator);
        vault.removeBot(bot2);

        assertEq(vault.operatorBotCount(), 0);
    }

    function test_operator_addBot_reverts_when_maxOperatorBots_zero() public {
        // Deploy fresh vault with default ceilings (maxOperatorBots = 0)
        AxonVault freshVault = new AxonVault(principal, address(registry), true);

        vm.prank(principal);
        freshVault.setOperator(operator);

        AxonVault.BotConfigParams memory params;
        vm.prank(operator);
        vm.expectRevert(AxonVault.OperatorBotLimitReached.selector);
        freshVault.addBot(bot2, params);
    }

    function test_operator_addBot_reverts_when_bot_limit_reached() public {
        // Set ceiling to 1 bot
        AxonVault.OperatorCeilings memory ceilings = AxonVault.OperatorCeilings({
            maxPerTxAmount: 1_000 * USDC_DECIMALS,
            maxBotDailyLimit: 5_000 * USDC_DECIMALS,
            maxOperatorBots: 1,
            vaultDailyAggregate: 10_000 * USDC_DECIMALS,
            minAiTriggerFloor: 500 * USDC_DECIMALS
        });
        vm.prank(principal);
        vault.setOperatorCeilings(ceilings);

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });

        vm.prank(operator);
        vault.addBot(bot2, params); // First one — ok

        address bot3 = makeAddr("bot3");
        vm.prank(operator);
        vm.expectRevert(AxonVault.OperatorBotLimitReached.selector);
        vault.addBot(bot3, params); // Second — over limit
    }

    function test_operator_addBot_reverts_maxPerTx_exceeds_ceiling() public {
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 2_000 * USDC_DECIMALS, // ceiling is $1k
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(operator);
        vm.expectRevert(AxonVault.ExceedsOperatorCeiling.selector);
        vault.addBot(bot2, params);
    }

    function test_operator_addBot_reverts_maxPerTx_zero_when_ceiling_set() public {
        // maxPerTxAmount = 0 means "no cap" — operator cannot set this when ceiling is active
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 0, // "unlimited" — not allowed when ceiling is set
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(operator);
        vm.expectRevert(AxonVault.ExceedsOperatorCeiling.selector);
        vault.addBot(bot2, params);
    }

    function test_operator_addBot_reverts_daily_limit_exceeds_ceiling() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({ amount: 6_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400 }); // $6k, ceiling is $5k

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(operator);
        vm.expectRevert(AxonVault.ExceedsOperatorCeiling.selector);
        vault.addBot(bot2, params);
    }

    function test_operator_addBot_reverts_ai_threshold_above_floor() public {
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 1_000 * USDC_DECIMALS, // above $500 floor
            requireAiVerification: false
        });
        vm.prank(operator);
        vm.expectRevert(AxonVault.ExceedsOperatorCeiling.selector);
        vault.addBot(bot2, params);
    }

    function test_operator_cannot_disable_requireAiVerification() public {
        // First set requireAiVerification = true via owner
        AxonVault.BotConfigParams memory enableParams = AxonVault.BotConfigParams({
            maxPerTxAmount: 2_000 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 500 * USDC_DECIMALS,
            requireAiVerification: true
        });
        vm.prank(principal);
        vault.updateBotConfig(bot, enableParams);

        // Now operator tries to disable it
        AxonVault.BotConfigParams memory disableParams = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 500 * USDC_DECIMALS,
            requireAiVerification: false // trying to disable
        });
        vm.prank(operator);
        vm.expectRevert(AxonVault.ExceedsOperatorCeiling.selector);
        vault.updateBotConfig(bot, disableParams);
    }

    function test_owner_can_set_bot_above_operator_ceilings() public {
        // Owner is not bound by operator ceilings
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 50_000 * USDC_DECIMALS, // far above operator ceiling of $1k
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(bot2, params); // should not revert

        AxonVault.BotConfig memory config = vault.getBotConfig(bot2);
        assertEq(config.maxPerTxAmount, 50_000 * USDC_DECIMALS);
    }

    // =========================================================================
    // Destination whitelist
    // =========================================================================

    function test_payment_allowed_to_any_destination_when_no_whitelist() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        // No whitelist set — recipient is arbitrary
        _executePayment(intent);
        assertEq(usdc.balanceOf(recipient), 100 * USDC_DECIMALS);
    }

    function test_addGlobalDestination_allows_payment() public {
        vm.prank(principal);
        vault.addGlobalDestination(recipient);

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        _executePayment(intent);
        assertEq(usdc.balanceOf(recipient), 100 * USDC_DECIMALS);
    }

    function test_addBotDestination_allows_payment() public {
        address other = makeAddr("other");
        vm.prank(principal);
        vault.addGlobalDestination(other); // only 'other' is whitelisted globally

        // recipient is not in global whitelist — add to bot-specific whitelist
        vm.prank(principal);
        vault.addBotDestination(bot, recipient);

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        _executePayment(intent);
        assertEq(usdc.balanceOf(recipient), 100 * USDC_DECIMALS);
    }

    function test_payment_reverts_destination_not_whitelisted() public {
        // Activate the whitelist by adding some other address
        vm.prank(principal);
        vault.addGlobalDestination(makeAddr("allowedDest"));

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DestinationNotWhitelisted.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_removeGlobalDestination_by_operator() public {
        vm.prank(principal);
        vault.addGlobalDestination(recipient);

        vm.prank(operator);
        vault.removeGlobalDestination(recipient);

        assertEq(vault.globalDestinationCount(), 0);
    }

    function test_operator_cannot_add_destination() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.addGlobalDestination(recipient);
    }

    // =========================================================================
    // Deposit / Withdraw
    // =========================================================================

    function test_deposit_by_principal() public {
        usdc.mint(principal, 1_000 * USDC_DECIMALS);
        vm.startPrank(principal);
        usdc.approve(address(vault), 1_000 * USDC_DECIMALS);
        vault.deposit(address(usdc), 1_000 * USDC_DECIMALS, bytes32(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), VAULT_DEPOSIT + 1_000 * USDC_DECIMALS);
    }

    function test_deposit_by_anyone() public {
        usdc.mint(attacker, 500 * USDC_DECIMALS);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 500 * USDC_DECIMALS);
        vault.deposit(address(usdc), 500 * USDC_DECIMALS, bytes32(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), VAULT_DEPOSIT + 500 * USDC_DECIMALS);
    }

    function test_deposit_emits_event() public {
        usdc.mint(principal, 1_000 * USDC_DECIMALS);
        vm.startPrank(principal);
        usdc.approve(address(vault), 1_000 * USDC_DECIMALS);

        vm.expectEmit(true, true, false, true);
        emit AxonVault.Deposited(principal, address(usdc), 1_000 * USDC_DECIMALS, bytes32(0));
        vault.deposit(address(usdc), 1_000 * USDC_DECIMALS, bytes32(0));
        vm.stopPrank();
    }

    function test_deposit_with_ref_emits_ref() public {
        bytes32 ref = bytes32("job-render-001");
        usdc.mint(attacker, 500 * USDC_DECIMALS);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 500 * USDC_DECIMALS);

        vm.expectEmit(true, true, false, true);
        emit AxonVault.Deposited(attacker, address(usdc), 500 * USDC_DECIMALS, ref);
        vault.deposit(address(usdc), 500 * USDC_DECIMALS, ref);
        vm.stopPrank();
    }

    function test_deposit_reverts_zero_amount() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAmount.selector);
        vault.deposit(address(usdc), 0, bytes32(0));
    }

    function test_deposit_eth_reverts_zero_amount() public {
        address nativeEth = vault.NATIVE_ETH();
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAmount.selector);
        vault.deposit{ value: 0 }(nativeEth, 0, bytes32(0));
    }

    function test_withdraw_by_owner() public {
        vm.prank(principal);
        vault.withdraw(address(usdc), 1_000 * USDC_DECIMALS, principal);
        assertEq(usdc.balanceOf(principal), 1_000 * USDC_DECIMALS);
    }

    function test_withdraw_reverts_non_owner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.withdraw(address(usdc), 1_000 * USDC_DECIMALS, attacker);
    }

    function test_withdraw_reverts_zero_address() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAddress.selector);
        vault.withdraw(address(usdc), 1_000 * USDC_DECIMALS, address(0));
    }

    function test_withdraw_reverts_zero_amount() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAmount.selector);
        vault.withdraw(address(usdc), 0, principal);
    }

    function test_operator_cannot_withdraw() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.withdraw(address(usdc), 1_000 * USDC_DECIMALS, operator);
    }

    function test_eth_accepted_via_receive() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool success,) = address(vault).call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(address(vault).balance, 1 ether);
    }

    // =========================================================================
    // executePayment — happy path
    // =========================================================================

    function test_executePayment_transfers_funds() public {
        uint256 amount = 500 * USDC_DECIMALS;
        AxonVault.PaymentIntent memory intent = _defaultIntent(amount);
        _executePayment(intent);

        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(vault)), VAULT_DEPOSIT - amount);
    }

    function test_executePayment_emits_event() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.expectEmit(true, true, true, true);
        emit AxonVault.PaymentExecuted(bot, recipient, address(usdc), 100 * USDC_DECIMALS, bytes32("test-ref-001"));

        vm.prank(relayer);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_marks_intent_as_used() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_INTENT_TYPEHASH, intent.bot, intent.to, intent.token, intent.amount, intent.deadline, intent.ref
            )
        );
        bytes32 intentHash = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));

        vm.prank(relayer);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");

        assertTrue(vault.usedIntents(intentHash));
    }

    // =========================================================================
    // executePayment — security
    // =========================================================================

    function test_executePayment_reverts_non_relayer() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorizedRelayer.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_reverts_expired_deadline() public {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdc),
            amount: 100 * USDC_DECIMALS,
            deadline: block.timestamp - 1, // already expired
            ref: bytes32("ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DeadlineExpired.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_reverts_inactive_bot() public {
        vm.prank(principal);
        vault.removeBot(bot);

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.BotNotActive.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_reverts_invalid_signature() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        // Sign with wrong key (attacker key instead of bot key)
        uint256 attackerKey = 0xDEAD;
        bytes memory sig = _signPayment(attackerKey, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.InvalidSignature.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_reverts_tampered_amount() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        // Tamper with amount after signing
        intent.amount = 50_000 * USDC_DECIMALS;

        vm.prank(relayer);
        vm.expectRevert(AxonVault.InvalidSignature.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_reverts_maxPerTxAmount_exceeded() public {
        // Set bot's maxPerTxAmount to $2k, then try to send $3k
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        vm.prank(principal);
        vault.updateBotConfig(
            bot,
            AxonVault.BotConfigParams({
                maxPerTxAmount: 2_000 * USDC_DECIMALS,
                maxRebalanceAmount: 0,
                spendingLimits: limits,
                aiTriggerThreshold: 0,
                requireAiVerification: false
            })
        );

        AxonVault.PaymentIntent memory intent = _defaultIntent(3_000 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.MaxPerTxExceeded.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_reverts_replay() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");

        // Second submission — same intent hash
        vm.prank(relayer);
        vm.expectRevert(AxonVault.IntentAlreadyUsed.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_no_replay_check_when_tracking_disabled() public {
        // Deploy vault without intent tracking
        AxonVault noTrackVault = new AxonVault(principal, address(registry), false);
        usdc.mint(address(noTrackVault), VAULT_DEPOSIT);

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 0,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        noTrackVault.addBot(bot, params);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdc),
            amount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });

        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_INTENT_TYPEHASH, intent.bot, intent.to, intent.token, intent.amount, intent.deadline, intent.ref
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", noTrackVault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOT_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        noTrackVault.executePayment(intent, sig, address(0), 0, address(0), "");

        // Same intent again — should NOT revert (tracking disabled)
        vm.prank(relayer);
        noTrackVault.executePayment(intent, sig, address(0), 0, address(0), "");

        assertEq(usdc.balanceOf(recipient), 200 * USDC_DECIMALS);
    }

    function test_executePayment_reverts_when_paused() public {
        vm.prank(principal);
        vault.pause();

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert();
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    // =========================================================================
    // Pause / Unpause
    // =========================================================================

    function test_owner_can_pause_and_unpause() public {
        vm.prank(principal);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(principal);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_operator_can_pause() public {
        vm.prank(operator);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_operator_cannot_unpause() public {
        vm.prank(principal);
        vault.pause();

        vm.prank(operator);
        vm.expectRevert();
        vault.unpause();
    }

    function test_attacker_cannot_pause() public {
        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.pause();
    }

    // =========================================================================
    // executePayment — swap path (Approach B)
    // =========================================================================

    function test_executePayment_swap_happy_path() public {
        // Pre-fund the swap router with USDT to give to recipient
        uint256 usdtOut = 495 * USDC_DECIMALS; // ~$495 after slippage
        usdt.mint(address(swapRouter), usdtOut);

        // Bot signs a standard PaymentIntent: "deliver usdtOut USDT to recipient"
        // Bot never needs to know the vault holds USDC — the relayer handles the swap transparently
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdt), // desired output token
            amount: usdtOut, // minimum the recipient must receive
            deadline: _deadline(),
            ref: bytes32("swap-ref-001")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 500 * USDC_DECIMALS, address(usdt), usdtOut, recipient)
        );

        vm.prank(relayer);
        vault.executePayment(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);

        assertEq(usdt.balanceOf(recipient), usdtOut);
    }

    function test_executePayment_swap_skipped_when_vault_has_enough() public {
        // Fund vault with USDT directly — no swap needed
        uint256 amount = 200 * USDC_DECIMALS;
        usdt.mint(address(vault), amount);

        // Even though relayer provides swap params, contract should skip the swap
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdt),
            amount: amount,
            deadline: _deadline(),
            ref: bytes32("direct-usdt")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        // Provide swap params as fallback — should be ignored since vault has enough
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 250 * USDC_DECIMALS, address(usdt), amount, recipient)
        );

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        vm.prank(relayer);
        vault.executePayment(intent, sig, address(usdc), 250 * USDC_DECIMALS, address(swapRouter), swapCalldata);

        // Recipient got USDT via direct transfer, vault's USDC untouched
        assertEq(usdt.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore);
    }

    function test_executePayment_reverts_insufficient_balance_no_swap_params() public {
        // Vault has no USDT and no swap params provided
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdt),
            amount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("no-balance")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.InsufficientBalance.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_executePayment_swap_reverts_unapproved_router() public {
        address fakeRouter = makeAddr("fakeRouter");
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdt),
            amount: 99 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.RouterNotApproved.selector);
        vault.executePayment(intent, sig, address(usdc), 100 * USDC_DECIMALS, fakeRouter, "");
    }

    function test_executePayment_swap_reverts_insufficient_output() public {
        usdt.mint(address(swapRouter), 1_000 * USDC_DECIMALS);

        // Bot wants 490 USDT minimum — swapShort delivers only half (~245 USDT) → should revert
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdt),
            amount: 490 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        // Use swapShort which delivers only half
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swapShort,
            (address(usdc), 500 * USDC_DECIMALS, address(usdt), 500 * USDC_DECIMALS, recipient)
        );

        vm.prank(relayer);
        vm.expectRevert(AxonVault.SwapOutputInsufficient.selector);
        vault.executePayment(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
    }

    // =========================================================================
    // View — operatorMaxDrainPerDay
    // =========================================================================

    function test_operatorMaxDrainPerDay_bounded_by_aggregate() public view {
        // maxOperatorBots=5, maxBotDailyLimit=$5k => theoretical $25k
        // vaultDailyAggregate=$10k => capped at $10k
        uint256 drain = vault.operatorMaxDrainPerDay();
        assertEq(drain, 10_000 * USDC_DECIMALS);
    }

    function test_operatorMaxDrainPerDay_zero_when_no_bots_allowed() public {
        AxonVault freshVault = new AxonVault(principal, address(registry), true);
        // Default ceilings: maxOperatorBots = 0
        assertEq(freshVault.operatorMaxDrainPerDay(), 0);
    }

    function test_operatorMaxDrainPerDay_theoretical_when_no_aggregate() public {
        AxonVault.OperatorCeilings memory c = AxonVault.OperatorCeilings({
            maxPerTxAmount: 1_000 * USDC_DECIMALS,
            maxBotDailyLimit: 5_000 * USDC_DECIMALS,
            maxOperatorBots: 3,
            vaultDailyAggregate: 0, // no aggregate cap
            minAiTriggerFloor: 500 * USDC_DECIMALS
        });
        vm.prank(principal);
        vault.setOperatorCeilings(c);

        // 3 bots × $5k = $15k theoretical, no aggregate cap
        assertEq(vault.operatorMaxDrainPerDay(), 15_000 * USDC_DECIMALS);
    }

    // =========================================================================
    // Ownership (Ownable2Step)
    // =========================================================================

    function test_ownership_transfer_two_step() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(principal);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), principal); // not transferred yet

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }

    // =========================================================================
    // SpendingLimit.maxCount
    // =========================================================================

    function test_BotConfig_WithCountLimits() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](2);
        limits[0] = AxonVault.SpendingLimit({ amount: 5_000 * USDC_DECIMALS, maxCount: 10, windowSeconds: 86400 });
        limits[1] = AxonVault.SpendingLimit({ amount: 20_000 * USDC_DECIMALS, maxCount: 50, windowSeconds: 604800 });

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 1_000 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 500 * USDC_DECIMALS,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(bot2, params);

        AxonVault.BotConfig memory config = vault.getBotConfig(bot2);
        assertEq(config.spendingLimits.length, 2);
        assertEq(config.spendingLimits[0].maxCount, 10);
        assertEq(config.spendingLimits[0].amount, 5_000 * USDC_DECIMALS);
        assertEq(config.spendingLimits[0].windowSeconds, 86400);
        assertEq(config.spendingLimits[1].maxCount, 50);
        assertEq(config.spendingLimits[1].windowSeconds, 604800);
    }

    function test_BotConfig_CountLimitZeroMeansNoLimit() public view {
        // Default bot was added with maxCount: 0
        AxonVault.BotConfig memory config = vault.getBotConfig(bot);
        assertEq(config.spendingLimits[0].maxCount, 0);
    }

    function test_updateBotConfig_preserves_maxCount() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({ amount: 8_000 * USDC_DECIMALS, maxCount: 25, windowSeconds: 86400 });

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 2_000 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 1_000 * USDC_DECIMALS,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.updateBotConfig(bot, params);

        AxonVault.BotConfig memory config = vault.getBotConfig(bot);
        assertEq(config.spendingLimits[0].maxCount, 25);
    }

    // =========================================================================
    // Global destination blacklist
    // =========================================================================

    function test_GlobalBlacklist_BlocksPayment() public {
        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DestinationBlacklisted.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_BlacklistTakesPriorityOverWhitelist() public {
        // Add recipient to both whitelist and blacklist
        vm.prank(principal);
        vault.addGlobalDestination(recipient);

        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        // Blacklist should win
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DestinationBlacklisted.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_OnlyOwnerCanRemoveBlacklist() public {
        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        // Operator cannot remove (loosening)
        vm.prank(operator);
        vm.expectRevert();
        vault.removeGlobalBlacklist(recipient);

        // Owner can remove
        vm.prank(principal);
        vault.removeGlobalBlacklist(recipient);
        assertEq(vault.globalBlacklistCount(), 0);

        // Payment now succeeds
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        _executePayment(intent);
        assertEq(usdc.balanceOf(recipient), 100 * USDC_DECIMALS);
    }

    function test_OperatorCanAddBlacklist() public {
        vm.prank(operator);
        vault.addGlobalBlacklist(recipient);

        assertTrue(vault.globalDestinationBlacklist(recipient));
        assertEq(vault.globalBlacklistCount(), 1);
    }

    function test_BlacklistBlocksSwapPayment() public {
        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        uint256 usdtOut = 495 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), usdtOut);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdt),
            amount: usdtOut,
            deadline: _deadline(),
            ref: bytes32("swap-ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 500 * USDC_DECIMALS, address(usdt), usdtOut, recipient)
        );

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DestinationBlacklisted.selector);
        vault.executePayment(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
    }

    function test_addGlobalBlacklist_reverts_zero_address() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAddress.selector);
        vault.addGlobalBlacklist(address(0));
    }

    function test_addGlobalBlacklist_idempotent() public {
        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        vm.prank(principal);
        vault.addGlobalBlacklist(recipient); // second add — no-op

        assertEq(vault.globalBlacklistCount(), 1);
    }

    function test_attacker_cannot_add_blacklist() public {
        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.addGlobalBlacklist(recipient);
    }

    // =========================================================================
    // Native ETH support
    // =========================================================================

    address constant NATIVE_ETH_ADDR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function test_ReceiveETH() public {
        vm.deal(principal, 10 ether);
        vm.prank(principal);
        (bool success,) = address(vault).call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_DepositETH() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);

        vm.prank(depositor);
        vault.deposit{ value: 2 ether }(NATIVE_ETH_ADDR, 2 ether, bytes32(0));

        assertEq(address(vault).balance, 2 ether);
    }

    function test_DepositETH_AmountMismatch() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);

        vm.startPrank(depositor);
        vm.expectRevert(AxonVault.AmountMismatch.selector);
        vault.deposit{ value: 1 ether }(NATIVE_ETH_ADDR, 2 ether, bytes32(0));
        vm.stopPrank();
    }

    function test_DepositERC20_RejectsETH() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);
        usdc.mint(depositor, 1000 * USDC_DECIMALS);

        vm.startPrank(depositor);
        vm.expectRevert(AxonVault.UnexpectedETH.selector);
        vault.deposit{ value: 1 ether }(address(usdc), 1000 * USDC_DECIMALS, bytes32(0));
        vm.stopPrank();
    }

    function test_WithdrawETH() public {
        vm.deal(address(vault), 5 ether);
        address withdrawTo = makeAddr("withdrawTo");

        vm.prank(principal);
        vault.withdraw(NATIVE_ETH_ADDR, 2 ether, withdrawTo);

        assertEq(withdrawTo.balance, 2 ether);
        assertEq(address(vault).balance, 3 ether);
    }

    function _ethBot() internal returns (address ethBot) {
        // Register a bot with a high maxPerTxAmount suitable for ETH amounts
        uint256 ethBotKey = 0xE7B07;
        ethBot = vm.addr(ethBotKey);

        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 0, // no cap
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(ethBot, params);
    }

    function test_ExecutePaymentETH() public {
        uint256 ethBotKey = 0xE7B07;
        address ethBot = _ethBot();

        vm.deal(address(vault), 10 ether);
        uint256 recipientBefore = recipient.balance;

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: ethBot,
            to: recipient,
            token: NATIVE_ETH_ADDR,
            amount: 1 ether,
            deadline: _deadline(),
            ref: bytes32("eth-payment-001")
        });
        bytes memory sig = _signPayment(ethBotKey, intent);

        vm.prank(relayer);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");

        assertEq(recipient.balance - recipientBefore, 1 ether);
        assertEq(address(vault).balance, 9 ether);
    }

    function test_ExecutePaymentETH_InsufficientBalance() public {
        uint256 ethBotKey = 0xE7B07;
        address ethBot = _ethBot();

        assertEq(address(vault).balance, 0);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: ethBot,
            to: recipient,
            token: NATIVE_ETH_ADDR,
            amount: 1 ether,
            deadline: _deadline(),
            ref: bytes32("eth-payment-fail")
        });
        bytes memory sig = _signPayment(ethBotKey, intent);

        // Approach B: contract checks balance on-chain, reverts with InsufficientBalance
        // (no swap params provided, vault has 0 ETH)
        vm.prank(relayer);
        vm.expectRevert(AxonVault.InsufficientBalance.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_DepositETH_emits_event() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);
        bytes32 ref = bytes32("eth-deposit-ref");

        vm.startPrank(depositor);
        vm.expectEmit(true, true, false, true);
        emit AxonVault.Deposited(depositor, NATIVE_ETH_ADDR, 1 ether, ref);
        vault.deposit{ value: 1 ether }(NATIVE_ETH_ADDR, 1 ether, ref);
        vm.stopPrank();
    }

    // =========================================================================
    // Self-payment and zero-address rejection
    // =========================================================================

    function test_ExecutePayment_RevertsSelfPayment() public {
        usdc.mint(address(vault), 1000 * USDC_DECIMALS);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: address(vault), // paying itself
            token: address(usdc),
            amount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("self-pay")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.SelfPayment.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_ExecutePayment_RevertsZeroAddress() public {
        usdc.mint(address(vault), 1000 * USDC_DECIMALS);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: address(0),
            token: address(usdc),
            amount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("zero-addr")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.PaymentToZeroAddress.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_ExecutePayment_RevertsZeroAmount() public {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot, to: recipient, token: address(usdc), amount: 0, deadline: _deadline(), ref: bytes32("zero-amount")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.ZeroAmount.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    function test_ExecutePaymentETH_RevertsSelfPayment() public {
        uint256 ethBotKey = 0xE7B07;
        address ethBot = _ethBot();
        vm.deal(address(vault), 10 ether);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: ethBot,
            to: address(vault),
            token: NATIVE_ETH_ADDR,
            amount: 1 ether,
            deadline: _deadline(),
            ref: bytes32("self-pay-eth")
        });
        bytes memory sig = _signPayment(ethBotKey, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.SelfPayment.selector);
        vault.executePayment(intent, sig, address(0), 0, address(0), "");
    }

    // =========================================================================
    // executeProtocol helpers
    // =========================================================================

    function _signExecute(uint256 privKey, AxonVault.ExecuteIntent memory intent) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_INTENT_TYPEHASH,
                intent.bot,
                intent.protocol,
                intent.calldataHash,
                intent.token,
                intent.amount,
                intent.deadline,
                intent.ref
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSwap(uint256 privKey, AxonVault.SwapIntent memory intent) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_INTENT_TYPEHASH, intent.bot, intent.toToken, intent.minToAmount, intent.deadline, intent.ref
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // Protocol whitelist management
    // =========================================================================

    function test_addProtocol_happy_path() public view {
        assertTrue(vault.isProtocolApproved(address(mockProtocol)));
        assertEq(vault.approvedProtocolCount(), 1);
    }

    function test_addProtocol_emits_event() public {
        address newProtocol = makeAddr("newProtocol");
        vm.expectEmit(true, false, false, false);
        emit AxonVault.ProtocolAdded(newProtocol);

        vm.prank(principal);
        vault.addProtocol(newProtocol);
    }

    function test_addProtocol_reverts_zero_address() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAddress.selector);
        vault.addProtocol(address(0));
    }

    function test_addProtocol_reverts_already_approved() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.AlreadyApprovedProtocol.selector);
        vault.addProtocol(address(mockProtocol));
    }

    function test_addProtocol_reverts_non_owner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        vault.addProtocol(makeAddr("someProtocol"));
    }

    function test_removeProtocol_by_owner() public {
        vm.prank(principal);
        vault.removeProtocol(address(mockProtocol));
        assertFalse(vault.isProtocolApproved(address(mockProtocol)));
        assertEq(vault.approvedProtocolCount(), 0);
    }

    function test_removeProtocol_by_operator() public {
        vm.prank(operator);
        vault.removeProtocol(address(mockProtocol));
        assertFalse(vault.isProtocolApproved(address(mockProtocol)));
    }

    function test_removeProtocol_emits_event() public {
        vm.expectEmit(true, false, false, false);
        emit AxonVault.ProtocolRemoved(address(mockProtocol));

        vm.prank(principal);
        vault.removeProtocol(address(mockProtocol));
    }

    function test_removeProtocol_reverts_not_in_list() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.ProtocolNotInList.selector);
        vault.removeProtocol(makeAddr("notApproved"));
    }

    function test_removeProtocol_reverts_attacker() public {
        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.removeProtocol(address(mockProtocol));
    }

    // =========================================================================
    // executeProtocol — happy path
    // =========================================================================

    function test_executeProtocol_openTrade_happy_path() public {
        uint256 collateral = 500 * USDC_DECIMALS;
        bytes memory callData = abi.encodeCall(MockProtocol.openTrade, (address(usdc), collateral, 1, true, 50));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(usdc),
            amount: collateral,
            deadline: _deadline(),
            ref: bytes32("open-trade-001")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(relayer);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");

        // Vault should have spent collateral
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - collateral);
        // Protocol should have received collateral
        assertEq(usdc.balanceOf(address(mockProtocol)), collateral);
        // Approval should be revoked (cleaned up)
        assertEq(usdc.allowance(address(vault), address(mockProtocol)), 0);
    }

    function test_executeProtocol_emits_event() public {
        uint256 collateral = 100 * USDC_DECIMALS;
        bytes memory callData = abi.encodeCall(MockProtocol.openTrade, (address(usdc), collateral, 0, true, 10));
        bytes32 ref = bytes32("emit-test");

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(usdc),
            amount: collateral,
            deadline: _deadline(),
            ref: ref
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.expectEmit(true, true, false, true);
        emit AxonVault.ProtocolExecuted(bot, address(mockProtocol), address(usdc), collateral, ref);

        vm.prank(relayer);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_zero_amount_action() public {
        // closeTrade — no token approval needed
        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (42));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("close-trade-42")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_returns_data() public {
        uint256 collateral = 100 * USDC_DECIMALS;
        bytes memory callData = abi.encodeCall(MockProtocol.openTrade, (address(usdc), collateral, 0, true, 10));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(usdc),
            amount: collateral,
            deadline: _deadline(),
            ref: bytes32("return-data-test")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        bytes memory returnData = vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");

        // openTrade returns orderId (should be 1 since it's the first call)
        uint256 orderId = abi.decode(returnData, (uint256));
        assertEq(orderId, 1);
    }

    // =========================================================================
    // executeProtocol — auth & validation
    // =========================================================================

    function test_executeProtocol_reverts_non_relayer() public {
        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (1));
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorizedRelayer.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_expired_deadline() public {
        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (1));
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: block.timestamp - 1,
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DeadlineExpired.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_bot_not_active() public {
        vm.prank(principal);
        vault.removeBot(bot);

        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (1));
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.BotNotActive.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_protocol_not_approved() public {
        address badProtocol = makeAddr("badProtocol");
        bytes memory callData = hex"deadbeef";
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: badProtocol,
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.ProtocolNotApproved.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_calldata_hash_mismatch() public {
        bytes memory signedCallData = abi.encodeCall(MockProtocol.closeTrade, (1));
        bytes memory differentCallData = abi.encodeCall(MockProtocol.closeTrade, (999));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(signedCallData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.CalldataHashMismatch.selector);
        vault.executeProtocol(intent, sig, differentCallData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_invalid_signature() public {
        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (1));
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(OPERATOR_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.InvalidSignature.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_replay() public {
        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (1));
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");

        vm.prank(relayer);
        vm.expectRevert(AxonVault.IntentAlreadyUsed.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_maxPerTx_exceeded() public {
        // Set bot's maxPerTxAmount to $2k
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        vm.prank(principal);
        vault.updateBotConfig(
            bot,
            AxonVault.BotConfigParams({
                maxPerTxAmount: 2_000 * USDC_DECIMALS,
                maxRebalanceAmount: 0,
                spendingLimits: limits,
                aiTriggerThreshold: 0,
                requireAiVerification: false
            })
        );

        uint256 tooMuch = 3_000 * USDC_DECIMALS;
        bytes memory callData = abi.encodeCall(MockProtocol.openTrade, (address(usdc), tooMuch, 0, true, 10));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(usdc),
            amount: tooMuch,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.MaxPerTxExceeded.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_when_paused() public {
        vm.prank(principal);
        vault.pause();

        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (1));
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_reverts_protocol_call_failed() public {
        bytes memory callData = abi.encodeCall(MockProtocol.failingAction, ());

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.ProtocolCallFailed.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    function test_executeProtocol_maxPerTx_zero_means_no_cap() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 0,
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(bot2, params);

        uint256 bigAmount = 50_000 * USDC_DECIMALS;
        bytes memory callData = abi.encodeCall(MockProtocol.openTrade, (address(usdc), bigAmount, 0, true, 10));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot2,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(usdc),
            amount: bigAmount,
            deadline: _deadline(),
            ref: bytes32("big-trade")
        });
        bytes memory sig = _signExecute(BOT2_KEY, intent);

        vm.prank(relayer);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");

        assertEq(usdc.balanceOf(address(mockProtocol)), bigAmount);
    }

    function test_executeProtocol_removed_protocol_blocks_execution() public {
        vm.prank(principal);
        vault.removeProtocol(address(mockProtocol));

        bytes memory callData = abi.encodeCall(MockProtocol.closeTrade, (1));
        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(0),
            amount: 0,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.ProtocolNotApproved.selector);
        vault.executeProtocol(intent, sig, callData, address(0), 0, address(0), "");
    }

    // =========================================================================
    // executeProtocol — with pre-swap (Approach B)
    // =========================================================================

    function test_executeProtocol_with_preswap() public {
        // Vault holds USDC but protocol needs USDT
        uint256 collateral = 500 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), collateral); // fund router with USDT output

        bytes memory callData = abi.encodeCall(MockProtocol.openTrade, (address(usdt), collateral, 1, true, 50));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(usdt),
            amount: collateral,
            deadline: _deadline(),
            ref: bytes32("preswap-trade")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        // Swap USDC→USDT, output goes to vault (not recipient), then vault approves protocol
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 510 * USDC_DECIMALS, address(usdt), collateral, address(vault))
        );

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(relayer);
        vault.executeProtocol(
            intent, sig, callData, address(usdc), 510 * USDC_DECIMALS, address(swapRouter), swapCalldata
        );

        // Protocol received USDT
        assertEq(usdt.balanceOf(address(mockProtocol)), collateral);
        // Vault spent USDC on the swap
        assertLt(usdc.balanceOf(address(vault)), vaultUsdcBefore);
        // Approval cleaned up
        assertEq(usdt.allowance(address(vault), address(mockProtocol)), 0);
    }

    function test_executeProtocol_preswap_skipped_when_vault_has_enough() public {
        // Fund vault with USDT directly — no swap needed
        uint256 collateral = 200 * USDC_DECIMALS;
        usdt.mint(address(vault), collateral);

        bytes memory callData = abi.encodeCall(MockProtocol.openTrade, (address(usdt), collateral, 0, true, 10));

        AxonVault.ExecuteIntent memory intent = AxonVault.ExecuteIntent({
            bot: bot,
            protocol: address(mockProtocol),
            calldataHash: keccak256(callData),
            token: address(usdt),
            amount: collateral,
            deadline: _deadline(),
            ref: bytes32("no-swap-needed")
        });
        bytes memory sig = _signExecute(BOT_KEY, intent);

        // Provide swap params as fallback — should be skipped
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 250 * USDC_DECIMALS, address(usdt), collateral, address(vault))
        );

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(relayer);
        vault.executeProtocol(
            intent, sig, callData, address(usdc), 250 * USDC_DECIMALS, address(swapRouter), swapCalldata
        );

        // Protocol got USDT, vault USDC untouched (swap was skipped)
        assertEq(usdt.balanceOf(address(mockProtocol)), collateral);
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore);
    }

    // =========================================================================
    // executeSwap — standalone in-vault rebalancing
    // =========================================================================

    function test_executeSwap_happy_path() public {
        uint256 minOutput = 490 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), minOutput); // fund router with USDT

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: minOutput,
            deadline: _deadline(),
            ref: bytes32("rebalance-001")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        // Swap USDC→USDT, output stays in vault
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 500 * USDC_DECIMALS, address(usdt), minOutput, address(vault))
        );

        vm.prank(relayer);
        vault.executeSwap(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);

        // Vault received USDT
        assertEq(usdt.balanceOf(address(vault)), minOutput);
    }

    function test_executeSwap_emits_event() public {
        uint256 minOutput = 490 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), minOutput);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot, toToken: address(usdt), minToAmount: minOutput, deadline: _deadline(), ref: bytes32("swap-event")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 500 * USDC_DECIMALS, address(usdt), minOutput, address(vault))
        );

        vm.expectEmit(true, false, false, true);
        emit AxonVault.SwapExecuted(
            bot, address(usdc), address(usdt), 500 * USDC_DECIMALS, minOutput, bytes32("swap-event")
        );

        vm.prank(relayer);
        vault.executeSwap(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
    }

    function test_executeSwap_reverts_zero_amount() public {
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot, toToken: address(usdt), minToAmount: 0, deadline: _deadline(), ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.ZeroAmount.selector);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executeSwap_reverts_expired_deadline() public {
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS,
            deadline: block.timestamp - 1,
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DeadlineExpired.selector);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executeSwap_reverts_unapproved_router() public {
        address fakeRouter = makeAddr("fakeRouter");
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.RouterNotApproved.selector);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, fakeRouter, "");
    }

    function test_executeSwap_reverts_non_relayer() public {
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorizedRelayer.selector);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executeSwap_reverts_inactive_bot() public {
        vm.prank(principal);
        vault.removeBot(bot);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.BotNotActive.selector);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executeSwap_reverts_invalid_signature() public {
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(OPERATOR_KEY, intent); // wrong key

        vm.prank(relayer);
        vm.expectRevert(AxonVault.InvalidSignature.selector);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executeSwap_reverts_replay() public {
        uint256 minOutput = 90 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), minOutput * 2);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot, toToken: address(usdt), minToAmount: minOutput, deadline: _deadline(), ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 100 * USDC_DECIMALS, address(usdt), minOutput, address(vault))
        );

        vm.prank(relayer);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), swapCalldata);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.IntentAlreadyUsed.selector);
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), swapCalldata);
    }

    function test_executeSwap_reverts_maxRebalanceAmount_exceeded() public {
        // Set bot's maxRebalanceAmount to $2k (separate from payment maxPerTxAmount)
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        vm.prank(principal);
        vault.updateBotConfig(
            bot,
            AxonVault.BotConfigParams({
                maxPerTxAmount: 0,
                maxRebalanceAmount: 2_000 * USDC_DECIMALS,
                spendingLimits: limits,
                aiTriggerThreshold: 0,
                requireAiVerification: false
            })
        );

        // Check is on INPUT (fromToken/maxFromAmount), not the gameable output
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        // fromToken=USDC, maxFromAmount=$3100 exceeds $2k maxRebalanceAmount
        vm.prank(relayer);
        vm.expectRevert(AxonVault.MaxRebalanceAmountExceeded.selector);
        vault.executeSwap(intent, sig, address(usdc), 3_100 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executeSwap_reverts_insufficient_output() public {
        usdt.mint(address(swapRouter), 1_000 * USDC_DECIMALS);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 490 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);
        // swapShort delivers only half
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swapShort,
            (address(usdc), 500 * USDC_DECIMALS, address(usdt), 500 * USDC_DECIMALS, address(vault))
        );

        vm.prank(relayer);
        vm.expectRevert(AxonVault.SwapOutputInsufficient.selector);
        vault.executeSwap(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
    }

    function test_executeSwap_reverts_when_paused() public {
        vm.prank(principal);
        vault.pause();

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("ref")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.executeSwap(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), "");
    }

    // =========================================================================
    // Rebalance token whitelist + maxRebalanceAmount
    // =========================================================================

    function test_executeSwap_rebalanceToken_whitelist_blocks_unlisted() public {
        // Owner adds only USDC to the rebalance whitelist
        vm.prank(principal);
        vault.addRebalanceTokens(_toArray(address(usdc)));
        assertEq(vault.rebalanceTokenCount(), 1);

        // Try to swap to USDT (not on whitelist) — should revert
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt), // NOT on whitelist
            minToAmount: 100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref: bytes32("blocked-swap")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.RebalanceTokenNotAllowed.selector);
        vault.executeSwap(intent, sig, address(usdc), 110 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executeSwap_rebalanceToken_whitelist_allows_listed() public {
        // Owner adds USDT to the rebalance whitelist
        vm.prank(principal);
        vault.addRebalanceTokens(_toArray(address(usdt)));

        uint256 minOutput = 490 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), minOutput);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt), // on whitelist
            minToAmount: minOutput,
            deadline: _deadline(),
            ref: bytes32("allowed-swap")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 500 * USDC_DECIMALS, address(usdt), minOutput, address(vault))
        );

        vm.prank(relayer);
        vault.executeSwap(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
        assertEq(usdt.balanceOf(address(vault)), minOutput);
    }

    function test_executeSwap_rebalanceToken_empty_allows_any() public {
        // No tokens on whitelist — any token should be allowed (permissive default)
        assertEq(vault.rebalanceTokenCount(), 0);

        uint256 minOutput = 490 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), minOutput);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot, toToken: address(usdt), minToAmount: minOutput, deadline: _deadline(), ref: bytes32("any-allowed")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 500 * USDC_DECIMALS, address(usdt), minOutput, address(vault))
        );

        vm.prank(relayer);
        vault.executeSwap(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
        assertEq(usdt.balanceOf(address(vault)), minOutput);
    }

    function test_rebalanceToken_owner_can_add() public {
        vm.prank(principal);
        vault.addRebalanceTokens(_toArray(address(usdt)));
        assertTrue(vault.rebalanceTokenWhitelist(address(usdt)));
        assertEq(vault.rebalanceTokenCount(), 1);
    }

    function test_rebalanceToken_operator_can_remove() public {
        vm.prank(principal);
        vault.addRebalanceTokens(_toArray(address(usdt)));
        assertEq(vault.rebalanceTokenCount(), 1);

        vm.prank(operator);
        vault.removeRebalanceTokens(_toArray(address(usdt)));
        assertFalse(vault.rebalanceTokenWhitelist(address(usdt)));
        assertEq(vault.rebalanceTokenCount(), 0);
    }

    function test_rebalanceToken_attacker_cannot_add() public {
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        vault.addRebalanceTokens(_toArray(address(usdt)));
    }

    function test_rebalanceToken_operator_cannot_add() public {
        vm.prank(operator);
        vm.expectRevert(); // OwnableUnauthorizedAccount — only owner can add (loosening)
        vault.addRebalanceTokens(_toArray(address(usdt)));
    }

    function test_rebalanceToken_add_zero_reverts() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAddress.selector);
        vault.addRebalanceTokens(_toArray(address(0)));
    }

    function test_rebalanceToken_add_idempotent() public {
        vm.prank(principal);
        vault.addRebalanceTokens(_toArray(address(usdt)));
        vm.prank(principal);
        vault.addRebalanceTokens(_toArray(address(usdt))); // no-op
        assertEq(vault.rebalanceTokenCount(), 1); // count not double-incremented
    }

    function test_rebalanceToken_remove_idempotent() public {
        // Remove a token that was never added — no-op
        vm.prank(principal);
        vault.removeRebalanceTokens(_toArray(address(usdt)));
        assertEq(vault.rebalanceTokenCount(), 0);
    }

    function test_executeSwap_maxRebalanceAmount_zero_means_no_cap() public {
        // maxRebalanceAmount = 0 means no cap on rebalancing
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        vm.prank(principal);
        vault.updateBotConfig(
            bot,
            AxonVault.BotConfigParams({
                maxPerTxAmount: 100 * USDC_DECIMALS, // tight payment cap
                maxRebalanceAmount: 0, // no rebalance cap
                spendingLimits: limits,
                aiTriggerThreshold: 0,
                requireAiVerification: false
            })
        );

        // Large rebalance should succeed even though maxPerTxAmount is $100
        uint256 minOutput = 9_000 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), minOutput);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: minOutput,
            deadline: _deadline(),
            ref: bytes32("large-rebalance")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 10_000 * USDC_DECIMALS, address(usdt), minOutput, address(vault))
        );

        vm.prank(relayer);
        vault.executeSwap(intent, sig, address(usdc), 10_000 * USDC_DECIMALS, address(swapRouter), swapCalldata);
        assertEq(usdt.balanceOf(address(vault)), minOutput);
    }

    function test_executeSwap_maxRebalanceAmount_checks_input_not_output() public {
        // maxRebalanceAmount = $2k — check is on INPUT (fromToken/maxFromAmount)
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        vm.prank(principal);
        vault.updateBotConfig(
            bot,
            AxonVault.BotConfigParams({
                maxPerTxAmount: 0,
                maxRebalanceAmount: 2_000 * USDC_DECIMALS,
                spendingLimits: limits,
                aiTriggerThreshold: 0,
                requireAiVerification: false
            })
        );

        // Small output, but large input — should be blocked
        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: 100 * USDC_DECIMALS, // small output
            deadline: _deadline(),
            ref: bytes32("input-check")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);

        // maxFromAmount = $3k USDC (exceeds $2k maxRebalanceAmount)
        vm.prank(relayer);
        vm.expectRevert(AxonVault.MaxRebalanceAmountExceeded.selector);
        vault.executeSwap(intent, sig, address(usdc), 3_000 * USDC_DECIMALS, address(swapRouter), "");
    }

    function test_executePayment_swap_not_restricted_by_rebalance_whitelist() public {
        // Set rebalance whitelist to USDC only
        vm.prank(principal);
        vault.addRebalanceTokens(_toArray(address(usdc)));
        assertEq(vault.rebalanceTokenCount(), 1);

        // Payment with swap routing to USDT (NOT on rebalance whitelist) — should SUCCEED
        // because rebalance whitelist only applies to executeSwap, not executePayment
        uint256 usdtOut = 495 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), usdtOut);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot,
            to: recipient,
            token: address(usdt), // not on rebalance whitelist
            amount: usdtOut,
            deadline: _deadline(),
            ref: bytes32("payment-swap")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 500 * USDC_DECIMALS, address(usdt), usdtOut, recipient)
        );

        vm.prank(relayer);
        vault.executePayment(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
        assertEq(usdt.balanceOf(recipient), usdtOut);
    }

    function test_executeSwap_maxPerTxAmount_independent_from_rebalance() public {
        // maxPerTxAmount = $100 (for payments), maxRebalanceAmount = $10K (for rebalancing)
        // A $5K rebalance should succeed even though maxPerTxAmount is $100
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](0);
        vm.prank(principal);
        vault.updateBotConfig(
            bot,
            AxonVault.BotConfigParams({
                maxPerTxAmount: 100 * USDC_DECIMALS,
                maxRebalanceAmount: 10_000 * USDC_DECIMALS,
                spendingLimits: limits,
                aiTriggerThreshold: 0,
                requireAiVerification: false
            })
        );

        uint256 minOutput = 4_500 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), minOutput);

        AxonVault.SwapIntent memory intent = AxonVault.SwapIntent({
            bot: bot,
            toToken: address(usdt),
            minToAmount: minOutput,
            deadline: _deadline(),
            ref: bytes32("independent-cap")
        });
        bytes memory sig = _signSwap(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), 5_000 * USDC_DECIMALS, address(usdt), minOutput, address(vault))
        );

        vm.prank(relayer);
        vault.executeSwap(intent, sig, address(usdc), 5_000 * USDC_DECIMALS, address(swapRouter), swapCalldata);
        assertEq(usdt.balanceOf(address(vault)), minOutput);
    }

    // =========================================================================
    // Bot re-registration (stale spending limits)
    // =========================================================================

    function test_reregister_bot_clears_stale_spending_limits() public {
        // bot was added in setUp with 1 spending limit (10k/day)
        AxonVault.BotConfig memory configBefore = vault.getBotConfig(bot);
        assertEq(configBefore.spendingLimits.length, 1);

        // Remove bot
        vm.prank(principal);
        vault.removeBot(bot);

        // Re-register with a different limit
        AxonVault.SpendingLimit[] memory newLimits = new AxonVault.SpendingLimit[](1);
        newLimits[0] = AxonVault.SpendingLimit({ amount: 5_000 * USDC_DECIMALS, maxCount: 10, windowSeconds: 3600 });

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 1_000 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: newLimits,
            aiTriggerThreshold: 500 * USDC_DECIMALS,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(bot, params);

        // Should have exactly 1 limit (the new one), NOT 2
        AxonVault.BotConfig memory configAfter = vault.getBotConfig(bot);
        assertEq(configAfter.spendingLimits.length, 1);

        // Verify it's the new limit, not the old one
        assertEq(configAfter.spendingLimits[0].amount, 5_000 * USDC_DECIMALS);
        assertEq(configAfter.spendingLimits[0].maxCount, 10);
        assertEq(configAfter.spendingLimits[0].windowSeconds, 3600);
    }

    // =========================================================================
    // Edge cases — role overlap & identity
    // =========================================================================

    /// @dev Owner cannot register themselves as a bot — enforces key separation.
    function test_addBot_reverts_owner_as_bot() public {
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 1_000 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        vm.expectRevert(AxonVault.OwnerCannotBeBot.selector);
        vault.addBot(principal, params);
    }

    /// @dev Owner cannot register as bot even if operator tries.
    function test_addBot_reverts_owner_as_bot_by_operator() public {
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({ amount: 500 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400 });

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: limits,
            aiTriggerThreshold: 100 * USDC_DECIMALS,
            requireAiVerification: false
        });
        vm.prank(operator);
        vm.expectRevert(AxonVault.OwnerCannotBeBot.selector);
        vault.addBot(principal, params);
    }

    /// @dev Operator can be registered as a bot — no restriction in contract.
    function test_operator_can_be_registered_as_bot() public {
        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 1_000 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(operator, params);
        assertTrue(vault.isBotActive(operator));
    }

    /// @dev Registering an already-active bot reverts with BotAlreadyExists.
    function test_addBot_reverts_duplicate_registration() public {
        // bot is already registered in setUp
        assertTrue(vault.isBotActive(bot));

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        vm.expectRevert(AxonVault.BotAlreadyExists.selector);
        vault.addBot(bot, params);
    }

    /// @dev Cannot set owner address as operator.
    function test_setOperator_reverts_owner_address() public {
        vm.prank(principal);
        vm.expectRevert(AxonVault.OperatorCannotBeOwner.selector);
        vault.setOperator(principal);
    }

    /// @dev Setting operator to zero address is valid (unsets operator).
    function test_setOperator_zero_address_unsets() public {
        vm.prank(principal);
        vault.setOperator(address(0));
        assertEq(vault.operator(), address(0));
    }

    /// @dev Cannot register zero address as a bot.
    function test_addBot_reverts_zero_address_bot() public {
        AxonVault.BotConfigParams memory params;
        vm.prank(principal);
        vm.expectRevert(AxonVault.ZeroAddress.selector);
        vault.addBot(address(0), params);
    }

    /// @dev Same bot address can be registered on different vaults (independent storage).
    function test_same_bot_on_different_vaults() public {
        // Deploy a second vault for the same principal
        AxonVault vault2 = new AxonVault(principal, address(registry), true);

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
            maxRebalanceAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });

        // bot is already on vault (setUp). Add to vault2.
        vm.prank(principal);
        vault2.addBot(bot, params);

        // Both vaults have the same bot independently
        assertTrue(vault.isBotActive(bot));
        assertTrue(vault2.isBotActive(bot));

        // Removing from one doesn't affect the other
        vm.prank(principal);
        vault2.removeBot(bot);
        assertTrue(vault.isBotActive(bot));
        assertFalse(vault2.isBotActive(bot));
    }

    // =========================================================================
    // Access control — who can call what
    // =========================================================================

    /// @dev Attacker cannot remove a bot.
    function test_removeBot_reverts_non_authorized() public {
        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.removeBot(bot);
    }

    /// @dev Attacker cannot update bot config.
    function test_updateBotConfig_reverts_non_authorized() public {
        AxonVault.BotConfigParams memory params;
        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.updateBotConfig(bot, params);
    }

    /// @dev Attacker cannot add to global destination whitelist.
    function test_addGlobalDestination_reverts_non_owner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.addGlobalDestination(recipient);
    }

    /// @dev Operator cannot add to global destination whitelist (owner-only, loosening).
    function test_addGlobalDestination_reverts_operator() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.addGlobalDestination(recipient);
    }

    /// @dev Attacker cannot remove from global destination whitelist.
    function test_removeGlobalDestination_reverts_non_authorized() public {
        vm.prank(principal);
        vault.addGlobalDestination(recipient);

        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.removeGlobalDestination(recipient);
    }

    /// @dev Attacker cannot add to bot destination whitelist.
    function test_addBotDestination_reverts_non_owner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.addBotDestination(bot, recipient);
    }

    /// @dev Operator cannot add to bot destination whitelist (owner-only, loosening).
    function test_addBotDestination_reverts_operator() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.addBotDestination(bot, recipient);
    }

    /// @dev Attacker cannot remove from bot destination whitelist.
    function test_removeBotDestination_reverts_non_authorized() public {
        vm.prank(principal);
        vault.addBotDestination(bot, recipient);

        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.removeBotDestination(bot, recipient);
    }

    /// @dev Attacker cannot add to global blacklist.
    function test_addGlobalBlacklist_reverts_non_authorized() public {
        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorized.selector);
        vault.addGlobalBlacklist(recipient);
    }

    /// @dev Attacker cannot remove from global blacklist (owner-only).
    function test_removeGlobalBlacklist_reverts_non_owner() public {
        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        vm.prank(attacker);
        vm.expectRevert();
        vault.removeGlobalBlacklist(recipient);
    }

    /// @dev Operator cannot remove from global blacklist (owner-only, loosening).
    function test_removeGlobalBlacklist_reverts_operator() public {
        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        vm.prank(operator);
        vm.expectRevert();
        vault.removeGlobalBlacklist(recipient);
    }

    /// @dev Attacker cannot unpause.
    function test_unpause_reverts_non_owner() public {
        vm.prank(principal);
        vault.pause();

        vm.prank(attacker);
        vm.expectRevert();
        vault.unpause();
    }

    /// @dev Operator cannot unpause (owner-only).
    function test_unpause_reverts_operator() public {
        vm.prank(principal);
        vault.pause();

        vm.prank(operator);
        vm.expectRevert();
        vault.unpause();
    }

    /// @dev Operator cannot withdraw (owner-only).
    function test_withdraw_reverts_operator() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.withdraw(address(usdc), 1_000 * USDC_DECIMALS, operator);
    }

    /// @dev Operator cannot set the operator (owner-only).
    function test_setOperator_reverts_operator() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.setOperator(attacker);
    }

    /// @dev Operator cannot set operator ceilings (owner-only).
    function test_setOperatorCeilings_reverts_operator() public {
        AxonVault.OperatorCeilings memory c;
        vm.prank(operator);
        vm.expectRevert();
        vault.setOperatorCeilings(c);
    }
}
