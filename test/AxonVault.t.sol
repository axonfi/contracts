// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AxonVault.sol";
import "../src/AxonRegistry.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockSwapRouter.sol";

contract AxonVaultTest is Test {
    // =========================================================================
    // Actors
    // =========================================================================

    uint256 constant PRINCIPAL_KEY = 0xA11CE;
    uint256 constant OPERATOR_KEY  = 0x0EA7;
    uint256 constant BOT_KEY       = 0xB07;
    uint256 constant BOT2_KEY      = 0xB072;

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
    AxonVault        vault;
    MockERC20        usdc;
    MockERC20        usdt;
    MockSwapRouter   swapRouter;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 constant USDC_DECIMALS  = 1e6;
    uint256 constant VAULT_DEPOSIT  = 100_000 * USDC_DECIMALS; // $100k
    uint256 constant DEADLINE_DELTA = 5 minutes;

    // EIP-712 type hashes — must match AxonVault exactly
    bytes32 constant PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address bot,address to,address token,uint256 amount,uint256 deadline,bytes32 ref)"
    );

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        principal = vm.addr(PRINCIPAL_KEY);
        operator  = vm.addr(OPERATOR_KEY);
        bot       = vm.addr(BOT_KEY);
        bot2      = vm.addr(BOT2_KEY);
        relayer   = makeAddr("relayer");
        recipient = makeAddr("recipient");
        attacker  = makeAddr("attacker");

        // Deploy infrastructure
        registry   = new AxonRegistry(address(this));
        registry.addRelayer(relayer);

        usdc       = new MockERC20("USD Coin", "USDC", 6);
        usdt       = new MockERC20("Tether USD", "USDT", 6);
        swapRouter = new MockSwapRouter();

        // Approve swap router on the global registry
        registry.addSwapRouter(address(swapRouter));

        // Deploy vault owned by principal
        vault = new AxonVault(principal, address(registry), true);

        // Fund vault
        usdc.mint(address(vault), VAULT_DEPOSIT);

        // Default operator ceilings (set by principal)
        AxonVault.OperatorCeilings memory ceilings = AxonVault.OperatorCeilings({
            maxPerTxAmount:      1_000 * USDC_DECIMALS,  // $1k per tx ceiling
            maxBotDailyLimit:    5_000 * USDC_DECIMALS,  // $5k/day ceiling
            maxOperatorBots:     5,                       // operator can add up to 5 bots
            vaultDailyAggregate: 10_000 * USDC_DECIMALS, // $10k/day total cap
            minAiTriggerFloor:   500 * USDC_DECIMALS      // AI threshold can't exceed $500
        });
        vm.prank(principal);
        vault.setOperatorCeilings(ceilings);

        // Set operator
        vm.prank(principal);
        vault.setOperator(operator);

        // Add a default bot (by principal, unconstrained by operator ceilings)
        AxonVault.SpendingLimit[] memory limits = new AxonVault.SpendingLimit[](1);
        limits[0] = AxonVault.SpendingLimit({amount: 10_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400});

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount:      2_000 * USDC_DECIMALS,
            spendingLimits:      limits,
            aiTriggerThreshold:  1_000 * USDC_DECIMALS,
            requireAiVerification: false
        });
        vm.prank(principal);
        vault.addBot(bot, params);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _deadline() internal view returns (uint256) {
        return block.timestamp + DEADLINE_DELTA;
    }

    function _signPayment(
        uint256 privKey,
        AxonVault.PaymentIntent memory intent
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            PAYMENT_INTENT_TYPEHASH,
            intent.bot, intent.to, intent.token,
            intent.amount, intent.deadline, intent.ref
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }


    function _defaultIntent(uint256 amount) internal view returns (AxonVault.PaymentIntent memory) {
        return AxonVault.PaymentIntent({
            bot:      bot,
            to:       recipient,
            token:    address(usdc),
            amount:   amount,
            deadline: _deadline(),
            ref:      bytes32("test-ref-001")
        });
    }

    function _executePayment(AxonVault.PaymentIntent memory intent) internal {
        bytes memory sig = _signPayment(BOT_KEY, intent);
        vm.prank(relayer);
        vault.executePayment(intent, sig);
    }

    // =========================================================================
    // Deployment
    // =========================================================================

    function test_version_is_1() public view {
        assertEq(vault.VERSION(), 1);
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
        assertEq(config.maxPerTxAmount, 2_000 * USDC_DECIMALS);
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
        limits[0] = AxonVault.SpendingLimit({amount: 20_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400});

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 3_000 * USDC_DECIMALS,
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
        limits[0] = AxonVault.SpendingLimit({amount: 4_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400});

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount:       800 * USDC_DECIMALS, // below $1k ceiling
            spendingLimits:       limits,              // $4k/day, below $5k ceiling
            aiTriggerThreshold:   300 * USDC_DECIMALS, // below $500 floor
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
            maxPerTxAmount:      1_000 * USDC_DECIMALS,
            maxBotDailyLimit:    5_000 * USDC_DECIMALS,
            maxOperatorBots:     1,
            vaultDailyAggregate: 10_000 * USDC_DECIMALS,
            minAiTriggerFloor:   500 * USDC_DECIMALS
        });
        vm.prank(principal);
        vault.setOperatorCeilings(ceilings);

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
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
        limits[0] = AxonVault.SpendingLimit({amount: 6_000 * USDC_DECIMALS, maxCount: 0, windowSeconds: 86400}); // $6k, ceiling is $5k

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
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
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 500 * USDC_DECIMALS,
            requireAiVerification: true
        });
        vm.prank(principal);
        vault.updateBotConfig(bot, enableParams);

        // Now operator tries to disable it
        AxonVault.BotConfigParams memory disableParams = AxonVault.BotConfigParams({
            maxPerTxAmount: 500 * USDC_DECIMALS,
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
        vault.executePayment(intent, sig);
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

    function test_operator_cannot_withdraw() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.withdraw(address(usdc), 1_000 * USDC_DECIMALS, operator);
    }

    function test_eth_accepted_via_receive() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool success,) = address(vault).call{value: 1 ether}("");
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
        vault.executePayment(intent, sig);
    }

    function test_executePayment_marks_intent_as_used() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        bytes32 structHash = keccak256(abi.encode(
            PAYMENT_INTENT_TYPEHASH,
            intent.bot, intent.to, intent.token,
            intent.amount, intent.deadline, intent.ref
        ));
        bytes32 intentHash = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));

        vm.prank(relayer);
        vault.executePayment(intent, sig);

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
        vault.executePayment(intent, sig);
    }

    function test_executePayment_reverts_expired_deadline() public {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot:      bot,
            to:       recipient,
            token:    address(usdc),
            amount:   100 * USDC_DECIMALS,
            deadline: block.timestamp - 1, // already expired
            ref:      bytes32("ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DeadlineExpired.selector);
        vault.executePayment(intent, sig);
    }

    function test_executePayment_reverts_inactive_bot() public {
        vm.prank(principal);
        vault.removeBot(bot);

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.BotNotActive.selector);
        vault.executePayment(intent, sig);
    }

    function test_executePayment_reverts_invalid_signature() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        // Sign with wrong key (attacker key instead of bot key)
        uint256 attackerKey = 0xDEAD;
        bytes memory sig = _signPayment(attackerKey, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.InvalidSignature.selector);
        vault.executePayment(intent, sig);
    }

    function test_executePayment_reverts_tampered_amount() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        // Tamper with amount after signing
        intent.amount = 50_000 * USDC_DECIMALS;

        vm.prank(relayer);
        vm.expectRevert(AxonVault.InvalidSignature.selector);
        vault.executePayment(intent, sig);
    }

    function test_executePayment_reverts_maxPerTxAmount_exceeded() public {
        // Bot's maxPerTxAmount is $2k; try to send $3k
        AxonVault.PaymentIntent memory intent = _defaultIntent(3_000 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.MaxPerTxExceeded.selector);
        vault.executePayment(intent, sig);
    }

    function test_executePayment_reverts_replay() public {
        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vault.executePayment(intent, sig);

        // Second submission — same intent hash
        vm.prank(relayer);
        vm.expectRevert(AxonVault.IntentAlreadyUsed.selector);
        vault.executePayment(intent, sig);
    }

    function test_executePayment_no_replay_check_when_tracking_disabled() public {
        // Deploy vault without intent tracking
        AxonVault noTrackVault = new AxonVault(principal, address(registry), false);
        usdc.mint(address(noTrackVault), VAULT_DEPOSIT);

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 0,
            spendingLimits: new AxonVault.SpendingLimit[](0),
            aiTriggerThreshold: 0,
            requireAiVerification: false
        });
        vm.prank(principal);
        noTrackVault.addBot(bot, params);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot, to: recipient, token: address(usdc),
            amount: 100 * USDC_DECIMALS, deadline: _deadline(), ref: bytes32("ref")
        });

        bytes32 structHash = keccak256(abi.encode(
            PAYMENT_INTENT_TYPEHASH,
            intent.bot, intent.to, intent.token,
            intent.amount, intent.deadline, intent.ref
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", noTrackVault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOT_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        noTrackVault.executePayment(intent, sig);

        // Same intent again — should NOT revert (tracking disabled)
        vm.prank(relayer);
        noTrackVault.executePayment(intent, sig);

        assertEq(usdc.balanceOf(recipient), 200 * USDC_DECIMALS);
    }

    function test_executePayment_reverts_when_paused() public {
        vm.prank(principal);
        vault.pause();

        AxonVault.PaymentIntent memory intent = _defaultIntent(100 * USDC_DECIMALS);
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert();
        vault.executePayment(intent, sig);
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
    // executeSwapAndPay
    // =========================================================================

    function test_executeSwapAndPay_happy_path() public {
        // Pre-fund the swap router with USDT to give to recipient
        uint256 usdtOut = 495 * USDC_DECIMALS; // ~$495 after slippage
        usdt.mint(address(swapRouter), usdtOut);

        // Bot signs a standard PaymentIntent: "deliver usdtOut USDT to recipient"
        // Bot never needs to know the vault holds USDC — the relayer handles the swap transparently
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot:      bot,
            to:       recipient,
            token:    address(usdt),  // desired output token
            amount:   usdtOut,        // minimum the recipient must receive
            deadline: _deadline(),
            ref:      bytes32("swap-ref-001")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap,
            (address(usdc), 500 * USDC_DECIMALS, address(usdt), usdtOut, recipient)
        );

        vm.prank(relayer);
        vault.executeSwapAndPay(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);

        assertEq(usdt.balanceOf(recipient), usdtOut);
    }

    function test_executeSwapAndPay_reverts_unapproved_router() public {
        address fakeRouter = makeAddr("fakeRouter");
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot, to: recipient, token: address(usdt),
            amount: 99 * USDC_DECIMALS, deadline: _deadline(), ref: bytes32("ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.RouterNotApproved.selector);
        vault.executeSwapAndPay(intent, sig, address(usdc), 100 * USDC_DECIMALS, fakeRouter, "");
    }

    function test_executeSwapAndPay_reverts_insufficient_output() public {
        usdt.mint(address(swapRouter), 1_000 * USDC_DECIMALS);

        // Bot wants 490 USDT minimum — swapShort delivers only half (~245 USDT) → should revert
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot, to: recipient, token: address(usdt),
            amount: 490 * USDC_DECIMALS, deadline: _deadline(), ref: bytes32("ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        // Use swapShort which delivers only half
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swapShort,
            (address(usdc), 500 * USDC_DECIMALS, address(usdt), 500 * USDC_DECIMALS, recipient)
        );

        vm.prank(relayer);
        vm.expectRevert(AxonVault.SwapOutputInsufficient.selector);
        vault.executeSwapAndPay(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
    }

    function test_executeSwapAndPay_reverts_non_relayer() public {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot, to: recipient, token: address(usdt),
            amount: 99 * USDC_DECIMALS, deadline: _deadline(), ref: bytes32("ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(attacker);
        vm.expectRevert(AxonVault.NotAuthorizedRelayer.selector);
        vault.executeSwapAndPay(intent, sig, address(usdc), 100 * USDC_DECIMALS, address(swapRouter), "");
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
            maxPerTxAmount:      1_000 * USDC_DECIMALS,
            maxBotDailyLimit:    5_000 * USDC_DECIMALS,
            maxOperatorBots:     3,
            vaultDailyAggregate: 0, // no aggregate cap
            minAiTriggerFloor:   500 * USDC_DECIMALS
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
        limits[0] = AxonVault.SpendingLimit({amount: 5_000 * USDC_DECIMALS, maxCount: 10, windowSeconds: 86400});
        limits[1] = AxonVault.SpendingLimit({amount: 20_000 * USDC_DECIMALS, maxCount: 50, windowSeconds: 604800});

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 1_000 * USDC_DECIMALS,
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
        limits[0] = AxonVault.SpendingLimit({amount: 8_000 * USDC_DECIMALS, maxCount: 25, windowSeconds: 86400});

        AxonVault.BotConfigParams memory params = AxonVault.BotConfigParams({
            maxPerTxAmount: 2_000 * USDC_DECIMALS,
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
        vault.executePayment(intent, sig);
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
        vault.executePayment(intent, sig);
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

    function test_BlacklistBlocksSwapAndPay() public {
        vm.prank(principal);
        vault.addGlobalBlacklist(recipient);

        uint256 usdtOut = 495 * USDC_DECIMALS;
        usdt.mint(address(swapRouter), usdtOut);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot: bot, to: recipient, token: address(usdt),
            amount: usdtOut, deadline: _deadline(), ref: bytes32("swap-ref")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);
        bytes memory swapCalldata = abi.encodeCall(
            MockSwapRouter.swap,
            (address(usdc), 500 * USDC_DECIMALS, address(usdt), usdtOut, recipient)
        );

        vm.prank(relayer);
        vm.expectRevert(AxonVault.DestinationBlacklisted.selector);
        vault.executeSwapAndPay(intent, sig, address(usdc), 500 * USDC_DECIMALS, address(swapRouter), swapCalldata);
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
        (bool success,) = address(vault).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_DepositETH() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);

        vm.prank(depositor);
        vault.deposit{value: 2 ether}(NATIVE_ETH_ADDR, 2 ether, bytes32(0));

        assertEq(address(vault).balance, 2 ether);
    }

    function test_DepositETH_AmountMismatch() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);

        vm.startPrank(depositor);
        vm.expectRevert(AxonVault.AmountMismatch.selector);
        vault.deposit{value: 1 ether}(NATIVE_ETH_ADDR, 2 ether, bytes32(0));
        vm.stopPrank();
    }

    function test_DepositERC20_RejectsETH() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);
        usdc.mint(depositor, 1000 * USDC_DECIMALS);

        vm.startPrank(depositor);
        vm.expectRevert(AxonVault.UnexpectedETH.selector);
        vault.deposit{value: 1 ether}(address(usdc), 1000 * USDC_DECIMALS, bytes32(0));
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
            maxPerTxAmount:       0,   // no cap
            spendingLimits:       limits,
            aiTriggerThreshold:   0,
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
            bot:      ethBot,
            to:       recipient,
            token:    NATIVE_ETH_ADDR,
            amount:   1 ether,
            deadline: _deadline(),
            ref:      bytes32("eth-payment-001")
        });
        bytes memory sig = _signPayment(ethBotKey, intent);

        vm.prank(relayer);
        vault.executePayment(intent, sig);

        assertEq(recipient.balance - recipientBefore, 1 ether);
        assertEq(address(vault).balance, 9 ether);
    }

    function test_ExecutePaymentETH_InsufficientBalance() public {
        uint256 ethBotKey = 0xE7B07;
        address ethBot = _ethBot();

        assertEq(address(vault).balance, 0);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot:      ethBot,
            to:       recipient,
            token:    NATIVE_ETH_ADDR,
            amount:   1 ether,
            deadline: _deadline(),
            ref:      bytes32("eth-payment-fail")
        });
        bytes memory sig = _signPayment(ethBotKey, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.NativeTransferFailed.selector);
        vault.executePayment(intent, sig);
    }

    function test_DepositETH_emits_event() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 5 ether);
        bytes32 ref = bytes32("eth-deposit-ref");

        vm.startPrank(depositor);
        vm.expectEmit(true, true, false, true);
        emit AxonVault.Deposited(depositor, NATIVE_ETH_ADDR, 1 ether, ref);
        vault.deposit{value: 1 ether}(NATIVE_ETH_ADDR, 1 ether, ref);
        vm.stopPrank();
    }

    // =========================================================================
    // Self-payment and zero-address rejection
    // =========================================================================

    function test_ExecutePayment_RevertsSelfPayment() public {
        usdc.mint(address(vault), 1000 * USDC_DECIMALS);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot:      bot,
            to:       address(vault),  // paying itself
            token:    address(usdc),
            amount:   100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref:      bytes32("self-pay")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.SelfPayment.selector);
        vault.executePayment(intent, sig);
    }

    function test_ExecutePayment_RevertsZeroAddress() public {
        usdc.mint(address(vault), 1000 * USDC_DECIMALS);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot:      bot,
            to:       address(0),
            token:    address(usdc),
            amount:   100 * USDC_DECIMALS,
            deadline: _deadline(),
            ref:      bytes32("zero-addr")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.PaymentToZeroAddress.selector);
        vault.executePayment(intent, sig);
    }

    function test_ExecutePayment_RevertsZeroAmount() public {
        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot:      bot,
            to:       recipient,
            token:    address(usdc),
            amount:   0,
            deadline: _deadline(),
            ref:      bytes32("zero-amount")
        });
        bytes memory sig = _signPayment(BOT_KEY, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.ZeroAmount.selector);
        vault.executePayment(intent, sig);
    }

    function test_ExecutePaymentETH_RevertsSelfPayment() public {
        uint256 ethBotKey = 0xE7B07;
        address ethBot = _ethBot();
        vm.deal(address(vault), 10 ether);

        AxonVault.PaymentIntent memory intent = AxonVault.PaymentIntent({
            bot:      ethBot,
            to:       address(vault),
            token:    NATIVE_ETH_ADDR,
            amount:   1 ether,
            deadline: _deadline(),
            ref:      bytes32("self-pay-eth")
        });
        bytes memory sig = _signPayment(ethBotKey, intent);

        vm.prank(relayer);
        vm.expectRevert(AxonVault.SelfPayment.selector);
        vault.executePayment(intent, sig);
    }
}
