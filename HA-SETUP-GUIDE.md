# PostgreSQL 18 HA Cluster with Patroni + etcd + PgBackRest

A production-grade, highly available PostgreSQL 18 cluster with automatic failover, streaming replication, and pgvector support.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│          Docker Network: pg-ha-network                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐         │
│  │   etcd     │  │ PgBackRest │  │    DBHub     │         │
│  │ (2379)     │  │  Backup    │  │   (9090)     │         │
│  └────────────┘  │ Repository │  │              │         │
│                  └──────────────┘  └──────────────┘         │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ pg-node-1   │  │ pg-node-2    │  │ pg-node-3    │     │
│  │ (Primary)   │◄─┤ (Replica 1)  │◄─┤ (Replica 2)  │     │
│  │ Port 5432   │  │ Port 5433    │  │ Port 5434    │     │
│  │ Patroni API │  │ Patroni API  │  │ Patroni API  │     │
│  │ :8008       │  │ :8009        │  │ :8010        │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│         ▲                ▲                  ▲               │
│         └────────────────┴──────────────────┘               │
│             Streaming Replication (async)                  │
│             All nodes watch etcd for leadership            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Key Features

✅ **Automatic Failover**: Sub-30 second failover via Patroni + etcd consensus
✅ **Streaming Replication**: Real-time replication with WAL streaming
✅ **Point-in-Time Recovery (PITR)**: Via PgBackRest with WAL archiving
✅ **pgvector Included**: 0.8.1 version with 1536-dimensional vector support
✅ **Multi-Node Consensus**: etcd provides distributed configuration coordination
✅ **Self-Healing**: Automatic replica rebuild after node failure
✅ **Persistent Storage**: Separate volumes for each node
✅ **DBHub Integration**: Web-based management UI connecting to primary

## Prerequisites

- Terraform v1.0+
- Docker v20.10+
- Docker Compose (optional, for testing)
- 4GB+ RAM
- 20GB+ disk space

## Quick Start

### 1. Deploy the HA Cluster

```bash
# Initialize Terraform
terraform init

# Plan the deployment
terraform plan -var-file="ha.tfvars"

# Deploy all 3 nodes, etcd, and DBHub
terraform apply -auto-approve \
  -var="postgres_password=$(openssl rand -base64 14)" \
  -var="replication_password=$(openssl rand -base64 14)"
```

### 2. Verify Cluster Status

```bash
# Check all containers are running
docker ps | grep "pg-node\|etcd\|dbhub"

# View cluster membership (wait 10-15 seconds for nodes to join)
docker exec etcd etcdctl member list

# Check Patroni cluster status
curl http://localhost:8008/cluster

# View primary node
curl http://localhost:8008/leader
```

### 3. Connect to PostgreSQL

**From host machine:**
```bash
# Connect to primary (auto-elected)
psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres

# Or use terraform output
psql $(terraform output -raw pg_primary_endpoint)

# Connect to replicas (read-only)
psql postgresql://pgadmin:pgAdmin1@localhost:5433/postgres  # Replica 1
psql postgresql://pgadmin:pgAdmin1@localhost:5434/postgres  # Replica 2
```

**From within cluster (e.g., from DBHub):**
```
postgresql://pgadmin:pgAdmin1@pg-node-1:5432/postgres
```

### 4. Access DBHub

Open `http://localhost:9090` in your browser and log in with:
- Email: admin@bytebase.com
- Password: bytebase

## PostgreSQL HA Cluster Details

### Cluster Information

| Component | Value |
|-----------|-------|
| **Cluster Name** | `pg-ha-cluster` |
| **PostgreSQL Version** | 18 (pgvector optimized) |
| **Total Nodes** | 3 (1 primary + 2 replicas) |
| **DCS** | etcd3 |
| **Replication Type** | Streaming async |
| **pgvector Version** | 0.8.1-pg18-trixie |

### Node Configuration

| Node | Role | External Port | Patroni API | Status |
|------|------|---------------|-------------|--------|
| pg-node-1 | Primary/Replica | 5432 | 8008 | Elected primary |
| pg-node-2 | Replica | 5433 | 8009 | In-sync replica |
| pg-node-3 | Replica | 5434 | 8010 | In-sync replica |

### Replication Setup

- **Type**: Streaming asynchronous replication
- **Slots**: 10 configured per node
- **WAL Level**: replica
- **Hot Standby**: Enabled (supports read queries on replicas)
- **WAL Archive**: PgBackRest

## Patroni Features

### Automatic Leadership Election

Patroni constantly monitors cluster health and automatically:

1. **Detects Primary Failure** - Via etcd lease timeout (default 30s)
2. **Replicas Compete** - All replicas in etcd consensus election
3. **Winner Promotes** - Replica with least replication lag wins
4. **Resync Losers** - Other replicas rebuild from primary

### Configuration Management

All cluster parameters are managed via config files:

- `patroni/patroni-node-1.yml` - Node 1 Patroni config
- `patroni/patroni-node-2.yml` - Node 2 Patroni config  
- `patroni/patroni-node-3.yml` - Node 3 Patroni config

Edit and revert to Terraform to apply config changes.

### Patroni REST API

Each node exposes a REST API for cluster management:

```bash
# Get cluster status
curl http://localhost:8008/cluster

# Get primary node
curl http://localhost:8008/leader

# Get node's role (primary/replica)
curl http://localhost:8008/role

# Initiate switchover (demote primary)
curl -X POST http://localhost:8008/switchover

# Restart a node
curl -X POST http://localhost:8008/restart
```

## PgBackRest Backup Strategy

### Automated Backups

Configuration file: `pgbackrest/pgbackrest.conf`

**Retention Policy:**
- Full backups: Keep 7 days
- Incremental backups: Keep 3 days
- WAL archive: Automatic via recovery_conf

### Backup Commands

```bash
# Trigger full backup (run on primary node)
docker exec pg-node-1 pgbackrest backup --type=full

# Incremental backup
docker exec pg-node-1 pgbackrest backup --type=incr

# View backup info
docker exec pg-node-1 pgbackrest info

# Show backup progress
docker exec pg-node-1 pgbackrest backup --log-level-console=info
```

### Point-in-Time Recovery (PITR)

Patroni can automatically restore from a backup and replay WAL:

1. Stop the cluster (or affected node)
2. Update recovery configuration to desired point-in-time
3. Start Patroni - it will restore and replay WAL automatically

```bash
# Restore specific node to point-in-time
# Edit postgresql recovery_conf in Patroni config
# Then restart: docker restart pg-node-1
```

## Working with pgvector in HA

### The items Table

All nodes automatically get the `items` table created:

```sql
-- Available on all nodes (replicated from primary)
CREATE TABLE items (
    id BIGSERIAL PRIMARY KEY,
    name TEXT,
    content TEXT,
    embedding vector(1536),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_items_embedding ON items 
  USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
```

### Writing to Primary

```bash
# Always write to primary (port 5432)
psql -h localhost -p 5432 -U pgadmin postgres

postgres=# INSERT INTO items (name, content, embedding) VALUES
  ('doc1', 'content...', '[0.1, 0.2, ...]'::vector),
  ('doc2', 'content...', '[0.3, 0.4, ...]'::vector);
```

### Reading from Replicas

```bash
# Read from replica 1 (port 5433)
psql -h localhost -p 5433 -U pgadmin postgres

postgres=# SELECT id, name, embedding <=> '[0.1, 0.2, ...]' AS distance
  FROM items
  ORDER BY embedding <=> '[0.1, 0.2, ...]'
  LIMIT 10;
```

**Note:** Replica reads are eventual consistent (lag ~0-100ms behind primary).

## Monitoring and Management

### Cluster Status Dashboard

```bash
# Summary status
watch -n 1 'curl -s http://localhost:8008/cluster | jq ".members"'

# Detailed summary
curl http://localhost:8008/cluster | jq '.'
```

### Container Logs

```bash
# Primary node logs
docker logs -f pg-node-1

# Replica node logs
docker logs -f pg-node-2
docker logs -f pg-node-3

# etcd logs
docker logs -f etcd

# Patroni API logs
docker logs -f pg-node-1 | grep -i patroni
```

### Manual Failover (Switchover)

```bash
# Initiate switchover (primary -> replica, replica -> primary)
curl -X POST http://localhost:8008/switchover \
  -d '{"leader": "pg-node-1", "candidate": "pg-node-2"}'

# Monitor switchover progress
watch -n 1 'curl -s http://localhost:8008/leader'
```

### Node Restart (Controlled)

```bash
# Restart a single replica (safe)
docker restart pg-node-2

# Patroni will automatically resync

# Restart primary (if in emergency, replicas will elect new primary)
docker restart pg-node-1
```

## Troubleshooting

### Cluster Won't Start

```bash
# Check etcd is running and accessible
curl http://localhost:2379/version

# Check if etcd has stale member entries
docker exec etcd etcdctl member list
# Remove stale members: docker exec etcd etcdctl member remove <id>

# Clear cluster state (destructive - loses all data)
docker exec etcd etcdctl del /patroni --prefix
```

### Replica Lagging

```bash
# Check replication lag
docker exec pg-node-1 psql -U pgadmin postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"

# Check WAL receiving status
docker exec pg-node-1 psql -U pgadmin postgres -c "SELECT * FROM pg_stat_replication;"
```

### Primary Election Issues

```bash
# Force primary role (if node is stuck)
curl -X POST http://localhost:8008/reinitialize

# Check cluster decision in etcd
docker exec etcd etcdctl get /patroni --prefix
```

### Replication Slot Conflicts

```bash
# Check replication slots
docker exec pg-node-1 psql -U pgadmin postgres -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;"

# Drop a stuck slot
docker exec pg-node-1 psql -U pgadmin postgres -c "SELECT pg_drop_replication_slot('slot_name');"
```

## Production Checklist

- [ ] Change default passwords before deploying
- [ ] Enable SSL/TLS in pg_hba.conf (update `patroni.yml`)
- [ ] Deploy 3-node etcd cluster (currently 1 node for simplicity)
- [ ] Set up external backup storage (S3, GCS) for PgBackRest
- [ ] Configure monitoring (Prometheus, Grafana)
- [ ] Set up alerting for cluster health
- [ ] Test failover procedure
- [ ] Document runbooks for incident response
- [ ] Enable audit logging in PostgreSQL
- [ ] Implement connection pooling (pgBouncer)
- [ ] Backup configuration files and SSH keys

## Advanced Configuration

### Enable Synchronous Replication

Edit `patroni/patroni-node-1.yml` and set:

```yaml
postgresql:
  parameters:
    synchronous_commit: on  # or 'remote_apply' for zero-loss
    synchronous_standby_names: '*'
```

**Note:** Synchronous replication adds latency but guarantees data safety.

### Add Read Window to Replicas

DBHub can be configured to use replicas for read-only queries:

```bash
# Add replica connections to DBHub UI
# Then set read-only user permissions on replicas
docker exec pg-node-2 psql -U pgadmin postgres -c \
  "CREATE ROLE readonly WITH LOGIN PASSWORD 'readonly1';"
```

### Scale to More Nodes

To add a 4th node:

1. Create `patroni/patroni-node-4.yml`
2. Add new node container to `main-ha.tf`
3. Redeploy: `terraform apply`

Patroni will automatically sync the new node from primary.

## Performance Tuning

### For Small Clusters (< 100GB data)

```yaml
postgresql:
  parameters:
    shared_buffers: 256MB    # 25% of RAM
    work_mem: 1MB
    maintenance_work_mem: 64MB
```

### For Large Clusters (> 1TB data)

```yaml
postgresql:
  parameters:
    shared_buffers: 8GB      # 25% of RAM
    work_mem: 64MB
    maintenance_work_mem: 2GB
    max_parallel_workers_per_gather: 4
```

## Maintenance Tasks

### Regular Backups

```bash
# Backup schedule (execute in cron job)
docker exec pg-node-1 pgbackrest backup --type=full
```

### Vacuum & Analyze

```bash
# Weekly maintenance (full cluster vacuum)
VACUUM ANALYZE;
```

### Check Replication Health

```bash
# Daily check
docker exec pg-node-1 psql -U pgadmin postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

## Destroying the Cluster

```bash
# Remove all containers and volumes (destructive)
terraform destroy -auto-approve

# Option: Keep volumes for recovery
# docker volume rm pg-node-1-data pg-node-2-data pg-node-3-data
```

## Support & Documentation

- [Patroni Documentation](https://patroni.readthedocs.io/)
- [etcd Documentation](https://etcd.io/docs/)  
- [PgBackRest Documentation](https://pgbackrest.org/user-guide.html)
- [PostgreSQL Replication](https://www.postgresql.org/docs/18/warm-standby.html)
- [pgvector GitHub](https://github.com/pgvector/pgvector)

## Next Steps

1. **Deploy**: Run `terraform apply` to start the cluster
2. **Verify**: Confirm all nodes are healthy
3. **Test Failover**: Stop the primary and watch automatic recovery
4. **Configure Backup**: Set up external backup storage for PgBackRest
5. **Monitor**: Add Prometheus + Grafana for metrics
6. **Optimize**: Tune PostgreSQL parameters for your workload
