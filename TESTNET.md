# Testnet Setup

## Base Sepolia USDC

- **Circle faucet** (confirmed working): https://faucet.circle.com/
  - Select Base Sepolia, paste your address, receive testnet USDC
  - USDC address: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`

## Deployed Addresses (Base Sepolia 84532)

| Contract                 | Address                                      |
| ------------------------ | -------------------------------------------- |
| AxonRegistry             | `0xC6d3B352B379F2cac502bB10f44C8B734A7f5B7d` |
| AxonVaultFactory         | `0x465ba07FD898239e4D64F3cE2E02F210DD2A4c51` |
| USDC                     | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| USDT                     | `0x323e78f944A9a1FcF3a10efcC5319DBb0bB6e673` |
| WETH                     | `0x4200000000000000000000000000000000000006` |
| Uniswap V3 SwapRouter02  | `0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4` |

## Deployed Addresses (Arbitrum Sepolia 421614)

| Contract                 | Address                                      |
| ------------------------ | -------------------------------------------- |
| AxonRegistry             | `0x7bBE5674113E7630B99eA0Fa491DE236f76c874d` |
| AxonVaultFactory         | `0x51192f74C81651156bc3a9110706085Bd5AC9de0` |
| USDC                     | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| WETH                     | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| Uniswap V3 SwapRouter    | `0x101F443B4d1b059569D643917553c771E1b9663E` |
| Uniswap V3 Factory       | `0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e` |

## Redeployment Checklist

When you redeploy AxonRegistry, AxonVaultFactory, or create a new vault, update **all** of the following:

1. **This file** (`TESTNET.md`) — addresses table above
2. **Relayer `.env`** — `AXON_REGISTRY_<chainId>`, `FACTORY_ADDRESS_<chainId>`
3. **Railway env** — same variables on the deployed relayer service
4. **Dashboard `.env.local`** — `NEXT_PUBLIC_FACTORY_<chainId>`
5. **Vercel env** — same variable on the deployed dashboard
6. **MEMORY.md** — deployment state section
7. **Register vault with relayer** — `curl -X POST /v1/metadata/register-vault`

### Oracle Config (post-deploy)

After deploying a new AxonRegistry, verify oracle config is set:

```bash
cast call <registry> "uniswapV3Factory()(address)" --rpc-url <rpc>
# Should NOT return 0x000...
```

If it returns zero, the deploy script didn't set it. Re-run `setOracleConfig()`.
