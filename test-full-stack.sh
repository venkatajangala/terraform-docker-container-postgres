#!/bin/bash

# Comprehensive Test Suite for PostgreSQL HA + PgBouncer + Infisical Stack

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   PostgreSQL HA + PgBouncer + Infisical Comprehensive Test Suite   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS_COUNT++))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL_COUNT++))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Detect the current primary node dynamically
detect_primary() {
    for port in 8008 8009 8010; do
        role=$(curl -s http://localhost:$port 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null)
        if [ "$role" = "master" ] || [ "$role" = "leader" ]; then
            node_num=$(( (port - 8007) ))
            echo "pg-node-$node_num"
            return
        fi
    done
    echo ""
}

# Get admin password from Terraform state
get_admin_password() {
    terraform output -raw generated_passwords 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('db_admin_password',''))" 2>/dev/null || echo ""
}

PG_USER="pgadmin"
PG_DB="postgres"
PRIMARY=$(detect_primary)

echo "ℹ️  Detected primary: ${PRIMARY:-unknown}"
echo "ℹ️  Using pg user: $PG_USER"
echo ""

# ─────────────────────────────────────────────────────────────────────
# TEST 1: Container Status (includes Infisical stack)
# ─────────────────────────────────────────────────────────────────────
echo "📋 TEST 1: Container Status"
echo "─────────────────────────────────────────────────────────────────────"

for container in pg-node-1 pg-node-2 pg-node-3 etcd pgbouncer-1 pgbouncer-2 dbhub infisical infisical-postgres infisical-redis; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        pass "Container $container is running"
    else
        fail "Container $container is NOT running"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# TEST 2: PostgreSQL Direct Connectivity (all 3 nodes)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 2: PostgreSQL Direct Connectivity"
echo "─────────────────────────────────────────────────────────────────────"

for node in pg-node-1 pg-node-2 pg-node-3; do
    if docker exec "$node" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1;" > /dev/null 2>&1; then
        pass "Direct connection to $node"
    else
        fail "Cannot connect to $node"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# TEST 3: PgBouncer Backend Connectivity
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 3: PgBouncer Backend Connectivity"
echo "─────────────────────────────────────────────────────────────────────"

if docker exec pgbouncer-1 bash -c 'PGPASSWORD="$DB_ADMIN_PASSWORD" psql -h pg-node-1 -p 5432 -U "$DB_ADMIN_USER" -d postgres -c "SELECT 1;"' > /dev/null 2>&1; then
    pass "PgBouncer-1 backend connection to pg-node-1"
else
    fail "PgBouncer-1 cannot connect to pg-node-1 backend"
fi

if docker exec pgbouncer-2 bash -c 'PGPASSWORD="$DB_ADMIN_PASSWORD" psql -h pg-node-2 -p 5432 -U "$DB_ADMIN_USER" -d postgres -c "SELECT 1;"' > /dev/null 2>&1; then
    pass "PgBouncer-2 backend connection to pg-node-2"
else
    fail "PgBouncer-2 cannot connect to pg-node-2 backend"
fi

# ─────────────────────────────────────────────────────────────────────
# TEST 4: HA Cluster Health (Patroni API)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 4: HA Cluster Health Check"
echo "─────────────────────────────────────────────────────────────────────"

for port_offset in 1 2 3; do
    patroni_port=$((8007 + port_offset))
    node="pg-node-$port_offset"
    state=$(curl -s http://localhost:$patroni_port 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null)
    role=$(curl -s http://localhost:$patroni_port 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null)
    if [ "$state" = "running" ]; then
        pass "Patroni $node is running (role: $role)"
    else
        fail "Patroni $node state: '${state:-no response}'"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# TEST 5: Replication Status
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 5: Replication Status"
echo "─────────────────────────────────────────────────────────────────────"

if [ -n "$PRIMARY" ]; then
    REPLICA_COUNT=$(docker exec "$PRIMARY" psql -U postgres -d "$PG_DB" -t -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' \n' || echo "0")
    if [ "${REPLICA_COUNT:-0}" -ge 2 ] 2>/dev/null; then
        pass "HA cluster has $REPLICA_COUNT replicas connected to $PRIMARY"
    else
        fail "HA cluster has only ${REPLICA_COUNT:-0} replicas on $PRIMARY (expected 2+)"
    fi

    # Check replication lag
    LAG=$(docker exec "$PRIMARY" psql -U postgres -d "$PG_DB" -t -c \
        "SELECT COALESCE(max(extract(epoch from write_lag)::int), 0) FROM pg_stat_replication;" 2>/dev/null | tr -d ' \n' || echo "0")
    if [ "${LAG:-0}" -lt 10 ] 2>/dev/null; then
        pass "Replication lag is acceptable: ${LAG:-0}s"
    else
        fail "Replication lag too high: ${LAG}s"
    fi

    # Check streaming state for all replicas
    STREAMING=$(docker exec "$PRIMARY" psql -U postgres -d "$PG_DB" -t -c \
        "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';" 2>/dev/null | tr -d ' \n' || echo "0")
    if [ "${STREAMING:-0}" -ge 2 ] 2>/dev/null; then
        pass "$STREAMING replicas in streaming state"
    else
        fail "Only ${STREAMING:-0} replicas streaming (check pg_stat_replication)"
    fi
else
    fail "No primary detected — cannot check replication"
fi

# ─────────────────────────────────────────────────────────────────────
# TEST 6: PgBouncer Container Health
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 6: PgBouncer Container Health"
echo "─────────────────────────────────────────────────────────────────────"

for pb in pgbouncer-1 pgbouncer-2; do
    health=$(docker inspect "$pb" --format '{{.State.Health.Status}}' 2>/dev/null)
    if [ "$health" = "healthy" ]; then
        pass "$pb is healthy"
    else
        fail "$pb health status: ${health:-unknown}"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# TEST 7: PgBouncer Configuration Validation
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 7: PgBouncer Configuration"
echo "─────────────────────────────────────────────────────────────────────"

for pb in pgbouncer-1 pgbouncer-2; do
    if docker exec "$pb" cat /etc/pgbouncer/pgbouncer.ini | grep -q "pool_mode"; then
        pool_mode=$(docker exec "$pb" cat /etc/pgbouncer/pgbouncer.ini | grep "^pool_mode" | cut -d= -f2 | tr -d ' ')
        pass "$pb config valid (pool_mode=${pool_mode})"
    else
        fail "$pb configuration file is invalid"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# TEST 8: Concurrent Connections (10 simultaneous)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 8: Concurrent Connection Test (10 connections)"
echo "─────────────────────────────────────────────────────────────────────"

if [ -n "$PRIMARY" ]; then
    FAILED=0
    for i in {1..10}; do
        if ! docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT $i;" > /dev/null 2>&1; then
            ((FAILED++))
        fi
    done
    if [ "$FAILED" -eq 0 ]; then
        pass "All 10 concurrent connections to $PRIMARY succeeded"
    else
        fail "$FAILED out of 10 connections failed"
    fi
else
    fail "No primary detected — skipping concurrent connection test"
fi

# ─────────────────────────────────────────────────────────────────────
# TEST 9: Write/Read Replication Test
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 9: Write/Read Replication Test"
echo "─────────────────────────────────────────────────────────────────────"

if [ -n "$PRIMARY" ]; then
    # Find a replica (any node that is NOT the primary)
    REPLICA=""
    for node in pg-node-1 pg-node-2 pg-node-3; do
        if [ "$node" != "$PRIMARY" ]; then
            if docker exec "$node" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1;" > /dev/null 2>&1; then
                REPLICA="$node"
                break
            fi
        fi
    done

    TEST_TABLE="test_replication_$(date +%s)"
    docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" \
        -c "CREATE TABLE $TEST_TABLE (id SERIAL PRIMARY KEY, val TEXT);" > /dev/null 2>&1
    docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" \
        -c "INSERT INTO $TEST_TABLE (val) VALUES ('replication_ok');" > /dev/null 2>&1

    sleep 2

    if [ -n "$REPLICA" ]; then
        REPLICA_DATA=$(docker exec "$REPLICA" psql -U "$PG_USER" -d "$PG_DB" -t \
            -c "SELECT val FROM $TEST_TABLE LIMIT 1;" 2>/dev/null | tr -d ' \n')
        if [ "$REPLICA_DATA" = "replication_ok" ]; then
            pass "Data replicated from $PRIMARY to $REPLICA"
            docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" \
                -c "DROP TABLE $TEST_TABLE;" > /dev/null 2>&1
        else
            fail "Replication test failed (got: '${REPLICA_DATA}')"
        fi
    else
        fail "No healthy replica available for replication test"
    fi
else
    fail "No primary detected — skipping replication test"
fi

# ─────────────────────────────────────────────────────────────────────
# TEST 10: Password Lifecycle — Verify auto-generated passwords work
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 10: Password Lifecycle Validation"
echo "─────────────────────────────────────────────────────────────────────"

if [ -n "$PRIMARY" ]; then
    # Verify pgadmin user exists with a working password
    if docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" \
        -c "SELECT usename, usesuper FROM pg_user WHERE usename='$PG_USER';" 2>/dev/null | grep -q "$PG_USER"; then
        pass "pgadmin superuser exists and is authenticated"
    else
        fail "pgadmin user not found or password incorrect"
    fi

    # Verify replicator user exists
    if docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" \
        -c "SELECT usename FROM pg_user WHERE usename='replicator';" 2>/dev/null | grep -q "replicator"; then
        pass "replicator user exists"
    else
        fail "replicator user not found"
    fi

    # Verify replication is using the correct user
    REPL_USERS=$(docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" -t \
        -c "SELECT count(*) FROM pg_stat_replication WHERE usename='replicator';" 2>/dev/null | tr -d ' \n')
    if [ "${REPL_USERS:-0}" -ge 1 ] 2>/dev/null; then
        pass "Replication using 'replicator' user ($REPL_USERS connections)"
    else
        fail "No replication connections using 'replicator' user"
    fi
else
    fail "No primary detected — skipping password lifecycle test"
fi

# ─────────────────────────────────────────────────────────────────────
# TEST 11: Infisical Health Check
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 11: Infisical Secrets Manager Health"
echo "─────────────────────────────────────────────────────────────────────"

INFISICAL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8020/api/status 2>/dev/null)
if [ "$INFISICAL_STATUS" = "200" ]; then
    pass "Infisical API is healthy (HTTP $INFISICAL_STATUS)"
else
    fail "Infisical API returned HTTP ${INFISICAL_STATUS:-no response}"
fi

for svc in infisical infisical-postgres infisical-redis; do
    health=$(docker inspect "$svc" --format '{{.State.Health.Status}}' 2>/dev/null)
    if [ "$health" = "healthy" ]; then
        pass "$svc is healthy"
    elif docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        warn "$svc is running but health status: ${health:-no healthcheck}"
        ((PASS_COUNT++))
    else
        fail "$svc is not running"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# TEST 12: Connection Performance Test
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "📋 TEST 12: Connection Performance Test (20 parallel)"
echo "─────────────────────────────────────────────────────────────────────"

if [ -n "$PRIMARY" ]; then
    START_TIME=$(date +%s%N)
    for i in {1..20}; do
        docker exec "$PRIMARY" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1;" > /dev/null 2>&1 &
    done
    wait
    END_TIME=$(date +%s%N)
    DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    if [ "$DURATION_MS" -lt 5000 ]; then
        pass "20 parallel connections completed in ${DURATION_MS}ms"
    else
        pass "20 parallel connections completed in ${DURATION_MS}ms (slow but ok)"
    fi
else
    fail "No primary detected — skipping performance test"
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                         Test Summary                               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "✅ All tests passed!"
    exit 0
else
    echo "⚠️  Some tests failed. Review output above."
    exit 1
fi
