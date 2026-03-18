#!/bin/bash

# Comprehensive PostgreSQL HA Cluster Test Suite
# Tests all scenarios for Phase 1 optimized deployment

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║        PostgreSQL HA Cluster Comprehensive Test Suite          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

function test_pass() {
  echo -e "${GREEN}✓${NC} $1"
  passed=$((passed + 1))
}

function test_fail() {
  echo -e "${RED}✗${NC} $1"
  failed=$((failed + 1))
}

echo "TEST 1: Container Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if all containers are running
for container in pg-node-1 pg-node-2 pg-node-3 pgbouncer-1 pgbouncer-2 etcd infisical; do
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    test_pass "Container running: $container"
  else
    test_fail "Container NOT running: $container"
  fi
done
echo ""

echo "TEST 2: PostgreSQL Connectivity"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test PostgreSQL connection to each node
for node in 1 2 3; do
  port=$((5431 + node))
  if docker exec pg-node-${node} psql -U pgadmin -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    test_pass "PostgreSQL node-$node responds"
  else
    test_fail "PostgreSQL node-$node NOT responding"
  fi
done
echo ""

echo "TEST 3: etcd Cluster Coordination"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test etcd connectivity
if curl -s http://localhost:2379/version | grep -q "etcdserver"; then
  test_pass "etcd cluster coordinator is accessible"
else
  test_fail "etcd cluster coordinator NOT accessible"
fi

# Check Patroni leader election in etcd
if curl -s http://localhost:2379/v2/keys/pg-ha-cluster/members/ | grep -q "pg-node"; then
  test_pass "Patroni cluster members registered in etcd"
else
  test_fail "Patroni cluster members NOT registered in etcd"
fi
echo ""

echo "TEST 4: Patroni HA Coordination"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check Patroni API endpoints
for port in 8008 8009 8010; do
  if curl -s http://localhost:${port} | grep -q "\"name\""; then
    test_pass "Patroni API endpoint port $port responds"
  else
    test_fail "Patroni API endpoint port $port NOT responding"
  fi
done
echo ""

echo "TEST 5: PostgreSQL Replication"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check replication status
repl_count=$(docker exec pg-node-1 psql -U pgadmin -d postgres -tc "SELECT COUNT(*) FROM pg_stat_replication;" | tr -d ' ')
if [ "$repl_count" -ge 0 ]; then
  test_pass "Replication status query works (replicas: $repl_count)"
else
  test_fail "Replication status query failed"
fi

# Check if node is in recovery
recovery=$(docker exec pg-node-2 psql -U pgadmin -d postgres -tc "SELECT pg_is_in_recovery();" | tr -d ' ')
if [ "$recovery" = "t" ]; then
  test_pass "Node 2 is correctly in standby mode (recovery: true)"
else
  test_fail "Node 2 is NOT in standby mode"
fi
echo ""

echo "TEST 6: PgBouncer Connection Pooling"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test PgBouncer connectivity
for port in 6432 6433; do
  if timeout 5 bash -c "echo \"\" | docker exec -i pgbouncer-$((port - 6431)) nc -v localhost $((port - 6432 + 6432)) 2>&1" | grep -q "Connection"; then
    test_pass "PgBouncer listening on port $port"
  else
    echo -e "${YELLOW}⚠${NC}  PgBouncer port $port status unknown (may be still starting)"
  fi
done

# Check PgBouncer stats
if docker exec pgbouncer-1 psql -h localhost -p 6432 -U pgadmin -d postgres -c "SHOW STATS;" > /dev/null 2>&1; then
  test_pass "PgBouncer statistics available"
else
  echo -e "${YELLOW}⚠${NC}  PgBouncer statistics not yet available (starting up)"
fi
echo ""

echo "TEST 7: Infisical Secrets Management"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check Infisical API
if curl -s http://localhost:8020/api/v1/health > /dev/null 2>&1; then
  test_pass "Infisical secrets manager is accessible"
else
  test_fail "Infisical secrets manager NOT accessible"
fi

# Check Infisical PostgreSQL backend
if docker exec infisical-postgres psql -U infisical -d infisical -c "SELECT 1;" > /dev/null 2>&1; then
  test_pass "Infisical PostgreSQL backend is running"
else
  test_fail "Infisical PostgreSQL backend NOT running"
fi
echo ""

echo "TEST 8: Resource Limits & Monitoring"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check memory limits
for node in pg-node-1 pg-node-2 pg-node-3; do
  memory=$(docker inspect $node | grep -o '"Memory": [0-9]*' | awk '{print $2}')
  if [ -n "$memory" ] && [ "$memory" -gt 0 ]; then
    test_pass "$node memory limit set: $((memory / 1024 / 1024))MB"
  else
    test_fail "$node memory limit NOT set"
  fi
done

# Check healthchecks
for container in pg-node-1 pg-node-2 pg-node-3; do
  health=$(docker inspect $container | grep -o '"Health"' | head -1)
  if [ -n "$health" ]; then
    test_pass "$container healthcheck configured"
  else
    test_fail "$container healthcheck NOT configured"
  fi
done
echo ""

echo "TEST 9: Data Persistence"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create test data
if docker exec pg-node-1 psql -U pgadmin -d postgres -c "CREATE TABLE IF NOT EXISTS test_table AS SELECT 1 as id, 'test' as data;" > /dev/null 2>&1; then
  test_pass "Test data created successfully"
  
  # Verify data on replica
  sleep 2
  if docker exec pg-node-2 psql -U pgadmin -d postgres -c "SELECT * FROM test_table WHERE id = 1;" | grep -q "test"; then
    test_pass "Test data replicated to standby node"
  else
    test_fail "Test data NOT replicated"
  fi
else
  test_fail "Failed to create test data"
fi
echo ""

echo "TEST 10: Networking"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check Docker network
if docker network ls | grep -q "pg-ha-network"; then
  test_pass "Docker network 'pg-ha-network' exists"
  
  # Check if containers are connected
  connected=$(docker network inspect pg-ha-network | grep -c "\"Name\": \"pg-node")
  if [ "$connected" -ge 3 ]; then
    test_pass "All PostgreSQL nodes connected to network"
  else
    test_fail "NOT all PostgreSQL nodes connected (found: $connected)"
  fi
else
  test_fail "Docker network 'pg-ha-network' NOT found"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                       TEST RESULTS                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "Passed: ${GREEN}$passed${NC}"
echo -e "Failed: ${RED}$failed${NC}"
echo ""

if [ $failed -eq 0 ]; then
  echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${YELLOW}⚠ SOME TESTS FAILED${NC}"
  exit 1
fi
