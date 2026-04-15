#!/usr/bin/env bash
# =============================================================================
# datadog-health-check.sh — Verify Datadog Agent health for the pg-ha-cluster
# =============================================================================
# Usage:
#   bash datadog-health-check.sh            # Full health report
#   bash datadog-health-check.sh --checks   # Show integration check results only
#   bash datadog-health-check.sh --status   # Show compact agent status summary
# =============================================================================
set -euo pipefail

AGENT="datadog-agent"
MODE="${1:-}"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
info() { echo -e "  ${BLUE}→${NC} $*"; }

# ── Helper: require the container to be running ───────────────────────────────
require_agent_running() {
  if ! docker ps --format '{{.Names}}' | grep -q "^${AGENT}$"; then
    echo ""
    fail "Datadog Agent container '${AGENT}' is not running."
    echo ""
    echo "  Deploy with:  terraform apply -var-file=ha-test.tfvars -auto-approve"
    echo "  (Ensure datadog_enabled = true and datadog_api_key is set in ha-test.tfvars)"
    exit 1
  fi
}

# =============================================================================
# --status : compact summary
# =============================================================================
if [[ "$MODE" == "--status" ]]; then
  require_agent_running
  echo ""
  echo -e "${BLUE}=== Datadog Agent Status ===${NC}"
  docker exec "${AGENT}" agent status 2>/dev/null | grep -E "Status|Running|Checks|Errors|Warnings" | head -30
  exit 0
fi

# =============================================================================
# --checks : integration check results only
# =============================================================================
if [[ "$MODE" == "--checks" ]]; then
  require_agent_running
  echo ""
  echo -e "${BLUE}=== Datadog Integration Check Results ===${NC}"
  docker exec "${AGENT}" agent check postgres   2>/dev/null || warn "postgres check failed or not configured"
  echo ""
  docker exec "${AGENT}" agent check pgbouncer  2>/dev/null || warn "pgbouncer check failed or not configured"
  echo ""
  docker exec "${AGENT}" agent check http_check 2>/dev/null || warn "http_check failed or not configured"
  exit 0
fi

# =============================================================================
# Full health report (default)
# =============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Datadog Agent Health Check — pg-ha-cluster           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Container status ───────────────────────────────────────────────────────
echo -e "${BLUE}── 1. Container Status ──────────────────────────────────────${NC}"

if docker ps --format '{{.Names}}\t{{.Status}}' | grep -q "^${AGENT}"; then
  STATUS=$(docker ps --format '{{.Names}}\t{{.Status}}' | grep "^${AGENT}" | awk '{$1=""; print $0}' | xargs)
  ok "datadog-agent is running  (${STATUS})"
else
  fail "datadog-agent is NOT running"
  echo ""
  echo "  Start with:  terraform apply -var-file=ha-test.tfvars -auto-approve"
  exit 1
fi
echo ""

# ── 2. Agent connectivity & API key validation ────────────────────────────────
echo -e "${BLUE}── 2. Agent Connectivity ────────────────────────────────────${NC}"

if docker exec "${AGENT}" agent status 2>/dev/null | grep -q "API key ending with"; then
  API_KEY_TAIL=$(docker exec "${AGENT}" agent status 2>/dev/null | grep "API key ending with" | awk '{print $NF}')
  ok "API key validated (…${API_KEY_TAIL})"
else
  warn "Could not confirm API key validation — check agent logs"
fi

HOSTNAME=$(docker exec "${AGENT}" agent hostname 2>/dev/null || echo "unknown")
info "Agent hostname: ${HOSTNAME}"
echo ""

# ── 3. Integration check status ───────────────────────────────────────────────
echo -e "${BLUE}── 3. Integration Checks ────────────────────────────────────${NC}"

check_integration() {
  local name="$1"
  local check_name="$2"
  local result
  result=$(docker exec "${AGENT}" agent check "${check_name}" 2>&1)
  # Use here-string (<<<) instead of echo | grep to avoid SIGPIPE on large outputs.
  # grep -q exits after first match, which causes SIGPIPE when piped from echo,
  # and set -o pipefail then misreports the pipeline as failed.
  if grep -qiE "=== Series ===" <<< "${result}"; then
    ok "${name} — metrics collected"
  elif grep -qiE "error|Error|CRITICAL" <<< "${result}"; then
    fail "${name} — error detected:"
    grep -iE "error|Error|CRITICAL" <<< "${result}" | head -5 | sed 's/^/       /'
  else
    warn "${name} — no series output (check may still be loading)"
  fi
}

check_integration "PostgreSQL (pg-node-1,2,3)" "postgres"
check_integration "PgBouncer (pgbouncer-1,2)"  "pgbouncer"
check_integration "HTTP checks (Patroni+etcd)" "http_check"
echo ""

# ── 4. Patroni REST API reachability ─────────────────────────────────────────
echo -e "${BLUE}── 4. Patroni REST API ──────────────────────────────────────${NC}"

for node in pg-node-1 pg-node-2 pg-node-3; do
  CODE=$(docker exec "${AGENT}" curl -s -o /dev/null -w "%{http_code}" \
    "http://${node}:8008/liveness" 2>/dev/null || echo "000")
  if [[ "$CODE" == "200" ]]; then
    ok "${node}:8008/liveness → ${CODE}"
  else
    fail "${node}:8008/liveness → ${CODE}"
  fi
done
echo ""

# ── 5. PostgreSQL direct reachability (from agent container) ──────────────────
echo -e "${BLUE}── 5. PostgreSQL Direct Reachability ────────────────────────${NC}"

for node in pg-node-1 pg-node-2 pg-node-3; do
  CODE=$(docker exec "${AGENT}" bash -c \
    "timeout 3 bash -c 'echo >/dev/tcp/${node}/5432' 2>/dev/null && echo 0 || echo 1")
  if [[ "$CODE" == "0" ]]; then
    ok "${node}:5432 — TCP reachable"
  else
    fail "${node}:5432 — TCP unreachable"
  fi
done
echo ""

# ── 6. PgBouncer reachability ─────────────────────────────────────────────────
echo -e "${BLUE}── 6. PgBouncer Reachability ────────────────────────────────${NC}"

for pb in pgbouncer-1 pgbouncer-2; do
  CODE=$(docker exec "${AGENT}" bash -c \
    "timeout 3 bash -c 'echo >/dev/tcp/${pb}/6432' 2>/dev/null && echo 0 || echo 1")
  if [[ "$CODE" == "0" ]]; then
    ok "${pb}:6432 — TCP reachable"
  else
    fail "${pb}:6432 — TCP unreachable (may be disabled)"
  fi
done
echo ""

# ── 7. etcd reachability ──────────────────────────────────────────────────────
echo -e "${BLUE}── 7. etcd Health ───────────────────────────────────────────${NC}"

CODE=$(docker exec "${AGENT}" curl -s -o /dev/null -w "%{http_code}" \
  "http://etcd:2379/health" 2>/dev/null || echo "000")
if [[ "$CODE" == "200" ]]; then
  ok "etcd:2379/health → ${CODE}"
else
  fail "etcd:2379/health → ${CODE}"
fi
echo ""

# ── 8. Vault health (if container exists) ─────────────────────────────────────
echo -e "${BLUE}── 8. Vault Health ──────────────────────────────────────────${NC}"

if docker ps --format '{{.Names}}' | grep -q "^vault$"; then
  CODE=$(docker exec "${AGENT}" curl -s -o /dev/null -w "%{http_code}" \
    "http://vault:8200/v1/sys/health" 2>/dev/null || echo "000")
  if [[ "$CODE" == "200" ]]; then
    ok "vault:8200/v1/sys/health → ${CODE} (active+unsealed)"
  else
    warn "vault:8200/v1/sys/health → ${CODE} (may be sealed or standby)"
  fi
else
  info "Vault container not running (vault_enabled = false, skipping)"
fi
echo ""

# ── 9. Recent agent logs (last 20 lines, errors only) ─────────────────────────
echo -e "${BLUE}── 9. Recent Agent Errors ───────────────────────────────────${NC}"

# Filter out expected 403 / API-key noise from log scan — all of the patterns
# below appear whenever datadoghq.com rejects a test/invalid API key and are
# not actionable for local development / CI environments.
ERRORS=$(docker logs "${AGENT}" --tail 100 2>&1 \
  | grep -iE "error|CRITICAL|panic" \
  | grep -v "API Key invalid (403" \
  | grep -v "Invalid response from.*datadoghq.com.*403" \
  | grep -v "code=40[0-9]" \
  | grep -v "Tokens are required" \
  | grep -v "Could not send payload" \
  | grep -v "No valid api key found" \
  | grep -v "Authentication failed.*missing_api_key" \
  | tail -10 || true)
if [[ -z "$ERRORS" ]]; then
  ok "No actionable errors in last 100 log lines"
  if docker logs "${AGENT}" --tail 100 2>&1 | grep -qE "code=403|API Key invalid"; then
    info "403 API key errors present (expected if using a test/placeholder key)"
  fi
else
  warn "Errors found in agent logs:"
  echo "$ERRORS" | sed 's/^/     /'
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}── Summary ──────────────────────────────────────────────────${NC}"
echo "  View full agent status:   docker exec datadog-agent agent status"
echo "  Tail agent logs:          docker logs datadog-agent -f"
echo "  Re-run postgres check:    docker exec datadog-agent agent check postgres"
echo "  Re-run pgbouncer check:   docker exec datadog-agent agent check pgbouncer"
echo "  Re-run http_check:        docker exec datadog-agent agent check http_check"
echo ""
