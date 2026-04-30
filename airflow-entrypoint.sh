#!/bin/bash
# ============================================================================
# Airflow Entrypoint — handles init, webserver, and scheduler modes.
# Usage: airflow-entrypoint.sh <init|webserver|scheduler>
#
# Discovers the Patroni primary via REST API and connects Airflow's metadata DB
# directly to that node (bypassing PgBouncer), which ensures writes never land
# on a read-only replica. This mirrors the approach used by liquibase-entrypoint.sh.
#
# Required env vars (set by Terraform in main-airflow.tf):
#   AIRFLOW_DB_USER       — PostgreSQL user for Airflow metadata DB (airflow_user)
#   AIRFLOW_DB_PASSWORD   — password for AIRFLOW_DB_USER
#   AIRFLOW__CORE__*      — Airflow settings (executor, fernet key, etc.)
#
# AIRFLOW__DATABASE__SQL_ALCHEMY_CONN is NOT pre-set by Terraform; this script
# builds it after discovering the primary so it always points to a writable node.
# ============================================================================

set -euo pipefail

MODE="${1:-webserver}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[AIRFLOW]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[AIRFLOW]${NC} $1"; }
log_error() { echo -e "${RED}[AIRFLOW]${NC} $1"; }

PATRONI_NODES="${PATRONI_NODES:-pg-node-1 pg-node-2 pg-node-3}"
PATRONI_PORT="${PATRONI_PORT:-8008}"
MAX_RETRIES="${MAX_RETRIES:-60}"
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"

AIRFLOW_DB_USER="${AIRFLOW_DB_USER:-airflow_user}"
AIRFLOW_DB_PASSWORD="${AIRFLOW_DB_PASSWORD:-}"
AIRFLOW_DB_NAME="${AIRFLOW_DB_NAME:-airflow}"

# ---------------------------------------------------------------------------
# discover_primary — poll all Patroni nodes via internal Docker DNS,
#                    set PG_PRIMARY_HOST on success
# ---------------------------------------------------------------------------
discover_primary() {
  log_info "Discovering Patroni primary (nodes: ${PATRONI_NODES})..."
  local attempt=1
  while [ $attempt -le "$MAX_RETRIES" ]; do
    for node in $PATRONI_NODES; do
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://${node}:${PATRONI_PORT}/leader" 2>/dev/null || echo "000")
      if [ "$http_code" = "200" ]; then
        log_info "Primary found: $node"
        PG_PRIMARY_HOST="$node"
        return 0
      fi
    done
    log_warn "Attempt ${attempt}/${MAX_RETRIES}: no primary yet, retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
    ((attempt++))
  done
  log_error "No Patroni primary found after $((MAX_RETRIES * RETRY_INTERVAL))s"
  return 1
}

# ---------------------------------------------------------------------------
# build_db_url — sets AIRFLOW__DATABASE__SQL_ALCHEMY_CONN after discovery
# ---------------------------------------------------------------------------
build_db_url() {
  discover_primary
  export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg2://${AIRFLOW_DB_USER}:${AIRFLOW_DB_PASSWORD}@${PG_PRIMARY_HOST}:5432/${AIRFLOW_DB_NAME}"
  log_info "Metadata DB URL: postgresql+psycopg2://${AIRFLOW_DB_USER}:***@${PG_PRIMARY_HOST}:5432/${AIRFLOW_DB_NAME}"
}

# ---------------------------------------------------------------------------
# init — db migrate + admin user creation (one-shot)
# ---------------------------------------------------------------------------
do_init() {
  log_info "=== Airflow Init Mode ==="
  build_db_url

  log_info "Running: airflow db migrate"
  airflow db migrate

  log_info "Creating Airflow admin user: ${AIRFLOW_ADMIN_USER:-admin}"
  airflow users create \
    --username  "${AIRFLOW_ADMIN_USER:-admin}" \
    --firstname "Airflow" \
    --lastname  "Admin" \
    --role      "Admin" \
    --email     "${AIRFLOW_ADMIN_EMAIL:-admin@airflow.local}" \
    --password  "${AIRFLOW_ADMIN_PASSWORD:-admin}" 2>&1 || {
      log_warn "User create returned non-zero (may already exist) — continuing"
    }

  log_info "=== Airflow Init Complete ==="
}

# ---------------------------------------------------------------------------
# webserver / scheduler — long-running processes
# ---------------------------------------------------------------------------
do_webserver() {
  log_info "=== Airflow Webserver Mode ==="
  build_db_url
  log_info "Starting Airflow webserver on port 8080..."
  exec airflow webserver --port 8080
}

do_scheduler() {
  log_info "=== Airflow Scheduler Mode ==="
  build_db_url
  log_info "Starting Airflow scheduler..."
  exec airflow scheduler
}

case "$MODE" in
  init)      do_init ;;
  webserver) do_webserver ;;
  scheduler) do_scheduler ;;
  *)
    log_error "Unknown mode: $MODE. Valid: init | webserver | scheduler"
    exit 1 ;;
esac
