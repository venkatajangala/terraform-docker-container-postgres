#!/usr/bin/env bash
# vault-bootstrap.sh
# Initialises and unseals Vault (server mode), then seeds AppRole + KV secrets.
#
# Run automatically by null_resource.vault_init (Terraform local-exec).
# Safe to re-run: init and AppRole setup are idempotent.
#
# On first run:
#   - Initialises Vault (5 key shares, threshold 3)
#   - Writes keys + root token to .vault-bootstrap/vault-init.json (chmod 600)
#   - Unseals with the first 3 keys
# On subsequent runs (e.g. after container restart):
#   - Skips init (already initialised)
#   - Re-unseals from the saved init file if still sealed
#
# Usage (called by Terraform, but can also be run manually):
#   VAULT_ADDR=http://localhost:8200 bash vault-bootstrap.sh [port] [role] [pg_user] [pg_pass] [repl_pass]
set -euo pipefail

PORT="${1:-8200}"
ROLE_NAME="${2:-pg-role}"
PG_USER="${3:-pgadmin}"
PG_PASS="${4:-}"
REPL_PASS="${5:-}"

VAULT_ADDR="${VAULT_ADDR:-http://localhost:$PORT}"
# VAULT_TOKEN is set dynamically by init_and_unseal() below; do NOT pre-set it
# from a static variable — that was the dev-mode pattern.
VAULT_TOKEN=""

OUT_DIR=".vault-bootstrap"
INIT_FILE="${OUT_DIR}/vault-init.json"
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# wait_for_vault — blocks until the Vault API responds.
# Accepts HTTP 200 (active), 429 (standby), 501 (not initialised), and
# 503 (sealed) as "process is up" signals.
# ---------------------------------------------------------------------------
wait_for_vault() {
  local attempts=0 max=60
  echo "Waiting for Vault at ${VAULT_ADDR}/v1/sys/health ..." >&2
  while [ $attempts -lt $max ]; do
    # Accept 200 (active), 429 (standby), 501 (not initialised), 503 (sealed)
    # — all mean the Vault process is up and the API is responding.
    # Do NOT embed & in the URL here; the shell would background the curl call
    # inside $() and status would be empty.
    status=$(curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health" || true)
    case "$status" in
      200|429|501|503)
        echo "Vault API is up (HTTP $status)" >&2
        return 0
        ;;
    esac
    attempts=$((attempts + 1))
    sleep 2
  done
  echo "ERROR: Vault did not respond after $((max * 2))s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# init_and_unseal — initialises Vault on first run, then unseals.
# Sets the global VAULT_TOKEN to the root token.
# ---------------------------------------------------------------------------
init_and_unseal() {
  local initialized
  initialized=$(curl -s "${VAULT_ADDR}/v1/sys/init" | jq -r '.initialized')

  if [ "$initialized" != "true" ]; then
    echo "Initialising Vault (5 shares, threshold 3) ..." >&2
    local init_output
    init_output=$(curl -s -X PUT \
      -d '{"secret_shares":5,"secret_threshold":3}' \
      "${VAULT_ADDR}/v1/sys/init")

    # Persist keys + root token with restricted permissions
    printf '%s\n' "$init_output" > "$INIT_FILE"
    chmod 600 "$INIT_FILE"
    echo "Init output written to ${INIT_FILE} (chmod 600 — never commit this file)" >&2
  else
    echo "Vault already initialised." >&2
  fi

  # Always reload the token from the saved file so re-runs work correctly
  if [ ! -f "$INIT_FILE" ]; then
    echo "ERROR: ${INIT_FILE} missing. Cannot unseal without the unseal keys." >&2
    echo "       If you lost the keys, destroy the vault-data volume and re-deploy." >&2
    return 1
  fi

  VAULT_TOKEN=$(jq -r '.root_token' "$INIT_FILE")

  # Unseal if currently sealed
  local sealed
  sealed=$(curl -s "${VAULT_ADDR}/v1/sys/seal-status" | jq -r '.sealed')
  if [ "$sealed" = "true" ]; then
    echo "Vault is sealed — unsealing with saved keys ..." >&2
    for i in 0 1 2; do
      local key
      key=$(jq -r ".keys[$i]" "$INIT_FILE")
      curl -s -X PUT -d "{\"key\":\"${key}\"}" "${VAULT_ADDR}/v1/sys/unseal" > /dev/null
    done
    echo "Vault unsealed." >&2
  else
    echo "Vault is already unsealed." >&2
  fi
}

# ---------------------------------------------------------------------------
# wait_for_active — blocks until Vault is active (HTTP 200 on /sys/health).
# Must be called after init_and_unseal so AppRole APIs are reachable.
# ---------------------------------------------------------------------------
wait_for_active() {
  local attempts=0 max=30
  echo "Waiting for Vault to reach active state (HTTP 200)..." >&2
  while [ $attempts -lt $max ]; do
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health" || true)
    if [ "$status" = "200" ]; then
      echo "Vault is active (HTTP 200)" >&2
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  echo "ERROR: Vault did not reach active state after $((max * 2))s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _api — authenticated Vault API helper
# Usage: _api METHOD path [json_payload]
# Omit payload (or pass empty string) for GET requests — no -d flag is sent.
# ---------------------------------------------------------------------------
_api() {
  local method="$1" path="$2" payload="${3:-}"
  if [ -n "$payload" ]; then
    curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
         -X "$method" \
         -d "$payload" \
         "${VAULT_ADDR}/v1/$path"
  else
    curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
         -X "$method" \
         "${VAULT_ADDR}/v1/$path"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
wait_for_vault
init_and_unseal
wait_for_active

# Enable KV v2 secrets engine (idempotent — ignore "already enabled" error)
echo "Enabling KV v2 secrets engine at secret/ ..." >&2
_api POST sys/mounts/secret '{"type":"kv","options":{"version":"2"}}' > /dev/null || true

# Create AppRole policy allowing read access to pg/* and pgbouncer/* paths
POLICY_HCL=$(cat <<'EOF'
path "secret/data/pg/*" {
  capabilities = ["read", "list"]
}
path "secret/data/pgbouncer/*" {
  capabilities = ["read", "list"]
}
EOF
)
POLICY_JSON=$(jq -nr --arg p "$POLICY_HCL" '{policy:$p}')
echo "Writing policy ${ROLE_NAME} ..." >&2
_api POST "sys/policies/acl/${ROLE_NAME}" "$POLICY_JSON" > /dev/null

# Enable AppRole auth method (idempotent)
echo "Enabling AppRole auth method ..." >&2
_api POST sys/auth/approle '{"type":"approle"}' > /dev/null || true

# Create / update the AppRole role bound to the policy
echo "Creating AppRole role ${ROLE_NAME} ..." >&2
_api POST "auth/approle/role/${ROLE_NAME}" \
    "{\"policies\":[\"${ROLE_NAME}\"],\"secret_id_ttl\":\"24h\"}" > /dev/null

# Retrieve role_id — retry up to 10 times in case Raft hasn't committed the role yet
role_id=""
for _try in $(seq 1 10); do
  role_id=$(_api GET "auth/approle/role/${ROLE_NAME}/role-id" "" | jq -r '.data.role_id // empty')
  [ -n "$role_id" ] && break
  echo "role_id not available yet (attempt ${_try}/10), waiting 2s..." >&2
  sleep 2
done
if [ -z "$role_id" ]; then
  echo "ERROR: failed to retrieve role_id after 10 attempts — Vault AppRole setup incomplete." >&2
  exit 1
fi

# Generate a new secret_id — same retry guard
secret_id=""
for _try in $(seq 1 10); do
  secret_id=$(_api POST "auth/approle/role/${ROLE_NAME}/secret-id" "{}" | jq -r '.data.secret_id // empty')
  [ -n "$secret_id" ] && break
  echo "secret_id generation failed (attempt ${_try}/10), waiting 2s..." >&2
  sleep 2
done
if [ -z "$secret_id" ]; then
  echo "ERROR: failed to generate secret_id after 10 attempts." >&2
  exit 1
fi

# Seed KV v2 secrets
if [ -n "${PG_PASS}" ]; then
  echo "Seeding postgres credentials ..." >&2
  payload=$(jq -n --arg u "${PG_USER}" --arg p "${PG_PASS}" \
    '{data:{postgres_user:$u,postgres_password:$p}}')
  _api POST secret/data/pg/postgres "$payload" > /dev/null
fi

if [ -n "${REPL_PASS}" ]; then
  echo "Seeding replication credentials ..." >&2
  payload=$(jq -n --arg r "${REPL_PASS}" '{data:{replication_password:$r}}')
  _api POST secret/data/pg/replication "$payload" > /dev/null
fi

# Write AppRole credentials for vault-agent
cat > "${OUT_DIR}/approle_${ROLE_NAME}.json" <<EOF
{ "role_id": "${role_id}", "secret_id": "${secret_id}" }
EOF
chmod 600 "${OUT_DIR}/approle_${ROLE_NAME}.json"

echo "Vault bootstrap complete. AppRole credentials: ${OUT_DIR}/approle_${ROLE_NAME}.json" >&2
echo "Root token and unseal keys:                    ${INIT_FILE}" >&2
echo "" >&2
echo "  IMPORTANT: Back up ${INIT_FILE} securely. If lost and the" >&2
echo "  container restarts, Vault cannot be unsealed automatically." >&2

# Split AppRole JSON into separate role_id / secret_id files for vault-agent
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/vault-bootstrap-split.sh" "${ROLE_NAME}" >&2
