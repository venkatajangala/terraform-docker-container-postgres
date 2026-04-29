#!/bin/bash
# HA PostgreSQL Startup Script (Linux/WSL version)
# Starts containers in correct dependency order after reboot
# Usage: bash /home/vejang/start-ha-postgres.sh

set -e

# Configuration
WAIT_ETCD=15           # Seconds to wait for etcd startup
WAIT_PG_NODES=30       # Seconds to wait for pg-nodes to form cluster
WAIT_PGBOUNCER=10      # Seconds to wait for pgbouncer
WAIT_SERVICES=5        # Seconds for other services

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[ℹ]${NC} $1"
}

# Function to check if container is running and healthy
check_container_healthy() {
    local container=$1
    local max_retries=${2:-5}
    local retry_delay=${3:-5}
    local retries=0
    
    while [ $retries -lt $max_retries ]; do
        local state=$(docker inspect $container --format '{{.State.Running}}' 2>/dev/null || echo "false")
        local health=$(docker inspect $container --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
        
        if [ "$state" == "true" ]; then
            if [ "$health" == "healthy" ] || [ -z "$health" ]; then
                return 0
            fi
        fi
        
        retries=$((retries + 1))
        if [ $retries -lt $max_retries ]; then
            print_warning "Waiting for $container to be ready... (Attempt $retries/$max_retries)"
            sleep $retry_delay
        fi
    done
    
    return 1
}

# Header
echo ""
echo -e "${CYAN}========================================"
echo -e "${CYAN}HA PostgreSQL Cluster Startup Script${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Step 1: Start etcd
echo -e "${GREEN}[1/5] Starting etcd (Distributed coordination)...${NC}"
if docker start etcd > /dev/null 2>&1; then
    print_status "etcd started"
    echo -e "${YELLOW}⏳ Waiting $WAIT_ETCD seconds for etcd to be ready...${NC}"
    sleep $WAIT_ETCD
    
    if check_container_healthy "etcd"; then
        print_status "etcd is healthy"
    else
        print_warning "etcd may not be fully ready yet (continuing)"
    fi
else
    print_error "Failed to start etcd - STOPPING"
    exit 1
fi

echo ""

# Step 2: Start PostgreSQL nodes
echo -e "${GREEN}[2/5] Starting PostgreSQL nodes...${NC}"
for node in pg-node-1 pg-node-2 pg-node-3; do
    echo -e "${CYAN}  Starting $node...${NC}"
    if docker start $node > /dev/null 2>&1; then
        print_status "$node started"
    else
        print_error "Failed to start $node"
        exit 1
    fi
done

echo -e "${YELLOW}⏳ Waiting $WAIT_PG_NODES seconds for cluster to form...${NC}"
sleep $WAIT_PG_NODES

echo -e "${CYAN}Checking node health...${NC}"
for node in pg-node-1 pg-node-2 pg-node-3; do
    if check_container_healthy $node; then
        print_status "$node is healthy"
    else
        print_warning "$node may not be fully ready yet"
    fi
done

echo ""

# Step 3: Start pgBouncer
echo -e "${GREEN}[3/5] Starting pgBouncer connection poolers...${NC}"
for bouncer in pgbouncer-1 pgbouncer-2; do
    echo -e "${CYAN}  Starting $bouncer...${NC}"
    if docker start $bouncer > /dev/null 2>&1; then
        print_status "$bouncer started"
    else
        print_error "Failed to start $bouncer"
        exit 1
    fi
done

echo -e "${YELLOW}⏳ Waiting $WAIT_PGBOUNCER seconds for pgBouncer to connect...${NC}"
sleep $WAIT_PGBOUNCER

for bouncer in pgbouncer-1 pgbouncer-2; do
    if check_container_healthy $bouncer; then
        print_status "$bouncer is healthy"
    else
        print_warning "$bouncer may not be fully ready yet"
    fi
done

echo ""

# Step 4: Start supporting services
echo -e "${GREEN}[4/5] Starting monitoring and security services...${NC}"
for service in postgres-exporter-1 postgres-exporter-2 postgres-exporter-3 pgbouncer-exporter-1 pgbouncer-exporter-2 vault vault-agent; do
    echo -e "${CYAN}  Starting $service...${NC}"
    if docker start $service > /dev/null 2>&1; then
        print_status "$service started"
    else
        print_warning "$service not available or already running"
    fi
done

echo -e "${YELLOW}⏳ Waiting $WAIT_SERVICES seconds...${NC}"
sleep $WAIT_SERVICES

echo ""

# Step 5: Start observability stack
echo -e "${GREEN}[5/5] Starting observability stack...${NC}"
for service in prometheus grafana pg-dashboard; do
    echo -e "${CYAN}  Starting $service...${NC}"
    if docker start $service > /dev/null 2>&1; then
        print_status "$service started"
    else
        print_warning "$service not available or already running"
    fi
done

echo ""

# Final verification
echo -e "${CYAN}========================================"
echo -e "Final Status Check"
echo -e "${CYAN}========================================${NC}"

all_running=true
for service in etcd pg-node-1 pg-node-2 pg-node-3 pgbouncer-1 pgbouncer-2; do
    state=$(docker inspect $service --format '{{.State.Running}}' 2>/dev/null || echo "false")
    health=$(docker inspect $service --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
    
    if [ "$state" == "true" ]; then
        if [ "$health" == "healthy" ] || [ -z "$health" ]; then
            echo -e "${GREEN}✓${NC} $service : RUNNING"
        else
            echo -e "${YELLOW}⚠${NC} $service : RUNNING (health: $health)"
            all_running=false
        fi
    else
        echo -e "${RED}✗${NC} $service : STOPPED"
        all_running=false
    fi
done

echo ""

if [ "$all_running" = true ]; then
    echo -e "${CYAN}========================================"
    echo -e "${GREEN}✓ HA PostgreSQL Cluster is READY${NC}"
    echo -e "${CYAN}========================================${NC}"
    exit 0
else
    echo -e "${CYAN}========================================"
    echo -e "${YELLOW}⚠ Some services may still be starting${NC}"
    echo -e "${CYAN}========================================${NC}"
    exit 0
fi

