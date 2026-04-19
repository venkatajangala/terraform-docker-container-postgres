#!/bin/bash
# ============================================================================
# Liquibase Entrypoint - Wait for Primary PostgreSQL and Run Migrations
# ============================================================================

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# Configuration
# ============================================================================

DB_HOST="${DB_HOST:-pgbouncer-1}"
DB_PORT="${DB_PORT:-6432}"
DB_NAME="${DB_NAME:-postgres_liquibase}"
DB_USER="${DB_USER:-pgadmin}"
DB_PASSWORD="${DB_PASSWORD:-}"
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"

# Try to source Vault for DB credentials
if [ -f /etc/vault/vault-secrets.sh ]; then
  source /etc/vault/vault-secrets.sh
elif [ -f /vault-secrets.sh ]; then
  source /vault-secrets.sh
fi

# If Vault Agent rendered file exists, load and map to LIQUIBASE_PASSWORD
if [ -f /etc/vault/secrets/postgres.env ]; then
  set -a
  source /etc/vault/secrets/postgres.env
  set +a
  if [ -n "${POSTGRES_PASSWORD:-}" ]; then
    DB_PASSWORD="$POSTGRES_PASSWORD"
    export DB_PASSWORD
    LIQUIBASE_PASSWORD="$DB_PASSWORD"
    export LIQUIBASE_PASSWORD
    echo "Loaded Liquibase DB password from /etc/vault/secrets/postgres.env"
  fi
fi

if command -v verify_vault_connection >/dev/null 2>&1; then
  # Attempt AppRole login if possible
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
    # Fetch into a local var so we never clobber DB_PASSWORD with an empty string
    # if the secret path doesn't exist yet (race with vault-bootstrap.sh).
    _vault_pw=$(fetch_secret_field "pg/postgres" "postgres_password" 2>/dev/null) || true
    if [ -n "$_vault_pw" ]; then
      DB_PASSWORD="$_vault_pw"
      LIQUIBASE_PASSWORD="$DB_PASSWORD"
      export DB_PASSWORD LIQUIBASE_PASSWORD
      echo "Fetched Liquibase DB password from Vault"
    fi
    unset _vault_pw
  fi
fi

LIQUIBASE_DRIVER="org.postgresql.Driver"
LIQUIBASE_USERNAME="${DB_USER}"
LIQUIBASE_PASSWORD="${DB_PASSWORD}"
LIQUIBASE_CHANGELOG_DIR="/liquibase/changelog"
LIQUIBASE_CHANGELOG_FILE="db.changelog-master.yml"

# Patroni API port used by all nodes inside the Docker network
PATRONI_PORT="${PATRONI_PORT:-8008}"
# Space-separated list of all cluster node names
PATRONI_NODES="${PATRONI_NODES:-pg-node-1 pg-node-2 pg-node-3}"

# ============================================================================
# discover_primary — query each node's Patroni REST API to find the leader.
# Sets PG_PRIMARY_HOST (node name) and PG_PRIMARY_PORT (5432).
# Retries for up to MAX_RETRIES * RETRY_INTERVAL seconds.
# ============================================================================

discover_primary() {
  log_info "Discovering Patroni primary via REST API (nodes: ${PATRONI_NODES})..."

  local attempt=1
  while [ $attempt -le "$MAX_RETRIES" ]; do
    for node in $PATRONI_NODES; do
      local http_code
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://${node}:${PATRONI_PORT}/leader" 2>/dev/null || echo "000")
      if [ "$http_code" = "200" ]; then
        log_info "Primary discovered: ${node} (Patroni /leader → HTTP 200)"
        PG_PRIMARY_HOST="$node"
        PG_PRIMARY_PORT=5432
        return 0
      fi
    done

    log_warn "Attempt ${attempt}/${MAX_RETRIES}: No primary found yet, retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
    ((attempt++))
  done

  log_error "Could not discover a Patroni primary after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
  return 1
}

# ============================================================================
# Wait for the discovered primary's PostgreSQL port to accept connections
# ============================================================================

wait_for_postgres() {
  log_info "Waiting for PostgreSQL on ${PG_PRIMARY_HOST}:${PG_PRIMARY_PORT}..."

  local attempt=1
  while [ $attempt -le "$MAX_RETRIES" ]; do
    if pg_isready -h "$PG_PRIMARY_HOST" -p "$PG_PRIMARY_PORT" -U "$DB_USER" -d postgres &>/dev/null; then
      log_info "PostgreSQL primary is accepting connections"
      return 0
    fi

    log_warn "Attempt ${attempt}/${MAX_RETRIES}: PostgreSQL not ready yet, retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
    ((attempt++))
  done

  log_error "PostgreSQL primary did not accept connections after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
  return 1
}

# ============================================================================
# Verify Changelog File Exists
# ============================================================================

verify_changelog() {
  if [ ! -f "$LIQUIBASE_CHANGELOG_DIR/$LIQUIBASE_CHANGELOG_FILE" ]; then
    log_error "Changelog file not found: $LIQUIBASE_CHANGELOG_DIR/$LIQUIBASE_CHANGELOG_FILE"
    log_info "Available files in $LIQUIBASE_CHANGELOG_DIR:"
    ls -la "$LIQUIBASE_CHANGELOG_DIR/" || true
    return 1
  fi
  log_info "Changelog file verified: $LIQUIBASE_CHANGELOG_DIR/$LIQUIBASE_CHANGELOG_FILE"
  return 0
}

# ============================================================================
# Run Liquibase Migrations
# ============================================================================

run_liquibase() {
  log_info "Starting Liquibase migrations..."

  cd "$LIQUIBASE_CHANGELOG_DIR"

  # Resolve actual PostgreSQL JDBC driver path (lpm installs to internal/lib, manual download to lib/)
  local pg_jar
  pg_jar=$(ls /liquibase/lib/postgresql*.jar 2>/dev/null | head -1)
  if [ -z "$pg_jar" ]; then
    pg_jar=$(ls /liquibase/internal/lib/postgresql*.jar 2>/dev/null | head -1)
  fi

  log_info "Liquibase configuration:"
  log_info "  URL: $LIQUIBASE_URL"
  log_info "  Username: $LIQUIBASE_USERNAME"
  log_info "  Changelog: $LIQUIBASE_CHANGELOG_FILE"
  log_info "  JDBC Driver: ${pg_jar:-auto-detected}"

  # Override/unset env var so LiquibaseLauncher doesn't try to expand the glob
  unset LIQUIBASE_CLASSPATH
  [ -n "$pg_jar" ] && export LIQUIBASE_CLASSPATH="$pg_jar"

  # Run liquibase update — pass all connection params as CLI args (Liquibase 5.x compatible)
  if PGPASSWORD="$LIQUIBASE_PASSWORD" liquibase \
      --url="$LIQUIBASE_URL" \
      --username="$LIQUIBASE_USERNAME" \
      --password="$LIQUIBASE_PASSWORD" \
      --driver="$LIQUIBASE_DRIVER" \
      --changeLogFile="$LIQUIBASE_CHANGELOG_FILE" \
      update; then
    log_info "Liquibase migrations completed successfully"
    return 0
  else
    log_error "Liquibase migrations failed"
    return 1
  fi
}

# ============================================================================
# Main Flow
# ============================================================================

main() {
  log_info "Liquibase Migration Container Started"

  # Step 1 — find which node is currently the Patroni leader
  discover_primary || exit 1

  # Step 2 — wait for that node's PostgreSQL port to be ready
  wait_for_postgres || exit 1

  # Step 3 — build the JDBC URL pointing directly at the primary (not PgBouncer)
  LIQUIBASE_URL="jdbc:postgresql://${PG_PRIMARY_HOST}:${PG_PRIMARY_PORT}/postgres"

  verify_changelog || exit 1
  run_liquibase || exit 1

  log_info "All migration tasks completed successfully"
  
  # Keep container running if needed
  if [ "$1" == "sleep" ]; then
    log_info "Keeping container alive (sleep mode)"
    tail -f /dev/null
  fi
}

main "$@"
