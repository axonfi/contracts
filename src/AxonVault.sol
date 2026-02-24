// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAxonRegistry.sol";

/// @title AxonVault
/// @notice Non-custodial treasury vault for autonomous AI agent fleets.
///
///         Principals deploy one vault per chain via AxonVaultFactory. Bots sign
///         EIP-712 payment intents; the Axon relayer validates and executes them.
///         All policy values are stored on-chain for Principal verifiability — the
///         relayer reads limits from the contract, not its own database.
///
///         Security model:
///         - Only authorized relayers (AxonRegistry) can call executePayment/executeSwapAndPay
///         - Bots never hold ETH or submit transactions directly
///         - maxPerTxAmount is enforced on-chain (hard cap)
///         - Destination whitelist enforced on-chain
///         - All other limits (daily, velocity, AI thresholds) stored on-chain, enforced by relayer
///         - Operator hot wallet is bounded by owner-set OperatorCeilings — cannot drain vault
///         - Global pause available to owner (and operator for emergencies); only owner can unpause
contract AxonVault is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // =========================================================================
    // Constants
    // =========================================================================

    uint16 public constant VERSION = 1;
    uint8 public constant MAX_SPENDING_LIMITS = 5;
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes32 private constant PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address bot,address to,address token,uint256 amount,uint256 deadline,bytes32 ref)"
    );


    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice A rolling window spending limit. Stored on-chain, enforced by relayer.
    struct SpendingLimit {
        uint256 amount;         // max spend in this window (token base units, e.g. USDC 6 decimals)
        uint256 maxCount;       // max number of transactions in this window (0 = no count limit)
        uint256 windowSeconds;  // rolling window: 3600=1h, 86400=1d, 604800=1w, 2592000=30d
    }

    /// @notice Per-bot configuration. Policy values stored on-chain for verifiability.
    struct BotConfig {
        bool isActive;
        uint256 registeredAt;
        uint256 maxPerTxAmount;          // hard cap enforced ON-CHAIN in executePayment (0 = no cap)
        SpendingLimit[] spendingLimits;  // rolling window limits — stored on-chain, enforced by relayer
        uint256 aiTriggerThreshold;      // relayer triggers AI scan above this amount (0 = never by amount)
        bool requireAiVerification;      // relayer always requires AI scan for this bot
    }

    /// @notice Parameters for adding or updating a bot. Mirrors BotConfig minus isActive/registeredAt.
    struct BotConfigParams {
        uint256 maxPerTxAmount;
        SpendingLimit[] spendingLimits;
        uint256 aiTriggerThreshold;
        bool requireAiVerification;
    }

    /// @notice Owner-set ceilings that bound operator actions. Operator can never exceed these.
    ///         0 in a ceiling field means "no ceiling enforced" for that field,
    ///         EXCEPT maxOperatorBots where 0 means "operator cannot add bots" (restrictive default).
    struct OperatorCeilings {
        uint256 maxPerTxAmount;      // operator cannot configure a bot's maxPerTxAmount above this
        uint256 maxBotDailyLimit;    // operator cannot configure a bot's daily limit above this
        uint256 maxOperatorBots;     // 0 = operator CANNOT add bots. Must be explicitly set by owner.
        uint256 vaultDailyAggregate; // total vault daily outflow cap — relayer reads and enforces (0 = none)
        uint256 minAiTriggerFloor;   // operator cannot set aiTriggerThreshold above this (0 = no floor)
    }

    /// @notice Signed payment intent — bot commits to these exact terms.
    struct PaymentIntent {
        address bot;
        address to;
        address token;
        uint256 amount;
        uint256 deadline;
        bytes32 ref; // keccak256 of off-chain memo; full text stored in relayer PostgreSQL
    }


    // =========================================================================
    // Immutable state
    // =========================================================================

    /// @notice Axon's AxonRegistry for this chain. Immutable — set at deploy, never changes.
    address public immutable axonRegistry;

    /// @notice If true, executed intent hashes are stored to prevent exact duplicate submissions.
    ///         Set at deploy. Disable only for extreme high-frequency bots that need maximum throughput.
    bool public immutable trackUsedIntents;

    // =========================================================================
    // Mutable state
    // =========================================================================

    /// @notice Hot wallet for bot management. Cannot be the owner. address(0) = no operator.
    address public operator;

    /// @notice Owner-set ceilings bounding operator actions.
    OperatorCeilings public operatorCeilings;

    // Bot state
    mapping(address => BotConfig) private _bots;
    mapping(address => bool) public botAddedByOperator;
    uint256 public operatorBotCount;

    // Destination whitelists (empty = any destination allowed; non-empty = restrict to listed)
    mapping(address => bool) public globalDestinationWhitelist;
    uint256 public globalDestinationCount;
    mapping(address => mapping(address => bool)) public botDestinationWhitelist;
    mapping(address => uint256) public botDestinationCount;

    // Destination blacklist (always blocks, regardless of whitelist status)
    mapping(address => bool) public globalDestinationBlacklist;
    uint256 public globalBlacklistCount;

    // Intent deduplication (only active if trackUsedIntents = true)
    mapping(bytes32 => bool) public usedIntents;

    // =========================================================================
    // Events
    // =========================================================================

    event BotAdded(address indexed bot, address indexed addedBy);
    event BotRemoved(address indexed bot, address indexed removedBy);
    event BotConfigUpdated(address indexed bot, address indexed updatedBy);

    event PaymentExecuted(
        address indexed bot, address indexed to, address indexed token, uint256 amount, bytes32 ref
    );
    event SwapPaymentExecuted(
        address indexed bot,
        address indexed to,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount,
        bytes32 ref
    );

    event Deposited(address indexed from, address indexed token, uint256 amount, bytes32 ref);
    event Withdrawn(address indexed token, uint256 amount, address indexed to);

    event OperatorSet(address indexed oldOperator, address indexed newOperator);
    event OperatorCeilingsUpdated(OperatorCeilings ceilings);

    event GlobalDestinationAdded(address indexed destination);
    event GlobalDestinationRemoved(address indexed destination);
    event BotDestinationAdded(address indexed bot, address indexed destination);
    event BotDestinationRemoved(address indexed bot, address indexed destination);

    event GlobalBlacklistAdded(address indexed destination);
    event GlobalBlacklistRemoved(address indexed destination);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotAuthorizedRelayer();
    error NotAuthorized();
    error BotNotActive();
    error BotAlreadyExists();
    error BotDoesNotExist();
    error DeadlineExpired();
    error InvalidSignature();
    error IntentAlreadyUsed();
    error MaxPerTxExceeded();
    error DestinationBlacklisted();
    error DestinationNotWhitelisted();
    error RouterNotApproved();
    error SwapFailed();
    error SwapOutputInsufficient();
    error OperatorCannotBeOwner();
    error OperatorBotLimitReached();
    error ExceedsOperatorCeiling();
    error TooManySpendingLimits();
    error ZeroAddress();
    error NativeTransferFailed();
    error AmountMismatch();
    error UnexpectedETH();
    error SelfPayment();
    error PaymentToZeroAddress();
    error ZeroAmount();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyRelayer() {
        if (!IAxonRegistry(axonRegistry).isAuthorized(msg.sender)) revert NotAuthorizedRelayer();
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && (operator == address(0) || msg.sender != operator)) {
            revert NotAuthorized();
        }
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _owner           The Principal — vault owner, cold wallet recommended.
    /// @param _axonRegistry    Axon's AxonRegistry for this chain. Immutable.
    /// @param _trackUsedIntents If true, intent hashes are tracked to prevent duplicates.
    constructor(
        address _owner,
        address _axonRegistry,
        bool _trackUsedIntents
    )
        Ownable(_owner)
        EIP712("AxonVault", "1")
    {
        if (_axonRegistry == address(0)) revert ZeroAddress();
        axonRegistry = _axonRegistry;
        trackUsedIntents = _trackUsedIntents;
    }

    // =========================================================================
    // Owner-only configuration
    // =========================================================================

    /// @notice Assign or rotate the operator hot wallet. Use address(0) to unset.
    function setOperator(address _operator) external onlyOwner {
        if (_operator == owner()) revert OperatorCannotBeOwner();
        address old = operator;
        operator = _operator;
        emit OperatorSet(old, _operator);
    }

    /// @notice Set ceilings that bound all operator actions.
    ///         maxOperatorBots = 0 means operator cannot add any bots.
    function setOperatorCeilings(OperatorCeilings calldata ceilings) external onlyOwner {
        operatorCeilings = ceilings;
        emit OperatorCeilingsUpdated(ceilings);
    }

    // =========================================================================
    // Bot management
    // =========================================================================

    /// @notice Register a new bot address. Owner can set any config; operator is bounded by ceilings.
    function addBot(address bot, BotConfigParams calldata params) external onlyOwnerOrOperator {
        if (bot == address(0)) revert ZeroAddress();
        if (_bots[bot].isActive) revert BotAlreadyExists();
        if (params.spendingLimits.length > MAX_SPENDING_LIMITS) revert TooManySpendingLimits();

        bool byOperator = (msg.sender == operator && operator != address(0));

        if (byOperator) {
            _checkOperatorBotLimit();
            _checkOperatorCeilings(params, false);
        }

        BotConfig storage config = _bots[bot];
        config.isActive = true;
        config.registeredAt = block.timestamp;
        config.maxPerTxAmount = params.maxPerTxAmount;
        config.aiTriggerThreshold = params.aiTriggerThreshold;
        config.requireAiVerification = params.requireAiVerification;

        for (uint256 i = 0; i < params.spendingLimits.length; i++) {
            config.spendingLimits.push(params.spendingLimits[i]);
        }

        if (byOperator) {
            botAddedByOperator[bot] = true;
            operatorBotCount++;
        }

        emit BotAdded(bot, msg.sender);
    }

    /// @notice Revoke a bot's access. Owner or operator can remove any bot.
    function removeBot(address bot) external onlyOwnerOrOperator {
        if (!_bots[bot].isActive) revert BotDoesNotExist();
        _bots[bot].isActive = false;

        if (botAddedByOperator[bot]) {
            botAddedByOperator[bot] = false;
            if (operatorBotCount > 0) operatorBotCount--;
        }

        emit BotRemoved(bot, msg.sender);
    }

    /// @notice Update an existing bot's config. Operator can only tighten — not loosen.
    function updateBotConfig(address bot, BotConfigParams calldata params) external onlyOwnerOrOperator {
        if (!_bots[bot].isActive) revert BotDoesNotExist();
        if (params.spendingLimits.length > MAX_SPENDING_LIMITS) revert TooManySpendingLimits();

        bool byOperator = (msg.sender == operator && operator != address(0));

        if (byOperator) {
            _checkOperatorCeilings(params, true);
            // Operator cannot disable requireAiVerification once enabled
            if (_bots[bot].requireAiVerification && !params.requireAiVerification) {
                revert ExceedsOperatorCeiling();
            }
        }

        BotConfig storage config = _bots[bot];
        config.maxPerTxAmount = params.maxPerTxAmount;
        config.aiTriggerThreshold = params.aiTriggerThreshold;
        config.requireAiVerification = params.requireAiVerification;

        // Replace spending limits array
        uint256 existing = config.spendingLimits.length;
        for (uint256 i = 0; i < existing; i++) {
            config.spendingLimits.pop();
        }
        for (uint256 i = 0; i < params.spendingLimits.length; i++) {
            config.spendingLimits.push(params.spendingLimits[i]);
        }

        emit BotConfigUpdated(bot, msg.sender);
    }

    // =========================================================================
    // Destination whitelist management
    // =========================================================================

    /// @notice Add a destination to the vault-wide whitelist. Owner only (loosening).
    function addGlobalDestination(address destination) external onlyOwner {
        if (destination == address(0)) revert ZeroAddress();
        if (!globalDestinationWhitelist[destination]) {
            globalDestinationWhitelist[destination] = true;
            globalDestinationCount++;
            emit GlobalDestinationAdded(destination);
        }
    }

    /// @notice Remove a destination from the vault-wide whitelist. Owner or operator (tightening).
    function removeGlobalDestination(address destination) external onlyOwnerOrOperator {
        if (globalDestinationWhitelist[destination]) {
            globalDestinationWhitelist[destination] = false;
            globalDestinationCount--;
            emit GlobalDestinationRemoved(destination);
        }
    }

    /// @notice Add a destination to a specific bot's whitelist. Owner only (loosening).
    function addBotDestination(address bot, address destination) external onlyOwner {
        if (destination == address(0)) revert ZeroAddress();
        if (!botDestinationWhitelist[bot][destination]) {
            botDestinationWhitelist[bot][destination] = true;
            botDestinationCount[bot]++;
            emit BotDestinationAdded(bot, destination);
        }
    }

    /// @notice Remove a destination from a bot's whitelist. Owner or operator (tightening).
    function removeBotDestination(address bot, address destination) external onlyOwnerOrOperator {
        if (botDestinationWhitelist[bot][destination]) {
            botDestinationWhitelist[bot][destination] = false;
            botDestinationCount[bot]--;
            emit BotDestinationRemoved(bot, destination);
        }
    }

    // =========================================================================
    // Destination blacklist management
    // =========================================================================

    /// @notice Block a destination for the entire vault. Owner or operator (tightening).
    function addGlobalBlacklist(address destination) external onlyOwnerOrOperator {
        if (destination == address(0)) revert ZeroAddress();
        if (!globalDestinationBlacklist[destination]) {
            globalDestinationBlacklist[destination] = true;
            globalBlacklistCount++;
            emit GlobalBlacklistAdded(destination);
        }
    }

    /// @notice Unblock a destination. Owner only (loosening).
    function removeGlobalBlacklist(address destination) external onlyOwner {
        if (globalDestinationBlacklist[destination]) {
            globalDestinationBlacklist[destination] = false;
            globalBlacklistCount--;
            emit GlobalBlacklistRemoved(destination);
        }
    }

    // =========================================================================
    // Pause
    // =========================================================================

    /// @notice Freeze the vault. Owner or operator can pause (emergency response).
    function pause() external onlyOwnerOrOperator {
        _pause();
    }

    /// @notice Unfreeze the vault. Owner only — resuming operations requires cold wallet.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Deposit / Withdraw
    // =========================================================================

    /// @notice Accept raw ETH transfers (e.g. from swap routers, WETH unwrap, direct sends).
    receive() external payable {}

    /// @notice Deposit tokens or native ETH into the vault. Open to anyone — no restriction.
    ///         For native ETH: pass NATIVE_ETH as token, msg.value must equal amount.
    ///         `ref` links this deposit to an off-chain payment request or invoice tracked
    ///         in the relayer's PostgreSQL. Pass bytes32(0) for plain deposits with no reference.
    ///         Direct transfers (no function call) also work but emit no vault event.
    function deposit(address token, uint256 amount, bytes32 ref) external payable nonReentrant {
        if (token == NATIVE_ETH) {
            if (msg.value != amount) revert AmountMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedETH();
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        emit Deposited(msg.sender, token, amount, ref);
    }

    /// @notice Withdraw tokens or native ETH. Owner only — non-custodial guarantee.
    function withdraw(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _transferOut(token, to, amount);
        emit Withdrawn(token, amount, to);
    }

    // =========================================================================
    // Relayer fee withdrawal
    // =========================================================================

    // =========================================================================
    // Execute payment
    // =========================================================================

    /// @notice Execute a bot's signed payment intent. Only callable by authorized relayers.
    ///         On-chain enforcement: signature validity, bot active, deadline, maxPerTxAmount,
    ///         destination whitelist, optional intent deduplication.
    ///         Off-chain enforcement by relayer: daily limits, velocity, AI verification.
    function executePayment(PaymentIntent calldata intent, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        onlyRelayer
    {
        if (intent.amount == 0) revert ZeroAmount();
        if (intent.to == address(this)) revert SelfPayment();
        if (intent.to == address(0)) revert PaymentToZeroAddress();
        if (block.timestamp > intent.deadline) revert DeadlineExpired();

        BotConfig storage bot = _bots[intent.bot];
        if (!bot.isActive) revert BotNotActive();

        // Verify EIP-712 signature — signer must be the bot address in the intent
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_INTENT_TYPEHASH,
                intent.bot,
                intent.to,
                intent.token,
                intent.amount,
                intent.deadline,
                intent.ref
            )
        );
        bytes32 intentHash = _hashTypedDataV4(structHash);

        if (intentHash.recover(signature) != intent.bot) revert InvalidSignature();

        // Optional deduplication — prevents exact duplicate submissions
        if (trackUsedIntents) {
            if (usedIntents[intentHash]) revert IntentAlreadyUsed();
            usedIntents[intentHash] = true;
        }

        // Hard per-tx cap — enforced on-chain regardless of relayer behavior
        if (bot.maxPerTxAmount > 0 && intent.amount > bot.maxPerTxAmount) revert MaxPerTxExceeded();

        // Destination whitelist — enforced on-chain
        _checkDestination(intent.bot, intent.to);

        _transferOut(intent.token, intent.to, intent.amount);

        emit PaymentExecuted(intent.bot, intent.to, intent.token, intent.amount, intent.ref);
    }

    // =========================================================================
    // Execute swap and pay (same-chain)
    // =========================================================================

    /// @notice Execute a bot's signed payment intent via a DEX swap when the vault lacks the output token.
    ///         Bot signs a standard PaymentIntent specifying the desired output: token, amount, recipient.
    ///         The relayer transparently supplies swap routing — the bot never needs to know what the vault holds.
    ///         On-chain: verifies PaymentIntent signature, router approved, recipient received >= intent.amount.
    ///
    /// @param intent       Standard PaymentIntent signed by the bot. `token` = desired output token,
    ///                     `amount` = minimum the recipient must receive (slippage guarantee).
    /// @param signature    Bot's EIP-712 signature over the PaymentIntent.
    /// @param fromToken    Token the vault holds and will swap from (relayer-supplied, not signed by bot).
    /// @param maxFromAmount Max input the vault will spend on the swap (relayer-supplied).
    /// @param swapRouter   Approved DEX router to call (relayer-supplied).
    /// @param swapCalldata Encoded swap call to execute against swapRouter (relayer-supplied).
    function executeSwapAndPay(
        PaymentIntent calldata intent,
        bytes calldata signature,
        address fromToken,
        uint256 maxFromAmount,
        address swapRouter,
        bytes calldata swapCalldata
    ) external nonReentrant whenNotPaused onlyRelayer {
        if (intent.amount == 0) revert ZeroAmount();
        if (intent.to == address(this)) revert SelfPayment();
        if (intent.to == address(0)) revert PaymentToZeroAddress();
        if (block.timestamp > intent.deadline) revert DeadlineExpired();
        if (!IAxonRegistry(axonRegistry).isApprovedSwapRouter(swapRouter)) revert RouterNotApproved();

        BotConfig storage bot = _bots[intent.bot];
        if (!bot.isActive) revert BotNotActive();

        // Verify EIP-712 PaymentIntent signature — same typehash as executePayment
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_INTENT_TYPEHASH,
                intent.bot,
                intent.to,
                intent.token,
                intent.amount,
                intent.deadline,
                intent.ref
            )
        );
        bytes32 intentHash = _hashTypedDataV4(structHash);

        if (intentHash.recover(signature) != intent.bot) revert InvalidSignature();

        if (trackUsedIntents) {
            if (usedIntents[intentHash]) revert IntentAlreadyUsed();
            usedIntents[intentHash] = true;
        }

        // Per-tx cap applies to the desired output amount
        if (bot.maxPerTxAmount > 0 && intent.amount > bot.maxPerTxAmount) revert MaxPerTxExceeded();

        // Destination whitelist check
        _checkDestination(intent.bot, intent.to);

        // Snapshot balances before swap (use address.balance for native ETH)
        uint256 toBalanceBefore = (intent.token == NATIVE_ETH)
            ? intent.to.balance
            : IERC20(intent.token).balanceOf(intent.to);
        uint256 fromBalanceBefore = (fromToken == NATIVE_ETH)
            ? address(this).balance
            : IERC20(fromToken).balanceOf(address(this));

        // Execute swap — send ETH value if fromToken is native, otherwise approve ERC-20
        if (fromToken == NATIVE_ETH) {
            (bool success,) = swapRouter.call{value: maxFromAmount}(swapCalldata);
            if (!success) revert SwapFailed();
        } else {
            IERC20(fromToken).forceApprove(swapRouter, maxFromAmount);
            (bool success,) = swapRouter.call(swapCalldata);
            if (!success) revert SwapFailed();
            IERC20(fromToken).forceApprove(swapRouter, 0);
        }

        // Verify recipient received at least intent.amount of the desired output
        uint256 toBalanceAfter = (intent.token == NATIVE_ETH)
            ? intent.to.balance
            : IERC20(intent.token).balanceOf(intent.to);
        uint256 fromBalanceAfter = (fromToken == NATIVE_ETH)
            ? address(this).balance
            : IERC20(fromToken).balanceOf(address(this));
        uint256 toAmount   = toBalanceAfter - toBalanceBefore;
        uint256 fromAmount = fromBalanceBefore - fromBalanceAfter;
        if (toAmount < intent.amount) revert SwapOutputInsufficient();

        emit SwapPaymentExecuted(intent.bot, intent.to, fromToken, intent.token, fromAmount, toAmount, intent.ref);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Returns the EIP-712 domain separator for off-chain signature verification.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Returns the full BotConfig for a given bot address.
    function getBotConfig(address bot) external view returns (BotConfig memory) {
        return _bots[bot];
    }

    /// @notice Returns whether a bot address is currently active.
    function isBotActive(address bot) external view returns (bool) {
        return _bots[bot].isActive;
    }

    /// @notice Computes the maximum daily amount an operator-compromised wallet could drain.
    ///         Used by the dashboard to display the operator exposure warning to the Principal.
    ///         Formula: min(maxOperatorBots × maxBotDailyLimit, vaultDailyAggregate)
    function operatorMaxDrainPerDay() external view returns (uint256) {
        OperatorCeilings memory c = operatorCeilings;
        if (c.maxOperatorBots == 0 || c.maxBotDailyLimit == 0) return 0;
        uint256 theoretical = c.maxOperatorBots * c.maxBotDailyLimit;
        if (c.vaultDailyAggregate > 0 && c.vaultDailyAggregate < theoretical) {
            return c.vaultDailyAggregate;
        }
        return theoretical;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Transfer tokens or native ETH to a recipient.
    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == NATIVE_ETH) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _checkDestination(address bot, address to) internal view {
        // Blacklist always blocks, regardless of whitelist
        if (globalDestinationBlacklist[to]) revert DestinationBlacklisted();

        // Whitelist check (unchanged)
        bool hasRestrictions = (globalDestinationCount > 0 || botDestinationCount[bot] > 0);
        if (hasRestrictions) {
            if (!globalDestinationWhitelist[to] && !botDestinationWhitelist[bot][to]) {
                revert DestinationNotWhitelisted();
            }
        }
    }

    function _checkOperatorBotLimit() internal view {
        // maxOperatorBots = 0 means operator cannot add any bots — restrictive default
        if (operatorCeilings.maxOperatorBots == 0) revert OperatorBotLimitReached();
        if (operatorBotCount >= operatorCeilings.maxOperatorBots) revert OperatorBotLimitReached();
    }

    function _checkOperatorCeilings(BotConfigParams calldata params, bool isUpdate) internal view {
        OperatorCeilings memory c = operatorCeilings;

        // Per-tx ceiling: if set, operator must provide a non-zero cap within the ceiling
        if (c.maxPerTxAmount > 0) {
            if (params.maxPerTxAmount == 0 || params.maxPerTxAmount > c.maxPerTxAmount) {
                revert ExceedsOperatorCeiling();
            }
        }

        // AI trigger floor: operator cannot set a threshold above the floor
        // (higher threshold = fewer transactions get AI-scanned = loosening coverage)
        if (c.minAiTriggerFloor > 0 && params.aiTriggerThreshold > 0) {
            if (params.aiTriggerThreshold > c.minAiTriggerFloor) {
                revert ExceedsOperatorCeiling();
            }
        }

        // Daily limit ceiling: check any daily-ish spending windows
        if (c.maxBotDailyLimit > 0) {
            for (uint256 i = 0; i < params.spendingLimits.length; i++) {
                // Apply ceiling to windows of 1 day or shorter
                if (params.spendingLimits[i].windowSeconds <= 86400) {
                    if (params.spendingLimits[i].amount > c.maxBotDailyLimit) {
                        revert ExceedsOperatorCeiling();
                    }
                }
            }
        }
    }
}
