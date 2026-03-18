#!/bin/bash
set -euo pipefail

# Trap errors and signals
trap 'echo "ERROR: Patroni entrypoint failed"; exit 1' ERR
trap 'echo "Interrupted"; exit 130' INT TERM

# Add PostgreSQL binaries to PATH
export PATH="/usr/lib/postgresql/18/bin:$PATH"

echo "=== Starting Patroni PostgreSQL Node ==="

# ============================================================================
# SECTION 1: Infisical Secrets Integration
# ============================================================================

echo "Checking Infisical integration..."

if [ -f /etc/patroni/infisical-secrets.sh ]; then
  source /etc/patroni/infisical-secrets.sh
  
  if [ -n "${INFISICAL_API_KEY:-}" ] && [ -n "${INFISICAL_PROJECT_ID:-}" ]; then
    echo "Infisical integration enabled"
    
    if verify_infisical_connection 2>/dev/null; then
      echo "Fetching secrets from Infisical..."
      
      if POSTGRES_PASSWORD=$(fetch_secret_from_infisical "db-admin-password" 2>/dev/null); then
        echo "✓ Fetched db-admin-password from Infisical"
        export POSTGRES_PASSWORD
      else
        echo "⚠ Using environment db-admin-password"
      fi
      
      if REPLICATION_PASSWORD=$(fetch_secret_from_infisical "db-replication-password" 2>/dev/null); then
        echo "✓ Fetched db-replication-password from Infisical"
        export REPLICATION_PASSWORD
      else
        echo "⚠ Using environment db-replication-password"
      fi
    else
      echo "⚠ Infisical not reachable, using environment variables"
    fi
  else
    echo "ℹ Infisical not configured"
  fi
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
