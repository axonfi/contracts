# Testnet Setup

## Base Sepolia USDC

- **Circle faucet** (confirmed working): https://faucet.circle.com/
  - Select Base Sepolia, paste your address, receive testnet USDC
  - USDC address: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`

## Deployed Addresses (Base Sepolia 84532)

| Contract                | Address                                      |
| ----------------------- | -------------------------------------------- |
| AxonRegistry (v3+)      | `0xEF9280ee20DBc78c73e71874bbC234d4023eaD14` |
| AxonVaultFactory (v5)   | `0x5Fb75454D191e110776B058b2a10989A9E446FF1` |
| Test Vault (v5)         | `0x0Bc5DF90FA4FE46179E2fEd508e4987863059932` |

<details>
<summary>Old deployments (archived)</summary>

| Contract                | Address                                      |
| ----------------------- | -------------------------------------------- |
| Old Factory (v4)        | `0x7fCd3b48D6DF01e8E309d8e6097Ad77C3e84bf72` |
| Old Test Vault (v4)     | `0x16f089d32866b36a1308c6ac77113caa4b890a98` |
| Old Factory (v3)        | `0x73b971B40D65520514A64Da8cFbC656Ce276d1DA` |
| Old Test Vault (v3)     | `0x6f49704bf51ee0f4f9632462b1663725543a37f9` |
| Old Registry (v2)       | `0x21340E5066d1C51FA58CDbCaE492407f2a109e64` |
| Old Factory (v2)        | `0xDbd90785E57fd433ee4dAc65318C4083624649db` |
| Old Vault (v2)          | `0x736fd8450a2ac4449684b71fc24724804b82aaef` |
| Old Registry (v1)       | `0x2ccd97040c1f4D97ac90e8bA8FEe9D0DCf4e3dc3` |
| Old Factory (v1)        | `0x55D71180ed38EBc0E2959840589BF4506A05641a` |
| Old Factory (v2-pre)    | `0xCC75dC0F9617AAF4179EDD9F7d27B67aA4DC60E6` |
| Old Vault (v2-pre)      | `0xdC3b0a3246e63983fAC310D2c8aE4991Fe69cA08` |

</details>
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
