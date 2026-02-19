# HA Cluster Deployment Guide

This guide walks you through deploying and verifying the 3-node PostgreSQL HA cluster.

## Prerequisites Checklist

- [ ] Terraform v1.0+ installed: `terraform version`
- [ ] Docker v20.10+ installed: `docker version`
- [ ] Docker daemon running: `docker ps`
- [ ] 8GB+ RAM available: `free -h`
- [ ] 20GB+ disk space: `df -h /var/lib/postgresql` (or your Docker volume mount)
- [ ] All HA files present (check [HA-SETUP-GUIDE.md](HA-SETUP-GUIDE.md))

## Step 1: Review Configuration

### A. Check Terraform Files

```bash
# Verify all required files exist
ls -la main-ha.tf variables-ha.tf outputs-ha.tf

# Review configuration
cat variables-ha.tf | grep -E "default|type"
```

### B. Generate tfvars File (Optional)

Create a `ha.tfvars` file to store variables:

```bash
cat > ha.tfvars <<EOF
postgres_user     = "pgadmin"
postgres_password = "SecurePassword123!"
postgres_db       = "postgres"
replication_password = "ReplicationPass456!"
dbhub_port        = 9090
etcd_port         = 2379
patroni_api_port_base = 8008
EOF

# Protect credentials
chmod 600 ha.tfvars
```

## Step 2: Initialize Terraform

```bash
# Initialize Terraform (downloads Docker provider)
terraform init

# Expected output:
# Terraform has been successfully configured!
# You may now begin working with Terraform.
```

## Step 3: Plan Deployment

```bash
# Review what will be created (no changes yet)
terraform plan -var-file="ha.tfvars"

# Or inline (for testing):
terraform plan \
  -var="postgres_password=TestPass123!" \
  -var="replication_password=ReplicaPass456!"

# Review the output carefully:
# - Should show: 1 network, 1 image, 9-13 resources (volumes, containers)
# - Should NOT show any destroy operations
```

**Expected Plan Output:**
```
Plan: 13 to add, 0 to change, 0 to destroy.

Resources to be added:
  - docker_network.pg_ha_network
  - docker_volume.etcd_data
  - docker_volume.pg_node_1_data
  - docker_volume.pg_node_2_data
  - docker_volume.pg_node_3_data
  - docker_volume.pgbackrest_repo
  - docker_image.postgres_patroni
  - docker_container.etcd
  - docker_container.pg_node_1
  - docker_container.pg_node_2
  - docker_container.pg_node_3
  - docker_container.dbhub
  - ... (any other resources)
```

## Step 4: Deploy the Cluster

### Full Deployment

```bash
# Deploy all resources (will take 2-5 minutes)
terraform apply -var-file="ha.tfvars"

# Or with inline variables:
terraform apply \
  -var="postgres_password=TestPass123!" \
  -var="replication_password=ReplicaPass456!" \
  -auto-approve

# Expected output:
# Apply complete! Resources: 13 added, 0 changed, 0 destroyed.
```

### Expected Timeline

| Time | Event | Status |
|------|-------|--------|
| 0s | Docker images built | etcd, pgvector+Patroni |
| 10s | etcd container started | Port 2379 listening |
| 15s | pg-node-1 container started | PostgreSQL initializing |
| 20s | pg-node-1 PostgreSQL ready | Port 5432 listening |
| 25s | Patroni begins | Connects to etcd |
| 30s | pg-node-2 starts | Performing basebackup |
| 35s | pg-node-3 starts | Performing basebackup |
| 45s | Patroni elects primary | pg-node-1 becomes primary |
| 50s | Replicas sync | In-sync status |
| 55s | DBHub container started | Port 9090 listening |
| 60s | Full cluster ready | ✓ Deployment complete |

### Monitor Deployment Progress

In another terminal, watch containers start:

```bash
# Real-time container status
watch -n 2 'docker ps --format "table {{.Names}}\t{{.Status}}"'

# Real-time logs from primary node
docker logs -f pg-node-1 2>&1 | grep -E "Patroni|bootstrap|elected|streaming"
```

## Step 5: Initial Verification

### A. Container Health

```bash
# All containers running?
docker ps | grep -E "pg-node|etcd|dbhub"

# Expected: 5 containers (etcd, pg-node-1/2/3, dbhub) all "Up X seconds"

# No errors/crashes?
docker ps -a | grep -v "Up"
# Expected: empty (all containers healthy)
```

### B. Cluster Status

```bash
# Check cluster membership
curl http://localhost:8008/cluster

# Expected JSON response with 3 members
# Look for: "members": [{"name": "pg-node-1"...}, {"name": "pg-node-2"...}, ...]
```

### C. Check Primary Election

```bash
# Who is primary?
curl http://localhost:8008/leader

# Expected: {"leader": "pg-node-1"}

# If null/empty, wait 30 seconds and retry
sleep 30
curl http://localhost:8008/leader
```

### D. Verify Replication

```bash
# Connect to primary and check replicas
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT client_addr, state FROM pg_stat_replication;"

# Expected output:
# ┌──────────────────┬───────────┐
# │  client_addr     │   state   │
# ├──────────────────┼───────────┤
# │ <replica-2-ip>   │ streaming │
# │ <replica-3-ip>   │ streaming │
# └──────────────────┴───────────┘
```

### E. Verify etcd

```bash
# etcd working?
docker exec etcd etcdctl member list

# Expected: 1 member listed with "name=etcd"

# Can nodes access etcd?
docker exec pg-node-1 curl http://etcd:2379/version

# Expected: JSON with etcd version info
```

### F. Port Accessibility

```bash
# Port scan for all services
netstat -tlnp 2>/dev/null | grep -E "5432|5433|5434|8008|9090|2379"

# Or using Docker:
for port in 5432 5433 5434 8008 2379 9090; do
  echo -n "Port $port: "
  timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$port" 2>/dev/null && echo "OPEN" || echo "CLOSED"
done

# Expected: All ports OPEN
```

## Step 6: Initialize pgvector

```bash
# Run initialization script on primary
docker exec pg-node-1 psql -U pgadmin postgres \
  -f /var/lib/postgresql/init-pgvector-ha.sql

# Expected output:
# CREATE EXTENSION
# CREATE TABLE
# CREATE INDEX

# Verify on primary
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT extname FROM pg_extension WHERE extname='vector';"

# Expected: vector

# Wait 5 seconds for replication
sleep 5

# Verify on replica
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT extname FROM pg_extension WHERE extname='vector';"

# Expected: vector (replicated from primary)
```

### Create Sample Data

```bash
# Insert sample vectors (1536-dimensional, OpenAI-compatible)
docker exec pg-node-1 psql -U pgadmin postgres <<EOF
INSERT INTO items (name, content, embedding) VALUES
  ('document_1', 'A sample document with content', 
   '[$(printf '0.1,%.0s' {1..1536})]'::vector),
  ('document_2', 'Another document for similarity search',
   '[$(printf '0.2,%.0s' {1..1536})]'::vector);

SELECT id, name FROM items;
EOF

# Expected: 2 rows inserted and visible
```

## Step 7: Test Primary to Replica Replication

```bash
# Insert on primary
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "INSERT INTO items (name, content, embedding) VALUES ('test_doc', 'test content', '[0.5]'::vector);"

# Query replica (should see the data)
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT COUNT(*) FROM items;"

# If 0 rows, replication lag exists - wait and retry
sleep 2
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT COUNT(*) FROM items;"

# Expected: All rows replicated (same count on both nodes)
```

## Step 8: Test Failover

### A. Verify Current Primary

```bash
# Confirm pg-node-1 is primary
curl http://localhost:8008/leader

# Expected: {"leader": "pg-node-1"}
```

### B. Simulate Primary Failure

```bash
# Kill the primary node
docker kill pg-node-1

# Monitor failover (30+ seconds)
watch -n 2 'curl -s http://localhost:8009/leader || curl -s http://localhost:8008/cluster | jq ".members[] | select(.role==\"primary\") | .name"'

# Alternative: Check logs from replica
docker logs -f pg-node-2 2>&1 | grep -i "became primary\|elected"
```

### C. Verify New Primary Elected

```bash
# After ~30 seconds, check new primary
curl http://localhost:8008/leader
# or
curl http://localhost:8009/leader

# Expected: {"leader": "pg-node-2"} or {"leader": "pg-node-3"}

# Verify replication continues
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "SELECT client_addr, state FROM pg_stat_replication;"

# Expected: 2 replicas connected (pg-node-1 will be down, pg-node-3 should show)
```

### D. Restart Failed Primary

```bash
# pg-node-1 will rejoin as a replica
docker start pg-node-1

# Monitor restart
docker logs pg-node-1 | tail -20

# Check cluster status
curl http://localhost:8008/cluster | jq '.members[].name, .members[].role'

# Expected: pg-node-1 is now a replica (will rebuild from new primary)

# Verify it re-syncs (may take 10-30 seconds)
sleep 10
curl http://localhost:8008/cluster | jq '.members[] | select(.name=="pg-node-1")'
```

## Step 9: Test DBHub Connection

```bash
# Open browser
open http://localhost:9090
# or
firefox http://localhost:9090

# Login default credentials:
# Email: admin@bytebase.com
# Password: bytebase

# Once logged in:
# 1. Go to Instances
# 2. Should see PostgreSQL instance
# 3. Query items table to verify connection
```

### DBHub Data Query

```bash
# Via DBHub UI:
# 1. Click on the PostgreSQL instance
# 2. Run SQL: SELECT * FROM items;
# 3. Should return all inserted documents with vectors

# Or via CLI:
docker exec dbhub psql -U pgadmin -h pg-node-1 postgres -c \
  "SELECT id, name FROM items LIMIT 5;"
```

## Step 10: PgBackRest Backup Test

```bash
# List backups
docker exec pg-node-1 pgbackrest info

# Expected output:
# stanza: pg-ha
#   status: backup, archive-push, archive-get
#   backup: ...
#   wal archive min/max: ...

# Trigger a full backup
docker exec pg-node-1 pgbackrest backup --type=full

# Monitor progress
docker logs pg-node-1 | grep -i backup

# Verify backup completed
docker exec pg-node-1 pgbackrest info
# Should show "backup:" section with details

# Verify backup size
docker exec pg-node-1 du -sh /var/lib/pgbackrest/

# Expected: Backup size should be similar to database size
```

## Post-Deployment Checklist

- [ ] All 5 containers running
- [ ] etcd responding to requests
- [ ] Primary elected (pg-node-1 or elected via consensus)
- [ ] Both replicas in "in_sync" state
- [ ] pgvector extension installed on all nodes
- [ ] Sample data replicated to replicas
- [ ] Failover tested (primary killed, replica promoted)
- [ ] DBHub accessible and connected to database
- [ ] First backup completed and verified
- [ ] Replication lag < 1 second

## Troubleshooting Deployment Issues

### Containers Won't Start

```bash
# Check logs
docker logs pg-node-1

# Common errors:
# "etcd: connection refused" - wait 10s, etcd still starting
# "permission denied" - volume permission issue
# "data directory already exists" - clear volumes: docker volume rm ...

# Full restart
docker-compose down -v 2>/dev/null || true
rm -rf terraform.tfstate* .terraform
terraform init && terraform apply -auto-approve
```

### Primary Not Elected

```bash
# Check etcd
docker exec etcd etcdctl member list
# If empty: etcd cluster failed

# Clear etcd and restart
docker exec etcd etcdctl del /patroni --prefix
docker restart etcd pg-node-1 pg-node-2 pg-node-3

# Wait 30s for re-election
sleep 30
curl http://localhost:8008/leader
```

### Replication Not Working

```bash
# Check replica can connect to primary
docker exec pg-node-2 psql -U replicator -h pg-node-1 postgres \
  -c "IDENTIFY_SYSTEM;"

# If fails: connection/credentials issue
# Check PostgreSQL logs
docker logs pg-node-1 | grep replication

# Check pg_hba.conf (in Patroni config)
```

### DBHub Can't Connect

```bash
# Check Docker network
docker network inspect pg-ha-network | grep dbhub

# Test connectivity
docker exec dbhub ping pg-node-1
docker exec dbhub nc -zv pg-node-1 5432

# Check DBHub logs
docker logs dbhub | grep -i "postgres\|connection"
```

## Cleanup (If Needed)

### Destroy Everything

```bash
# Remove all resources (⚠️ destructive - deletes data)
terraform destroy -auto-approve

# Clean up volumes too
docker volume rm pg-node-1-data pg-node-2-data pg-node-3-data pgbackrest-repo etcd-data

# Remove Terraform state
rm -rf terraform.tfstate* .terraform
```

## Next Steps

1. **Production Hardening** - Review [HA-SETUP-GUIDE.md](HA-SETUP-GUIDE.md#production-checklist)
2. **Monitoring Setup** - Follow [HA-MONITORING.md](HA-MONITORING.md)
3. **Backup Strategy** - Configure external backup storage (S3, GCS)
4. **High Availability Testing** - Run failover tests weekly
5. **Documentation** - Update with your specific passwords and endpoints
6. **Automation** - Set up automated backup and verification crons

## Support

- 📖 Full guide: [HA-SETUP-GUIDE.md](HA-SETUP-GUIDE.md)
- 🔍 Troubleshooting: [HA-TROUBLESHOOTING.md](HA-TROUBLESHOOTING.md)
- 📊 Monitoring: [HA-MONITORING.md](HA-MONITORING.md)
- 🐧 PostgreSQL: https://www.postgresql.org/docs/18/
- 🎯 Patroni: https://patroni.readthedocs.io/
