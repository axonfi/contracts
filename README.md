# Axon — Smart Contracts

Solidity contracts for the Axon vault system. Built with [Foundry](https://book.getfoundry.sh/).

## Contracts

| Contract           | Description                                                                                               |
| ------------------ | --------------------------------------------------------------------------------------------------------- |
| `RelayerRegistry`  | Axon-controlled whitelist of authorized relayer addresses. All vaults point to this.                      |
| `AxonVaultFactory` | Permissionless factory. Any address deploys a vault in one transaction.                                   |
| `AxonVault`        | Per-owner treasury vault. Holds funds, enforces bot spending limits, verifies EIP-712 signed intents. |

---

## Development

```bash
# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with gas output
forge test --gas-report

# Run a specific test
forge test --match-test test_executePayment_transfers_funds -vvvv

# Format
forge fmt
```

### Security Analysis

Static analyzers and fuzzers for auditing contracts before deployment.

```bash
# Slither — static analysis (Trail of Bits)
# Detects reentrancy, access control, and common vulnerability patterns.
pip install slither-analyzer  # one-time install
slither . --foundry-out-directory out/

# Aderyn — static analysis (Cyfrin)
# Rust-based, fast. Generates report.md with categorized findings.
# Install: cargo install aderyn (or brew)
aderyn .

# Mythril — symbolic execution (ConsenSys)
# Explores execution paths to find reachable bugs. Slow but thorough.
pip install mythril  # one-time install
myth analyze src/AxonVault.sol \
  --solc-json mythril.config.json \
  --solv 0.8.25 \
  --execution-timeout 300

# Echidna — property-based fuzzer (Trail of Bits)
# Runs invariant tests from src/test/AxonVaultEchidna.sol.
# Install: brew install echidna
echidna . --contract AxonVaultEchidna --config echidna.yaml --test-mode property

# All static analyzers (shortcut)
make audit
```

Fuzz harness lives at `src/test/AxonVaultEchidna.sol` (in `src/` for crytic-compile compatibility).
It tests 6 invariants: balance conservation, setup completion, owner immutability, bot persistence,
relayer authorization, and version constancy. Medusa harness at `test/fuzz/AxonVaultFuzzHarness.sol`
tests 10 additional properties (requires Medusa >= 1.5.0; v1.3.0 has a `via_ir` bug).

---

## Deployment

### Prerequisites

1. **Install Foundry** — https://getfoundry.sh
2. **Get an RPC URL** — [Alchemy](https://alchemy.com) or [Infura](https://infura.io). Free tier is fine for testnet.
3. **Get a funded testnet wallet** — you need Base Sepolia ETH for gas. Faucets:
   - https://faucet.quicknode.com/base/sepolia
   - https://www.coinbase.com/faucets/base-ethereum-goerli-faucet

---

### Step 1 — Create your `.env`

```bash
cp .env.example .env
```

Edit `.env`:

```bash
# Your deployer wallet private key (testnet only — never use a mainnet key here)
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Optional: set to a Safe address on mainnet so the Safe owns contracts from block zero.
# On testnet you can leave this blank — the deployer becomes the owner.
OWNER_ADDRESS=

# RPC URLs
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY

# Etherscan/Basescan API key for contract verification
BASESCAN_API_KEY=YOUR_BASESCAN_KEY
```

> **Never commit `.env`** — it is in `.gitignore`.

---

### Step 2 — Deploy to Base Sepolia

```bash
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

You will see output like:

```
=== Axon Deployment ===
Chain ID   : 84532
Deployer   : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Owner      : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  (owner == deployer: true)

=== Deployed Addresses ===
RelayerRegistry : 0x5FbDB2315678afecb367f032d93F642f64180aa3
AxonVaultFactory: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

=== Verification ===
registry.owner()         : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
factory.owner()          : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
factory.relayerRegistry(): 0x5FbDB2315678afecb367f032d93F642f64180aa3
factory.vaultCount()     : 0
```

Save the two deployed addresses — you'll need them for the next step.

---

### Step 3 — Authorize the relayer

Once deployed, the registry has no authorized relayers yet. Add the relayer address:

```bash
REGISTRY_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3 \
RELAYER_ADDRESS=0xYourRelayerHotWallet \
forge script script/AddRelayer.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

You will see:

```
=== AddRelayer ===
Registry : 0x5FbDB2315678afecb367f032d93F642f64180aa3
Relayer  : 0xYourRelayerHotWallet
Authorized before: false
Authorized after : true
```

---

### Step 4 — Verify it works (optional sanity check)

Use `cast` to confirm state on-chain:

```bash
# Check relayer is authorized
cast call $REGISTRY_ADDRESS "isAuthorized(address)(bool)" $RELAYER_ADDRESS \
  --rpc-url $BASE_SEPOLIA_RPC_URL

# Check factory owner
cast call $FACTORY_ADDRESS "owner()(address)" \
  --rpc-url $BASE_SEPOLIA_RPC_URL

# Check vault count (should be 0)
cast call $FACTORY_ADDRESS "vaultCount()(uint256)" \
  --rpc-url $BASE_SEPOLIA_RPC_URL
```

---

## Mainnet Deployment

The commands are identical — swap the RPC URL and add `--ledger` to sign with a hardware wallet instead of a `.env` key. Set `OWNER_ADDRESS` to your Safe multisig so ownership lands on the Safe from block zero.

```bash
OWNER_ADDRESS=0xYourSafeMultisig \
forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --ledger \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

See [docs/deployment-mainnet.md] for the full mainnet checklist (audit sign-off, Safe setup, relayer key rotation).

---

## Deployed Addresses

| Network          | RelayerRegistry | AxonVaultFactory |
| ---------------- | --------------- | ---------------- |
| Base Sepolia     | —               | —                |
| Base Mainnet     | —               | —                |
| Arbitrum Sepolia | —               | —                |
| Arbitrum One     | —               | —                |

_Addresses will be filled in after each deployment._

## Links

- [Website](https://axonfi.xyz)
- [Dashboard](https://app.axonfi.xyz)
- [Documentation](https://axonfi.xyz/llms.txt)
- [npm — @axonfi/sdk](https://www.npmjs.com/package/@axonfi/sdk) (TypeScript SDK)
- [PyPI — axonfi](https://pypi.org/project/axonfi/) (Python SDK)
- [Examples](https://github.com/axonfi/examples)
- [Twitter/X — @axonfixyz](https://x.com/axonfixyz)
