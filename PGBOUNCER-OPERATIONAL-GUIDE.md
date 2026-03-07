# PostgreSQL HA + PgBouncer Operational Procedures

## Quick Start Guide

### Access Points

| Service | Host | Port | Purpose |
|---------|------|------|---------|
| **PostgreSQL Primary** | pg-node-1 | 5432 | Direct database connection (primary) |
| **PostgreSQL Replica 1** | pg-node-2 | 5433 | Read-only replica |
| **PostgreSQL Replica 2** | pg-node-3 | 5434 | Read-only replica |
| **PgBouncer-1** | pgbouncer-1 | 6432 | Connection pooling (primary) |
| **PgBouncer-2** | pgbouncer-2 | 6433 | Connection pooling (secondary) |
| **Patroni API Node-1** | pg-node-1 | 8008 | Cluster management / failover |
| **Patroni API Node-2** | pg-node-2 | 8009 | Cluster management / failover |
| **Patroni API Node-3** | pg-node-3 | 8010 | Cluster management / failover |
| **etcd** | etcd | 2379 | Distributed state store |
| **DBHub/Bytebase** | localhost/dbhub | 9090 | Web-based database management UI |

---

## Test Scenario 1: Direct PostgreSQL Connection

### Test Objective
Verify direct connections to all three PostgreSQL nodes are working.

### Test Steps

```bash
# Connect to primary (should have write privilege)
docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT 1, 'Connected to primary';"

# Connect to replica 1 (read-only)
docker exec pg-node-2 psql -U postgres -d postgres -c "SELECT 1, 'Connected to replica 1';"

# Connect to replica 2 (read-only)  
docker exec pg-node-3 psql -U postgres -d postgres -c "SELECT 1, 'Connected to replica 2';"
```

### Expected Result
All three connections succeed and return confirmation messages.

### Troubleshooting
- If connection fails: Check `docker logs pg-node-X` for errors
- If all fail: Verify Docker networks with `docker network ls`

---

## Test Scenario 2: Replication Status Check

### Test Objective
Verify that streaming replication is working and data flows from primary to replicas.

### Test Steps

```bash
# Check replication status from primary
docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"

# View current LSN position on primary
docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT pg_current_wal_lsn() as primary_lsn;"

# View replay progress on replica 1
docker exec pg-node-2 psql -U postgres -d postgres -c "SELECT pg_last_wal_receive_lsn() as replica1_lsn;"

# View replay progress on replica 2
docker exec pg-node-3 psql -U postgres -d postgres -c "SELECT pg_last_wal_receive_lsn() as replica2_lsn;"
```

### Expected Result
- Both replicas show "streaming" state
- LSN positions are identical or replica slightly behind (< 1 second lag)

### Troubleshooting
- If state is "stopped": Check network connectivity between nodes
- If LSN is far behind: Check replication slots with `SELECT * FROM pg_replication_slots;`

---

## Test Scenario 3: Verify Patroni Cluster State

### Test Objective
Confirm Patroni is managing the cluster correctly and can promote replicas if needed.

### Test Steps

```bash
# Check cluster member status
curl -s http://localhost:8008/cluster | python3 -m json.tool

# View primary/leader information
curl -s http://localhost:8008/leader | python3 -m json.tool

# Check node-2 replica status
curl -s http://localhost:8009/replica | python3 -m json.tool

# Check node-3 replica status
curl -s http://localhost:8010/replica | python3 -m json.tool
```

### Expected Result
- Primary shows `"role": "master"`
- Replicas show `"role": "replica"`
- All nodes show `"state": "running"`

### Troubleshooting
- If primary is missing: Run `curl http://localhost:8008/master` on a working node
- If replica won't catch up: Check `pg_stat_replication` for issues

---

## Test Scenario 4: PgBouncer Connection Pooling

### Test Objective
Verify PgBouncer is correctly pooling connections and routing to PostgreSQL.

### Test Steps

```bash
# Create test connection pool
docker run --rm --network pg-ha-network postgres:18 psql \
  -h pgbouncer-1 -p 6432 -U postgres -d postgres \
  -c "SELECT pg_backend_id(), 'Connection via PgBouncer' as test;"

# Test second PgBouncer instance  
docker run --rm --network pg-ha-network postgres:18 psql \
  -h pgbouncer-2 -p 6433 -U postgres -d postgres \
  -c "SELECT pg_backend_id(), 'Connection via PgBouncer-2' as test;"

# Monitor PgBouncer pool usage
docker exec pgbouncer-1 psql -U postgres -h localhost -p 6333 -d pgbouncer -c "SHOW POOLS;"
```

### Expected Result
- Both connections succeed
- Each shows unique backend process ID initially, then reuses if reconnected quickly

### Troubleshooting
- If connection hangs: Check PgBouncer logs: `docker logs pgbouncer-1 | tail -50`
- If pool is stuck: Restart with `docker restart pgbouncer-1`

---

## Test Scenario 5: Failover Testing

### Test Objective
Verify automatic failover works when primary node fails.

### Prerequisites
- All cluster nodes healthy and synced

### Test Steps

**Step 1: Confirm current primary**
```bash
curl -s http://localhost:8008/leader
# Output should show pg-node-1 is master
```

**Step 2: Simulate primary failure**
```bash
docker stop pg-node-1
sleep 5
```

**Step 3: Verify automatic failover**
```bash
# One of the replicas should be promoted to primary
curl -s http://localhost:8009/leader
# or
curl -s http://localhost:8010/leader
```

**Step 4: Verify read access works through failover**
```bash
docker run --rm --network pg-ha-network postgres:18 psql \
  -h pgbouncer-1 -p 6432 -U postgres -d postgres \
  -c "SELECT 1 as 'failover test';"
```

**Step 5: Restart original primary**
```bash
docker start pg-node-1
sleep 10  # Wait for rejoin
```

**Step 6: Verify cluster healed**
```bash
curl -s http://localhost:8008/cluster | python3 -m json.tool
# Should show 3 members, 1 leader, 2 replicas
```

### Expected Result
- Failover completes within 30 seconds
- New leader elected automatically
- Applications maintain connection through PgBouncer
- Original node rejoins as replica when restarted

### Success Criteria
✓ No manual intervention required  
✓ New leader elected from replicas  
✓ Connections never dropped (from client perspective with connection pooling)
✓ Cluster returns to normal state

---

## Test Scenario 6: Load Testing

### Test Objective
Verify system can handle multiple concurrent connections with proper pooling.

### Test Steps

**Create test load (20 concurrent connections)**
```bash
for i in {1..20}; do
  docker exec pg-node-1 psql -U postgres -d postgres \
    -c "SELECT pg_backend_id() as connection_$i;" &
done
wait

# Check load on PostgreSQL
docker exec pg-node-1 psql -U postgres -d postgres \
  -c "SELECT count(*) as active_connections FROM pg_stat_activity;"
```

**Monitor pool statistics**
```bash
docker logs pgbouncer-1 | grep -i "pool\|config" | tail -20
```

### Expected Result
- All 20 connections succeed
- PostgreSQL shows fewer actual connections (due to pooling)
- No connection timeouts or rejections

---

## Test Scenario 7: Data Replication Verification

### Test Objective  
Ensure data written to primary is replicated to standby nodes.

### Test Steps

**Step 1: Create test table on primary**
```bash
TEST_TABLE="test_$(date +%s)"
docker exec pg-node-1 psql -U postgres -d postgres -c \
  "CREATE TABLE $TEST_TABLE (id SERIAL PRIMARY KEY, data TEXT);"
```

**Step 2: Insert test data**
```bash
docker exec pg-node-1 psql -U postgres -d postgres -c \
  "INSERT INTO $TEST_TABLE (data) VALUES ('test data from primary');"
```

**Step 3: Wait for replication**
```bash
sleep 2
```

**Step 4: Verify data on replica 1**
```bash
docker exec pg-node-2 psql -U postgres -d postgres -c \
  "SELECT * FROM $TEST_TABLE;"
```

**Step 5: Verify data on replica 2**
```bash
docker exec pg-node-3 psql -U postgres -d postgres -c \
  "SELECT * FROM $TEST_TABLE;"
```

**Step 6: Cleanup**
```bash
docker exec pg-node-1 psql -U postgres -d postgres -c \
  "DROP TABLE $TEST_TABLE;"
```

### Expected Result
- Table is created on primary
- Data is inserted successfully
- Table and data appear on both replicas within 2 seconds
- Drop replicates to both standby nodes

---

## Test Scenario 8: Health Checks & Monitoring

### Test Objective
Monitor system health and catch issues early.

### Health Check Commands

**Patroni Status**
```bash
for port in 8008 8009 8010; do
  echo "Node port $port:"
  curl -s http://localhost:$port/leader | python3 -c "import sys, json; d=json.load(sys.stdin); print(f\"  Role: {d.get('role')}, State: {d.get('state')}\")"
done
```

**PostgreSQL Activity**
```bash
docker exec pg-node-1 psql -U postgres -d postgres -c \
  "SELECT datname, count(*) as connections FROM pg_stat_activity GROUP BY datname ORDER BY 2 DESC;"
```

**PgBouncer Status**
```bash
docker exec pgbouncer-1 psql -h localhost -p 6333 -U postgres -d pgbouncer -c "SHOW STATS;"
```

**Replication Lag**
```bash
docker exec pg-node-1 psql -U postgres -d postgres -c \
  "SELECT slot_name, slot_type, restart_lsn FROM pg_replication_slots;"
```

### Interpretation
- Response time < 1 second = ✅ Healthy  
- Response time 1-5 seconds = ⚠️ Degraded
- No response = ❌ Down

---

## Operational References

### Common Issues and Solutions

**Issue: "Connection refused" to PgBouncer**
```bash
# Restart PgBouncer
docker restart pgbouncer-1 pgbouncer-2
```

**Issue: Replica lagging behind primary**
```bash
# Check WAL sender on primary
docker exec pg-node-1 psql -U postgres -d postgres -c \
  "SELECT slot_name, active FROM pg_replication_slots;"

# Restart if slot is inactive
docker restart pg-node-2  # Affected replica node
```

**Issue: Patroni not managing cluster**
```bash
# Check etcd connectivity
curl -s http://etcd:2379/v3/health

# Restart Patroni if stuck
docker restart pg-node-1 pg-node-2 pg-node-3
```

### Log Locations

- **PostgreSQL logs**: `docker logs pg-node-{1,2,3}`
- **Patroni logs**: `docker logs pg-node-{1,2,3}` (combined with PostgreSQL)
- **PgBouncer logs**: `docker logs pgbouncer-{1,2}`
- **etcd logs**: `docker logs etcd`

### Configuration Files

- **PgBouncer config**: `pgbouncer/pgbouncer.ini`
- **PgBouncer users**: `pgbouncer/userlist.txt`
- **Patroni config**: `patroni/patroni-node-{1,2,3}.yml`
- **Terraform config**: `main-ha.tf`, `variables-ha.tf`, `outputs-ha.tf`

---

## Performance Baseline

**Connection Performance**
- Direct PostgreSQL: ~20-30ms per new connection
- Through PgBouncer: ~5-10ms (connection reuse)
- Failover time: 20-30 seconds

**Capacity**
- Max concurrent connections: 1000 (configurable in PgBouncer)
- Typical pool size: 25 connections per database/user
- Supported concurrent users: 40-80 (with pooling)

**Replication**
- Typical lag: < 100ms
- Maximum safe lag: 1 second (before requiring intervention)

---

## Maintenance Windows

### Regular Maintenance Tasks

**Daily**
- [ ] Check Patroni cluster status: `curl http://localhost:8008/leader`
- [ ] Monitor replication lag: `docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT round((now() - pg_last_xact_replay_timestamp())::numeric, 2) as replication_lag_sec;"`

**Weekly**
- [ ] Review PostgreSQL logs for errors
- [ ] Check disk usage: `docker exec pg-node-1 df -h /var/lib/postgresql`
- [ ] Verify backup completion status

**Monthly**
- [ ] Test failover scenario
- [ ] Update PostgreSQL and Docker images
- [ ] Review slow query logs

---

## Safety Notes

⚠️ **Critical Operations**
- Do NOT stop all PostgreSQL nodes simultaneously
- Always ensure 1 node is active before major changes
- Test failover in non-production first

✓ **Safe Operations**
- Stopping 1 replica while 1 primary + 1 replica running = SAFE
- Restarting PgBouncer with system running = SAFE
- Checking logs/status = ALWAYS SAFE

---

**Last Updated**: 2026-03-07  
**Maintained By**: DevOps Team  
**Infrastructure**: PostgreSQL 18 + Patroni + etcd + PgBouncer
