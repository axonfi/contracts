# Testing Bot Payments

How to issue payment requests from a bot, both direct and with swaps.

## Prerequisites

- Vault deployed and funded (see [TESTNET.md](./TESTNET.md) for addresses)
- Bot registered on the vault (`addBot`)
- Delegator registered on AxonRegistry (`addDelegator`)
- For swap payments: swap router approved on AxonRegistry (`addSwapRouter`)

## Direct Payment (vault has the output token)

Bot signs a `PaymentIntent`, delegator calls `executePayment` with no swap params.

```bash
# 1. Bot signs EIP-712 PaymentIntent (done in SDK/script, not cast)
# 2. Delegator submits:
cast send $VAULT "executePayment((address,address,address,uint256,uint256,bytes32),bytes,address,uint256,address,bytes)" \
  "(${BOT},${TO},${TOKEN},${AMOUNT},${DEADLINE},${REF})" \
  $SIGNATURE \
  "0x0000000000000000000000000000000000000000" 0 "0x0000000000000000000000000000000000000000" "0x" \
  --private-key $DELEGATOR_KEY --rpc-url $RPC_URL
```

The last 4 args (`fromToken=address(0), maxFromAmount=0, swapRouter=address(0), swapCalldata=0x`) mean "no swap".

## Swap+Payment (vault doesn't have the output token)

Approach B: bot still signs a `PaymentIntent` for the desired output token. The relayer (or script) supplies swap params. The contract swaps atomically and verifies the recipient received the right amount.

### Flow

1. Bot signs `PaymentIntent { bot, to, token: WETH, amount: 0.001e18, deadline, ref }`
2. Relayer checks vault balance — vault has USDC, not WETH
3. Relayer builds Uniswap V3 `exactOutputSingle` calldata:
   - `tokenIn`: USDC
   - `tokenOut`: WETH
   - `fee`: 3000 (0.3% pool)
   - `recipient`: the payment recipient (NOT the vault)
   - `amountOut`: the exact WETH amount from the intent
   - `amountInMaximum`: max USDC willing to spend
   - `sqrtPriceLimitX96`: 0 (no limit)
4. Delegator calls `executePayment(intent, sig, USDC, maxUSDC, swapRouter, swapCalldata)`
5. Contract: approves USDC to router → calls router → verifies recipient got ≥ intent.amount of WETH → emits `SwapPaymentExecuted`

### Important: swap `recipient` is the payment recipient

The contract checks `IERC20(intent.token).balanceOf(intent.to)` before and after the swap. So the Uniswap swap must route output tokens directly to `intent.to`, not to the vault.

### Uniswap V3 `exactOutputSingle` encoding

```typescript
const swapCalldata = encodeFunctionData({
  abi: [
    {
      type: 'function',
      name: 'exactOutputSingle',
      inputs: [
        {
          name: 'params',
          type: 'tuple',
          components: [
            { name: 'tokenIn', type: 'address' },
            { name: 'tokenOut', type: 'address' },
            { name: 'fee', type: 'uint24' },
            { name: 'recipient', type: 'address' },
            { name: 'amountOut', type: 'uint256' },
            { name: 'amountInMaximum', type: 'uint256' },
            { name: 'sqrtPriceLimitX96', type: 'uint160' },
          ],
        },
      ],
      outputs: [{ name: 'amountIn', type: 'uint256' }],
      stateMutability: 'payable',
    },
  ],
  functionName: 'exactOutputSingle',
  args: [
    {
      tokenIn: USDC,
      tokenOut: WETH,
      fee: 3000,
      recipient: PAYMENT_RECIPIENT, // NOT the vault
      amountOut: WETH_AMOUNT,
      amountInMaximum: MAX_USDC,
      sqrtPriceLimitX96: 0n,
    },
  ],
});
```

## `executePayment` Signature (Approach B)

```solidity
function executePayment(
    PaymentIntent calldata intent,    // bot-signed
    bytes calldata signature,         // EIP-712 sig from bot
    address fromToken,                // address(0) = no swap; USDC for swap
    uint256 maxFromAmount,            // max input tokens for swap
    address swapRouter,               // Uniswap V3 SwapRouter02
    bytes calldata swapCalldata       // encoded exactOutputSingle call
) external nonReentrant whenNotPaused onlyRelayer
```

### Contract logic (Approach B balance check)

```
if vault has enough of intent.token → direct transfer (ignores swap params)
else if fromToken != address(0)    → execute swap, verify output, emit SwapPaymentExecuted
else                                → revert InsufficientBalance
```

## EIP-712 Domain & Types

```typescript
const domain = {
  name: 'AxonVault',
  version: '1',
  chainId: 84532, // Base Sepolia
  verifyingContract: VAULT_ADDRESS,
};

const types = {
  PaymentIntent: [
    { name: 'bot', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'token', type: 'address' },
    { name: 'amount', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
    { name: 'ref', type: 'bytes32' },
  ],
};
```

## Test Scripts

- **`scripts/send-payment.ts`** — send payment via relayer API (`POST /v1/payments`)
- **`scripts/test-swap-payment.ts`** — direct on-chain swap+payment (bypasses relayer, tests Solidity)

## Verified Test (2026-02-25)

Atomic USDC→WETH swap+payment on Base Sepolia:

- TX: `0xa74f09a1dc2b2bde4bc8b6c893be69bdbbe0c879edbb04dd5e76524497577df9`
- Vault spent 0.089222 USDC → recipient received 0.001 WETH
- Pool: USDC/WETH 0.3% fee tier
- Event: `SwapPaymentExecuted` with full from/to token amounts

## Pool Addresses (Base Sepolia)

| Pair      | Fee         | Pool Address                                 |
| --------- | ----------- | -------------------------------------------- |
| USDC/WETH | 0.05% (500) | `0x94bfc0574FF48E92cE43d495376C477B1d0EEeC0` |
| USDC/WETH | 0.3% (3000) | `0x46880b404CD35c165EDdefF7421019F8dD25F4Ad` |
| USDC/WETH | 1% (10000)  | `0x4664755562152EDDa3a3073850FB62835451926a` |

## Common Errors

| Error                    | Cause                                                    |
| ------------------------ | -------------------------------------------------------- |
| `NotAuthorizedRelayer`   | Delegator not registered on AxonRegistry                 |
| `BotNotActive`           | Bot not added to vault via `addBot`                      |
| `InvalidSignature`       | Wrong EIP-712 domain (check chainId, verifyingContract)  |
| `RouterNotApproved`      | Swap router not approved on AxonRegistry                 |
| `SwapFailed`             | Uniswap call reverted (no liquidity, bad calldata)       |
| `SwapOutputInsufficient` | Swap output < intent.amount (slippage too high)          |
| `InsufficientBalance`    | Vault doesn't have the token and no swap params provided |
| `DeadlineExpired`        | Intent deadline passed                                   |

## Redeployment Checklist

See [TESTNET.md](./TESTNET.md#redeployment-checklist) — update all env vars after redeploy.
