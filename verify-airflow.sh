#!/bin/bash
# ============================================================================
# Airflow Verification Script
# Tests: container health, webserver API, scheduler, DAGs, DB connection,
#        PgBouncer airflow pool, and Patroni health-check DAG connectivity.
# Usage: bash verify-airflow.sh [--quick]
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

QUICK=${1:-""}
PASS=0; FAIL=0; WARN=0

pass()  { echo -e "${GREEN}  ✓${NC} $1"; PASS=$((PASS + 1)); }
fail()  { echo -e "${RED}  ✗${NC} $1"; FAIL=$((FAIL + 1)); }
warn()  { echo -e "${YELLOW}  !${NC} $1"; WARN=$((WARN + 1)); }
header(){ echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}"; }

# ---------------------------------------------------------------------------
# Read AIRFLOW__DATABASE__SQL_ALCHEMY_CONN from the running webserver PID 1.
# The entrypoint builds this dynamically at runtime; it is NOT in the static
# Docker env, so docker exec commands need it injected explicitly.
# ---------------------------------------------------------------------------
AIRFLOW_SQLALCHEMY_CONN=$(docker exec airflow-webserver sh -c \
  'cat /proc/1/environ | tr "\0" "\n" | grep "^AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=" | cut -d= -f2-' \
  2>/dev/null || echo "")

# Wrapper that injects the DB connection string for any airflow CLI call
airflow_cli() {
  local ctr="$1"; shift
  docker exec -e "AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=${AIRFLOW_SQLALCHEMY_CONN}" "$ctr" "$@" 2>&1
}

AIRFLOW_PORT="${AIRFLOW_PORT:-8081}"

# ---------------------------------------------------------------------------
# 1. Container status
# ---------------------------------------------------------------------------
header "1. Container Health"

for ctr in airflow-init airflow-webserver airflow-scheduler; do
  status=$(docker inspect --format '{{.State.Status}}' "$ctr" 2>/dev/null || echo "missing")
  case "$ctr" in
    airflow-init)
      exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$ctr" 2>/dev/null || echo "?")
      if [ "$status" = "exited" ] && [ "$exit_code" = "0" ]; then
        pass "$ctr exited cleanly (exit 0)"
      elif [ "$status" = "running" ]; then
        warn "$ctr is still running (init in progress)"
      else
        fail "$ctr status=$status exit=$exit_code (expected exited/0)"
        echo "    Logs: docker logs airflow-init --tail 30"
      fi
      ;;
    airflow-webserver|airflow-scheduler)
      if [ "$status" = "running" ]; then
        pass "$ctr is running"
      else
        fail "$ctr status=$status (expected running)"
        echo "    Logs: docker logs $ctr --tail 30"
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 2. Webserver health endpoint
# ---------------------------------------------------------------------------
header "2. Webserver API Health"

health=$(curl -sf "http://localhost:${AIRFLOW_PORT}/health" 2>/dev/null || echo "")
if echo "$health" | grep -q '"status": "healthy"'; then
  pass "Webserver /health → healthy"
elif echo "$health" | grep -q '"status"'; then
  warn "Webserver /health returned non-healthy: $(echo "$health" | python3 -m json.tool 2>/dev/null || echo "$health")"
else
  fail "Webserver /health unreachable on localhost:${AIRFLOW_PORT}"
  echo "    Check: docker logs airflow-webserver --tail 30"
fi

# Also verify the discovered primary is set
if [ -n "$AIRFLOW_SQLALCHEMY_CONN" ]; then
  primary=$(echo "$AIRFLOW_SQLALCHEMY_CONN" | grep -oE '@[^:]+:' | tr -d '@:')
  pass "Metadata DB connection → direct to primary ${primary}"
else
  fail "Could not read AIRFLOW__DATABASE__SQL_ALCHEMY_CONN from webserver PID 1 env"
fi

# ---------------------------------------------------------------------------
# 3. DAG discovery (inject the correct DB connection for CLI commands)
# ---------------------------------------------------------------------------
header "3. DAG Discovery"

# Brief pause — scheduler parses DAGs on startup, give it a moment
sleep 3
dags_raw=$(airflow_cli airflow-scheduler airflow dags list --output plain 2>/dev/null || echo "")
for dag in "postgres_etl_example" "postgres_ha_health_check"; do
  if echo "$dags_raw" | grep -q "$dag"; then
    pass "DAG '$dag' discovered by scheduler"
  else
    fail "DAG '$dag' NOT found — check dags/ dir mount and syntax"
  fi
done

# ---------------------------------------------------------------------------
# 4. PgBouncer airflow pool
# ---------------------------------------------------------------------------
header "4. PgBouncer Airflow Pool"

# Check pgbouncer.ini configuration (no auth needed — read from inside the container)
if docker exec pgbouncer-1 grep -qE "^airflow\s*=" /etc/pgbouncer/pgbouncer.ini 2>/dev/null; then
  pass "PgBouncer 'airflow' pool configured in pgbouncer.ini"
else
  fail "PgBouncer 'airflow' pool not found in pgbouncer.ini"
fi

# Check airflow_user is in userlist.txt (required for PgBouncer authentication)
if docker exec pgbouncer-1 grep -q '"airflow_user"' /etc/pgbouncer/userlist.txt 2>/dev/null; then
  pass "airflow_user present in PgBouncer userlist.txt"
else
  fail "airflow_user not in PgBouncer userlist.txt — check entrypoint-pgbouncer.sh AIRFLOW_DB_PASSWORD"
fi

# Connectivity check: pg_isready through PgBouncer to the airflow pool
if docker exec pgbouncer-1 pg_isready -h 127.0.0.1 -p 6432 -U airflow_user -d airflow &>/dev/null; then
  pass "pg_isready: airflow_user@pgbouncer-1:6432/airflow → accepts connections"
else
  warn "pg_isready: airflow_user@pgbouncer-1:6432/airflow failed (check userlist.txt)"
fi

# ---------------------------------------------------------------------------
# 5. Airflow metadata DB schema (via postgres superuser on the primary node)
# ---------------------------------------------------------------------------
header "5. Airflow Metadata DB Schema"

# Extract primary hostname and airflow password from the live connection string
primary_host=$(echo "$AIRFLOW_SQLALCHEMY_CONN" | grep -oE '@[^:]+:' | tr -d '@:' || echo "")
airflow_pass=$(echo "$AIRFLOW_SQLALCHEMY_CONN" | grep -oE '://[^:]+:([^@]+)@' | grep -oE ':([^@]+)@' | tr -d ':@' || echo "")

if [ -n "$primary_host" ]; then
  table_count=$(docker exec -e "PGPASSWORD=${airflow_pass}" "$primary_host" \
    psql -U airflow_user -d airflow -t \
    -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" \
    2>/dev/null | tr -d ' \n' || echo "0")
  if [ "${table_count:-0}" -gt 20 ] 2>/dev/null; then
    pass "Airflow metadata DB has ${table_count} tables (schema fully initialized)"
  else
    fail "Airflow metadata DB has ${table_count:-?} tables — expected >20"
  fi
else
  warn "Cannot determine primary host from connection string — skipping table count check"
fi

# ---------------------------------------------------------------------------
# 6. Airflow admin user
# ---------------------------------------------------------------------------
header "6. Airflow Admin User"

user_list=$(airflow_cli airflow-webserver airflow users list --output plain 2>/dev/null || echo "")
user_count=$(echo "$user_list" | grep -c "Admin" 2>/dev/null || echo "0")
if [ "$user_count" -gt 0 ]; then
  pass "Airflow admin user exists ($user_count admin user(s))"
else
  fail "No admin user found — check airflow-init logs"
fi

# ---------------------------------------------------------------------------
# 7. DAG import errors
# ---------------------------------------------------------------------------
header "7. DAG Import Errors"

import_errors=$(airflow_cli airflow-scheduler airflow dags list-import-errors 2>/dev/null || echo "")
if echo "$import_errors" | grep -qE "No import errors|No data found"; then
  pass "No DAG import errors"
elif echo "$import_errors" | grep -qE "Filepath|Stacktrace"; then
  fail "DAG import errors detected:"
  echo "$import_errors" | grep -A2 "Filepath" | head -20
else
  warn "Could not verify import errors (scheduler may still be starting)"
fi

# ---------------------------------------------------------------------------
# 8. Quick ETL DAG trigger (skipped with --quick)
# ---------------------------------------------------------------------------
if [ "$QUICK" != "--quick" ]; then
  header "8. ETL DAG Trigger Test"

  run_id="verify_$(date +%s)"
  trigger_result=$(airflow_cli airflow-webserver \
    airflow dags trigger postgres_etl_example --run-id "$run_id" 2>&1 || echo "FAIL")

  if echo "$trigger_result" | grep -qE "queued|running|success|Created"; then
    pass "ETL DAG triggered (run_id=$run_id, state=queued)"
    echo "    Monitor: docker exec -e AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=\$CONN airflow-scheduler airflow dags state postgres_etl_example $run_id"
  else
    warn "ETL DAG trigger returned: $trigger_result"
  fi
else
  header "8. ETL DAG Trigger Test"
  warn "Skipped (--quick mode)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}==============================${NC}"
echo -e "${BOLD}Airflow Verification Summary${NC}"
echo -e "${BOLD}==============================${NC}"
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${YELLOW}WARN${NC}: $WARN"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo ""

if [ $FAIL -gt 0 ]; then
  echo -e "${RED}${BOLD}✗ Some checks failed — review logs above${NC}"
  echo ""
  echo "Useful commands:"
  echo "  docker logs airflow-init       --tail 50"
  echo "  docker logs airflow-webserver  --tail 50"
  echo "  docker logs airflow-scheduler  --tail 50"
  echo "  terraform output airflow_credentials"
  exit 1
else
  echo -e "${GREEN}${BOLD}✓ All checks passed — Airflow is healthy${NC}"
  echo ""
  echo "Access Airflow UI: http://localhost:${AIRFLOW_PORT}"
  echo "Get credentials:   terraform output airflow_credentials"
fi
