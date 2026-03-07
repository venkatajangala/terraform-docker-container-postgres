# 🛠️ Operations & Maintenance Guide

How to operate, maintain, and troubleshoot your PostgreSQL HA cluster.

## Daily Operations

### Check Cluster Status

```bash
# Quick health check
curl -s http://localhost:8008/leader | python3 -m json.tool

# Full cluster view
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -E '"name"|"state"|"role"|"lag"'

# Check all containers
docker ps | grep -E 'pg-node|pgbouncer|etcd'
```

### Monitor PgBouncer

```bash
# Connect to admin console
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Common commands (inside admin console)
pgbouncer> SHOW POOLS;       # Pool statistics
pgbouncer> SHOW STATS;       # Detailed statistics
pgbouncer> SHOW CLIENTS;     # Active clients
pgbouncer> SHOW CONFIG;      # Current configuration
pgbouncer> \q                # Exit
```

### View Logs

```bash
# Primary node
docker logs pg-node-1 -f

# Other nodes
docker logs pg-node-2 -f
docker logs pg-node-3 -f

# PgBouncer logs
docker logs pgbouncer-1 -f
docker logs pgbouncer-2 -f

# etcd logs
docker logs etcd -f
```

## Weekly Maintenance Tasks

### Verify Replication

```bash
# Check on primary
docker exec pg-node-1 psql -U postgres -d postgres << 'EOF'
SELECT 
  application_name,
  client_addr,
  state,
  sync_state,
  write_lag,
  flush_lag,
  replay_lag
FROM pg_stat_replication;
EOF
```

### Check Cluster Consensus

```bash
# View etcd cluster status
curl -s http://localhost:12379/v3/cluster/member/list | python3 -m json.tool

# Check Patroni consensus
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -E '"dcs_last_seen"|"timeline"'
```

### Disk Usage Monitoring

```bash
# Docker volume sizes
docker volume ls | grep pg

# Check specific volume usage
docker exec pg-node-1 du -sh /var/lib/postgresql/18/main

# Check available disk
docker exec pg-node-1 df -h /
```

## Monthly Tasks

### Test Failover

**⚠️ IMPORTANT: Do this during low-traffic windows only**

```bash
# Step 1: Record current leader
curl -s http://localhost:8008/leader | python3 -m json.tool | grep '"name"'

# Step 2: Stop the primary
docker stop pg-node-1

# Step 3: Wait 30 seconds
sleep 30

# Step 4: Check new leader elected
curl -s http://localhost:8008/leader | python3 -m json.tool | grep '"name"'
# Should show pg-node-2 or pg-node-3

# Step 5: Verify applications still work
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT version();"

# Step 6: Bring primary back online
docker start pg-node-1

# Step 7: Verify cluster heals
sleep 30
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -c '"role"'
# Should show 3 members
```

### Review Slow Queries

```bash
# Connect to primary
docker exec -it pg-node-1 psql -U postgres -d postgres

# Enable logging (if not already)
postgres> CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
postgres> SET log_min_duration_statement = 1000;  -- Log queries > 1s

# Find slow queries
postgres> SELECT query, mean_exec_time FROM pg_stat_statements 
          ORDER BY mean_exec_time DESC LIMIT 10;

postgres> \q
```

### Check Backup Status (if pgBackRest configured)

```bash
# List backups
docker exec pg-node-1 pgbackrest info 2>/dev/null || echo "pgBackRest not configured"

# Create ad-hoc backup (if needed)
docker exec pg-node-1 pgbackrest backup --backup-standby 2>/dev/null || echo "Configure backup first"
```

## Scaling Operations

### Add More Data

```bash
# Create table
psql -h localhost -p 6432 -U pgadmin -d postgres << 'EOF'
CREATE TABLE production_data AS
SELECT 
  generate_series(1, 1000000) as id,
  md5(random()::text) as data,
  NOW() as created_at;
CREATE INDEX idx_prod_id ON production_data(id);
EOF

# Verify on replica
psql -h localhost -p 5433 -U pgadmin -d postgres << 'EOF'
SELECT COUNT(*) FROM production_data;
EOF
```

### Monitor Connection Pools

```bash
# Check current pool usage
psql -h localhost -p 6432 -U pgadmin -d pgbouncer << 'EOF'
SELECT 
  database,
  user,
  pool_mode,
  cl_active,
  cl_waiting,
  sv_active,
  sv_idle
FROM pgbouncer.pools;
EOF

# If approaching limits, increase in ha-test.tfvars:
# pgbouncer_default_pool_size = 50  (from 25)
# pgbouncer_max_client_conn = 2000   (from 1000)
# Then redeploy: terraform apply -var-file="ha-test.tfvars"
```

## Performance Tuning

### PostgreSQL Connection Parameters

Edit `patroni/patroni-node-*.yml`:

```yaml
postgresql:
  parameters:
    # Connection handling
    max_connections: 100                 # Default: 100 (increase if needed)
    superuser_reserved_connections: 3    # Default: 3

    # Memory settings
    shared_buffers: 256MB               # Default: 256MB (tune for your RAM)
    effective_cache_size: 1GB           # Set to ~25% of total RAM
    work_mem: 4MB                       # Per operation memory

    # Replication
    max_wal_senders: 5                  # Default: 5 (one for each replica + margin)
    wal_keep_size: 1GB                  # Default: 0 (keep WAL for streaming)
    max_replication_slots: 10           # Default: 10
```

Then redeploy:
```bash
terraform apply -var-file="ha-test.tfvars"
```

### PgBouncer Tuning

Edit `pgbouncer/pgbouncer.ini`:

```ini
;; For high-throughput (many connections)
default_pool_size = 50              # Increase from 25
min_pool_size = 10                  # Increase from 5
reserve_pool_size = 10              # Increase from 5
max_client_conn = 2000              # Increase from 1000

;; For low-latency
pool_mode = session                 # Instead of transaction

;; For debugging
log_connections = 1
log_disconnections = 1
```

Then redeploy:
```bash
terraform apply -var-file="ha-test.tfvars"
```

## Backup & Recovery

### Manual Backup

```bash
# Full database backup
docker exec pg-node-1 pg_dump -U postgres -F custom -f /tmp/backup.dump postgres

# Copy out of container
docker cp pg-node-1:/tmp/backup.dump ./backup.dump

# Compress
gzip backup.dump
```

### Restore from Backup

```bash
# Stop cluster
docker-compose down

# Rebuild from backup (advanced - see PostgreSQL docs)
# This requires careful coordination with Patroni and etcd

# Simpler: Use Patroni's built-in recovery
# Restore primary, replicas sync automatically
```

## Upgrades & Maintenance Windows

### PostgreSQL Minor Version Upgrade

```bash
# 1. Save state
docker ps -a

# 2. Update Dockerfile.patroni (change base image version)
# 3. Redeploy
terraform apply -var-file="ha-test.tfvars"

# 4. Verify
curl -s http://localhost:8008/leader | python3 -m json.tool
```

### Patroni/etcd Upgrade

```bash
# Update Dockerfile.patroni to new version
# Redeploy
terraform apply -var-file="ha-test.tfvars"

# Verify
docker exec pg-node-1 patronictl --version
```

## Emergency Procedures

### Primary Node Completely Down

If the primary won't start:

```bash
# 1. Check if replica can be promoted
docker exec pg-node-2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# Result: f = primary, t = replica

# 2. Wait - Patroni will auto-elect new primary
sleep 30

# 3. Verify
curl -s http://localhost:8008/leader

# 4. Fix original primary
docker logs pg-node-1
# Apply fixes, restart

docker start pg-node-1
sleep 30

# 5. Verify recovery
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

### Network Partition

If a node is isolated from etcd:

```bash
# 1. Node detects it's in minority partition
docker logs pg-node-1 | grep "promote"

# 2. Node shuts down to prevent split-brain
docker ps | grep pg-node-1

# 3. Restore network
# Node automatically rejoins after network is fixed

# 4. If not rejoining automatically
docker start pg-node-1
sleep 30
curl -s http://localhost:8008/cluster
```

### All Nodes Down (Disaster Recovery)

```bash
# 1. Check for data corruption
for i in 1 2 3; do
  echo "=== Node $i ==="
  docker logs pg-node-$i | tail -20
done

# 2. Start primary only
docker start pg-node-1
sleep 60

# 3. Start replicas
docker start pg-node-2 pg-node-3
sleep 60

# 4. Verify recovery
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

## Monitoring Health

### Create Monitoring Dashboard

```bash
# Check every 10 seconds
watch -n 10 'curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -E "\"name\"|\"state\"|\"role\"'
```

### Set Up Alerts

```bash
# Simple script to monitor and alert
cat > monitor.sh << 'EOF'
#!/bin/bash
while true; do
  STATUS=$(curl -s http://localhost:8008/leader | python3 -c "import sys, json; print(json.load(sys.stdin).get('state', 'unknown'))")
  if [ "$STATUS" != "running" ]; then
    echo "ALERT: Cluster status is $STATUS"
    # Send email, Slack, etc.
  fi
  sleep 30
done
EOF

chmod +x monitor.sh
./monitor.sh &
```

## Maintenance Windows

### Safe Maintenance Procedure

```bash
# 1. Take primary out of rotation
docker stop pg-node-1
sleep 30

# 2. Let replica become primary
curl -s http://localhost:8008/leader

# 3. Do maintenance on stopped primary
docker exec pg-node-1 reboot  # or update, etc.

# 4. Restart primary
docker start pg-node-1
sleep 30

# 5. Verify cluster health
curl -s http://localhost:8008/cluster
```

## Regular Inspections

### Monthly Health Check Checklist

- [ ] All 3 PostgreSQL nodes running
- [ ] All 2 PgBouncer instances healthy
- [ ] etcd cluster has quorum (2/2 or 3/3)
- [ ] Replication lag < 100ms
- [ ] No connection pool exhaustion
- [ ] No slow queries > 5s
- [ ] Disk usage < 80%
- [ ] All containers memory healthy
- [ ] Failover test successful
- [ ] Backups running (if configured)

## Documentation References

- [PostgreSQL Administration](https://www.postgresql.org/docs/18/admin.html)
- [Patroni Management](https://patroni.readthedocs.io/en/latest/patroni_documentation.html)
- [PgBouncer Admin](https://www.pgbouncer.org/usage.html)
- [etcd Maintenance](https://etcd.io/docs/v3.5/op-guide/maintenance/)
