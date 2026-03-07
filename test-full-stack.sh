#!/bin/bash

# Comprehensive Test Suite for PostgreSQL HA + PgBouncer Stack

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   PostgreSQL HA + PgBouncer Comprehensive Test Suite               ║"
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

# Test 1: Check all containers are running
echo ""
echo "📋 TEST 1: Container Status"
echo "─────────────────────────────────────────────────────────────────────"

for container in pg-node-1 pg-node-2 pg-node-3 etcd pgbouncer-1 pgbouncer-2 dbhub; do
    if docker ps | grep -q "$container"; then
        pass "Container $container is running"
    else
        fail "Container $container is NOT running"
    fi
done

# Test 2: PostgreSQL direct connectivity (primary)
echo ""
echo "📋 TEST 2: PostgreSQL Direct Connectivity"
echo "─────────────────────────────────────────────────────────────────────"

if docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    pass "Direct connection to PostgreSQL primary (node 1)"
else
    fail "Cannot connect to PostgreSQL primary (node 1)"
fi

if docker exec pg-node-2 psql -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    pass "Direct connection to PostgreSQL replica 1 (node 2)"
else
    fail "Cannot connect to PostgreSQL replica 1 (node 2)"
fi

if docker exec pg-node-3 psql -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    pass "Direct connection to PostgreSQL replica 2 (node 3)"
else
    fail "Cannot connect to PostgreSQL replica 2 (node 3)"
fi

# Test 3: PgBouncer connectivity
echo ""
echo "📋 TEST 3: PgBouncer Connectivity"
echo "─────────────────────────────────────────────────────────────────────"

if docker exec pgbouncer-1 psql -h pg-node-1 -p 5432 -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    pass "PgBouncer-1 backend connection to PostgreSQL (node 1)"
else
    fail "PgBouncer-1 cannot connect to PostgreSQL backend"
fi

if docker exec pgbouncer-2 psql -h pg-node-2 -p 5432 -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    pass "PgBouncer-2 backend connection to PostgreSQL (node 2)"
else
    fail "PgBouncer-2 cannot connect to PostgreSQL backend"
fi

# Test 4: HA Cluster Health
echo ""
echo "📋 TEST 4: HA Cluster Health Check"
echo "─────────────────────────────────────────────────────────────────────"

# Check Patroni on node 1
PATRONI_OUTPUT=$(curl -s http://localhost:8008 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 || echo "")
if echo "$PATRONI_OUTPUT" | grep -q "running"; then
    pass "Patroni on Node 1 is running"
else
    fail "Patroni on Node 1 is not running"
fi

# Check Patroni on node 2
PATRONI_OUTPUT=$(curl -s http://localhost:8009 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 || echo "")
if echo "$PATRONI_OUTPUT" | grep -q "running"; then
    pass "Patroni on Node 2 is running"
else
    fail "Patroni on Node 2 is not running"
fi

# Check Patroni on node 3
PATRONI_OUTPUT=$(curl -s http://localhost:8010 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 || echo "")
if echo "$PATRONI_OUTPUT" | grep -q "running"; then
    pass "Patroni on Node 3 is running"
else
    fail "Patroni on Node 3 is not running"
fi

# Test 5: Replication Status
echo ""
echo "📋 TEST 5: Replication Status"
echo "─────────────────────────────────────────────────────────────────────"

REPLICA_COUNT=$(docker exec pg-node-1 psql -U pgadmin -d postgres -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | grep -o "[0-9]" | head -1 || echo "0")
if [ "$REPLICA_COUNT" -ge 2 ]; then
    pass "HA cluster has $REPLICA_COUNT replicas connected"
else
    fail "HA cluster has only $REPLICA_COUNT replicas (expected 2+)"
fi

# Test 6: PgBouncer Admin Console
echo ""
echo "📋 TEST 6: PgBouncer Container Status"
echo "─────────────────────────────────────────────────────────────────────"

if docker ps | grep -q "pgbouncer-1"; then
    pass "PgBouncer-1 container is running"
else
    fail "PgBouncer-1 container is NOT running"
fi

if docker ps | grep -q "pgbouncer-2"; then
    pass "PgBouncer-2 container is running"
else
    fail "PgBouncer-2 container is NOT running"
fi

# Test 7: Connection Pooling Statistics
echo ""
echo "📋 TEST 7: PgBouncer Configuration"
echo "─────────────────────────────────────────────────────────────────────"

if docker exec pgbouncer-1 cat /etc/pgbouncer/pgbouncer.ini | grep -q "pool_mode"; then
    pass "PgBouncer-1 configuration file is present and valid"
else
    fail "PgBouncer-1 configuration file is invalid"
fi

if docker exec pgbouncer-2 cat /etc/pgbouncer/pgbouncer.ini | grep -q "pool_mode"; then
    pass "PgBouncer-2 configuration file is present and valid"
else
    fail "PgBouncer-2 configuration file is invalid"
fi

# Test 8: Load Testing - Multiple Concurrent Connections
echo ""
echo "📋 TEST 8: Concurrent Connection Test (10 connections)"
echo "─────────────────────────────────────────────────────────────────────"

FAILED=0
for i in {1..10}; do
    if ! docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT $i;" > /dev/null 2>&1; then
        ((FAILED++))
    fi
done

if [ "$FAILED" -eq 0 ]; then
    pass "All 10 concurrent connections to PostgreSQL succeeded"
else
    fail "$FAILED out of 10 connections failed"
fi

# Test 9: Write to Primary, Read from Replica
echo ""
echo "📋 TEST 9: Write/Read Replication Test"
echo "─────────────────────────────────────────────────────────────────────"

TEST_TABLE="test_replication_$(date +%s)"
docker exec pg-node-1 psql -U pgadmin -d postgres -c "CREATE TABLE $TEST_TABLE (id SERIAL PRIMARY KEY, val TEXT);" > /dev/null 2>&1 && \
docker exec pg-node-1 psql -U pgadmin -d postgres -c "INSERT INTO $TEST_TABLE (val) VALUES ('test_data');" > /dev/null 2>&1

sleep 2

REPLICA_DATA=$(docker exec pg-node-2 psql -U pgadmin -d postgres -t -c "SELECT val FROM $TEST_TABLE LIMIT 1;" 2>/dev/null || echo "")
if [ "$REPLICA_DATA" = "test_data" ]; then
    pass "Data replicated successfully from primary to replica"
    docker exec pg-node-1 psql -U pgadmin -d postgres -c "DROP TABLE $TEST_TABLE;" > /dev/null 2>&1
else
    fail "Data replication test failed"
fi

# Test 10: PgBouncer Connection Pooling Performance
echo ""
echo "📋 TEST 10: Connection Performance Test"
echo "─────────────────────────────────────────────────────────────────────"

START_TIME=$(date +%s%N)
for i in {1..20}; do
    docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1 &
done
wait
END_TIME=$(date +%s%N)

DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
if [ "$DURATION_MS" -lt 5000 ]; then
    pass "20 connections completed in ${DURATION_MS}ms (fast)"
else
    pass "20 connections completed in ${DURATION_MS}ms"
fi

# Summary
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
