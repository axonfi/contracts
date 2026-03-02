#!/usr/bin/env bash
set -euo pipefail

# Deploy a vault via the factory and register it with the relayer.
#
# Usage:
#   ./script/deploy-vault.sh                          # defaults: Base Sepolia
#   FACTORY=0x... ./script/deploy-vault.sh             # custom factory
#   RELAYER_URL=https://relay.axonfi.xyz ./script/deploy-vault.sh
#
# Requires:
#   - PRIVATE_KEY in .env (deployer = vault owner)
#   - FACTORY or NEXT_PUBLIC_FACTORY_84532 in env / .env
#   - cast (Foundry) installed

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# Load .env
if [ -f .env ]; then
  set -a; source .env; set +a
fi

# ── Config ──────────────────────────────────────────────────────────────
RPC_URL="${RPC_URL:-https://sepolia.base.org}"
CHAIN_ID="${CHAIN_ID:-84532}"
RELAYER_URL="${RELAYER_URL:-http://localhost:3000}"

# Resolve factory address
if [ -z "${FACTORY:-}" ]; then
  # Use the LAST factory in the comma-separated list (newest)
  RAW="${NEXT_PUBLIC_FACTORY_84532:-}"
  if [ -z "$RAW" ]; then
    # Fall back to relayer env var
    RAW="${FACTORY_ADDRESS_84532:-}"
  fi
  if [ -z "$RAW" ]; then
    echo "ERROR: No factory address. Set FACTORY=0x... or NEXT_PUBLIC_FACTORY_84532 in .env"
    exit 1
  fi
  # Take last entry (newest factory)
  FACTORY=$(echo "$RAW" | tr ',' '\n' | tail -1 | tr -d ' ')
fi

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)

echo "=== Deploy Vault ==="
echo "Chain ID   : $CHAIN_ID"
echo "RPC        : $RPC_URL"
echo "Factory    : $FACTORY"
echo "Deployer   : $DEPLOYER"
echo ""

# ── TOS pre-flight check ───────────────────────────────────────────────
echo "Checking TOS acceptance for $DEPLOYER..."
TOS_RESPONSE=$(curl -s "$RELAYER_URL/v1/tos/status?wallet=$DEPLOYER" 2>&1)
TOS_ACCEPTED=$(echo "$TOS_RESPONSE" | jq -r '.accepted // "unknown"' 2>/dev/null)

if [ "$TOS_ACCEPTED" = "false" ]; then
  echo ""
  echo "ERROR: TOS not accepted for wallet $DEPLOYER"
  echo ""
  echo "The vault owner must accept the Terms of Service before deploying."
  echo "Accept via:"
  echo "  1. Dashboard: connect your wallet at https://app.axonfi.xyz"
  echo "  2. SDK:       client.acceptTos(signer, '$DEPLOYER')"
  echo ""
  echo "After accepting, re-run this script."
  exit 1
elif [ "$TOS_ACCEPTED" = "unknown" ]; then
  echo "WARNING: Could not check TOS status (relayer may be offline). Proceeding anyway..."
else
  echo "TOS accepted."
fi
echo ""

# ── Deploy ──────────────────────────────────────────────────────────────
echo "Deploying vault..."
TX_OUTPUT=$(cast send "$FACTORY" "deployVault()" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  --json 2>&1)

TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash')
STATUS=$(echo "$TX_OUTPUT" | jq -r '.status')

if [ "$STATUS" != "0x1" ] && [ "$STATUS" != "1" ]; then
  echo "ERROR: Transaction failed"
  echo "$TX_OUTPUT" | jq .
  exit 1
fi

# Extract vault address from VaultDeployed event (2nd log, topic[2] = vault address)
VAULT_RAW=$(echo "$TX_OUTPUT" | jq -r '.logs[1].topics[2]')
VAULT_ADDRESS="0x$(echo "$VAULT_RAW" | cut -c27-)"

# Verify VERSION
VERSION=$(cast call "$VAULT_ADDRESS" "VERSION()(uint16)" --rpc-url "$RPC_URL" 2>/dev/null)

echo ""
echo "=== Vault Deployed ==="
echo "Vault      : $VAULT_ADDRESS"
echo "VERSION    : $VERSION"
echo "TX         : $TX_HASH"

# ── Register with relayer ───────────────────────────────────────────────
echo ""
echo "Registering with relayer at $RELAYER_URL..."
REG_RESPONSE=$(curl -s -X POST "$RELAYER_URL/v1/metadata/register-vault" \
  -H "Content-Type: application/json" \
  -d "{\"chainId\":$CHAIN_ID,\"vaultAddress\":\"$VAULT_ADDRESS\",\"owner\":\"$DEPLOYER\"}" 2>&1)

REGISTERED=$(echo "$REG_RESPONSE" | jq -r '.registered // .error // "unknown"')

if [ "$REGISTERED" = "true" ]; then
  echo "Registered OK"
else
  echo "WARNING: Registration response: $REG_RESPONSE"
  echo "(Vault is deployed on-chain but may not appear in dashboard until registered)"
fi

echo ""
echo "=== Done ==="
echo "Dashboard   : https://app.axonfi.xyz/vaults/$VAULT_ADDRESS"
