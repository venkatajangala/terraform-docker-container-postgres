#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-8200}"
ROLE_NAME="${2:-pg-role}"
PG_USER="${3:-pgadmin}"
PG_PASS="${4:-}"
REPL_PASS="${5:-}"

VAULT_ADDR="${VAULT_ADDR:-http://localhost:$PORT}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

OUT_DIR=".vault-bootstrap"
mkdir -p "$OUT_DIR"

wait_for_vault() {
  local attempts=0
  local max=60
  echo "Waiting for Vault at ${VAULT_ADDR}/v1/sys/health..." >&2
  while [ $attempts -lt $max ]; do
    status=$(curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health" || true)
    if [ "$status" = "200" ] || [ "$status" = "429" ]; then
      echo "Vault is ready (HTTP $status)" >&2
      return 0
    fi
    attempts=$((attempts+1))
    sleep 2
  done
  echo "ERROR: Vault did not become ready after $((max*2))s" >&2
  return 1
}

_api() {
  local method="$1" path="$2" payload="$3"
  if [ -n "${VAULT_TOKEN}" ]; then
    curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" -X "$method" -d "$payload" "${VAULT_ADDR}/v1/$path"
  else
    curl -s -X "$method" -d "$payload" "${VAULT_ADDR}/v1/$path"
  fi
}

wait_for_vault

# Create policy "pg-role" allowing read/list to secret/data/pg/* and secret/data/pgbouncer/*
POLICY_NAME="pg-role"
POLICY_HCL=$(cat <<'EOF'
path "secret/data/pg/*" {
  capabilities = ["read", "list"]
}
path "secret/data/pgbouncer/*" {
  capabilities = ["read", "list"]
}
EOF
)

# Prepare JSON payload for policy (escape newlines)
POLICY_JSON=$(jq -nr --arg p "$POLICY_HCL" '{policy:$p}')

echo "Writing policy ${POLICY_NAME}..." >&2
_api POST sys/policies/acl/${POLICY_NAME} "${POLICY_JSON}"

# Enable AppRole auth method (idempotent)
echo "Enabling AppRole auth method..." >&2
_api POST sys/auth/approle "{\"type\":\"approle\"}"

# Create role bound to policy
echo "Creating AppRole role ${ROLE_NAME}..." >&2
_api POST auth/approle/role/${ROLE_NAME} "{\"policies\":[\"${POLICY_NAME}\"],\"secret_id_ttl\":\"24h\"}"

# Retrieve role_id
role_id=$(_api GET auth/approle/role/${ROLE_NAME}/role-id "" | jq -r '.data.role_id')
# Create secret_id
secret_id=$(_api POST auth/approle/role/${ROLE_NAME}/secret-id "{}" | jq -r '.data.secret_id')

# Seed KV v2 secrets
if [ -n "${PG_PASS}" ]; then
  echo "Seeding postgres credentials..." >&2
  payload=$(jq -n --arg u "${PG_USER}" --arg p "${PG_PASS}" '{data:{postgres_user:$u,postgres_password:$p}}')
  _api POST secret/data/pg/postgres "$payload"
fi

if [ -n "${REPL_PASS}" ]; then
  echo "Seeding replication credentials..." >&2
  payload=$(jq -n --arg r "${REPL_PASS}" '{data:{replication_password:$r}}')
  _api POST secret/data/pg/replication "$payload"
fi

# write role info to file
cat > "${OUT_DIR}/approle_${ROLE_NAME}.json" <<EOF
{ "role_id": "${role_id}", "secret_id": "${secret_id}" }
EOF
chmod 600 "${OUT_DIR}/approle_${ROLE_NAME}.json"

echo "Vault bootstrap complete. Role info written to ${OUT_DIR}/approle_${ROLE_NAME}.json" >&2

# Split JSON into plain-text files expected by vault/agent/agent.hcl auto_auth.
# agent.hcl needs /etc/vault/role/role_id and /etc/vault/role/secret_id as separate files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/vault-bootstrap-split.sh" "${ROLE_NAME}" >&2
