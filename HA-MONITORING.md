# PostgreSQL HA Cluster - Monitoring & Observability Guide

## Monitoring Overview

This guide covers monitoring and observability for the 3-node PostgreSQL HA cluster with Patroni, etcd, and PgBackRest.

## Quick Health Check

### One-Command Health Status

```bash
# Get entire cluster status in one call
curl -s http://localhost:8008/cluster | jq '{
  cluster_name: .cluster_name,
  members: [.members[] | {name, role: .role, state: .state}],
  primary: .members[] | select(.role=="primary") | .name
}'
```

### Expected Output

```json
{
  "cluster_name": "pg-ha-cluster",
  "members": [
    {
      "name": "pg-node-1",
      "role": "primary",
      "state": "running"
    },
    {
      "name": "pg-node-2",
      "role": "replica",
      "state": "in_sync"
    },
    {
      "name": "pg-node-3",
      "role": "replica",
      "state": "in_sync"
    }
  ],
  "primary": "pg-node-1"
}
```

## Container Health Monitoring

### Docker Container Status

```bash
# Check all containers are running
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Expected status: Up X minutes

# Check for restart loops (container restarted > N times = problem)
docker inspect pg-node-1 | grep RestartCount
# Expected: <5 per 24 hours
```

### Container Logs Analysis

```bash
# Recent 50 lines of primary logs
docker logs --tail 50 pg-node-1

# Follow logs in realtime
docker logs -f pg-node-1

# grep for errors
docker logs pg-node-1 2>&1 | grep -i "error\|fatal\|panic"

# Check sync status (quorum-synced replicas)
docker logs pg-node-1 2>&1 | grep -i "synchronous\|in_sync"
```

## Patroni REST API Monitoring

### Cluster Status Endpoint

```bash
# Full cluster details
curl http://localhost:8008/cluster | jq '.'

# Key fields:
# - members[].state: "running", "in_sync", "streaming", "catch-up"
# - members[].role: "primary", "replica", "demoted"
# - features: [supported_features]
```

### Node Role & Status

```bash
# Get specific node's role
curl http://localhost:8008/role

# Possible responses:
# - "primary\n"
# - "replica\n"
# - "demoted\n"

# Wrap for JSON parsing
curl -s http://localhost:8008/role | sed 's/\(.*\)/"\1"/'
```

### Primary Node Info

```bash
# Get current primary node name
curl -s http://localhost:8008/leader | jq '.'

# Response:
# {
#   "leader": "pg-node-1"
# }

# If no primary elected:
#   null
```

### Replica Health

```bash
# Check all replicas synchronization state
curl -s http://localhost:8008/cluster | jq '.members[] | select(.role=="replica")'

# Shows: {
#   "name": "pg-node-2",
#   "role": "replica",
#   "state": "in_sync",      ← should be "in_sync"
#   "lag": 0,                 ← lag in bytes
#   "db_lsn": "0/30000D50"
# }
```

### Watchdog Status (Health)

```bash
# Check all nodes are alive (watchdog)
curl -s http://localhost:8008/cluster | jq '.cluster_bootstrap'

# Or check individual node health
curl http://localhost:8009/health -I
# HTTP status: 200 OK = healthy
# HTTP status: 503 = unhealthy
```

## PostgreSQL Replication Monitoring

### Connection Status

```bash
# Check replication connections from primary
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT client_addr, state, state_change FROM pg_stat_replication;"

# Expected output:
# ┌──────────────┬──────────┬──────────────────────────┐
# │ client_addr  │  state   │      state_change        │
# ├──────────────┼──────────┼──────────────────────────┤
# │ 192.168.0.2  │ streaming│ 2024-01-15 10:30:15+00   │
# │ 192.168.0.3  │ streaming│ 2024-01-15 10:30:20+00   │
# └──────────────┴──────────┴──────────────────────────┘
```

### Replication Lag

```bash
# On primary: Get lag of each replica (in bytes)
docker exec pg-node-1 psql -U pgadmin postgres -c "
  SELECT client_addr,
         (pg_current_wal_lsn() - lsn) as lag_bytes,
         state,
         sync_state
  FROM pg_stat_replication;"

# Expected: lag_bytes < 1000000 (< 1MB = good)

# On replica: Get lag behind primary (in time)
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"

# Expected: < 1 second (typically 0-100ms)
```

### Replication Slots

```bash
# View active replication slots
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT slot_name, slot_type, active, retained_bytes FROM pg_replication_slots;"

# Expected output:
# ┌──────────┬───────────┬────────┬─────────────┐
# │ slot_name│ slot_type │ active │ retained_... │
# ├──────────┼───────────┼────────┼─────────────┤
# │ node_slot_2 │ physical│ t      │ 16777216  │
# │ node_slot_3 │ physical│ t      │ 16777216  │
# └──────────────┴─────────────┴────────┴─────────────┘

# Slots should be active=true; retained_bytes < 1GB
```

### Recovery Status

```bash
# Check if node is in recovery (standby/replica)
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT pg_is_in_recovery();"

# true = replica mode (expected on pg-node-2, pg-node-3)
# false = primary mode (expected on pg-node-1)
```

## WAL (Write-Ahead Log) Monitoring

### WAL Activity

```bash
# Current WAL LSN (Log Sequence Number)
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT pg_current_wal_lsn();"

# Last applied LSN on replica
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT pg_last_wal_receive_lsn() as received, 
          pg_last_wal_replay_lsn() as replayed;"

# If received > replayed: replica is catching up (lag exists)
```

### WAL File Accumulation

```bash
# Count WAL files waiting to be archived
docker exec pg-node-1 ls -1 /var/lib/postgresql/pg_wal/ | wc -l

# Expected: < 200 files (unless archiving is blocked)

# Check WAL directory size
docker exec pg-node-1 du -sh /var/lib/postgresql/pg_wal/

# Expected: < 10GB
```

### WAL Archiving Status

```bash
# Check if WAL archiving is enabled and working
docker exec pg-node-1 psql -U pgadmin postgres -c "
  SELECT archived_count,
         failed_count,
         (CASE WHEN failed_count > 0 THEN 'FAILING' ELSE 'OK' END) as status
  FROM pg_stat_archiver;"

# Good state:
# - failed_count = 0
# - archived_count growing over time
```

## PgBackRest Backup Monitoring

### Backup Status

```bash
# Info about all backups
docker exec pg-node-1 pgbackrest info

# Example output:
# stanza: pg-ha
#   status: backup, archive-push, archive-get
#   wal archive min/max (18): 000000010000000000000001/000000010000000018
#   full backup: 20240115-103015F
#     timestamp start/stop: 2024-01-15 10:30:15 UTC / 10:35:45 UTC
#     wal included: 000000010000000000000001 to 000000010000000018
#     database size: 125 MB
#     backup size: 75 MB
```

### Recent Backup Details

```bash
# Show backup timeline
docker exec pg-node-1 pgbackrest info --output=json | jq '.backup[]'

# Check if recent full backup exists
docker exec pg-node-1 pgbackrest info | grep -A 3 "full backup:"
# Should see a backup from today (or recent date)
```

### Backup Retention Policy

```bash
# View retention settings
docker exec pg-node-1 cat /var/lib/pgbackrest/pgbackrest.conf | grep -E "retain|expire"

# Expected:
# repo1-retention-full=7         = keep 7 days of full backups
# repo1-retention-diff=3         = keep 3 days of incremental/differential

# Manually expire old backups
docker exec pg-node-1 pgbackrest expire
```

### WAL Archive Status (for PITR)

```bash
# Verify WAL files are being archived
docker exec pg-node-1 pgbackrest info --with-archive

# Provides info on available WAL for point-in-time recovery
```

## etcd Distributed Consensus Monitoring

### etcd Health

```bash
# Check etcd cluster health
docker exec etcd etcdctl endpoint health

# Expected: healthy, took <100ms

# Check member count
docker exec etcd etcdctl member list

# Expected: 1 member (or 3+ in production)
```

### Patroni Configuration in etcd

```bash
# View current Patroni configuration stored in etcd
docker exec etcd etcdctl get /patroni --prefix | head -30

# Check cluster leadership decision
docker exec etcd etcdctl get /patroni/pg-ha-cluster/leader

# Should return current primary node
```

### etcd Performance

```bash
# Measure etcd latency
docker exec etcd etcdctl --endpoints=localhost:2379 endpoint health --dial-timeout=500ms

# Good latency: < 100ms
# Acceptable: 100-500ms
# Poor: > 500ms (failover takes longer)
```

## Database Activity Monitoring

### Connection Count

```bash
# Total connections
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;"

# Expected: < (max_connections / 2)

# Find idle connections
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT pid, usename, state, query, state_change 
   FROM pg_stat_activity 
   WHERE state = 'idle' 
   ORDER BY state_change DESC LIMIT 10;"
```

### Query Performance

```bash
# Top 10 slowest queries
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT query, calls, total_time/1000 as total_sec, 
          (total_time/calls/1000) as avg_ms
   FROM pg_stat_statements 
   ORDER BY total_time DESC LIMIT 10;"

# Queries using lots of memory
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT query, rows, mean_time 
   FROM pg_stat_statements 
   ORDER BY rows DESC LIMIT 10;"
```

### Cache Hit Ratio

```bash
# Check cache efficiency (should be > 99%)
docker exec pg-node-1 psql -U pgadmin postgres -c "
  SELECT sum(heap_blks_read) as disk_reads,
         sum(heap_blks_hit) as cache_hits,
         ROUND(100 * sum(heap_blks_hit) / 
               (sum(heap_blks_hit) + sum(heap_blks_read)), 2) 
               as cache_hit_ratio
  FROM pg_statio_user_tables;"

# Expected: cache_hit_ratio > 99%
```

### Disk Usage

```bash
# Database size
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) 
   FROM pg_database ORDER BY pg_database_size(datname) DESC;"

# Table sizes
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
   FROM pg_tables ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;"
```

## pgvector Extension Monitoring

### Extension Status

```bash
# Verify pgvector is installed
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname='vector';"

# Expected: vector 0.8.1

# Check on replicas too (should match)
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname='vector';"
```

### Vector Data Statistics

```bash
# Count vectors in items table
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT COUNT(*) as total_items, 
          COUNT(embedding) as vectors_count,
          COUNT(CASE WHEN embedding IS NULL THEN 1 END) as null_vectors
   FROM items;"

# Check index statistics
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch 
   FROM pg_stat_user_indexes 
   WHERE schemaname='public' AND indexname='idx_items_embedding';"

# idx_scan = 0: index not being used (consider removing)
```

### Vector Index Health

```bash
# Check index size
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT schemaname, indexname, pg_size_pretty(pg_relation_size(indexrelid)) as size
   FROM pg_stat_user_indexes 
   WHERE indexname='idx_items_embedding';"

# Rebuild index if it grows too large
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "REINDEX INDEX CONCURRENTLY idx_items_embedding;"
```

## Monitoring Dashboards (Integration)

### Prometheus Metrics (Integration)

To expose Prometheus metrics from Patroni:

```bash
# Patroni exposes metrics on /metrics endpoint (if configured)
# Add to Prometheus scrape config:

# - job_name: 'patroni'
#   static_configs:
#     - targets: ['localhost:8008', 'localhost:8009', 'localhost:8010']
#   metrics_path: '/metrics'
```

### Grafana Dashboard

Key metrics to visualize:

```
- Cluster Status (members, primary, replicas)
- Replication Lag (seconds)
- WAL File Count
- Query Performance (avg response time)
- Cache Hit Ratio
- Disk Usage
- Connection Count
- Backup Status
- pgvector Operations/sec
```

## Alerting Rules

### Critical Alerts

**NO PRIMARY ELECTED**
```
Condition: curl http://localhost:8008/leader returns null
Action: Page on-call engineer immediately
Timeout: 30 seconds
```

**REPLICATION LAG > 10s**
```
Condition: now() - pg_last_xact_replay_timestamp() > 10 seconds
Action: Warn engineer, check replica health
Timeout: 5 minutes
```

**BACKUP FAILED**
```
Condition: pgbackrest info shows failed_count > 0
Action: Alert and review logs
Timeout: 1 day
```

**DISK FULL > 90%**
```
Condition: df /var/lib/postgresql > 90%
Action: Page engineer to add storage
Timeout: 1 hour
```

### Warning Alerts

**REPLICATION LAG > 1s** - Check network/load
**WAL FILES > 200** - Archiving may be backing up
**CACHE HIT RATIO < 95%** - May need more memory
**SLOW QUERY > 5s** - Investigate query performance

## Monitoring Scripts

### Automated Health Check Script

```bash
#!/bin/bash
# save as health_check.sh

set -e

echo "=== PostgreSQL HA Cluster Health Check ==="
echo "Time: $(date)"

# 1. Cluster Status
STATUS=$(curl -s http://localhost:8008/cluster 2>/dev/null || echo "OFFLINE")
if [ "$STATUS" != "OFFLINE" ]; then
  PRIMARY=$(echo $STATUS | jq -r '.members[] | select(.role=="primary") | .name' 2>/dev/null || echo "NONE")
  REPLICAS=$(echo $STATUS | jq -r '.members[] | select(.role!="primary") | .name' 2>/dev/null || echo "NONE")
  echo "✓ Cluster Status: OK"
  echo "  Primary: $PRIMARY"
  echo "  Replicas: $REPLICAS"
else
  echo "✗ Cluster Status: OFFLINE"
  exit 1
fi

# 2. Container Health
for NODE in pg-node-1 pg-node-2 pg-node-3; do
  if docker ps | grep -q $NODE; then
    echo "✓ $NODE: Running"
  else
    echo "✗ $NODE: Not running"
  fi
done

# 3. Replication Lag
LAG=$(docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int as lag" 2>/dev/null || echo "-1")

if [ "$LAG" -lt 1 ]; then
  echo "✓ Replication Lag: ${LAG}s (OK)"
elif [ "$LAG" -lt 10 ]; then
  echo "⚠ Replication Lag: ${LAG}s (WARNING)"
else
  echo "✗ Replication Lag: ${LAG}s (CRITICAL)"
fi

# 4. Backup Status
BACKUP_STATUS=$(docker exec pg-node-1 pgbackrest info 2>/dev/null | grep -c "full backup" || echo "0")
if [ "$BACKUP_STATUS" -gt 0 ]; then
  echo "✓ Backup Status: OK"
else
  echo "⚠ Backup Status: No backups found"
fi

echo ""
echo "=== Check Complete ==="
```

### Cron Job for Periodic Monitoring

```bash
# Run every 5 minutes
*/5 * * * * /path/to/health_check.sh >> /var/log/pg-ha-health.log 2>&1

# Run backup check daily at 2 AM
0 2 * * * docker exec pg-node-1 pgbackrest backup >> /var/log/pg-backup.log 2>&1
```

## Long-Term Trend Analysis

### Weekly Health Report

```bash
#!/bin/bash
# Generate weekly monitoring report

echo "=== PostgreSQL HA Weekly Report ==="
echo "Week: $(date +%Y-W%V)"
echo ""

# Failover count
docker logs pg-node-1 | grep -c "became primary" || echo "Failovers: 0"

# Backup count
docker exec pg-node-1 pgbackrest info | grep "full backup" | wc -l | xargs -I {} echo "Backups: {}"

# Uptime
docker inspect pg-node-1 | grep StartedAt

# Replication slots ever disconnected
docker logs pg-node-1 | grep -c "slot" || echo "Slot issues: 0"
```

## References

- [PostgreSQL Monitoring Documentation](https://www.postgresql.org/docs/18/monitoring.html)
- [Patroni REST API](https://patroni.readthedocs.io/en/latest/rest_api.html)
- [pgBackRest Monitoring](https://pgbackrest.org/user-guide.html)
- [etcd Monitoring](https://etcd.io/docs/v3.5/metrics/)
