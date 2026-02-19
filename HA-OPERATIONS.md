# PostgreSQL HA Cluster - Operations & Best Practices

## Quick Reference

### Daily Health Check (30 seconds)

```bash
# One command to verify cluster is healthy
curl -s http://localhost:8008/cluster | jq '{
  primary: .members[] | select(.role=="primary") | .name,
  replicas: [.members[] | select(.role=="replica") | {name, state}],
  cluster_name: .cluster_name
}'
```

**Expected output:**
```json
{
  "primary": "pg-node-1",
  "replicas": [
    {"name": "pg-node-2", "state": "in_sync"},
    {"name": "pg-node-3", "state": "in_sync"}
  ],
  "cluster_name": "pg-ha-cluster"
}
```

### Emergency Access (If Primary Down)

```bash
# Connect to any available replica (only read queries)
psql -h localhost -p 5433 -U pgadmin postgres

# Once connected in HA cluster, queries on replicas are read-only
postgres=# SET transaction_isolation TO 'serializable';
ERROR: cannot set transaction isolation level inside a transaction block

# Writes still require primary to be running
```

## Connection Management

### Connection String Patterns

**Use For Development (Single Node)**
```
postgresql://pgadmin:password@localhost:5432/postgres
```

**Use For HA (Round-robin across nodes)**
```
postgresql://pgadmin:password@localhost:5432,localhost:5433,localhost:5434/postgres?target_session_attrs=prefer-standby
```

**Use For Read-Heavy Workloads (All replicas)**
```
postgresql://pgadmin:password@localhost:5433,localhost:5434/postgres?target_session_attrs=standby
```

**Use For Writes (Primary only)**
```
postgresql://pgadmin:password@localhost:5432/postgres?target_session_attrs=primary
```

### Python Connection Pool Example

```python
from psycopg_pool import ConnectionPool

# Detect primary dynamically
import requests

def get_primary():
    response = requests.get('http://localhost:8008/leader')
    return response.json().get('leader', 'pg-node-1')

# Create pool to primary only (for writes)
pool = ConnectionPool(
    f'postgresql://pgadmin:password@{get_primary()}:5432/postgres',
    min_size=5,
    max_size=20
)

# Use pool for queries
with pool.connection() as conn:
    with conn.cursor() as cur:
        cur.execute("INSERT INTO items (name, embedding) VALUES (%s, %s)", 
                    ("doc", "[0.1, 0.2, ...]"::vector))
        conn.commit()
```

## Replication Management

### Monitor Replication Lag

```bash
# Check actual lag in bytes on primary
docker exec pg-node-1 psql -U pgadmin postgres -c "
  SELECT client_addr,
         (pg_current_wal_lsn() - lsn)::text as lag_bytes,
         CASE WHEN pg_current_wal_lsn() - lsn > 1000000 
              THEN 'HIGH LAG'
              ELSE 'OK' END as status
  FROM pg_stat_replication;"

# Or in time (replica perspective)
for i in 2 3; do
  echo "=== pg-node-$i ==="
  docker exec pg-node-$i psql -U pgadmin postgres -c \
    "SELECT COALESCE((now() - pg_last_xact_replay_timestamp())::text, '0 ms') AS lag;"
done
```

### Handle Replica Sync Issues

**If replica stuck in "catch-up" state:**

```bash
# 1. Check replica can reach primary
docker exec pg-node-2 psql -U replicator -h pg-node-1 postgres -c "SELECT 1;"

# 2. Check replication slot on primary
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT slot_name, active, retained_bytes FROM pg_replication_slots;"

# 3. If slot shows high retained_bytes, WAL is piling up
# Fix: Increase wal_keep_size in patroni-node-1.yml:
# postgresql:
#   parameters:
#     wal_keep_size: 2GB  # default 1GB

# 4. Restart replication slot
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT pg_drop_replication_slot('node_slot_2');"
docker restart pg-node-2
```

**If replica keeps crashing during sync:**

```bash
# Force full rebuild from primary
docker exec pg-node-2 rm -rf /var/lib/postgresql/*
docker restart pg-node-2

# Patroni will handle basebackup and initial sync
# Monitor: docker logs pg-node-2 | grep -i "streaming\|basebackup"

# Verify recovery takes < 5 minutes
watch -n 10 'curl -s http://localhost:8009/cluster | jq ".members[] | select(.name==\"pg-node-2\")"'
```

## Failover Strategies

### Planned Failover (Switchover)

Use when:
- Updating primary node
- Maintenance on primary
- Load balancing between nodes

```bash
# Announce switchover to applications
# "Primary will change in 30 seconds to pg-node-2"

# Initiate switchover
curl -X POST http://localhost:8008/switchover \
  -d '{"leader": "pg-node-1", "candidate": "pg-node-2"}'

# Monitor progress
for i in {1..30}; do
  LEADER=$(curl -s http://localhost:8008/leader 2>/dev/null | jq -r '.leader // "NONE"')
  echo "[$i] Leader: $LEADER"
  [ "$LEADER" = "pg-node-2" ] && break
  sleep 1
done

# Verify switchover complete
curl http://localhost:8008/cluster | jq '.members[] | {name, role}'

# Redirect connections to new primary (if using connection pooling)
# Update connection string to point to pg-node-2 or use service discovery
```

### Unplanned Failover Recovery

When primary crashes unexpectedly:

```bash
# 1. Patroni auto-detects Primary failure (30s timeout)
# 2. Replicas compete for leadership
# 3. Winner becomes new primary

# Monitor failover
while true; do
  CLUSTER=$(curl -s http://localhost:8008/cluster 2>/dev/null | jq '.')
  PRIMARY=$(echo $CLUSTER | jq -r '.members[] | select(.role=="primary") | .name // "NONE"')
  echo "Primary: $PRIMARY | Members: $(echo $CLUSTER | jq '.members | length')"
  
  [ "$PRIMARY" != "NONE" ] && break
  sleep 2
done

# Expected: One replica becomes primary within 30-60 seconds

# Check old primary's status
docker ps | grep pg-node-1

# Repair and restart old primary
# (It will rejoin as replica)
docker logs pg-node-1  # Check what went wrong
docker start pg-node-1 # Will rebuild and sync
```

## Backup & Recovery Procedures

### Scheduled Backups

```bash
# Add to crontab for daily backup at 2 AM
0 2 * * * docker exec pg-node-1 pgbackrest backup >> /var/log/pg-backup.log 2>&1

# Backup on-demand
docker exec pg-node-1 pgbackrest backup

# Verify backup
docker exec pg-node-1 pgbackrest info

# Expected:
# stanza: pg-ha
#   status: backup, archive-push
#   full backup: 20240115-103015F
#     timestamp: 2024-01-15  
#     size: ~500MB
```

### Point-in-Time Recovery (PITR)

**Scenario:** User accidentally deleted production data at 14:30 UTC. Recover to 14:29 UTC.

```bash
# 1. Stop the cluster
docker stop pg-node-1 pg-node-2 pg-node-3

# 2. Restore primary from backup
docker exec pg-node-1 pgbackrest restore \
  --recovery-option="recovery_target_time='2024-01-15 14:29:00 UTC'" \
  --recovery-option="recovery_target_timeline=latest"

# 3. Start primary
docker start pg-node-1

# 4. Monitor recovery
docker logs -f pg-node-1 | grep -i "consistent\|recovery\|restored"

# 5. Verify recovery point
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT pg_last_xact_replay_timestamp();"

# Should show time close to 14:29 UTC

# 6. Start replicas (they'll rebuild from restored primary)
docker start pg-node-2 pg-node-3

# 7. Verify cluster rebuilt
curl http://localhost:8008/cluster | jq '.members[] | {name, role, state}'
```

### Backup to External Storage (S3)

Edit `pgbackrest/pgbackrest.conf`:

```ini
[global]
repo1-type=s3
repo1-path=/pgbackrest
repo1-s3-bucket=my-backups-bucket
repo1-s3-region=us-east-1
repo1-s3-endpoint=s3.amazonaws.com
repo1-s3-key=<AWS_ACCESS_KEY>
repo1-s3-key-secret=<AWS_SECRET_KEY>

[pg-ha]
pg1-path=/var/lib/postgresql
```

Then deploy:

```bash
terraform apply

# Test backup to S3
docker exec pg-node-1 pgbackrest backup --repo=1
```

## Performance Tuning

### Query Performance Analysis

```bash
# Find slowest queries
docker exec pg-node-1 psql -U pgadmin postgres -c "
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
  SELECT query, mean_time, calls 
  FROM pg_stat_statements 
  ORDER BY mean_time DESC LIMIT 10;"

# Analyze slow query (example)
EXPLAIN ANALYZE SELECT * FROM items 
  ORDER BY embedding <-> '[0.1, ...]'::vector LIMIT 100;

# Check if index is being used
# Look for "Index Scan" in EXPLAIN output

# If not using index, rebuild it
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "REINDEX INDEX CONCURRENTLY idx_items_embedding;"
```

### Memory & Cache Tuning

**For small clusters (< 100GB):**

```yaml
# In patroni-node-1.yml
postgresql:
  parameters:
    shared_buffers: 256MB        # 25% RAM
    effective_cache_size: 768MB  # Total cache (RAM)
    work_mem: 4MB                # Per operation
```

**For large clusters (> 1TB):**

```yaml
postgresql:
  parameters:
    shared_buffers: 8GB          # 25% of 32GB RAM
    effective_cache_size: 24GB   # 75% of RAM
    work_mem: 256MB              # Per operation
    max_parallel_workers_per_gather: 4
    max_parallel_io_workers: 4
```

Apply tuning:

```bash
# Edit patroni-node-1.yml with tuned values
terraform plan  # Review changes
terraform apply # Apply configuration

# PostgreSQL will reload without restart
docker logs pg-node-1 | grep -i "reloaded"
```

### Index Maintenance

```bash
# Check index usage
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT schemaname, tablename, indexname, idx_scan 
   FROM pg_stat_user_indexes 
   WHERE idx_scan = 0  -- unused indexes"

# Drop unused indexes (careful!)
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "DROP INDEX CONCURRENTLY unused_index_name;"

# Rebuild fragmented indexes
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "REINDEX INDEX CONCURRENTLY idx_items_embedding;"
```

## Maintenance Windows

### Zero-Downtime Maintenance

1. **Patch replica first (pg-node-2)**
   ```bash
   docker restart pg-node-2  # Replicas can restart
   sleep 5
   curl http://localhost:8008/cluster  # Verify still healthy
   ```

2. **Patch second replica (pg-node-3)**
   ```bash
   docker restart pg-node-3
   sleep 5
   curl http://localhost:8008/cluster
   ```

3. **Switchover and patch primary**
   ```bash
   # Switchover: demote pg-node-1, promote pg-node-2 or pg-node-3
   curl -X POST http://localhost:8008/switchover \
     -d '{"leader": "pg-node-1", "candidate": "pg-node-2"}'
   
   # Wait for switchover
   sleep 10
   
   # Now pg-node-1 is replica, safe to patch
   docker restart pg-node-1
   sleep 5
   curl http://localhost:8008/cluster
   ```

### VACUUM & ANALYZE Schedule

```bash
# Add to crontab (Sunday 2 AM)
0 2 * * 0 docker exec pg-node-1 psql -U pgadmin postgres -c "VACUUM ANALYZE items;"

# For large tables, use concurrent variant
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "VACUUM (ANALYZE, VERBOSE) items;"  # Blocks writes

# Or on replica
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "ANALYZE items;"  # Non-blocking
```

## WAL Management

### Check WAL Archiving

```bash
# Status
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT archived_count, failed_count, last_archived_wal 
   FROM pg_stat_archiver;"

# If failed_count > 0, archives aren't working
# Check pgbackrest logs:
docker logs pg-node-1 | grep -i archive

# Force re-archive
docker exec pg-node-1 pgbackrest backup --type=incr
```

### Prevent WAL Disk Overflow

```bash
# If WAL directory grows too large
docker exec pg-node-1 du -sh /var/lib/postgresql/pg_wal/

# If > 5GB:
# 1. Check wal_keep_size setting
docker exec pg-node-1 psql -U pgadmin postgres -c "SHOW wal_keep_size;"

# 2. Increase if needed (in patroni-node-1.yml)
# postgresql:
#   parameters:
#     wal_keep_size: 2GB  # default 1GB

# 3. Or trigger checkpoint to flush old WAL
docker exec pg-node-1 psql -U pgadmin postgres -c "CHECKPOINT FAST;"

# 4. Restart if needed
docker restart pg-node-1
```

## Monitoring Essentials

### Automated Health Script

```bash
#!/bin/bash
# save as check-ha.sh

ERRORS=0

# 1. Check all containers running
for NODE in pg-node-1 pg-node-2 pg-node-3 etcd dbhub; do
  if ! docker ps | grep -q $NODE; then
    echo "ERROR: $NODE not running"
    ERRORS=$((ERRORS + 1))
  fi
done

# 2. Check primary elected
PRIMARY=$(curl -s http://localhost:8008/leader 2>/dev/null | jq -r '.leader // ""')
if [ -z "$PRIMARY" ]; then
  echo "ERROR: No primary elected"
  ERRORS=$((ERRORS + 1))
fi

# 3. Check replication lag
LAG=$(docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int" -t 2>/dev/null || echo "-1")

if [ "$LAG" -gt 10 ]; then
  echo "WARNING: Replication lag: ${LAG}s"
fi

# 4. Check disk usage
DISK=$(docker exec pg-node-1 df /var/lib/postgresql | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$DISK" -gt 90 ]; then
  echo "ERROR: Disk usage: ${DISK}%"
  ERRORS=$((ERRORS + 1))
fi

# Exit with error code if problems found
exit $ERRORS
```

Add to crontab:

```bash
# Run every 5 minutes, send alerts if fails
*/5 * * * * /path/to/check-ha.sh || mail -s "HA Cluster Alert" ops@company.com < /tmp/ha-status.log
```

## Disaster Recovery Runbook

### Scenario: Two Nodes Down (Only 1 Replica Up)

```bash
# Cluster is degraded but still running

# 1. Check which nodes are down
docker ps -a | grep -v "Up"

# 2. Check if primary is still alive
curl http://localhost:8008/leader

# 3. If primary alive:
# - Cluster continues (with reduced replicas)
# - Data is safe on primary
# - Restart failed nodes when ready

docker start pg-node-2  # or whichever is down

# 4. If primary is DOWN:
# - Only 1 replica left (can't form quorum)
# - Cluster cannot function

# To recover:
# a) Immediately restart primary OR
# b) Promote last remaining replica as new primary (data loss possible)

# Option A (Preferred - if primary comes back):
docker start pg-node-1
sleep 10
docker start pg-node-2
curl http://localhost:8008/cluster  # Verify recovery

# Option B (Emergency - if primary won't come back):
# Promote pg-node-3 manually (will lose recent changes)
docker exec pg-node-3 pg_ctl promote -D /var/lib/postgresql
docker restart pg-node-3
# Now pg-node-3 is the new primary (data loss of recent transactions)
```

### Scenario: Corrupted Primary Data

Data corruption detected on primary (pgvector embeddings, table structure, etc.)

```bash
# 1. Verify replicas are healthy
docker exec pg-node-2 psql -U pgadmin postgres -c "SELECT COUNT(*) FROM items;"
docker exec pg-node-3 psql -U pgadmin postgres -c "SELECT COUNT(*) FROM items;"

# 2. If replicas OK, promote healthiest replica
curl -X POST http://localhost:8008/switchover \
  -d '{"leader": "pg-node-1", "candidate": "pg-node-2"}'

# 3. Rebuild corrupted node
docker exec pg-node-1 rm -rf /var/lib/postgresql/*
docker restart pg-node-1  # Will rebuild from new primary

# 4. Verify recovery
docker logs pg-node-1 | grep -i "streaming\|basebackup\|ready"

# 5. Restore full cluster health
curl http://localhost:8008/cluster | jq '.members[] | {name, role, state}'
```

### Scenario: All Nodes Lost (Complete Restore)

```bash
# 1. Restore from backup (if available)
docker exec pg-node-1 pgbackrest restore

# 2. Start cluster
docker start pg-node-1
sleep 10
docker start pg-node-2 pg-node-3

# 3. Verify
curl http://localhost:8008/cluster

# If no backup exists (worst case - data loss):
# - Terraform destroy (remove all containers/volumes)
# - Terraform apply (fresh cluster)
# - Restore from external backup (if available)
```

## Useful Commands Reference

```bash
# Cluster commands
curl http://localhost:8008/cluster            # Full cluster status
curl http://localhost:8008/leader             # Who is primary
curl http://localhost:8008/health -I          # Node health

# Container management
docker logs pg-node-1 --tail 50              # Recent logs
docker exec pg-node-1 psql -U pgadmin ...    # Run SQL
docker restart pg-node-1                      # Restart container

# PostgreSQL commands
SELECT pg_current_wal_lsn()                  # Current WAL position
SELECT * FROM pg_replication_slots            # Replication slots
SELECT * FROM pg_stat_replication             # Replica status
CHECKPOINT FAST                                # Force checkpoint
VACUUM ANALYZE                                 # Clean & optimize

# Patroni REST API
curl -X POST http://localhost:8008/switchover # Initiate switchover
curl -X POST http://localhost:8008/reinitialize # Reset cluster choice

# pgBackRest
pgbackrest backup                             # Trigger backup
pgbackrest info                               # Show backup info
pgbackrest backup --type=incr                 # Incremental backup
pgbackrest check                              # Check archiving

# etcd
docker exec etcd etcdctl member list           # etcd members
docker exec etcd etcdctl get /patroni --prefix # Patroni config
```

## References

- [Patroni Documentation](https://patroni.readthedocs.io/) - HA management
- [PostgreSQL HA Guide](https://www.postgresql.org/docs/18/warm-standby.html) - Streaming replication
- [PgBackRest User Guide](https://pgbackrest.org/user-guide.html) - Backup & recovery
- [etcd Documentation](https://etcd.io/docs/) - Distributed consensus

---

**Last Updated:** 2024
**Version:** 1.0 - PostgreSQL 18 + Patroni 3.0.4 + pgvector 0.8.1
