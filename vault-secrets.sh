#!/bin/bash
# Vault Secret Fetching Utility Functions
# Source this file in entrypoint scripts to read secrets from Vault (supports VAULT_TOKEN and AppRole via role_id/secret_id)

set -e

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
# Use a vault-private variable so callers that set MAX_RETRIES (e.g. liquibase-entrypoint.sh
# sets MAX_RETRIES=30 for PgBouncer polling) do not inflate Vault HTTP retry counts.
VAULT_MAX_RETRIES="${VAULT_MAX_RETRIES:-5}"
RETRY_DELAY="${RETRY_DELAY:-2}"

# Internal helper: perform Vault HTTP GET with retries
_vault_get() {
  local path="$1"
  local attempt=1
  while [ $attempt -le $VAULT_MAX_RETRIES ]; do
    if [ -n "${VAULT_TOKEN}" ]; then
      response=$(curl -s -w "\n%{http_code}" -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/${path}" 2>/dev/null) || true
    else
      response=$(curl -s -w "\n%{http_code}" "${VAULT_ADDR}/v1/${path}" 2>/dev/null) || true
    fi

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
      echo "$body"
      return 0
    else
      echo "Attempt $attempt/$VAULT_MAX_RETRIES: Vault HTTP $http_code, retrying in ${RETRY_DELAY}s..." >&2
      attempt=$((attempt+1))
      sleep $RETRY_DELAY
    fi
  done
  return 1
}

# Fetch secret from KV v2 at path 'secret/data/<key>' and return the 'value' field
fetch_secret_from_vault() {
  local key="$1"
  if [ -z "$key" ]; then
    echo "ERROR: secret key required" >&2
    return 1
  fi

  # KV v2 read path
  local path="secret/data/${key}"
  body=$(_vault_get "$path") || return 1

  if command -v jq &>/dev/null; then
    # Try common locations
    echo "$body" | jq -r '.data.data.value // .data.data.value1 // .data.data.secret // empty' | sed -n '1p'
  else
    # Fallback: crude extraction
    echo "$body" | grep -o '"value"\s*:\s*"[^"]*"' | head -n1 | sed -E 's/"value"\s*:\s*"(.*)"/\1/'
  fi
}

fetch_secret_safe() {
  local key="$1"
  local fallback="$2"
  val=$(fetch_secret_from_vault "$key" 2>/dev/null) || {
    echo "WARNING: failed to fetch $key, using fallback" >&2
    echo "$fallback"
    return 0
  }
  echo "$val"
}

verify_vault_connection() {
  echo "Verifying Vault connectivity..." >&2
  status_code=$(curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health") || true
  if [ "$status_code" = "200" ] || [ "$status_code" = "429" ]; then
    echo "Vault reachable (HTTP $status_code)" >&2
    return 0
  fi
  echo "ERROR: Vault not reachable (HTTP $status_code)" >&2
  return 1
}

# Create or update secret at KV v2 path 'secret/data/<key>' with {"value": "..."}
create_secret_in_vault() {
  local key="$1"
  local value="$2"
  if [ -z "$key" ] || [ -z "$value" ]; then
    echo "ERROR: key and value required" >&2
    return 1
  fi

  payload=$(jq -n --arg v "$value" '{data:{value:$v}}')
  if [ -n "${VAULT_TOKEN}" ]; then
    curl -s -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" -d "$payload" "${VAULT_ADDR}/v1/secret/data/${key}" > /dev/null
  else
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "${VAULT_ADDR}/v1/secret/data/${key}" > /dev/null
  fi
}


# Login using AppRole: set VAULT_TOKEN to the client token returned
login_with_approle() {
  local role_id="$1"
  local secret_id="$2"
  if [ -z "$role_id" ] || [ -z "$secret_id" ]; then
    echo "ERROR: role_id and secret_id required" >&2
    return 1
  fi
  payload=$(jq -n --arg r "$role_id" --arg s "$secret_id" '{role_id:$r, secret_id:$s}')
  response=$(curl -s -X POST -H "Content-Type: application/json" -d "$payload" "${VAULT_ADDR}/v1/auth/approle/login") || true
  token=$(echo "$response" | jq -r '.auth.client_token // empty')
  if [ -n "$token" ]; then
    VAULT_TOKEN="$token"
    export VAULT_TOKEN
    echo "Logged in via AppRole, token acquired" >&2
    return 0
  fi
  echo "ERROR: failed to login with AppRole" >&2
  return 1
}

# Convenience: fetch a specific field from a KV v2 secret (eg. key=pg/postgres, field=postgres_password)
fetch_secret_field() {
  local key="$1"
  local field="$2"
  if [ -z "$key" ]; then
    echo "ERROR: key required" >&2
    return 1
  fi
  local path="secret/data/${key}"
  body=$(_vault_get "$path") || return 1
  if command -v jq &>/dev/null; then
    if [ -n "$field" ]; then
      echo "$body" | jq -r --arg f "$field" '.data.data[$f] // empty' | sed -n '1p'
    else
      echo "$body" | jq -r '.data.data.postgres_password // .data.data.postgres_user // .data.data.replication_password // .data.data.value // .data.data.secret // empty' | sed -n '1p'
    fi
  else
    echo "$body" | grep -o '"value"\s*:\s*"[^\"]*"' | head -n1 | sed -E 's/"value"\s*:\s*"(.*)"/\1/'
  fi
}

echo "Vault secret utilities loaded" >&2
