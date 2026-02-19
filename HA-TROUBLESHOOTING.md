# PostgreSQL HA Troubleshooting Guide

## Common Issues & Solutions

### 1. Cluster Won't Start

#### Symptom
Containers start but don't form a cluster. Patroni shows "could not connect to etcd".

#### Root Causes & Solutions

**A. etcd not responding**
```bash
# Check etcd is running
docker ps | grep etcd
# Expected: UP status

# Check etcd is responding
curl http://localhost:2379/version
# Expected: JSON output with etcd version

# If not responding, view logs
docker logs etcd | tail -20
```

**B. Stale etcd state**
```bash
# Clear all Patroni entries from etcd (⚠️ destructive)
docker exec etcd etcdctl del /patroni --prefix

# Check member list
docker exec etcd etcdctl member list

# Remove unhealthy members
docker exec etcd etcdctl member remove <member_id>

# Restart containers
docker restart pg-node-1 pg-node-2 pg-node-3
```

**C. PostgreSQL data corruption**
```bash
# Backup current data
docker exec pg-node-1 pg_dumpall -U pgadmin > backup.sql

# Wipe volumes (⚠️ data loss)
docker volume rm pg-node-1-data pg-node-2-data pg-node-3-data

# Restart with terraform
terraform apply
```

---

### 2. Nodes Can't Find Primary

#### Symptom
All nodes show as replicas; no primary elected. Patroni logs show repeated "promoting_" messages.

#### Root Causes & Solutions

**A. etcd connectivity issue**
```bash
# Check each node's etcd connection
docker exec pg-node-1 sh -c 'cat /patroni/patroni.yml | grep -A 5 etcd3'

# Test etcd connectivity from node
docker exec pg-node-1 curl -v http://etcd:2379/version

# If fails, check network
docker network inspect pg-ha-network | grep -A 10 Containers
```

**B. All nodes have same replication lag**
```bash
# Check if primary died before replicas replicated anything
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT pg_last_wal_receive_lsn();"

# If all show same LSN, kill one replica (let Patroni resync):
docker kill pg-node-2
docker restart pg-node-1
# Wait 30s, then restart pg-node-2
docker restart pg-node-2
```

**C. Quorum lost (2+ nodes down)**
```bash
# etcd requires majority; with 3 nodes, 2 must be alive
# Bring back at least 1 additional node
docker restart pg-node-2

# Monitor recovery
curl http://localhost:8008/cluster | jq '.members'
```

#### Wait Time
Allow **30-60 seconds** for new primary election.

---

### 3. Replication Lagging

#### Symptom
Replicas showing high replication lag (> 1 second). Queries on replicas are stale.

#### Root Causes & Solutions

**A. Slow network/I/O**
```bash
# Check replication lag
docker exec pg-node-1 psql -U pgadmin postgres -c "
  SELECT slot_name, restart_lsn, confirmed_flush_lsn
  FROM pg_replication_slots;"

# Check sync status
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS lag;"
```

**B. Replica falling behind**
```bash
# Check WAL receiver status on replica
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT * FROM pg_stat_replication;"

# Monitor WAL files
docker exec pg-node-1 ls -lah /var/lib/postgresql/pg_wal/ | head

# Increase wal_keep_size if WAL is being pruned
# Edit patroni/patroni-node-1.yml:
# postgresql:
#   parameters:
#     wal_keep_size: 1GB
```

**C. Deadlocked checkpoint**
```bash
# Force checkpoint on primary
docker exec pg-node-1 psql -U pgadmin postgres \
  -c "CHECKPOINT FAST;"

# Check if checkpoint finishes
docker logs pg-node-1 | grep -i checkpoint | tail
```

---

### 4. Patroni Won't Promote Replica

#### Symptom
Failover initiated but replica stays in standby mode. Patroni shows "promoting_..." for hours.

#### Root Causes & Solutions

**A. WAL files are corrupted**
```bash
# Check WAL integrity on replicas
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT pg_last_wal_receive_lsn();"

# If shows repeated errors, check WAL directory
docker exec pg-node-2 ls -la /var/lib/postgresql/pg_wal/ | grep -E '^-' | wc -l

# Force recovery (⚠️ may lose data)
docker exec pg-node-2 pgbackrest restore --delta
```

**B. Replication slot blocking**
```bash
# Check if replica is stuck in replication slot
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"

# Drop stuck slot
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT pg_drop_replication_slot('node_slot_2');"

# Reconnect replica
docker restart pg-node-2
```

**C. Primary still running**
```bash
# Ensure old primary is fully stopped
docker ps | grep pg-node-1
# If running, kill it:
docker kill -9 pg-node-1

# Let Patroni do automatic promotion
# Monitor:
watch -n 1 'curl -s http://localhost:8009/leader'
```

---

### 5. Cascading Replication Issues

#### Symptom
Node-3 can't connect to Node-2 (replica of replica). "Replication timeout" errors.

#### Root Causes & Solutions

**A. Network interface down**
```bash
# Check Docker network
docker network inspect pg-ha-network

# Check if all nodes can ping each other
docker exec pg-node-1 ping pg-node-2
docker exec pg-node-2 ping pg-node-3

# If fails, recreate network
docker network rm pg-ha-network
terraform apply
```

**B. Replica connection slots exhausted**
```bash
# Check max connection settings
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SHOW max_connections;"

# If low, increase in patroni-node-2.yml:
# postgresql:
#   parameters:
#     max_connections: 200
```

**C. pg_hba.conf blocking replica**
```bash
# Check current pg_hba rules
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT * FROM pg_hba_file_rules WHERE type = 'local';"

# Verify replication user can connect
docker exec pg-node-2 psql \
  -U replicator -h pg-node-2 postgres \
  -c "IDENTIFY_SYSTEM;" 2>&1
```

---

### 6. DBHub Can't Connect to Database

#### Symptom
DBHub shows "Connection refused" or "Authentication failed" when trying to query the database.

#### Root Causes & Solutions

**A. Primary node failed**
```bash
# DBHub connects to pg-node-1:5432
# If pg-node-1 is down, DBHub can't connect

# Either:
# 1. Restart pg-node-1
docker restart pg-node-1

# 2. Or update DBHub connection after failover
#    Admin > Instances > Edit > Update to new primary
curl http://localhost:8008/leader  # Find new primary

# LIMITATION: DBHub doesn't automatically discover new primary after failover
#            Manual reconnection required
```

**B. Credentials are wrong**
```bash
# Check DBHub environment vars
docker inspect dbhub | grep -A 20 Env | grep -i postgres

# Expected:
# POSTGRES_PASSWORD=<your_password>
# DB_HOST=pg-node-1
# DB_PORT=5432
# DB_NAME=postgres
# DB_USER=pgadmin

# If wrong, update main-ha.tf vars and redeploy:
terraform apply -var="postgres_password=new_password"
```

**C. Network isolation**
```bash
# Verify DBHub is on same network
docker network inspect pg-ha-network | grep dbhub

# Check connectivity
docker exec dbhub ping pg-node-1
docker exec dbhub nc -zv pg-node-1 5432
```

---

### 7. PgBackRest Backup Fails

#### Symptom
`pgbackrest backup` command hangs or returns "Archive error" or "Backup Error".

#### Root Causes & Solutions

**A. Backup repository not initialized**
```bash
# Initialize pgBackRest repo (run once)
docker exec pg-node-1 pgbackrest --stanza=pg-ha \
  repo-create --repo-type=posix

# Verify
docker exec pg-node-1 ls -la /var/lib/pgbackrest/
```

**B. WAL archiving not working**
```bash
# Check archiving status
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT pg_is_in_recovery(), now() - pg_last_xact_replay_timestamp();"

# Check WAL archive command (in archiving process)
docker exec pg-node-1 ps aux | grep pgbackrest

# View archiving errors
docker logs pg-node-1 | grep -i "archive\|backup" | tail -20
```

**C. Disk space exhausted**
```bash
# Check pgbackrest repo size
docker exec pg-node-1 du -sh /var/lib/pgbackrest/

# Check if volumes are full
docker exec pg-node-1 df -h /var/lib/postgresql/

# If full, delete old backups
docker exec pg-node-1 pgbackrest expire
```

**D. Permissions issue**
```bash
# pgBackRest runs as postgres user
# Verify permissions on backup dir
docker exec pg-node-1 ls -la /var/lib/pgbackrest/

# Should be: drwx------ postgres postgres

# Fix if needed
docker exec pg-node-1 chown -R postgres:postgres /var/lib/pgbackrest/
docker exec pg-node-1 chmod 700 /var/lib/pgbackrest/
```

---

### 8. Node Won't Rejoin Cluster After Restart

#### Symptom
Node restarts but stays in "starting" or "stopped" state. Patroni keeps trying to sync.

#### Root Causes & Solutions

**A. Data directory is corrupted**
```bash
# Check PostgreSQL status
docker exec pg-node-2 pg_controldata /var/lib/postgresql/

# Try to start PostgreSQL directly
docker exec pg-node-2 pg_ctl status -D /var/lib/postgresql

# If shows corruption, wipe and restore from primary
docker exec pg-node-2 rm -rf /var/lib/postgresql/*
docker restart pg-node-2  # Patroni will rebuild from primary

# Monitor rebuild
watch -n 5 'curl -s http://localhost:8009/cluster | jq ".members | map(.name, .state)"'
```

**B. Disk space exceeded during sync**
```bash
# Check disk usage
docker exec pg-node-2 df -h /var/lib/postgresql/

# If full, delete pgBackRest cache and WAL
docker exec pg-node-2 rm -rf /var/lib/pgbackrest/backup/*

# Force full resync
docker exec pg-node-2 pgbackrest restore --force

# Restart Patroni
docker restart pg-node-2
```

**C. etcd lease expired**
```bash
# Check etcd members
docker exec etcd etcdctl member list

# If node is listed but stuck, remove and re-add
docker exec etcd etcdctl member remove <node_id>

# Restart the node
docker restart pg-node-2

# It will re-register automatically
```

---

### 9. Switchover/Failover Takes Too Long

#### Symptom
Manual switchover or automatic failover takes 2+ minutes instead of expected 30 seconds.

#### Root Causes & Solutions

**A. etcd is slow**
```bash
# Check etcd latency
docker exec etcd etcdctl --endpoints=localhost:2379 endpoint health

# Expected: healthy, took <100ms

# If slow, check container resources
docker stats etcd

# Restart etcd
docker restart etcd

# Wait for cluster to re-stabilize
sleep 10
curl http://localhost:8008/cluster
```

**B. PostgreSQL is slow to start**
```bash
# Check startup time in logs
docker logs pg-node-2 | grep -i "startup\|started" | head

# If > 30s, tune PostgreSQL:
# - Reduce shared_buffers
# - Increase wal_buffers
# - Enable fast recovery: archive_recovery_parallel_workers=4

# Edit patroni-node-2.yml and apply
terraform apply
```

**C. Replica selection is ambiguous**
```bash
# All replicas have same replication lag → tie in election
# Force specific replica as winner:

curl -X POST http://localhost:8008/switchover \
  -d '{"leader": "pg-node-1", "candidate": "pg-node-2", "scheduled_at": "2024-01-01T00:00:00"}'

# Will switchover to pg-node-2 as new primary
```

---

### 10. Vector Operations (pgvector) Return NULL

#### Symptom
`SELECT embedding <=> query_vector FROM items` returns NULL values or throws "type mismatch" error.

#### Root Causes & Solutions

**A. Embedding vector is NULL**
```sql
-- Check for NULL embeddings
SELECT id, embedding FROM items WHERE embedding IS NULL;

-- Update with real vectors
UPDATE items SET embedding = '[0.1, 0.2, 0.3, ...]'::vector(1536)
WHERE embedding IS NULL;
```

**B. Vector dimension mismatch**
```sql
-- Vector must be exactly 1536 dimensions
SELECT id, array_length(embedding, 1) AS dim FROM items LIMIT 1;

-- Should return 1536

-- If different, recreate column with correct dimension
ALTER TABLE items ALTER COLUMN embedding TYPE vector(1536);
```

**C. Replication lag on replica**
```bash
# pgvector extension not yet replicated to replica
# Check if extension exists on replica
docker exec pg-node-2 psql -U pgadmin postgres -c "
  SELECT extname FROM pg_extension WHERE extname = 'vector';"

# If not, wait for replication to catch up
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS lag;"
```

---

## Network Debugging Checklist

```bash
# 1. Verify all containers on correct network
docker network inspect pg-ha-network | jq '.Containers | keys'

# 2. Check DNS resolution
docker exec pg-node-1 nslookup pg-node-2
docker exec pg-node-1 nslookup etcd

# 3. Test port connectivity
docker exec pg-node-1 nc -zv pg-node-2 5432
docker exec pg-node-1 nc -zv etcd 2379

# 4. Check IP addresses
docker inspect pg-node-1 | grep IPAddress
docker inspect pg-node-2 | grep IPAddress
docker inspect etcd | grep IPAddress

# 5. View iptables rules (if Docker swarm)
docker exec pg-node-1 iptables -t filter -L -v -n

# 6. Check Docker daemon logs
docker logs --since 5m
```

## Performance Diagnosis

```bash
# 1. Check query performance on primary
docker exec pg-node-1 psql -U pgadmin postgres -c "
  SELECT total_time/calls as avg_ms, calls, query 
  FROM pg_stat_statements 
  ORDER BY total_time DESC LIMIT 10;"

# 2. Monitor replication slot retention
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT slot_name, active, retained_bytes FROM pg_replication_slots;"

# 3. Check WAL file growth
docker exec pg-node-1 du -sh /var/lib/postgresql/pg_wal/

# 4. Monitor index fragmentation
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT schemaname, tablename, indexname, idx_scan 
   FROM pg_stat_user_indexes 
   WHERE idx_scan = 0; -- unused indexes"
```

## Advanced Diagnostics

### Collect Full Cluster Diagnostics

```bash
#!/bin/bash
# save as diagnose.sh

echo "=== Cluster Status ===" 
curl -s http://localhost:8008/cluster | jq '.'

echo -e "\n=== etcd Status ===" 
docker exec etcd etcdctl member list

echo -e "\n=== Replication Status ===" 
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT * FROM pg_stat_replication LIMIT 3;"

echo -e "\n=== Container Status ===" 
docker ps --format "table {{.Names}}\t{{.Status}}"

echo -e "\n=== Disk Usage ===" 
docker exec pg-node-1 df -h /var/lib/postgresql/

echo -e "\n=== PgBackRest Status ===" 
docker exec pg-node-1 pgbackrest info
```

Run this regularly if experiencing issues.

---

## Emergency Recovery Procedures

### Scenario: All 3 Nodes Down

```bash
# 1. Identify which node has newest data
for i in 1 2 3; do
  echo "=== Node $i ===" 
  docker exec pg-node-$i pg_controldata /var/lib/postgresql/ | grep checkpoint
done

# 2. Start the newest node first
docker start pg-node-1

# 3. Wait for it to become primary
sleep 30
curl http://localhost:8008/leader

# 4. Start other nodes (they'll sync)
docker start pg-node-2 pg-node-3

# 5. Verify cluster is healthy
curl http://localhost:8008/cluster | jq '.members | map(.role, .state)'
```

### Scenario: Corrupted Primary Data

```bash
# 1. Failover to healthy replica
curl -X POST http://localhost:8008/switchover \
  -d '{"leader": "pg-node-1", "candidate": "pg-node-2"}'

# 2. Wait for switchover
sleep 10

# 3. Wipe corrupted primary
docker exec pg-node-1 rm -rf /var/lib/postgresql/*

# 4. Restart primary (will rebuild from new primary pg-node-2)
docker restart pg-node-1

# 5. Verify recovery
curl http://localhost:8008/cluster
```

---

## When To Call Support

- ❌ Cluster doesn't start after 3+ restarts
- ❌ Continuous failover loops (primary elected, immediately demoted)
- ❌ Data corruption detected on multiple nodes
- ❌ Replication lag > 5 minutes without clear cause
- ❌ Disk space growing uncontrollably
- ❌ etcd member list shows 0 members
