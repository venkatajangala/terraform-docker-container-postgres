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

# Health-check DB: use the postgres_liquibase session pool (routes to pg-node-1 only)
# This ensures pg_is_in_recovery() checks the designated primary, not a round-robin replica
DB_HEALTH_NAME="${DB_NAME}"

LIQUIBASE_DRIVER="org.postgresql.Driver"
LIQUIBASE_URL="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}"
LIQUIBASE_USERNAME="${DB_USER}"
LIQUIBASE_PASSWORD="${DB_PASSWORD}"
LIQUIBASE_CHANGELOG_DIR="/liquibase/changelog"
LIQUIBASE_CHANGELOG_FILE="db.changelog-master.yml"

# ============================================================================
# Wait for PostgreSQL to be ready
# ============================================================================

wait_for_postgres() {
  log_info "Waiting for PgBouncer at ${DB_HOST}:${DB_PORT}..."

  local attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_HEALTH_NAME" &>/dev/null; then
      log_info "PgBouncer is ready!"
      return 0
    fi

    log_warn "Attempt $attempt/$MAX_RETRIES: PgBouncer not ready, retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
    ((attempt++))
  done

  log_error "PgBouncer did not become ready after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
  return 1
}

# ============================================================================
# Wait for Patroni primary (via PgBouncer session pool)
# ============================================================================

wait_for_patroni_primary() {
  log_info "Waiting for PostgreSQL primary to be available via PgBouncer..."

  local attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    # PgBouncer routes to primary; pg_is_in_recovery() must return 'f'
    if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" \
        -U "$DB_USER" -d "$DB_HEALTH_NAME" \
        -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q " f"; then
      log_info "PostgreSQL primary is ready and accepting writes"
      return 0
    fi

    log_warn "Attempt $attempt/$MAX_RETRIES: Primary not ready via PgBouncer, retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
    ((attempt++))
  done

  log_error "PostgreSQL primary did not become available after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
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
  
  wait_for_postgres || exit 1
  wait_for_patroni_primary || exit 1
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
