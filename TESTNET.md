# Testnet Setup

## Base Sepolia USDC

- **Circle faucet** (confirmed working): https://faucet.circle.com/
  - Select Base Sepolia, paste your address, receive testnet USDC
  - USDC address: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`

## Deployed Addresses (Base Sepolia 84532)

| Contract                | Address                                      |
| ----------------------- | -------------------------------------------- |
| AxonRegistry            | `0x2ccd97040c1f4D97ac90e8bA8FEe9D0DCf4e3dc3` |
| AxonVaultFactory        | `0x55D71180ed38EBc0E2959840589BF4506A05641a` |
| Test Vault              | `0x1F17b2f2A99e9DfC611B3A012357e56afEAdd348` |
| USDC                    | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| USDT                    | `0x323e78f944A9a1FcF3a10efcC5319DBb0bB6e673` |
| WETH                    | `0x4200000000000000000000000000000000000006` |
| Uniswap V3 SwapRouter02 | `0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4` |

## Redeployment Checklist

When you redeploy AxonRegistry, AxonVaultFactory, or create a new vault, update **all** of the following:

1. **This file** — update the Deployed Addresses table above
2. **`packages/dashboard/.env.local`**
   - `NEXT_PUBLIC_FACTORY_84532` — new factory address
3. **`packages/relayer/.env`**
   - `AXON_REGISTRY_84532` — new registry address
   - `FACTORY_ADDRESS_84532` — new factory address
4. **Register the relayer delegator** on the new registry:
   ```bash
   cast send <NEW_REGISTRY> "addDelegator(address)" <DELEGATOR_ADDRESS> --private-key $PRIVATE_KEY --rpc-url https://sepolia.base.org
   ```
5. **Create a new vault** via the factory (or dashboard)
6. **Add bot(s)** to the new vault
7. **Fund the new vault** (transfer tokens from deployer or faucet)
8. **Restart** dashboard and relayer dev servers to pick up new env vars

## Deployer

Address: `0xD8f5dbF83236fBe7B77E52F874f378ff52e904E0` (key in `packages/contracts/.env`)

## Relayer Delegator

Address: `0x7F9F97413551E047edfDdE5c1a94f233A705c3DB` (key in `packages/relayer/.env`)
