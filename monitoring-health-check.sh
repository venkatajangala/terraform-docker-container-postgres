#!/usr/bin/env bash
# =============================================================================
# monitoring-health-check.sh — Verify Prometheus + Grafana stack for pg-ha
# =============================================================================
# Usage:
#   bash monitoring-health-check.sh              # Full health report
#   bash monitoring-health-check.sh --targets    # Prometheus scrape targets only
#   bash monitoring-health-check.sh --metrics    # pg_up spot-check only
#   bash monitoring-health-check.sh --dashboard  # nginx proxy endpoints only
# =============================================================================
set -euo pipefail

# ── Port defaults (override via env vars if you changed them in ha-test.tfvars)
PROM_PORT="${PROMETHEUS_PORT:-9091}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
DASHBOARD_PORT="${DASHBOARD_PORT:-5005}"
GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"

MODE="${1:-}"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
info() { echo -e "  ${BLUE}→${NC} $*"; }
FAILURES=0

# ── Helper: HTTP status code ──────────────────────────────────────────────────
http_code() { curl -s -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "000"; }

# ── Helper: check a container is running ─────────────────────────────────────
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

# ── Helper: require monitoring stack is deployed ──────────────────────────────
require_monitoring() {
  if ! container_running prometheus; then
    echo ""
    fail "Prometheus container is not running."
    echo ""
    echo "  Deploy with:  terraform apply -var-file=ha-test.tfvars -auto-approve"
    echo "  (Ensure monitoring_enabled = true in ha-test.tfvars)"
    exit 1
  fi
}

# =============================================================================
# --targets : Prometheus scrape target status only
# =============================================================================
if [[ "$MODE" == "--targets" ]]; then
  require_monitoring
  echo ""
  echo -e "${BLUE}=== Prometheus Scrape Targets ===${NC}"
  echo ""
  curl -s "http://localhost:${PROM_PORT}/api/v1/targets" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    job      = t['labels'].get('job', '?')
    instance = t['labels'].get('instance', '?')
    health   = t['health']
    last_err = t.get('lastError', '')
    mark = '✓' if health == 'up' else '✗'
    line = f'  {mark}  {job:<20} {instance:<35} {health}'
    if last_err:
        line += f'  ({last_err[:60]})'
    print(line)
" 2>/dev/null || warn "Could not parse Prometheus target response"
  echo ""
  exit 0
fi

# =============================================================================
# --metrics : pg_up spot-check only
# =============================================================================
if [[ "$MODE" == "--metrics" ]]; then
  require_monitoring
  echo ""
  echo -e "${BLUE}=== pg_up Spot-check ===${NC}"
  echo ""
  curl -s "http://localhost:${PROM_PORT}/api/v1/query?query=pg_up" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if not results:
    print('  ! No pg_up results yet — exporters may still be starting')
    sys.exit(0)
for r in results:
    node = r['metric'].get('node', r['metric'].get('instance', '?'))
    val  = r['value'][1]
    mark = '✓' if val == '1' else '✗'
    status = 'UP' if val == '1' else 'DOWN'
    print(f'  {mark}  {node:<25} {status}')
" 2>/dev/null || warn "Could not parse Prometheus query response"
  echo ""
  exit 0
fi

# =============================================================================
# --dashboard : nginx proxy endpoint checks only
# =============================================================================
if [[ "$MODE" == "--dashboard" ]]; then
  require_monitoring
  echo ""
  echo -e "${BLUE}=== nginx Dashboard Proxy (port ${DASHBOARD_PORT}) ===${NC}"
  echo ""
  for path in "" "api/cluster" "api/leader" "api/etcd" "api/vault" "api/datadog"; do
    url="http://localhost:${DASHBOARD_PORT}/${path}"
    code=$(http_code "$url")
    label="/${path}"
    [[ -z "$path" ]] && label="/ (HTML)"
    if [[ "$code" =~ ^(200|429|503)$ ]]; then
      ok "${label}  →  HTTP ${code}"
    elif [[ "$code" == "502" ]]; then
      warn "${label}  →  HTTP ${code}  (backend container not running)"
    else
      fail "${label}  →  HTTP ${code}"
    fi
  done
  echo ""
  exit 0
fi

# =============================================================================
# Full health report (default)
# =============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Monitoring Stack Health Check — pg-ha-cluster          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Container Status ───────────────────────────────────────────────────────
echo -e "${BLUE}── 1. Container Status ──────────────────────────────────────${NC}"

CONTAINERS=(
  "postgres-exporter-1"
  "postgres-exporter-2"
  "postgres-exporter-3"
  "pgbouncer-exporter-1"
  "pgbouncer-exporter-2"
  "prometheus"
  "grafana"
)

for name in "${CONTAINERS[@]}"; do
  if container_running "$name"; then
    status=$(docker ps --format '{{.Names}}\t{{.Status}}' \
      | awk -v n="$name" '$1==n{$1=""; print $0}' | xargs)
    ok "${name}  (${status})"
  else
    # pgbouncer exporters are optional (depend on pgbouncer_enabled)
    if [[ "$name" == pgbouncer-exporter-* ]]; then
      warn "${name}  not running  (pgbouncer_enabled = false?)"
    else
      fail "${name}  NOT running"
    fi
  fi
done
echo ""

require_monitoring

# ── 2. Prometheus Target Health ───────────────────────────────────────────────
echo -e "${BLUE}── 2. Prometheus Scrape Targets ─────────────────────────────${NC}"

TARGET_JSON=$(curl -s "http://localhost:${PROM_PORT}/api/v1/targets" 2>/dev/null || echo "")

if [[ -z "$TARGET_JSON" ]]; then
  fail "Cannot reach Prometheus at localhost:${PROM_PORT}"
else
  echo "$TARGET_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
targets = data['data']['activeTargets']
down = 0
for t in targets:
    job      = t['labels'].get('job', '?')
    instance = t['labels'].get('instance', '?')
    health   = t['health']
    last_err = t.get('lastError', '')
    if health == 'up':
        print(f'  \033[0;32m✓\033[0m  {job:<20} {instance:<35} up')
    else:
        down += 1
        msg = f'  \033[0;31m✗\033[0m  {job:<20} {instance:<35} DOWN'
        if last_err:
            msg += f'  — {last_err[:55]}'
        print(msg)
if down == 0:
    print(f'  \033[0;34m→\033[0m  All {len(targets)} targets healthy')
else:
    print(f'  \033[1;33m!\033[0m  {down} of {len(targets)} targets are DOWN')
    sys.exit(1)
" 2>/dev/null || fail "Could not parse Prometheus target response"
fi
echo ""

# ── 3. Prometheus Metrics Spot-check ─────────────────────────────────────────
echo -e "${BLUE}── 3. PostgreSQL Node Metrics (pg_up) ───────────────────────${NC}"

PG_UP_JSON=$(curl -s "http://localhost:${PROM_PORT}/api/v1/query?query=pg_up" 2>/dev/null || echo "")

if [[ -z "$PG_UP_JSON" ]]; then
  fail "Could not query Prometheus"
else
  echo "$PG_UP_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if not results:
    print('  \033[1;33m!\033[0m  No pg_up results yet — exporters may still be initialising')
    sys.exit(0)
down = 0
for r in results:
    node = r['metric'].get('node', r['metric'].get('instance', '?'))
    val  = r['value'][1]
    if val == '1':
        print(f'  \033[0;32m✓\033[0m  {node:<25}  UP')
    else:
        down += 1
        print(f'  \033[0;31m✗\033[0m  {node:<25}  DOWN')
if down:
    sys.exit(1)
" 2>/dev/null || fail "Could not parse pg_up query response"
fi
echo ""

# ── 4. PgBouncer Metrics Spot-check ──────────────────────────────────────────
echo -e "${BLUE}── 4. PgBouncer Pool Metrics ────────────────────────────────${NC}"

PGB_JSON=$(curl -s "http://localhost:${PROM_PORT}/api/v1/query?query=pgbouncer_pools_client_active_connections" 2>/dev/null || echo "")

if [[ -z "$PGB_JSON" ]]; then
  warn "Could not query Prometheus for PgBouncer metrics"
else
  echo "$PGB_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if not results:
    print('  \033[1;33m!\033[0m  No pgbouncer metrics yet (pgbouncer_enabled = false, or still loading)')
    sys.exit(0)
total = sum(float(r['value'][1]) for r in results)
instances = {r['metric'].get('instance', '?') for r in results}
print(f'  \033[0;32m✓\033[0m  {len(instances)} pool instance(s) reporting  —  {int(total)} active client connection(s)')
" 2>/dev/null || warn "Could not parse pgbouncer metrics"
fi
echo ""

# ── 5. Grafana Health + Dashboard Provisioning ───────────────────────────────
echo -e "${BLUE}── 5. Grafana Dashboards ────────────────────────────────────${NC}"

GF_HEALTH=$(http_code "http://localhost:${GRAFANA_PORT}/api/health")
if [[ "$GF_HEALTH" == "200" ]]; then
  ok "Grafana is reachable  (http://localhost:${GRAFANA_PORT})"
else
  fail "Grafana not reachable at localhost:${GRAFANA_PORT}  (HTTP ${GF_HEALTH})"
fi

DASH_JSON=$(curl -s -u "admin:${GRAFANA_PASS}" \
  "http://localhost:${GRAFANA_PORT}/api/search?type=dash-db" 2>/dev/null || echo "[]")

EXPECTED_UIDS=("pg-ha-postgres" "pg-ha-pgbouncer")
EXPECTED_TITLES=("PostgreSQL Cluster" "PgBouncer Pool")

for i in "${!EXPECTED_UIDS[@]}"; do
  uid="${EXPECTED_UIDS[$i]}"
  title="${EXPECTED_TITLES[$i]}"
  if echo "$DASH_JSON" | python3 -c "
import json,sys
uids=[d['uid'] for d in json.load(sys.stdin)]
sys.exit(0 if '${uid}' in uids else 1)
" 2>/dev/null; then
    ok "Dashboard provisioned:  ${title}  (uid: ${uid})"
  else
    fail "Dashboard MISSING:  ${title}  (uid: ${uid})"
  fi
done
echo ""

# ── 6. nginx Dashboard Proxy Endpoints ───────────────────────────────────────
echo -e "${BLUE}── 6. nginx Dashboard Proxy (port ${DASHBOARD_PORT}) ──────────────────${NC}"

if ! container_running pg-dashboard; then
  warn "pg-dashboard container not running  (dashboard_enabled = false?)"
else
  declare -A PATHS=(
    ["/"]="HTML dashboard"
    ["/api/cluster"]="Patroni cluster JSON"
    ["/api/leader"]="Patroni leader JSON"
    ["/api/etcd"]="etcd health JSON"
    ["/api/vault"]="Vault sys/health JSON"
  )
  for path in "/" "/api/cluster" "/api/leader" "/api/etcd" "/api/vault"; do
    code=$(http_code "http://localhost:${DASHBOARD_PORT}${path}")
    label="${PATHS[$path]}"
    if [[ "$code" =~ ^(200|429|503)$ ]]; then
      ok "${path}  →  HTTP ${code}  (${label})"
    elif [[ "$code" == "502" ]]; then
      warn "${path}  →  HTTP ${code}  (backend not running)"
    else
      fail "${path}  →  HTTP ${code}"
    fi
  done
fi
echo ""

# ── 7. Recent Exporter Errors ─────────────────────────────────────────────────
echo -e "${BLUE}── 7. Recent Exporter Errors (last 50 lines each) ───────────${NC}"

for name in postgres-exporter-1 postgres-exporter-2 postgres-exporter-3; do
  if container_running "$name"; then
    ERRS=$(docker logs "$name" --tail 50 2>&1 \
      | grep -iE "error|fatal|panic" \
      | grep -v "postgres_exporter.yml" \
      | grep -v "^$" | tail -3 || true)
    if [[ -z "$ERRS" ]]; then
      ok "${name} — no errors"
    else
      warn "${name} — errors found:"
      echo "$ERRS" | sed 's/^/       /'
    fi
  fi
done

for name in pgbouncer-exporter-1 pgbouncer-exporter-2; do
  if container_running "$name"; then
    ERRS=$(docker logs "$name" --tail 50 2>&1 | grep -iE "error|fatal|panic" | grep -v "^$" | tail -3 || true)
    if [[ -z "$ERRS" ]]; then
      ok "${name} — no errors"
    else
      warn "${name} — errors found:"
      echo "$ERRS" | sed 's/^/       /'
    fi
  fi
done
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}── Summary ──────────────────────────────────────────────────${NC}"

if [[ $FAILURES -eq 0 ]]; then
  echo -e "  ${GREEN}All checks passed.${NC}"
else
  echo -e "  ${RED}${FAILURES} check(s) failed — review output above.${NC}"
fi

echo ""
echo "  Grafana dashboards:     http://localhost:${GRAFANA_PORT}  (admin / ${GRAFANA_PASS})"
echo "  Prometheus targets:     http://localhost:${PROM_PORT}/targets"
echo "  Prometheus metrics:     http://localhost:${PROM_PORT}/graph"
echo "  nginx status page:      http://localhost:${DASHBOARD_PORT}"
echo ""
echo "  Focused checks:"
echo "    bash monitoring-health-check.sh --targets    # scrape target status"
echo "    bash monitoring-health-check.sh --metrics    # pg_up per node"
echo "    bash monitoring-health-check.sh --dashboard  # nginx proxy endpoints"
echo ""
echo "  Live logs:"
echo "    docker logs prometheus          -f"
echo "    docker logs grafana             -f"
echo "    docker logs postgres-exporter-1 -f"
echo "    docker logs pgbouncer-exporter-1 -f"
echo ""

[[ $FAILURES -eq 0 ]] && exit 0 || exit 1
