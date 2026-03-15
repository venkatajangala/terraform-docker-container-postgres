#!/bin/bash
# Infisical Secret Fetching Utility Functions
# Source this file in your entrypoint scripts

set -e

# Global configuration
INFISICAL_HOST="${INFISICAL_HOST:-http://infisical:8020}"
INFISICAL_API_KEY="${INFISICAL_API_KEY}"
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID}"
INFISICAL_ENVIRONMENT="${INFISICAL_ENVIRONMENT:-dev}"
MAX_RETRIES=5
RETRY_DELAY=2

# ============================================================================
# Function: fetch_secret_from_infisical
# Description: Fetches a secret value from Infisical API with retry logic
# Arguments:
#   $1 - Secret key/name
# Returns:
#   Secret value on success, exits with error on failure
# ============================================================================
fetch_secret_from_infisical() {
  local secret_key=$1
  
  if [ -z "$INFISICAL_API_KEY" ]; then
    echo "ERROR: INFISICAL_API_KEY not set" >&2
    return 1
  fi
  
  if [ -z "$INFISICAL_PROJECT_ID" ]; then
    echo "ERROR: INFISICAL_PROJECT_ID not set" >&2
    return 1
  fi
  
  echo "Fetching secret from Infisical: $secret_key" >&2
  
  local attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    local response
    local http_code
    
    # Fetch secret from Infisical API
    response=$(curl -s -w "\n%{http_code}" -X GET \
      "${INFISICAL_HOST}/api/v1/secrets/${secret_key}" \
      -H "Authorization: Bearer ${INFISICAL_API_KEY}" \
      -H "X-Infisical-Project-ID: ${INFISICAL_PROJECT_ID}" \
      -H "X-Infisical-Environment: ${INFISICAL_ENVIRONMENT}" \
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
      echo "ERROR: Unauthorized - Check INFISICAL_API_KEY" >&2
      return 1
    elif [ "$http_code" = "404" ]; then
      echo "ERROR: Secret '$secret_key' not found in Infisical" >&2
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
  secret_value=$(fetch_secret_from_infisical "$secret_key" 2>/dev/null) || {
    echo "WARNING: Failed to fetch '$secret_key', using fallback value" >&2
    echo "$fallback_value"
    return 0
  }
  
  echo "$secret_value"
}

# ============================================================================
# Function: verify_infisical_connection
# Description: Verifies connectivity to Infisical service
# Returns:
#   0 if connected, 1 if not
# ============================================================================
verify_infisical_connection() {
  echo "Verifying Infisical connectivity..." >&2
  
  local response
  response=$(curl -s -X GET "${INFISICAL_HOST}/api/v1/health" 2>/dev/null) || {
    echo "ERROR: Cannot connect to Infisical at ${INFISICAL_HOST}" >&2
    return 1
  }
  
  if echo "$response" | grep -q "ok\|healthy"; then
    echo "Infisical is reachable and healthy" >&2
    return 0
  else
    echo "ERROR: Infisical returned unhealthy status" >&2
    return 1
  fi
}

# ============================================================================
# Function: list_secrets
# Description: Lists all available secrets in Infisical project
# Returns:
#   JSON array of secrets
# ============================================================================
list_secrets() {
  if [ -z "$INFISICAL_API_KEY" ] || [ -z "$INFISICAL_PROJECT_ID" ]; then
    echo "ERROR: INFISICAL_API_KEY and INFISICAL_PROJECT_ID must be set" >&2
    return 1
  fi
  
  curl -s -X GET \
    "${INFISICAL_HOST}/api/v1/secrets" \
    -H "Authorization: Bearer ${INFISICAL_API_KEY}" \
    -H "X-Infisical-Project-ID: ${INFISICAL_PROJECT_ID}" \
    -H "X-Infisical-Environment: ${INFISICAL_ENVIRONMENT}"
}

# ============================================================================
# Function: create_secret_in_infisical
# Description: Creates or updates a secret in Infisical
# Arguments:
#   $1 - Secret key/name
#   $2 - Secret value
# Returns:
#   0 on success, 1 on failure
# ============================================================================
create_secret_in_infisical() {
  local secret_key=$1
  local secret_value=$2
  
  if [ -z "$INFISICAL_API_KEY" ] || [ -z "$INFISICAL_PROJECT_ID" ]; then
    echo "ERROR: INFISICAL_API_KEY and INFISICAL_PROJECT_ID must be set" >&2
    return 1
  fi
  
  echo "Creating/updating secret in Infisical: $secret_key" >&2
  
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${INFISICAL_HOST}/api/v1/secrets" \
    -H "Authorization: Bearer ${INFISICAL_API_KEY}" \
    -H "X-Infisical-Project-ID: ${INFISICAL_PROJECT_ID}" \
    -H "X-Infisical-Environment: ${INFISICAL_ENVIRONMENT}" \
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

echo "Infisical secret utilities loaded successfully" >&2
