# PostgreSQL HA Cluster - File Reference Guide

## Configuration Files Overview

This guide explains all files related to the 3-node PostgreSQL HA cluster setup using Patton, etcd, and PgBackRest.

---

## Core Infrastructure Files (Terraform)

### `main-ha.tf` (220+ lines)
**Purpose**: Main Terraform configuration defining all Docker infrastructure for the HA cluster.

**Contains**:
- Docker network: `pg-ha-network` (bridge driver)
- etcd container configuration (DCS)
- Custom PostgreSQL/Patroni image build definition
- Volume definitions (pgdata, pgbackrest-repo)
- Three PostgreSQL node containers (pg-node-1, pg-node-2, pg-node-3)
- DBHub container configuration
- Port mappings
- Environment variable declarations
- Service dependencies

**Key Resources**:
```terraform
docker_network.pg_ha_network        # Bridge for cluster communication
docker_container.etcd                # Distributed configuration store
docker_image.postgres_patroni        # Custom Patroni + pgvector image
docker_container.pg_node_1/2/3      # Three nodes (1 primary + 2 replicas)
docker_container.dbhub               # Web-based database management
docker_volume.*                      # Persistent storage volumes
```

### `variables-ha.tf` (27 lines)
**Purpose**: Input variables for customizing HA cluster deployment.

**Variables**:
- `postgres_user` - Database username (default: pgadmin)
- `postgres_password` - Database password (sensitive)
- `postgres_db` - Database name (default: postgres)
- `replication_password` - Password for replication user (sensitive)
- `dbhub_port` - DBHub web UI port (default: 9090)
- `etcd_port` - etcd client API port (default: 2379)
- `patroni_api_port_base` - Base port for Patroni REST APIs (default: 8008)

### `outputs-ha.tf` (75+ lines)
**Purpose**: Displays cluster information and connection endpoints after deployment.

**Outputs**:
- Cluster status summary
- Node container names
- Primary and replica endpoints (host and internal)
- Patroni REST API endpoints (8008-8010)
- DBHub URL
- Cluster configuration JSON

**Usage**:
```bash
terraform output                      # See all outputs
terraform output pg_primary_endpoint  # Get primary connection string
terraform output pg_cluster_info      # Get cluster configuration
```

---

## Docker & Container Files

### `Dockerfile.patroni` (31 lines)
**Purpose**: Custom Docker image based on pgvector:0.8.1-pg18-trixie with Patroni and pgBackRest support.

**Installs**:
- Python3 (for Patroni)
- Patroni 3.0.4 (cluster management)
- pgBackRest (backup & restore)
- PostgreSQL contrib modules
- YAML/jq utilities

**Defines**:
- Entrypoint: `entrypoint-patroni.sh`
- Exposed ports: 5432 (PostgreSQL), 8008 (Patroni API)
- Base layers from pgvector:0.8.1-pg18-trixie (includes vector extension pre-loaded)

**Build Command**:
```bash
docker build -f Dockerfile.patroni -t postgres-patroni:latest .
# (Handled automatically by: terraform apply)
```

### `entrypoint-patroni.sh` (24 lines)
**Purpose**: Container initialization script ensuring readiness before passing control to Patroni.

**Steps**:
1. **Wait for etcd** - Polls etcd:2379 for availability (30-second timeout)
2. **Initialize PostgreSQL directories** - Creates data directory with correct permissions
3. **Initialize pgBackRest** - Sets up backup repository
4. **Start Patroni** - Launches Patroni process with configuration

**Key Features**:
- Idempotent (safe to run multiple times)
- Proper error handling and logging
- Sets correct file permissions for postgres user

---

## Patroni Configuration Files

### `patroni/patroni-node-1.yml`
**Purpose**: Patroni configuration for primary node (initially).

**Sections**:
```yaml
scope: pg-ha-cluster                 # Cluster name
name: pg-node-1                      # Node identifier
etcd3:
  hosts: etcd:2379                   # DCS endpoint

postgresql:
  data_dir: /var/lib/postgresql     # Data directory
  parameters:
    wal_level: replica               # Enable replication
    max_wal_senders: 10             # Max replication connections
    synchronous_commit: on           # Data safety
    ...
  pg_hba:                            # Host-based authentication rules
    - local all postgres peer
    - host replication replicator all md5
```

### `patroni/patroni-node-2.yml`
**Purpose**: Identical to node-1 except `name: pg-node-2`.

### `patroni/patroni-node-3.yml`
**Purpose**: Identical to node-1 except `name: pg-node-3`.

**Why separate files?**
- Each node has unique identifier (`PATRONI_NAME`)
- Mounted as bind-mounts in their respective containers
- Allows individual configuration without rebuilding image

**Key Settings (All Nodes)**:
- etcd connection: `etcd:2379` (internal DNS)
- DCS type: etcd3
- Replication user: `replicator` with environment variable password
- Streaming replication enabled
- WAL archiving via pgBackRest configured
- Automatic watchdog for health monitoring
- pgBackRest for basebackup during replica initialization

---

## Backup & Recovery Files

### `pgbackrest/pgbackrest.conf` (25 lines)
**Purpose**: PgBackRest configuration for backup management and WAL archiving.

**Sections**:
```ini
[global]
repo1-type=posix              # Local file storage
repo1-path=/var/lib/pgbackrest

[pg-ha]
pg1-path=/var/lib/postgresql
retention-full=7              # Keep 7 days of full backups
retention-incr=3              # Keep 3 days of incremental backups
process-max=4                 # Parallel processes
compress=y                    # Compress WAL and backups
archive-async=y              # Async WAL archiving
```

**Features**:
- Automatic WAL archiving (for PITR)
- Compression to save disk space
- Parallel backup operations
- Shared repository across all nodes

**Shared across all nodes:**
- Single `pgbackrest-repo` volume
- All nodes archive WAL to same location
- Any node can restore from shared backups

---

## Initialization Files

### `init-pgvector-ha.sql` (28 lines)
**Purpose**: Idempotent SQL script to initialize pgvector extension and sample table on all nodes.

**Executed on**:
- **Primary only** during initialization (first run)
- **All replicas** automatically via streaming replication

**Creates**:
1. pgvector extension (if not exists)
2. `items` table with:
   - `id` - Serial primary key
   - `name` - Text field
   - `content` - Text field
   - `embedding` - 1536-dimensional vector (OpenAI-compatible)
   - `created_at` - Timestamp
3. IVFFLAT index on embeddings for fast similarity search

**Idempotency**:
- Uses `CREATE EXTENSION IF NOT EXISTS`
- Uses `pg_is_in_recovery()` check to run only on primary
- Safe to run multiple times

**Replication Behavior**:
- Primary executes: `CREATE EXTENSION`, `CREATE TABLE`, `CREATE INDEX`
- Replicas receive changes via streaming replication
- No need to run on replicas separately
- Replicas become read-only copies (can query, cannot modify)

---

## Documentation Files

### `HA-SETUP-GUIDE.md`
**Purpose**: Complete architecture and feature documentation.

**Covers**:
- Architecture diagrams
- Cluster information (3 nodes, streaming replication)
- Key features (automatic failover, PITR, pgvector)
- Patroni features (election, REST API)
- PgBackRest backup strategy
- pgvector usage on HA cluster
- Advanced configuration options
- Performance tuning

**For**: Understanding the design and capabilities

### `HA-DEPLOYMENT.md`
**Purpose**: Step-by-step deployment and testing guide.

**Covers**:
- Prerequisites checklist
- Configuration review
- Terraform initialization
- Deployment execution
- Verification steps (containers, cluster, primary election)
- pgvector initialization
- Failover testing
- DBHub testing
- PgBackRest backup testing
- Post-deployment checklist
- Troubleshooting deployment issues

**For**: First-time deployment and initial testing

### `HA-MONITORING.md`
**Purpose**: Health monitoring and observability guide.

**Covers**:
- Quick health checks (one-line commands)
- Container health
- Patroni REST API endpoints
- Replication monitoring (lag, slots)
- WAL activity tracking
- PgBackRest monitoring
- etcd health
- Database activity (connections, queries, cache hit ratio)
- pgvector extension health
- Alerting rules and thresholds
- Monitoring scripts and cron jobs
- Dashboard integration (Prometheus, Grafana)

**For**: Ongoing operational monitoring

### `HA-TROUBLESHOOTING.md`
**Purpose**: Common issues and troubleshooting procedures.

**Covers**:
- 10 common problems with solutions:
  - Cluster won't start
  - Nodes can't find primary
  - Replication lagging
  - Patroni won't promote
  - Cascading replication issues
  - DBHub connection failures
  - pgBackRest backup failures
  - Node rejoin issues
  - Slow failover
  - pgvector returning NULL
- Network debugging checklist
- Performance diagnosis
- Emergency recovery procedures
- Disaster recovery runbook

**For**: Troubleshooting issues and breakfix scenarios

### `HA-OPERATIONS.md`
**Purpose**: Day-to-day operations and maintenance manual.

**Covers**:
- Daily health check (30-second command)
- Emergency access procedures
- Connection management (connection pools, Python examples)
- Replication management (monitoring lag, handling issues)
- Failover strategies (planned switchover, unplanned recovery)
- Backup & recovery procedures
- Performance tuning
- Maintenance windows (zero-downtime patching)
- VACUUM & ANALYZE scheduling
- WAL management
- Monitoring essentials
- Disaster recovery scenarios
- Useful commands reference

**For**: Daily operations and maintenance tasks

---

## Deployment Workflow

```
1. User reads HA-SETUP-GUIDE.md
   ↓
2. User reviews configuration files:
   - main-ha.tf (infrastructure)
   - variables-ha.tf (variables)
   - outputs-ha.tf (outputs)
   - Dockerfile.patroni (custom image)
   - patroni/*.yml (node configs)
   - pgbackrest.conf (backup config)
   ↓
3. User follows HA-DEPLOYMENT.md
   - terraform init
   - terraform apply
   - Verification steps
   ↓
4. User runs HA-MONITORING.md checks
   - Cluster health
   - Replication status
   ↓
5. User follows HA-OPERATIONS.md
   - Daily maintenance
   - Scheduled backups
   - Performance tuning
   ↓
6. If issues arise:
   User consult HA-TROUBLESHOOTING.md
```

---

## File Tree

```
/home/vejang/terraform-docker-container-postgres/
├── Terraform HA Configurations
│   ├── main-ha.tf              # Infrastructure definitions
│   ├── variables-ha.tf          # Input variables
│   └── outputs-ha.tf            # Output values
│
├── Docker Configurations  
│   ├── Dockerfile.patroni       # Custom image with Patroni
│   └── entrypoint-patroni.sh    # Container startup script
│
├── Patroni Configurations
│   └── patroni/
│       ├── patroni-node-1.yml   # Node 1 config
│       ├── patroni-node-2.yml   # Node 2 config
│       └── patroni-node-3.yml   # Node 3 config
│
├── Backup Configuration
│   └── pgbackrest/
│       └── pgbackrest.conf      # Backup & recovery config
│
├── Initialization
│   └── init-pgvector-ha.sql     # pgvector & table setup
│
└── Documentation
    ├── HA-SETUP-GUIDE.md        # Architecture & features
    ├── HA-DEPLOYMENT.md         # Deployment guide
    ├── HA-MONITORING.md         # Monitoring guide
    ├── HA-TROUBLESHOOTING.md    # Troubleshooting guide
    ├── HA-OPERATIONS.md         # Operations manual
    └── HA-FILES.md (this file)  # File reference guide
```

---

## Original Single-Node Files (Still Available)

The repository also contains the original single-node configuration for development:

- `main.tf` - Single-node Terraform config
- `variables.tf` - Variables for single-node
- `outputs.tf` - Outputs for single-node
- `Dockerfile` - Original single-node image
- `init-pgvector.sql` - Single-node initialization

These can be used independently for development/testing.

---

## Getting Started

1. **Read Architecture**: [HA-SETUP-GUIDE.md](HA-SETUP-GUIDE.md)
2. **Deploy Cluster**: [HA-DEPLOYMENT.md](HA-DEPLOYMENT.md)
3. **Monitor Operations**: [HA-MONITORING.md](HA-MONITORING.md)
4. **Daily Operations**: [HA-OPERATIONS.md](HA-OPERATIONS.md)
5. **If Issues Arise**: [HA-TROUBLESHOOTING.md](HA-TROUBLESHOOTING.md)

---

## Quick Command Reference

```bash
# Deployment
terraform init
terraform plan -var-file=ha.tfvars
terraform apply -var-file=ha.tfvars

# Health Check
curl -s http://localhost:8008/cluster | jq '.members'

# Connect to Primary
psql $(terraform output -raw pg_primary_endpoint)

# View Logs
docker logs -f pg-node-1

# Check Failover Status
curl http://localhost:8008/leader

# Backup Database
docker exec pg-node-1 pgbackrest backup

# Monitor Replication
docker exec pg-node-1 psql -U pgadmin postgres -c "SELECT * FROM pg_stat_replication;"

# Destroy Cluster
terraform destroy -auto-approve
```

---

## Support

Each documentation file includes references to:
- PostgreSQL official documentation
- Patroni documentation
- PgBackRest user guide
- etcd documentation
- pgvector repository

For specific issues, consult the appropriate guide above.
