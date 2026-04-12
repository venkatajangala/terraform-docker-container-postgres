#!/bin/bash
set -euo pipefail

# Trap errors and signals
trap 'echo "ERROR: Patroni entrypoint failed"; exit 1' ERR
trap 'echo "Interrupted"; exit 130' INT TERM

# Add PostgreSQL binaries to PATH
export PATH="/usr/lib/postgresql/18/bin:$PATH"

echo "=== Starting Patroni PostgreSQL Node ==="

# ============================================================================
# SECTION 1: Vault Secrets Integration
# ============================================================================

echo "Checking Vault integration..."

# Source vault helper if present (common paths)
if [ -f /etc/vault/vault-secrets.sh ]; then
  source /etc/vault/vault-secrets.sh
elif [ -f /vault-secrets.sh ]; then
  source /vault-secrets.sh
fi

# If Vault Agent rendered file exists, load and export variables as env
if [ -f /etc/vault/secrets/postgres.env ]; then
  set -a
  source /etc/vault/secrets/postgres.env
  set +a
  echo "Loaded /etc/vault/secrets/postgres.env"
fi

if command -v verify_vault_connection >/dev/null 2>&1; then
  # Attempt AppRole login via env vars or mounted approle file
  if [ -n "${VAULT_ROLE_ID:-}" ] && [ -n "${VAULT_SECRET_ID:-}" ]; then
    login_with_approle "$VAULT_ROLE_ID" "$VAULT_SECRET_ID" || true
  elif [ -f /etc/vault/approle_pg-role.json ]; then
    if command -v jq >/dev/null 2>&1; then
      role_id=$(jq -r '.role_id' /etc/vault/approle_pg-role.json)
      secret_id=$(jq -r '.secret_id' /etc/vault/approle_pg-role.json)
      login_with_approle "$role_id" "$secret_id" || true
    fi
  fi

  if verify_vault_connection 2>/dev/null; then
    echo "Fetching secrets from Vault..."

    if POSTGRES_PASSWORD=$(fetch_secret_field "pg/postgres" "postgres_password" 2>/dev/null); then
      echo "✓ Fetched db-admin-password from Vault"
      export POSTGRES_PASSWORD
    else
      echo "⚠ Using environment db-admin-password"
    fi

    if REPLICATION_PASSWORD=$(fetch_secret_field "pg/replication" "replication_password" 2>/dev/null); then
      echo "✓ Fetched db-replication-password from Vault"
      export REPLICATION_PASSWORD
    else
      echo "⚠ Using environment db-replication-password"
    fi
  else
    echo "⚠ Vault not reachable, using environment variables"
  fi
else
  echo "ℹ Vault helper not present"
fi

# Validate required passwords
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  echo "ERROR: POSTGRES_PASSWORD not set" >&2
  exit 1
fi

if [ -z "${REPLICATION_PASSWORD:-}" ]; then
  echo "ERROR: REPLICATION_PASSWORD not set" >&2
  exit 1
fi

# ============================================================================
# SECTION 2: Wait for etcd DCS
# ============================================================================

echo "Waiting for etcd service..."
max_attempts=30
attempt=0
until curl -s http://etcd:2379/version > /dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -gt $max_attempts ]; then
    echo "ERROR: etcd failed to start after $max_attempts attempts" >&2
    exit 1
  fi
  echo "  Attempt $attempt/$max_attempts..."
  sleep 2
done
echo "✓ etcd is ready"

# ============================================================================
# SECTION 3: PostgreSQL Directory Setup
# ============================================================================

echo "Setting up PostgreSQL directories..."
mkdir -p /var/lib/postgresql/18/main
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql
chmod 700 /var/lib/postgresql/18/main
chmod 755 /var/lib/postgresql
chmod 755 /var/lib/postgresql/18
chmod 777 /var/run/postgresql 2>/dev/null || true

# ============================================================================
# SECTION 4: Verify initdb Wrapper Exists (from Dockerfile)
# ============================================================================

if [ ! -f /usr/lib/postgresql/18/bin/initdb.real ]; then
  echo "ERROR: initdb wrapper must be set up in Dockerfile" >&2
  exit 1
fi

# ============================================================================
# SECTION 5: Initialize pgBackRest
# ============================================================================

if [ ! -f /etc/pgbackrest/.initialized ]; then
  echo "Initializing pgBackRest..."
  mkdir -p /etc/pgbackrest
  mkdir -p /var/lib/pgbackrest
  mkdir -p /var/log/pgbackrest
  chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest
  touch /etc/pgbackrest/.initialized
  echo "✓ pgBackRest initialized"
fi

# ============================================================================
# SECTION 6: Final Permission Check
# ============================================================================

echo "Enforcing PostgreSQL permissions..."
chmod 700 /var/lib/postgresql/18/main
chmod 755 /var/lib/postgresql
chmod 755 /var/lib/postgresql/18
chmod 777 /var/run/postgresql 2>/dev/null || true

# ============================================================================
# SECTION 7: Execute Patroni
# ============================================================================

echo "Starting Patroni..."
exec sudo -u postgres env PATH="$PATH" "$@"
