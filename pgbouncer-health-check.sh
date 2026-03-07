#!/bin/bash
# PgBouncer Health Check and Validation Script

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔍 PgBouncer Health Check${NC}"
echo "================================"

# Function to test connection
test_connection() {
    local host=$1
    local port=$2
    local name=$3
    
    if nc -z "$host" "$port" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $name reachable at $host:$port"
        return 0
    else
        echo -e "${RED}✗${NC} $name NOT reachable at $host:$port"
        return 1
    fi
}

# Test PostgreSQL nodes
echo ""
echo -e "${YELLOW}PostgreSQL Nodes:${NC}"
test_connection "pg-node-1" "5432" "PG Node 1" || true
test_connection "pg-node-2" "5432" "PG Node 2" || true
test_connection "pg-node-3" "5432" "PG Node 3" || true

# Test etcd
echo ""
echo -e "${YELLOW}etcd:${NC}"
test_connection "etcd" "2379" "etcd" || true

# Test PgBouncer connections
echo ""
echo -e "${YELLOW}PgBouncer Instances:${NC}"
test_connection "pgbouncer-1" "6432" "PgBouncer 1" || true
test_connection "pgbouncer-2" "6432" "PgBouncer 2" || true
test_connection "pgbouncer-3" "6432" "PgBouncer 3" || true

echo ""
echo -e "${YELLOW}Summary:${NC}"
echo "================================"
echo "Container Network: pg-ha-network"
echo "PostgreSQL Ports: 5432-5434"
echo "PgBouncer Port: 6432"
echo "Patroni API Ports: 8008-8010"
echo "etcd Ports: 2379, 2380"

echo ""
echo -e "${GREEN}✓ Health check complete${NC}"
