#!/bin/bash
# Vault Secret Fetching Utility Functions
# Source this file in your entrypoint scripts

set -euo pipefail

# Global configuration with safe defaults
Vault_ENABLED="${Vault_ENABLED:-false}"
Vault_HOST="${Vault_HOST:-http://vault:8020}"
Vault_API_KEY="${Vault_API_KEY:-}"
Vault_PROJECT_ID="${Vault_PROJECT_ID:-}"
Vault_ENVIRONMENT="${Vault_ENVIRONMENT:-dev}"
MAX_RETRIES=5
RETRY_DELAY=2

# If Vault is disabled, define no-op fallback functions so sourcing this file is safe
if [ "${Vault_ENABLED}" != "true" ]; then
  echo "Vault disabled via Vault_ENABLED=${Vault_ENABLED}" >&2
  fetch_secret_from_vault() { echo "ERROR: Vault disabled" >&2; return 1; }
  fetch_secret_safe() { echo "$2"; return 0; }
  verify_vault_connection() { return 1; }
  list_secrets() { echo "[]"; return 0; }
  create_secret_in_vault() { echo "ERROR: Vault disabled" >&2; return 1; }
fi

# ============================================================================
# Function: fetch_secret_from_vault
# Description: Fetches a secret value from Vault API with retry logic
# Arguments:
#   $1 - Secret key/name
# Returns:
#   Secret value on success, exits with error on failure
# ============================================================================
fetch_secret_from_vault() {
  local secret_key=$1
  
  if [ -z "$Vault_API_KEY" ]; then
    echo "ERROR: Vault_API_KEY not set" >&2
    return 1
  fi
  
  if [ -z "$Vault_PROJECT_ID" ]; then
    echo "ERROR: Vault_PROJECT_ID not set" >&2
    return 1
  fi
  
  echo "Fetching secret from Vault: $secret_key" >&2
  
  local attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    local response
    local http_code
    
    # Fetch secret from Vault API
    response=$(curl -s -w "\n%{http_code}" -X GET \
      "${Vault_HOST}/api/v1/secrets/${secret_key}" \
      -H "Authorization: Bearer ${Vault_API_KEY}" \
      -H "X-Vault-Project-ID: ${Vault_PROJECT_ID}" \
      -H "X-Vault-Environment: ${Vault_ENVIRONMENT}" \
      2>/dev/null)
    
    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "200" ]; then
      # Extract secret value using jq or grep+awk
      if command -v jq &> /dev/null; then
        echo "$body" | jq -r '.secret.value // .value'
      else
        # Fallback if jq is not available
        echo "$body" | grep -o '"value":"[^"]*' | cut -d'"' -f4
      fi
      return 0
    elif [ "$http_code" = "401" ]; then
      echo "ERROR: Unauthorized - Check Vault_API_KEY" >&2
      return 1
    elif [ "$http_code" = "404" ]; then
      echo "ERROR: Secret '$secret_key' not found in Vault" >&2
      return 1
    else
      echo "Attempt $attempt/$MAX_RETRIES: HTTP $http_code, retrying in ${RETRY_DELAY}s..." >&2
      attempt=$((attempt + 1))
      sleep $RETRY_DELAY
    fi
  done
  
  echo "ERROR: Failed to fetch secret after $MAX_RETRIES attempts" >&2
  return 1
}

# ============================================================================
# Function: fetch_secret_safe
# Description: Fetches a secret with default fallback value
# Arguments:
#   $1 - Secret key/name
#   $2 - Fallback value (used if fetch fails)
# Returns:
#   Secret value on success, fallback value on failure (does not exit)
# ============================================================================
fetch_secret_safe() {
  local secret_key=$1
  local fallback_value=$2
  
  local secret_value
  secret_value=$(fetch_secret_from_vault "$secret_key" 2>/dev/null) || {
    echo "WARNING: Failed to fetch '$secret_key', using fallback value" >&2
    echo "$fallback_value"
    return 0
  }
  
  echo "$secret_value"
}

# ============================================================================
# Function: verify_vault_connection
# Description: Verifies connectivity to Vault service
# Returns:
#   0 if connected, 1 if not
# ============================================================================
verify_vault_connection() {
  echo "Verifying Vault connectivity..." >&2
  
  local response
  response=$(curl -s -X GET "${Vault_HOST}/api/status" 2>/dev/null) || {
    echo "ERROR: Cannot connect to Vault at ${Vault_HOST}" >&2
    return 1
  }
  
  if echo "$response" | grep -q "ok\|healthy"; then
    echo "Vault is reachable and healthy" >&2
    return 0
  else
    echo "ERROR: Vault returned unhealthy status" >&2
    return 1
  fi
}

# ============================================================================
# Function: list_secrets
# Description: Lists all available secrets in Vault project
# Returns:
#   JSON array of secrets
# ============================================================================
list_secrets() {
  if [ -z "$Vault_API_KEY" ] || [ -z "$Vault_PROJECT_ID" ]; then
    echo "ERROR: Vault_API_KEY and Vault_PROJECT_ID must be set" >&2
    return 1
  fi
  
  curl -s -X GET \
    "${Vault_HOST}/api/v1/secrets" \
    -H "Authorization: Bearer ${Vault_API_KEY}" \
    -H "X-Vault-Project-ID: ${Vault_PROJECT_ID}" \
    -H "X-Vault-Environment: ${Vault_ENVIRONMENT}"
}

# ============================================================================
# Function: create_secret_in_vault
# Description: Creates or updates a secret in Vault
# Arguments:
#   $1 - Secret key/name
#   $2 - Secret value
# Returns:
#   0 on success, 1 on failure
# ============================================================================
create_secret_in_vault() {
  local secret_key=$1
  local secret_value=$2
  
  if [ -z "$Vault_API_KEY" ] || [ -z "$Vault_PROJECT_ID" ]; then
    echo "ERROR: Vault_API_KEY and Vault_PROJECT_ID must be set" >&2
    return 1
  fi
  
  echo "Creating/updating secret in Vault: $secret_key" >&2
  
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${Vault_HOST}/api/v1/secrets" \
    -H "Authorization: Bearer ${Vault_API_KEY}" \
    -H "X-Vault-Project-ID: ${Vault_PROJECT_ID}" \
    -H "X-Vault-Environment: ${Vault_ENVIRONMENT}" \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"${secret_key}\", \"value\": \"${secret_value}\"}" \
    2>/dev/null)
  
  local http_code=$(echo "$response" | tail -n1)
  
  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    echo "Secret '$secret_key' created/updated successfully" >&2
    return 0
  else
    echo "ERROR: Failed to create secret '$secret_key' (HTTP $http_code)" >&2
    return 1
  fi
}

# ============================================================================
# Function: generate_secure_password
# Description: Generates a cryptographically secure password
# Arguments:
#   $1 - Password length (default: 32)
# Returns:
#   Generated password
# ============================================================================
generate_secure_password() {
  local length=${1:-32}
  
  # Try using openssl (preferred)
  if command -v openssl &> /dev/null; then
    openssl rand -base64 "$length" | tr -d '=+/' | cut -c1-"$length"
  # Fallback to /dev/urandom
  elif [ -c /dev/urandom ]; then
    head -c "$length" /dev/urandom | base64 | tr -d '=+/' | cut -c1-"$length"
  # Last resort: use date/pid
  else
    date +%s%N | md5sum | head -c "$length"
  fi
}

echo "Vault secret utilities loaded successfully" >&2
