# PostgreSQL HA Cluster - Deployment & Operations Workflow

## Table of Contents
1. [Deployment Workflow](#deployment-workflow)
2. [Runtime Operations](#runtime-operations)
3. [Failover Process](#failover-process)
4. [Cluster Architecture](#cluster-architecture)
5. [Component Interactions](#component-interactions)
6. [Data Flow Diagrams](#data-flow-diagrams)
7. [Authentication Flow](#authentication-flow)
8. [Terraform Code Flow](#terraform-code-flow)

---

## Deployment Workflow

### Step 1: Initialization Phase

```
┌─────────────────────────────────────────────────────────┐
│           TERRAFORM INITIALIZATION & VALIDATION          │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  1. terraform init                                       │
│     ├─ Download Docker provider (kreuzwerker/docker)   │
│     │  Current: v3.6.2                                 │
│     ├─ Initialize .terraform/ directory                │
│     └─ Setup state management (local terraform.tfstate)│
│                                                           │
│  2. Load variables from terraform.tfvars                │
│     ├─ postgres_user (default: pgadmin)                │
│     ├─ postgres_password (⚠️ DEFAULT: pgAdmin1)         │
│     ├─ postgres_db (default: postgres)                 │
│     ├─ replication_password (⚠️ DEFAULT: replicator1)   │
│     ├─ dbhub_port (default: 9090)                      │
│     ├─ etcd_port (default: 2379)                       │
│     ├─ etcd_peer_port (default: 2380)                  │
│     └─ patroni_api_port_base (default: 8008)           │
│                                                           │
│  3. Validate Terraform configuration                    │
│     └─ Check syntax and variable types (main-ha.tf)   │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

### Step 2: Docker Resources Creation Phase

```
┌──────────────────────────────────────────────────────────────┐
│       DOCKER RESOURCES CREATION (from main-ha.tf)              │
├──────────────────────────────────────────────────────────────┤
│                                                                │
│  Phase A: Network Foundation (No Dependencies)               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_network.pg_ha_network                            │ │
│  │ ├─ Name: "pg-ha-network"                               │ │
│  │ ├─ Driver: "bridge"                                    │ │
│  │ ├─ Internal: false (can reach external)                │ │
│  │ └─ IPAM: 172.20.0.0/16 subnet                          │ │
│  └─────────────────────────────────────────────────────────┘ │
│              ↓                                                 │
│  Phase B: Storage Volumes (No Dependencies)                  │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_volume.pg_node_1_data                            │ │
│  │ docker_volume.pg_node_2_data                            │ │
│  │ docker_volume.pg_node_3_data                            │ │
│  │ ├─ Name: "pg-node-1-data", "pg-node-2-data", etc.     │ │
│  │ ├─ Driver: "local"                                     │ │
│  │ └─ Mount path: /var/lib/postgresql (in containers)    │ │
│  │                                                          │ │
│  │ docker_volume.etcd_data                                 │ │
│  │ ├─ Name: "etcd-data"                                   │ │
│  │ └─ Mount path: /var/lib/etcd (in etcd container)      │ │
│  │                                                          │ │
│  │ docker_volume.pgbackrest_repo                           │ │
│  │ ├─ Name: "pgbackrest-repo"                             │ │
│  │ └─ Mount path: /var/lib/pgbackrest (backup storage)   │ │
│  └─────────────────────────────────────────────────────────┘ │
│                       ↓                                        │
│  Phase C: Docker Images (Parallel, No Dependencies)          │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_image.postgres_patroni                           │ │
│  │ ├─ Build Source: ./Dockerfile.patroni (local build)    │ │
│  │ ├─ Base Image: pgvector/pgvector:0.8.1-pg18-trixie    │ │
│  │ ├─ Installed Components:                                │ │
│  │ │  ├─ PostgreSQL 18.x                                  │ │
│  │ │  ├─ pgvector 0.8.1                                   │ │
│  │ │  ├─ Patroni 3.3.8+ (with etcd3 support)             │ │
│  │ │  ├─ pgBackRest (backup/archive tool)                │ │
│  │ │  ├─ Python 3.x (for Patroni)                        │ │
│  │ │  └─ pg_stat_statements extension                    │ │
│  │ └─ Image Name: "postgres-patroni:18-pgvector"        │ │
│  │                                                          │ │
│  │ docker_image.etcd                                       │ │
│  │ ├─ Pull Source: quay.io/coreos/etcd:v3.5.0            │ │
│  │ ├─ Size: ~50MB                                         │ │
│  │ └─ Role: Distributed configuration/consensus           │ │
│  │                                                          │ │
│  │ docker_image.dbhub                                      │ │
│  │ ├─ Pull Source: bytebase/bytebase:latest               │ │
│  │ ├─ Size: ~200MB                                        │ │
│  │ └─ Role: Database management UI                        │ │
│  └─────────────────────────────────────────────────────────┘ │
│                       ↓                                        │
│  Phase D: etcd Container (DCS Layer)                         │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_container.etcd                                   │ │
│  │ ├─ Dependencies: pg_ha_network, etcd volume, image      │ │
│  │ ├─ Hostname: "etcd"                                     │ │
│  │ ├─ IP Address: 172.20.0.5 (auto-assigned)              │ │
│  │ ├─ Port Mappings:                                       │ │
│  │ │  ├─ 2379:2379 (etcd client API)                      │ │
│  │ │  └─ 2380:2380 (peer-to-peer communication)          │ │
│  │ ├─ Environment Variables:                               │ │
│  │ │  ├─ ETCD_NAME=etcd                                   │ │
│  │ │  ├─ ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379    │ │
│  │ │  ├─ ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379    │ │
│  │ │  └─ ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380      │ │
│  │ ├─ Health Check: etcdctl endpoint health                │ │
│  │ ├─ Startup Time: ~5 seconds                             │ │
│  │ └─ Wait Logic: Terraform waits for etcd to be ready    │ │
│  └─────────────────────────────────────────────────────────┘ │
│                       ↓                                        │
│  Phase E: PostgreSQL Primary Node (pg-node-1)               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_container.pg_node_1                              │ │
│  │ ├─ Dependencies: etcd, network, volumes, image          │ │
│  │ ├─ Hostname: "pg-node-1"                                │ │
│  │ ├─ IP Address: 172.20.0.2                               │ │
│  │ ├─ Ports:                                               │ │
│  │ │  ├─ 5432:5432 (PostgreSQL primary)                   │ │
│  │ │  └─ 8008:8008 (Patroni REST API)                     │ │
│  │ ├─ Volume Mounts (read-write):                          │ │
│  │ │  ├─ pg-node-1-data → /var/lib/postgresql            │ │
│  │ │  ├─ pgbackrest-repo → /var/lib/pgbackrest           │ │
│  │ │  └─ patroni-node-1.yml → /etc/patroni/patroni.yml   │ │
│  │ ├─ Entrypoint: /usr/local/bin/entrypoint-patroni.sh   │ │
│  │ │                                                        │ │
│  │ ├─ Startup Sequence (entrypoint-patroni.sh):            │ │
│  │ │  1. Create /var/lib/postgresql/18/main with 700     │ │
│  │ │  2. Ensure postgres:postgres ownership              │ │
│  │ │  3. Create pg_hba.conf from template                │ │
│  │ │  4. Start Patroni daemon (patroni /etc/patroni.yml) │ │
│  │ │  5. Patroni executes initdb (first time only)       │ │
│  │ │     └─ Initializes PostgreSQL 18 cluster            │ │
│  │ │  6. PostgreSQL starts in primary mode               │ │
│  │ │  7. Patroni acquires leader lock in etcd            │ │
│  │ │     Key: /pg-ha-cluster/leader                      │ │
│  │ │                                                        │ │
│  │ ├─ Patroni Configuration (patroni-node-1.yml):          │ │
│  │ │  ├─ cluster_name: pg-ha-cluster                     │ │
│  │ │  ├─ dcs_type: etcd3                                 │ │
│  │ │  ├─ etcd hosts: etcd:2379                           │ │
│  │ │  ├─ postgresql.data_dir: /var/lib/postgresql/18/...│ │
│  │ │  ├─ postgresql.parameters:                          │ │
│  │ │  │  ├─ shared_preload_libraries: vector,pg_stat_... │ │
│  │ │  │  └─ data_checksums: on                          │ │
│  │ │  └─ synchronous_mode: true (for all replicas)      │ │
│  │ │                                                        │ │
│  │ ├─ Environment Variables (from main-ha.tf):             │ │
│  │ │  ├─ PATRONI_POSTGRESQL__PARAMETERS='...'            │ │
│  │ │  ├─ PATRONI_DCS_TYPE=etcd3                          │ │
│  │ │  ├─ PATRONI_ETCD__HOSTS=etcd:2379                   │ │
│  │ │  └─ PATRONI_NAME=pg-node-1                          │ │
│  │ │                                                        │ │
│  │ ├─ Health Check: Patroni ping/health endpoint          │ │
│  │ ├─ Startup Time: ~30-45 seconds (initdb is slow)      │ │
│  │ └─ Role After Startup: PRIMARY (LEADER)                │ │
│  └─────────────────────────────────────────────────────────┘ │
│                       ↓                                        │
│  Phase F: PostgreSQL Replica Node 1 (pg-node-2)            │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_container.pg_node_2                              │ │
│  │ ├─ Dependencies: pg_node_1, network, volumes, image     │ │
│  │ │  (waits for pg_node_1 to be ready)                   │ │
│  │ ├─ Hostname: "pg-node-2"                                │ │
│  │ ├─ IP Address: 172.20.0.3                               │ │
│  │ ├─ Ports:                                               │ │
│  │ │  ├─ 5433:5432 (mapped from 5432 in container)       │ │
│  │ │  └─ 8009:8008 (Patroni REST API)                     │ │
│  │ ├─ Volume Mounts:                                       │ │
│  │ │  └─ Same structure as pg-node-1                      │ │
│  │ │                                                        │ │
│  │ ├─ Startup Sequence:                                    │ │
│  │ │  1. Same directory & permission prep as pg-node-1   │ │
│  │ │  2. Start Patroni daemon                             │ │
│  │ │  3. Patroni connects to etcd                         │ │
│  │ │     └─ Discovers primary (pg-node-1)                │ │
│  │ │  4. Patroni calls pg_basebackup                      │ │
│  │ │     └─ Streams full backup from pg-node-1           │ │
│  │ │  5. PostgreSQL starts in hot_standby mode            │ │
│  │ │  6. WAL streaming begins (from primary)              │ │
│  │ │  7. Patroni registers as replica in etcd             │ │
│  │ │                                                        │ │
│  │ ├─ Replication Status:                                  │ │
│  │ │  ├─ Replication slot: pg-node-2 (active)            │ │
│  │ │  ├─ Synchronous replication: YES                    │ │
│  │ │  └─ Replication lag: ~0 bytes (sync)                │ │
│  │ │                                                        │ │
│  │ ├─ Startup Time: ~30 seconds (pg_basebackup + WAL)    │ │
│  │ └─ Role After Startup: STANDBY (REPLICA)               │ │
│  └─────────────────────────────────────────────────────────┘ │
│                       ↓                                        │
│  Phase G: PostgreSQL Replica Node 2 (pg-node-3)            │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_container.pg_node_3                              │ │
│  │ ├─ Dependencies: pg_node_2, network, volumes, image     │ │
│  │ ├─ Hostname: "pg-node-3"                                │ │
│  │ ├─ IP Address: 172.20.0.4                               │ │
│  │ ├─ Ports:                                               │ │
│  │ │  ├─ 5434:5432 (mapped from 5432)                    │ │
│  │ │  └─ 8010:8008 (Patroni REST API)                     │ │
│  │ ├─ Same startup sequence as pg-node-2                  │ │
│  │ └─ Role After Startup: STANDBY (REPLICA)               │ │
│  └─────────────────────────────────────────────────────────┘ │
│                       ↓                                        │
│  Phase H: DBHub Container (Database Management UI)          │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ docker_container.dbhub                                  │ │
│  │ ├─ Dependencies: all PostgreSQL nodes ready             │ │
│  │ ├─ Hostname: "dbhub"                                    │ │
│  │ ├─ IP Address: 172.20.0.6                               │ │
│  │ ├─ Ports:                                               │ │
│  │ │  ├─ 9090:8080 (mapped to dbhub_port variable)       │ │
│  │ │  └─ From variables.tf: default dbhub_port = 9090    │ │
│  │ ├─ Environment Variables:                               │ │
│  │ │  └─ BYTEBASE_POSTGRES_URL=postgres://pgadmin:...   │ │
│  │ │     @pg-node-1:5432/postgres?sslmode=disable       │ │
│  │ ├─ Features Available:                                  │ │
│  │ │  ├─ SQL editor with syntax highlighting             │ │
│  │ │  ├─ Schema browser                                  │ │
│  │ │  ├─ Database migration management                   │ │
│  │ │  ├─ Query history                                   │ │
│  │ │  └─ User access control                             │ │
│  │ ├─ Health Check: HTTP GET /healthz endpoint            │ │
│  │ └─ Startup Time: ~30 seconds                            │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                                │
└──────────────────────────────────────────────────────────────┘

TOTAL DEPLOYMENT TIME: 2-3 minutes
├─ Image build/pull: 0-1 minute
├─ Network & volumes: 10 seconds
├─ etcd startup: 10 seconds
├─ pg-node-1 (primary) init: 40 seconds
├─ pg-node-2 (replica) sync: 40 seconds
├─ pg-node-3 (replica) sync: 40 seconds
└─ DBHub startup: 30 seconds
```

---

## Runtime Operations

### Cluster Health Checking Cycle

```
┌────────────────────────────────────────────────────────┐
│    CONTINUOUS CLUSTER HEALTH MONITORING (Every 10s)     │
├────────────────────────────────────────────────────────┤
│                                                          │
│  Each Patroni daemon on every node:                    │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │ LOOP ITERATION (every 10 seconds)                │  │
│  ├──────────────────────────────────────────────────┤  │
│  │                                                   │  │
│  │ 1. Health Check Local PostgreSQL                │  │
│  │    ├─ Execute: SELECT 1                         │  │
│  │    ├─ Measure response time                     │  │
│  │    ├─ Record success/failure                    │  │
│  │    └─ Check pg_is_in_recovery() status         │  │
│  │                                                   │  │
│  │ 2. Verify PostgreSQL Directory Permissions      │  │
│  │    ├─ /var/lib/postgresql/18/main (700)        │  │
│  │    ├─ /var/lib/postgresql (755)                │  │
│  │    └─ postgres:postgres ownership               │  │
│  │                                                   │  │
│  │ 3. Update Node Status in etcd                   │  │
│  │    ├─ Write to: /pg-ha-cluster/members/{node}  │  │
│  │    ├─ TTL: 30 seconds                           │  │
│  │    ├─ Value: Node metadata + health status     │  │
│  │    └─ If fails: marked as unhealthy            │  │
│  │                                                   │  │
│  │ 4. Read Cluster State from etcd                 │  │
│  │    ├─ Check: /pg-ha-cluster/leader             │  │
│  │    ├─ Check: /pg-ha-cluster/members/*          │  │
│  │    ├─ Check: /pg-ha-cluster/sync               │  │
│  │    └─ Determine cluster topology                │  │
│  │                                                   │  │
│  │ 5. Replication Status Check (Standbys)         │  │
│  │    ├─ Query: pg_stat_replication()             │  │
│  │    ├─ Measure: write_lag, flush_lag, replay_lag│  │
│  │    ├─ Verify: replication_slot active          │  │
│  │    └─ Confirm: WAL streaming active            │  │
│  │                                                   │  │
│  │ 6. Synchronous Replication Check (Primary)     │  │
│  │    ├─ Read: synchronous_standby_names           │  │
│  │    ├─ Verify: both replicas in sync            │  │
│  │    ├─ Count: how many standbys ready           │  │
│  │    └─ If <2 ready: may demote to async mode    │  │
│  │                                                   │  │
│  │ 7. Decision Tree Based on Status               │  │
│  │    ├─ IF primary is healthy & 2+ standbys:    │  │
│  │    │  └─ CONTINUE normal operation              │  │
│  │    ├─ IF primary unhealthy:                    │  │
│  │    │  ├─ Initiate failover (see failover flow) │  │
│  │    │  └─ Promote best standby to primary       │  │
│  │    ├─ IF standby unhealthy:                    │  │
│  │    │  ├─ Check if lagged > limit               │  │
│  │    │  └─ Potentially demote from sync list     │  │
│  │    └─ IF <2 standbys ready:                    │  │
│  │       └─ Downgrade to asynchronous replication│  │
│  │                                                   │  │
│  │ 8. Sleep Until Next Iteration                  │  │
│  │    └─ Loop period: ~10 seconds (configurable) │  │
│  │                                                   │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
└────────────────────────────────────────────────────────┘
```

---

## Failover Process

### Automatic Failover Scenario (Primary Failure)

```
TIMELINE: Primary Node (pg-node-1) Crashes
═══════════════════════════════════════════
        
T=00:00 - PRIMARY FAILURE DETECTED
┌─────────────────────────────────────┐
│ pg-node-1 (PRIMARY):                │
│ ├─ PostgreSQL process crashes       │
│ ├─ Patroni health check fails       │
│ ├─ etcd heartbeat STOPS             │
│ ├─ TTL timer starts (default: 30s)  │
│ └─ Node locked → unrecoverable      │
└─────────────────────────────────────┘
                    ↓
T=00:05-00:10 - REPLICAS DETECT FAILURE
┌─────────────────────────────────────┐
│ pg-node-2 & pg-node-3:              │
│ ├─ WAL streaming connection: LOST   │
│ ├─ Try to reconnect: FAIL           │
│ ├─ Log error in Patroni logs        │
│ └─ Monitor etcd for leader change   │
└─────────────────────────────────────┘
                    ↓
T=10-30 - TTL EXPIRATION IN ETCD
┌─────────────────────────────────────┐
│ etcd DCS:                           │
│ ├─ Watch TTL for pg-node-1: EXPIRE │
│ ├─ Delete: /pg-ha-cluster/leader   │
│ ├─ Trigger watch notifications      │
│ └─ Cluster is LEADERLESS            │
└─────────────────────────────────────┘
                    ↓
T=30-35 - LEADER ELECTION (CRITICAL)
┌─────────────────────────────────────┐
│ Both Standby Nodes Race:            │
│                                     │
│ PHASE 1: Evaluate Candidates        │
│ ├─ Check replication lag            │
│ ├─ Check data_checksums status      │
│ ├─ Determine which is "fresher"     │
│ └─ Select best promotion candidate  │
│                                     │
│ PHASE 2: Acquire Leader Lock        │
│ ├─ Both attempt etcd compare-swap   │
│ ├─ Lock: /pg-ha-cluster/leader      │
│ ├─ Atomic operation (only 1 wins)   │
│ └─ Winner announced in etcd         │
│                                     │
│ EXAMPLE: pg-node-2 wins             │
│ ├─ Lowest replication lag           │
│ ├─ Successfully acquired lock       │
│ └─ Becomes PROMOTED PRIMARY         │
└─────────────────────────────────────┘
                    ↓
T=35-40 - NEW PRIMARY PROMOTION
┌─────────────────────────────────────┐
│ pg-node-2 (NEW PRIMARY):            │
│                                     │
│ PHASE 1: Exit Standby Mode          │
│ ├─ Execute: pg_ctl promote          │
│ ├─ Stop WAL replay                  │
│ └─ Timeline ID incremented (12→13)  │
│                                     │
│ PHASE 2: Open for Connections       │
│ ├─ Allow new connections            │
│ ├─ Accept writes                    │
│ ├─ PostgreSQL role: PRIMARY/MASTER  │
│ └─ Accept transactions              │
│                                     │
│ PHASE 3: Update etcd Leadership      │
│ ├─ Write: /pg-ha-cluster/leader     │
│ ├─ Value: pg-node-2 metadata        │
│ ├─ TTL: 30 seconds (heartbeat)      │
│ ├─ Add TTL refresh loop             │
│ └─ Cluster knows new leader         │
│                                     │
│ RESULT: Primary is READY for writes │
└─────────────────────────────────────┘
                    ↓
T=40-50 - REPLICA RESYNCHRONIZATION
┌─────────────────────────────────────┐
│ pg-node-3 (REMAINING STANDBY):      │
│                                     │
│ PHASE 1: Detect Primary Change      │
│ ├─ WAL streaming fails → reconnect  │
│ ├─ Read etcd new leader info        │
│ └─ Identify: pg-node-2 is new leader│
│                                     │
│ PHASE 2: Fast Resynchronization     │
│ ├─ Execute: pg_rewind               │
│ │  (instead of full pg_basebackup)  │
│ ├─ Roll back divergent WAL          │
│ ├─ Align with new timeline (13)     │
│ ├─ Time: ~5-10 seconds (faster)     │
│ └─ No data loss (pg_rewind safe)    │
│                                     │
│ PHASE 3: Resume WAL Streaming       │
│ ├─ Connect to pg-node-2 on 5432     │
│ ├─ Find LSN resume point            │
│ ├─ Start consuming WAL records      │
│ └─ Synchronous replication: ON      │
│                                     │
│ PHASE 4: Update Replication Slot    │
│ ├─ Reconnect to replication slot    │
│ ├─ Slot name: pg-node-3             │
│ └─ Resume slot streaming            │
│                                     │
│ RESULT: Replica fully synced        │
└─────────────────────────────────────┘
                    ↓
T=50-55 - CLUSTER STABILIZATION
┌─────────────────────────────────────┐
│ Final Cluster State:                │
│                                     │
│ pg-node-1 (OFFLINE):                │
│ ├─ Status: UNHEALTHY                │
│ ├─ No longer in replication         │
│ ├─ No longer in cluster leadership  │
│ ├─ Requires manual intervention     │
│ └─ Or automatic restart (if enabled)│
│                                     │
│ pg-node-2 (NEW PRIMARY):            │
│ ├─ Status: HEALTHY (LEADER)         │
│ ├─ Role: Primary                    │
│ ├─ Accepting writes: YES            │
│ ├─ Connected replicas: 1 (pg-node-3)│
│ └─ Replication lag: ~0 bytes        │
│                                     │
│ pg-node-3 (STANDBY):                │
│ ├─ Status: HEALTHY (REPLICA)        │
│ ├─ Role: Standby                    │
│ ├─ Connected to: pg-node-2          │
│ ├─ WAL streaming: ACTIVE            │
│ └─ Replication lag: ~0 bytes        │
│                                     │
│ Metrics:                            │
│ ├─ RPO: ~0 bytes (sync replication) │
│ ├─ RTO: ~50 seconds (detection+promo)
│ ├─ Data Loss: NONE                  │
│ └─ Write Availability: RESTORED     │
└─────────────────────────────────────┘

═══════════════════════════════════════════
SUCCESS: Cluster automatically healed!
New primary operational, reads/writes work
```

---

## Cluster Architecture

### Network & Container Layout

```
┌──────────────────────────────────────────────────────────────┐
│                   DOCKER HOST MACHINE                         │
│              (Linux/macOS/Windows with Docker)               │
└──────────────────────────────────────────────────────────────┘
                            ↓
                   
                ┌──────────────────┐
                │  Docker Engine   │
                │   (v20.0+)       │
                └──────────────────┘
                            ↓

┌──────────────────────────────────────────────────────────────────────┐
│                  pg-ha-network (Bridge Network)                      │
│                  IPAM: 172.20.0.0/16                                │
│                  Gateway: 172.20.0.1                                │
│                                                                      │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│  │   pg-node-1      │  │   pg-node-2      │  │   pg-node-3      │ │
│  │   (Primary)      │  │   (Standby)      │  │   (Standby)      │ │
│  │─────────────────┼──│─────────────────┼──│──────────────────┤ │
│  │ Image: postgres- │  │ Image: postgres- │  │ Image: postgres- │ │
│  │   patroni:18-... │  │   patroni:18-... │  │   patroni:18-... │ │
│  │                  │  │                  │  │                  │ │
│  │ IP: 172.20.0.2  │  │ IP: 172.20.0.3  │  │ IP: 172.20.0.4  │ │
│  │                  │  │                  │  │                  │ │
│  │ Ports:           │  │ Ports:           │  │ Ports:           │ │
│  │ ├─ :5432 (PG)   │  │ ├─ :5432 (PG)   │  │ ├─ :5432 (PG)   │ │
│  │ └─ :8008 (REST) │  │ └─ :8008 (REST) │  │ └─ :8008 (REST) │ │
│  │                  │  │                  │  │                  │ │
│  │ Volumes:         │  │ Volumes:         │  │ Volumes:         │ │
│  │ ├─ pg-node-1-... │  │ ├─ pg-node-2-... │  │ ├─ pg-node-3-... │ │
│  │ ├─ pgbackrest... │  │ └─ pgbackrest... │  │ └─ pgbackrest... │ │
│  │ └─ patroni YAML  │  │    (shared)      │  │    (shared)      │ │
│  │                  │  │                  │  │                  │ │
│  │ Config:          │  │ Config:          │  │ Config:          │ │
│  │ patroni-node-1   │  │ patroni-node-2   │  │ patroni-node-3   │ │
│  │ .yml (ro)        │  │ .yml (ro)        │  │ .yml (ro)        │ │
│  └─────────┬────────┘  └─────────┬────────┘  └─────────┬────────┘ │
│            │                     │                     │            │
│            └─────────────────────┼─────────────────────┘            │
│                                  │ WAL Streaming                    │
│                                  │ Replication Slots                │
│                                  ↓                                  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  etcd (Distributed Config Store)                             │  │
│  │  Image: quay.io/coreos/etcd:v3.5.0                          │  │
│  │                                                                │  │
│  │  IP: 172.20.0.5                                              │  │
│  │                                                                │  │
│  │  Ports:                                                       │  │
│  │  ├─ :2379 (client API) ← Patroni connects here              │  │
│  │  └─ :2380 (peer communication)                              │  │
│  │                                                                │  │
│  │  Data Store:                                                  │  │
│  │  ├─ /pg-ha-cluster/leader → pg-node-1 | pg-node-2 | ...    │  │
│  │  ├─ /pg-ha-cluster/members/{node} → node metadata           │  │
│  │  ├─ /pg-ha-cluster/initialize → init lock                   │  │
│  │  ├─ /pg-ha-cluster/sync → sync replicas list                │  │
│  │  └─ TTL: 30 seconds for each heartbeat                       │  │
│  │                                                                │  │
│  │  All 3 PostgreSQL nodes register here                        │  │
│  └──────────────────┬───────────────────────────────────────────┘  │
│                     │ (all nodes connected)                         │
│                     │                                               │
│  ┌──────────────────┴───────────────────────────────────────────┐  │
│  │  dbhub (Database Management UI - Bytebase)                   │  │
│  │  Image: bytebase/bytebase:latest                             │  │
│  │                                                                │  │
│  │  IP: 172.20.0.6                                              │  │
│  │                                                                │  │
│  │  Port:                                                        │  │
│  │  └─ :8080 (web UI)                                           │  │
│  │                                                                │  │
│  │  Connection:                                                  │  │
│  │  └─ Connects to pg-node-1:5432 (primary read/write)        │  │
│  │                                                                │  │
│  │  Features:                                                    │  │
│  │  ├─ SQL editor                                               │  │
│  │  ├─ Schema browser                                           │  │
│  │  ├─ Migrations                                               │  │
│  │  └─ User management                                          │  │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
                            ↓

           ┌────────────────────────────────────┐
           │     HOST MACHINE PORT MAPPINGS     │
           ├────────────────────────────────────┤
           │                                    │
           │  localhost:5432  ↔  pg-node-1:5432│
           │  (primary endpoint)                │
           │                                    │
           │  localhost:5433  ↔  pg-node-2:5432│
           │  (replica 1 - read-only)           │
           │                                    │
           │  localhost:5434  ↔  pg-node-3:5432│
           │  (replica 2 - read-only)           │
           │                                    │
           │  localhost:9090  ↔  dbhub:8080    │
           │  (Bytebase UI)                     │
           │                                    │
           │  localhost:12379 ↔  etcd:2379     │
           │  (etcd client API - optional)      │
           │                                    │
           │  localhost:12380 ↔  etcd:2380     │
           │  (etcd peer API - optional)        │
           │                                    │
           └────────────────────────────────────┘
                            ↓

                   ┌─────────────────┐
                   │  Client Apps    │
                   ├─────────────────┤
                   │                 │
                   │ psql -> 5432    │
                   │                 │
                   │ python-psycopg2 │
                   │  -> 5432        │
                   │                 │
                   │ Browser         │
                   │  -> :9090       │
                   │                 │
                   └─────────────────┘
```

---

## Component Interactions

### Write Transaction Flow (Synchronous Replication)

```
REQUEST: INSERT INTO items (vec) VALUES ('[...]'::vector);
═════════════════════════════════════════════════════════

Application Code
     │
     │ Sends SQL over TCP
     │
     ↓
     
┌─────────────────────────────────────────────────────┐
│ pg-node-1 (PRIMARY) - Port 5432                     │
│                                                      │
│ 1. PostgreSQL Connection Handler                    │
│    └─ Accept incoming TCP connection               │
│                                                      │
│ 2. Parse & Plan Query                              │
│    ├─ Parse: INSERT statement                      │
│    ├─ Plan: execute insert                         │
│    └─ Check: constraints, permissions              │
│                                                      │
│ 3. Write to WAL (Write-Ahead Log)                  │
│    ├─ Buffer in: shared_buffers                    │
│    ├─ Write to: /var/lib/postgresql/18/main/...  │
│    ├─ Log: BEGIN, INSERT, COMMIT statements       │
│    └─ Action: fsync() to disk immediately          │
│                                                      │
│ 4. Execute Transaction                             │
│    ├─ Update: heap page in shared_buffers          │
│    ├─ Update: pgvector index (if present)          │
│    ├─ Acquire: transaction lock                    │
│    └─ Status: IN PROGRESS                          │
│                                                      │
│ 5. Initiate WAL Streaming to Replicas              │
│    ├─ Send WAL records to: pg-node-2, pg-node-3  │
│    ├─ Protocol: Streaming Replication Protocol     │
│    ├─ Connection: TCP 5432 to 5432 (replication)  │
│    └─ Data: LSN + WAL data                         │
│                                                      │
└────────────────┬────────────────────────────────────┘
                 │
      (Parallel WAL Streaming)
                 │
        ┌────────┴────────┐
        │                 │
        ↓                 ↓

┌─────────────────────────────┐  ┌─────────────────────────────┐
│ pg-node-2 (STANDBY)         │  │ pg-node-3 (STANDBY)         │
│                              │  │                              │
│ 1. Receive WAL Segment      │  │ 1. Receive WAL Segment      │
│    ├─ Buffer received data  │  │    ├─ Buffer received data  │
│    └─ Parse WAL records     │  │    └─ Parse WAL records     │
│                              │  │                              │
│ 2. Write WAL to Disk        │  │ 2. Write WAL to Disk        │
│    ├─ Write to: pg_wal dir  │  │    ├─ Write to: pg_wal dir  │
│    ├─ fsync() to disk        │  │    ├─ fsync() to disk        │
│    └─ Confirm: written       │  │    └─ Confirm: written       │
│                              │  │                              │
│ 3. Replay WAL into Data     │  │ 3. Replay WAL into Data     │
│    ├─ Insert row into heap  │  │    ├─ Insert row into heap  │
│    ├─ Update pgvector index │  │    ├─ Update pgvector index │
│    ├─ Update visibility     │  │    ├─ Update visibility     │
│    └─ Data matches primary  │  │    └─ Data matches primary  │
│                              │  │                              │
│ 4. Update Replication Status│  │ 4. Update Replication Status│
│    ├─ LSN Position: XXXXX   │  │    ├─ LSN Position: XXXXX   │
│    ├─ Write LAG: 0 bytes    │  │    ├─ Write LAG: 0 bytes    │
│    ├─ Flush LAG: 0 bytes    │  │    ├─ Flush LAG: 0 bytes    │
│    ├─ Replay LAG: 0 bytes   │  │    ├─ Replay LAG: 0 bytes   │
│    └─ Status: SYNCED        │  │    └─ Status: SYNCED        │
│                              │  │                              │
│ 5. Send ACK Back to Primary │  │ 5. Send ACK Back to Primary │
│    ├─ Over: replication TCP │  │    ├─ Over: replication TCP │
│    ├─ Says: "data received" │  │    ├─ Says: "data received" │
│    └─ LSN: confirmed write  │  │    └─ LSN: confirmed write  │
│                              │  │                              │
└────────────┬─────────────────┘  └─────────────────┬──────────┘
             │                                       │
             └───────────────────────┬───────────────┘
                                     │ (Both ACKs)
                                     │
                                     ↓

┌──────────────────────────────────────────────────────┐
│ pg-node-1 (PRIMARY) - Receive ACKs                   │
│                                                       │
│ 1. Wait for Synchronous Replicas                    │
│    └─ synchronous_standby_names: '2 (pg-node-2, pg-node-3)'
│       (both must acknowledge)                        │
│                                                       │
│ 2. Received ACKs from:                              │
│    ├─ pg-node-2: ACK received ✓                     │
│    └─ pg-node-3: ACK received ✓                     │
│       (CONDITION MET: 2/2 standbys confirmed)       │
│                                                       │
│ 3. Complete Transaction Commit                      │
│    ├─ WAL: log COMMIT record                        │
│    ├─ Transaction: mark as COMMITTED                │
│    ├─ Locks: release all row locks                  │
│    ├─ Buffers: ready to be written by bg writer    │
│    └─ Status: COMPLETE                              │
│                                                       │
│ 4. Send COMMIT Result to Application               │
│    ├─ Protocol: PostgreSQL wire protocol            │
│    ├─ Message: "INSERT 0 1" (success)               │
│    ├─ Time: ~10-50ms (network dependent)            │
│    └─ Data: safely on 3 servers                     │
│                                                       │
└──────────────────────────────────────────────────────┘
     │
     │ COMMIT confirmed
     │
     ↓

Application (Success!)
├─ INSERT succeeded
├─ Data on primary + 2 replicas
├─ Zero data loss (RPO=0)
└─ Ready for next query


TRANSACTION GUARANTEES:
═════════════════════════════════════════════════════════
✅ ACID Compliance: Guaranteed
✅ Data Consistency: All 3 copies identical
✅ Durability: Data on disk (all 3 servers)
✅ RPO (Recovery Point Objective): 0 bytes/0 data loss
✅ RTO (Recovery Time Objective): <30 seconds (failover)
✅ Synchronous Mode: Yes (all writes wait for replicas)
```

---

## Data Flow Diagrams

### pgvector Vector Search Operations

```
VECTOR SIMILARITY SEARCH OPERATION
════════════════════════════════════

SETUP PHASE:
─────────────

1. Create Vector Table on Primary (pg-node-1)
   
   docker exec pg-node-1 psql -U postgres -d postgres -c "
   CREATE TABLE items (
     id BIGSERIAL PRIMARY KEY,
     name TEXT,
     embedding vector(1536)  ← pgvector type
   );
   "
   
   ├─ Replicates immediately to pg-node-2, pg-node-3
   ├─ WAL streaming propagates DDL
   └─ All 3 nodes have identical schema

2. Create IVFFLAT Index for Fast Search
   
   CREATE INDEX ON items USING ivfflat (
     embedding vector_cosine_ops
   ) WITH (lists = 10);
   
   ├─ Index Type: IVFFLAT
   │  ├─ Clusters vectors into 10 groups
   │  ├─ Computes cluster centers
   │  └─ Approximate nearest neighbor search
   ├─ Distance Metric: cosine_ops
   │  └─ Similarity range: 0 (identical) to 2 (opposite)
   └─ Replicates to standby nodes (WAL)

INSERTION PHASE:
────────────────

1. Extract Vector from ML Model
   
   Application (e.g., Python Flask)
   ├─ Text Input: "machine learning"
   ├─ Call OpenAI API / Local Model
   ├─ Returns: 1536-dimensional vector
   │  Example: [0.123, 0.456, ..., 0.789]
   └─ Type: PostgreSQL vector type

2. Insert Vector via Primary
   
   INSERT INTO items (name, embedding)
   VALUES ('ML Article', ARRAY[0.123, 0.456, ..., 0.789]::vector);
   
   ├─ Routes to pg-node-1 (primary)
   ├─ Synchronous replication: YES
   ├─ Waits for pg-node-2 & pg-node-3 ACK
   └─ Returns: INSERT 0 1 (when replicated)

3. Replication to Standby Nodes
   
   WAL Entry: BEGIN, INSERT (tuple), COMMIT
   ├─ Stream to pg-node-2 (port 5432)
   ├─ Stream to pg-node-3 (port 5432)
   ├─ Both replay WAL
   ├─ Both create tuple in heap
   ├─ Both update IVFFLAT index
   └─ Sync confirmed: ACK from both

SEARCH PHASE:
──────────────

1. Prepare Query Vector (from ML Model)
   
   Query Text: "deep learning"
   ├─ ML Model generates: [0.234, 0.567, ..., 0.891]
   └─ Type: PostgreSQL vector(1536)

2. Execute Similarity Search (via Replica for Load Balancing)
   
   SELECT id, name, embedding <-> query_vec AS distance
   FROM items
   ORDER BY embedding <-> query_vec
   LIMIT 5;
   
   Route to: pg-node-2 or pg-node-3 (standby, read-only)
   ├─ Load balancing: round-robin between 2 replicas
   └─ Query type: read-only (no replication needed)

3. Query Planner Analysis
   
   ├─ Check: IVFFLAT index available? YES
   ├─ Decision: Use IVFFLAT for approximate search
   ├─ Cost: O(log N) clusters vs O(N) full scan
   └─ Estimated rows: ~50 from index scan

4. IVFFLAT Index Operations
   
   Execution Plan:
   ├─ STEP 1: Compute cluster centers distance
   │  ├─ Find closest 2-3 clusters to query_vec
   │  ├─ Distance: cosine similarity
   │  └─ Clusters checked: 2/10 (~20% of data)
   │
   ├─ STEP 2: Scan selected cluster pages
   │  ├─ Fetch tuples from ~50 index entries
   │  ├─ Buffer reads: B-tree lookups
   │  └─ Approx rows examined: 50-100
   │
   ├─ STEP 3: Precise Distance Calculation
   │  ├─ Calculate exact distance all 100 rows
   │  ├─ Formula: 1 - (dot product / (norm1 * norm2))
   │  ├─ CPU operations: ~150,000 float calcs
   │  └─ Time: < 1ms (GPU not used in pgvector)
   │
   ├─ STEP 4: Sort & Return
   │  ├─ Sort by distance (ascending)
   │  ├─ LIMIT 5: take top results
   │  └─ Return: 5 rows
   │
   └─ Total Query Time: ~5-10ms (vs 2000ms full scan)

5. Results Returned to Client
   
   ┌─────────────────────────────────────────┐
   │ id │  name          │ distance          │
   ├────┼────────────────┼───────────────────┤
   │ 1  │ ML Basics      │ 0.0234 ← closest  │
   │ 2  │ Deep Learning  │ 0.1456            │
   │ 3  │ Neural Networks│ 0.2123            │
   │ 4  │ Transformers   │ 0.3567            │
   │ 5  │ AI Overview    │ 0.4234            │
   └─────────────────────────────────────────┘

LOAD BALANCING STRATEGY:
────────────────────────

Writes (INSERT/UPDATE/DELETE):
├─ Always route to: pg-node-1 (primary)
├─ Reason: Only primary accepts writes
└─ Sync: Wait for replica ACKs

Reads (SELECT):
├─ Route 50% to: pg-node-2 (replica 1)
├─ Route 50% to: pg-node-3 (replica 2)
├─ Reason: Distribute read load
├─ Benefit: 2x query throughput
└─ Caveat: Slight replication lag possible (<100ms)

Vector Similarity Searches:
├─ Preferably route to: pg-node-2, pg-node-3
├─ Index available: YES (replicated via WAL)
├─ Parallelism: Run 5 queries: 1 primary, 2+ replicas
└─ Throughput: 10+ queries/sec (on single machine)
```

---

## Authentication Flow (SCRAM-SHA-256)

```
NETWORK AUTHENTICATION SEQUENCE
════════════════════════════════════

Setup: pg_hba.conf rules (from entrypoint-patroni.sh)
────────────────────────────────────────────────────
# First, local connections (no auth needed)
local   all   all                     trust

# Localhost (no auth needed)
host    all   all   127.0.0.1/32     trust
host    all   all   ::1/128          trust

# Container-to-container (SCRAM-SHA-256)
host    all   all   172.20.0.0/16   scram-sha-256  ← replication auth

# External network (SCRAM-SHA-256)
host    all   all   ::/0             scram-sha-256


SCENARIO: pg-node-2 Replicates from pg-node-1
═════════════════════════════════════════════════

T=0: Connection Establishment

┌─────────────────────────────────────────────────────┐
│ pg-node-2 (Standby): "I need to replicate"         │
└──────────────┬──────────────────────────────────────┘
               │
               │ TCP Connect to pg-node-1:5432
               │ (replication protocol)
               │
               ↓
┌─────────────────────────────────────────────────────┐
│ pg-node-1 (Primary): Receives connection             │
│ ├─ Source IP: 172.20.0.3 (pg-node-2)               │
│ ├─ Port: random high port                          │
│ └─ Purpose: replication (determined by REPLICATION keyword)
└─────────────────────────────────────────────────────┘


T=1: pg_hba.conf Matching

┌─────────────────────────────────────────────────────┐
│ pg-node-1 checks pg_hba.conf rules (in order):     │
│                                                     │
│ 1. local   all   all   trust            ✘ not local
│ 2. host    all   all   127.0.0.1/32    ✘ not localhost
│ 3. host    all   all   ::1/128         ✘ not IPv6 loopback
│ 4. host    all   all   172.20.0.0/16   ✓ MATCH!
│    └─ Method: scram-sha-256
│
│ DECISION: Require SCRAM-SHA-256 authentication
└──────────────┬──────────────────────────────────────┘
               │
               ↓

T=2: SCRAM-SHA-256 Negotiation

┌──────────────┐                    ┌──────────────┐
│ pg-node-2    │                    │ pg-node-1    │
│ (Client)     │                    │ (Server)     │
└──────┬───────┘                    └───────┬──────┘
       │                                    │
       │ Client requests: SCRAM-SHA-256    │
       │ (offers mechanisms)                │
       ├────────────────────────────────→  │
       │                                    │
       │ Server: "OK, send username"       │
       │ ←────────────────────────────────┤
       │                                    │
       │ Client-First Msg: username=replicator
       ├────────────────────────────────→  │


T=3: Server Challenge

┌──────────────────────────────────────────────────────┐
│ pg-node-1 (Server):                                  │
│                                                      │
│ 1. Look up user: replicator                         │
│    └─ Query: SELECT rolpassword FROM pg_authid      │
│       WHERE rolname = 'replicator'                  │
│    └─ Stored: SCRAM-SHA-256$4096:salt:StoredKey...│
│                                                      │
│ 2. Extract stored parameters:                        │
│    ├─ Salt: 56-bit random value (base64)           │
│    ├─ Iterations: 4096 (PBKDF2 rounds)             │
│    └─ StoredKey: SHA256(ClientKey) hash            │
│                                                      │
│ 3. Generate server challenge:                       │
│    ├─ Nonce: random challenge value                │
│    ├─ Salt: from stored hash                       │
│    └─ Encoding: base64 with metadata               │
│                                                      │
│ 4. Send Server-First msg:                          │
│    ├─ r=clientNonce + serverNonce                  │
│    ├─ s=base64(salt)                               │
│    └─ i=4096 (iterations)                          │
└──────────────┬─────────────────────────────────────┘
               │ Server-First Message
               ↓

┌──────────────┐
│ pg-node-2    │
│ (Client)     │ Receives challenge
│              │
│ 1. Parse message:
│    ├─ Salt: extract & decode
│    ├─ Iterations: 4096
│    └─ Nonce: parse

│ 2. Perform CPU-intensive PBKDF2:
│    ├─ Input: password="replicator1"
│    ├─ Salt: random salt
│    ├─ Iterations: 4096 rounds
│    ├─ Hash Algorithm: PBKDF2-SHA256
│    │  └─ 1st-round: HMAC-SHA256(pass, salt)
│    │  └─ 2nd-round: HMAC-SHA256(result, salt)
│    │  └─ ... repeat 4094 more times ...
│    │  └─ Result: 256-bit salted hash
│    └─ Time: ~10-50ms (CPU intensive)
│
│ 3. Derive keys from salted hash:
│    ├─ SaltedPassword = PBKDF2(pass, salt, 4096)
│    ├─ ClientKey = HMAC-SHA256(SaltedPassword, "Client Key")
│    ├─ StoredKey = SHA256(ClientKey)
│    ├─ AuthMessage = nonce + server-first + client-final
│    ├─ ClientSignature = HMAC-SHA256(StoredKey, AuthMessage)
│    └─ ClientProof = ClientKey XOR ClientSignature
│
│ 4. Send Client-Final message:
│    ├─ channel_binding: base64 encoded
│    ├─ nonce: server's challenge nonce
│    └─ proof: ClientProof (base64)
└──────┬────────┘
       │ Client-Final Message
       ↓

T=4: Server Verification

┌──────────────────────────────────────────────────────┐
│ pg-node-1 (Server):                                  │
│                                                      │
│ 1. Receive Client-Final message                     │
│    └─ Extract: ClientProof                          │
│                                                      │
│ 2. Recreate authentication:                         │
│    ├─ Stored: SCRAM-SHA-256$4096:salt:StoredKey... │
│    ├─ Reconstruct: same PBKDF2 (same salt/iters)  │
│    ├─ Compute: ClientKey from received proof       │
│    ├─ Hash: SHA256(ClientKey) → compare StoredKey  │
│    └─ Match? YES ✓                                 │
│                                                      │
│ 3. Generate Server-Signature:                       │
│    ├─ ServerKey = HMAC-SHA256(SaltedPassword, ...)│
│    ├─ ServerSignature = HMAC-SHA256(ServerKey, ...) │
│    └─ Encodes: proof server knows password too     │
│                                                      │
│ 4. Send Server-Final message:                       │
│    └─ v=base64(ServerSignature)                    │
│       (proves server authenticated)                 │
│                                                      │
│ 5. Authentication Result:                           │
│    ├─ Status: ✓ AUTHENTICATED                      │
│    ├─ User: replicator                             │
│    ├─ Privileges: REPLICATION privilege checked    │
│    └─ Connection: READY FOR LOGICAL COMMANDS       │
└──────────────┬─────────────────────────────────────┘
               │ Server-Final Message
               ↓

┌──────────────┐
│ pg-node-2    │
│ (Client)     │
│              │ Receives signature
│ Verify signature confirms server knows password
│ ├─ Authentication: ✓ MUTUAL (client ↔ server)
│ └─ Connection: READY
└──────────────┘


T=5: Replication Begins

Both authenticated, connection ready:
├─ pg-node-2 commands: IDENTIFY_SYSTEM
├─ pg-node-1 responds: system parameters
├─ pg-node-2 commands: START_REPLICATION from LSN xxxx
├─ pg-node-1 begins: streaming WAL records
└─ Data now flows until standby catches up


SECURITY PROPERTIES:
═════════════════════════════════════════════════════
✓ No plaintext transmission
  └─ Password never sent over network
  
✓ Salt-based hashing
  └─ Rainbow table attacks prevented
  
✓ Work factor (4096 iterations)
  └─ Brute force attacks slowed
  
✓ Challenge-response
  └─ Replay attacks prevented
  
✓ Mutual authentication
  └─ Both client & server verified
  
✓ Modern standard
  └─ RFC 5802 compliant (SCRAM)
  └─ PostgreSQL 10+ native support
```

---

## Terraform Code Flow

### Complete Execution Path (main-ha.tf)

```
TERRAFORM DEPLOYMENT EXECUTION FLOW
═════════════════════════════════════

1. FILE: variables-ha.tf
   ──────────────────────
   Defines configuration parameters:
   
   variable "postgres_user"
   ├─ Default: "pgadmin"
   ├─ Type: string
   └─ Used in: all container env vars
   
   variable "postgres_password"  ⚠️ SENSITIVE
   ├─ Default: "pgAdmin1"        (should be changed!)
   ├─ Type: string
   ├─ Sensitive: true            (hidden in logs)
   └─ Used in: PATRONI_POSTGRESQL__PASSWORD env var
   
   variable "postgres_db"
   ├─ Default: "postgres"
   └─ Used in: database creation
   
   variable "replication_password"  ⚠️ SENSITIVE
   ├─ Default: "replicator1"   (should be changed!)
   ├─ Type: string
   └─ Used in: replication authentication
   
   variable "dbhub_port"
   ├─ Default: 9090
   └─ Used in: port mapping (8080:dbhub_port)
   
   variable "etcd_port", "etcd_peer_port", etc.
   └─ Used in: port mappings


2. FILE: main-ha.tf (Resource Order)
   ────────────────────────────────
   
   A. docker_network.pg_ha_network
      ├─ Name: "pg-ha-network"
      ├─ Driver: "bridge"
      ├─ IPAM block: 172.20.0.0/16
      └─ Output: network.pg_ha_network.name
   
   B. docker_volume (5x)
      ├─ docker_volume.pg_node_1_data
      ├─ docker_volume.pg_node_2_data
      ├─ docker_volume.pg_node_3_data
      ├─ docker_volume.etcd_data
      └─ docker_volume.pgbackrest_repo
      
      Depends on: nothing (parallel)
   
   C. docker_image.postgres_patroni
      ├─ Build from: Dockerfile.patroni
      ├─ Dockerfile path: ./Dockerfile.patroni
      ├─ Build context: current directory
      ├─ Build args: (loaded from Dockerfile)
      ├─ Tag: "postgres-patroni:18-pgvector"
      ├─ Keep locally: true
      └─ Depends on: nothing (parallel)
   
   D. docker_image.etcd
      ├─ Pull from: quay.io/coreos/etcd:v3.5.0
      ├─ Keep locally: true
      └─ Depends on: nothing (parallel)
   
   E. docker_image.dbhub
      ├─ Pull from: bytebase/bytebase:latest
      ├─ Keep locally: true
      └─ Depends on: nothing (parallel)
   
   F. docker_container.etcd
      ├─ Depends on: docker_image.etcd, docker_network, docker_volume.etcd_data
      │
      ├─ Configuration:
      │  ├─ Image: docker_image.etcd.image_id
      │  ├─ Name: "etcd"
      │  ├─ Network: "pg-ha-network"
      │  ├─ Ports:
      │  │  ├─ 2379:2379 (client)
      │  │  └─ 2380:2380 (peer)
      │  ├─ Env:
      │  │  ├─ ETCD_NAME=etcd
      │  │  ├─ ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
      │  │  ├─ ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379
      │  │  ├─ ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380
      │  │  └─ ETCD_INITIAL_ADVERTISE_PEER_URLS=http://etcd:2380
      │  ├─ Volumes:
      │  │  └─ /var/lib/etcd ← docker_volume.etcd_data
      │  ├─ Restart: unless-stopped
      │  └─ Must run: true
      │
      ├─ Outputs:
      │  ├─ container ID
      │  ├─ container name: "etcd"
      │  └─ network data (IP: 172.20.0.5)
      │
      └─ Health Check:
         └─ Patroni will verify connection to etcd:2379
   
   G. docker_container.pg_node_1 (PRIMARY)
      ├─ Depends on: 
      │  ├─ docker_container.etcd (must start first)
      │  ├─ docker_image.postgres_patroni
      │  ├─ docker_network.pg_ha_network
      │  ├─ docker_volume.pg_node_1_data
      │  ├─ docker_volume.pgbackrest_repo
      │  └─ (awaits etcd readiness)
      │
      ├─ Configuration:
      │  ├─ Image: docker_image.postgres_patroni.image_id
      │  ├─ Name: "pg-node-1"
      │  ├─ Network: "pg-ha-network"
      │  ├─ Ports:
      │  │  ├─ 5432:5432 (PostgreSQL)
      │  │  └─ 8008:8008 (Patroni API)
      │  │
      │  ├─ Entrypoint:
      │  │  └─ ["/usr/local/bin/entrypoint-patroni.sh"]
      │  │
      │  ├─ Env Variables (from variables-ha.tf):
      │  │  ├─ PATRONI_POSTGRESQL__PASSWORD=${var.postgres_password}
      │  │  ├─ PATRONI_POSTGRESQL__SUPERUSER_PASSWORD=${...}
      │  │  ├─ PATRONI_POSTGRESQL__REPLICATION_USERNAME=replicator
      │  │  ├─ PATRONI_POSTGRESQL__REPLICATION_PASSWORD=${var.replication_password}
      │  │  ├─ PATRONI_DCS_TYPE=etcd3
      │  │  ├─ PATRONI_ETCD__HOSTS=etcd:2379
      │  │  ├─ PATRONI_ETCD__PROTOCOL=http
      │  │  ├─ PATRONI_NAME=pg-node-1
      │  │  ├─ PATRONI_POSTGRESQL__CONNECT_ADDRESS=pg-node-1:5432
      │  │  ├─ PATRONI_POSTGRESQL__DATA_DIR=/var/lib/postgresql/18/main
      │  │  ├─ PATRONI_POSTGRESQL__INITDB__ENCODING=UTF8
      │  │  ├─ PATRONI_POSTGRESQL__INITDB__LOCALE=en_US.UTF-8
      │  │  ├─ PATRONI_POSTGRESQL__INITDB__DATA_CHECKSUMS=on
      │  │  ├─ PATRONI_POSTGRESQL__PARAMETERS__SHARED_PRELOAD_LIBRARIES=vector,pg_stat_statements
      │  │  └─ (many more...)
      │  │
      │  ├─ Mounts:
      │  │  ├─ /var/lib/postgresql ← docker_volume.pg_node_1_data
      │  │  ├─ /var/lib/pgbackrest ← docker_volume.pgbackrest_repo
      │  │  └─ /etc/patroni/patroni.yml ← patroni/patroni-node-1.yml (read-only)
      │  │
      │  ├─ Restart: unless-stopped
      │  ├─ Must run: true
      │  └─ Wait logic: Terraform waits for startup
      │
      ├─ Startup Sequence (/usr/local/bin/entrypoint-patroni.sh):
      │  1. mkdir -p /var/lib/postgresql/18/main
      │  2. chown postgres:postgres /var/lib/postgresql
      │  3. chmod 755 /var/lib/postgresql
      │  4. chmod 700 /var/lib/postgresql/18/main
      │  5. Create pg_hba.conf from template
      │  6. exec patroni /etc/patroni/patroni.yml
      │  7. Patroni bootstraps PostgreSQL (initdb)
      │  8. PostgreSQL starts in primary mode
      │  9. Patroni acquires leader lock in etcd
      │  10. Cluster ready for connections
      │
      ├─ Outputs:
      │  ├─ Container ID
      │  ├─ Container name: "pg-node-1"
      │  ├─ Network IP: 172.20.0.2
      │  └─ Ports: 5432, 8008
      │
      └─ Status After Startup:
         ├─ Role: PRIMARY (LEADER)
         ├─ etcd status: /pg-ha-cluster/leader → pg-node-1
         ├─ PostgreSQL: accepting connections
         └─ Ready for: replication slave connections
   
   H. docker_container.pg_node_2 (REPLICA)
      ├─ Depends on:
      │  ├─ docker_container.pg_node_1 ← SEQUENTIAL (waits for primary)
      │  ├─ docker_image.postgres_patroni
      │  ├─ docker_network.pg_ha_network
      │  └─ [similar volumes & configs]
      │
      ├─ Configuration:
      │  ├─ [Similar structure to pg_node_1]
      │  ├─ Name: "pg-node-2"
      │  ├─ Port: 5433:5432 (external 5433)
      │  ├─ Patroni API: 8009:8008
      │  ├─ PATRONI_NAME=pg-node-2
      │  └─ Mount: patroni/patroni-node-2.yml (read-only)
      │
      ├─ Startup Sequence:
      │  1. Same directory setup
      │  2. Start Patroni
      │  3. Patroni detects: primary already exists (pg-node-1)
      │  4. Get full backup via pg_basebackup from pg-node-1
      │  5. Start PostgreSQL in standby mode
      │  6. WAL streaming begins from pg-node-1
      │  7. Synchronous replication slot created
      │  8. Registered in etcd: /pg-ha-cluster/members/pg-node-2
      │
      └─ Status:
         ├─ Role: STANDBY (REPLICA)
         ├─ Connection: streaming from pg-node-1
         └─ Replication lag: ~0 bytes
   
   I. docker_container.pg_node_3 (REPLICA)
      ├─ Depends on:
      │  ├─ docker_container.pg_node_2 ← SEQUENTIAL
      │  └─ [similar to pg_node_2]
      │
      ├─ Configuration: [Similar structure]
      │
      └─ Status: [Similar to pg_node_2]
   
   J. docker_container.dbhub (DBHub UI)
      ├─ Depends on:
      │  ├─ docker_container.pg_node_1
      │  ├─ docker_container.pg_node_2
      │  ├─ docker_container.pg_node_3
      │  └─ docker_image.dbhub
      │
      ├─ Configuration:
      │  ├─ Image: docker_image.dbhub.image_id
      │  ├─ Name: "dbhub"
      │  ├─ Network: "pg-ha-network"
      │  ├─ Port: 9090:8080 (using var.dbhub_port)
      │  ├─ Env:
      │  │  ├─ BYTEBASE_POSTGRES_URL=postgres://pgadmin:${var.postgres_password}@pg-node-1:5432/postgres?sslmode=disable
      │  │  └─ (bytebase specific configs)
      │  ├─ Restart: unless-stopped
      │  └─ Health Check: /healthz endpoint
      │
      ├─ Startup:
      │  1. Pull image from docker hub
      │  2. Start bytebase process
      │  3. Initialize database (first run)
      │  4. Connect to pg-node-1 for management
      │  5. Web UI available on localhost:9090
      │
      └─ Status:
         ├─ Role: Database Management UI
         ├─ Connection: pg-node-1:5432
         └─ Accessible: http://localhost:9090


3. FILE: outputs-ha.tf
   ───────────────────
   
   output "pg_node_1_name"
   └─ Value: docker_container.pg_node_1.name
   
   output "pg_node_2_name"
   └─ Value: docker_container.pg_node_2.name
   
   output "pg_node_3_name"
   └─ Value: docker_container.pg_node_3.name
   
   output "pg_primary_endpoint"
   ├─ Value: "postgresql://pgadmin:PASSWORD@localhost:5432/postgres"
   ├─ Sensitive: true (hides password in output)
   └─ Description: Primary connection string
   
   output "pg_replica_1_endpoint"
   ├─ Value: "postgresql://pgadmin:PASSWORD@localhost:5433/postgres"
   └─ Description: Replica read-only endpoint
   
   output "pg_replica_2_endpoint"
   ├─ Value: "postgresql://pgadmin:PASSWORD@localhost:5434/postgres"
   └─ Description: Replica read-only endpoint
   
   output "dbhub_url"
   ├─ Value: "http://localhost:${var.dbhub_port}"
   └─ Description: Bytebase web interface
   
   output "ha_network"
   ├─ Value: docker_network.pg_ha_network.name
   └─ Description: Network name
   
   output "cluster_info"
   ├─ Value: {
   │  cluster_name: "pg-ha-cluster"
   │  dcs_type: "etcd3"
   │  total_nodes: 3
   │  replication_type: "streaming"
   │  pgvector_version: "0.8.1"
   │  postgres_version: "18"
   │ }
   └─ Description: Cluster metadata
   
   [More outputs...]


4. EXECUTION: terraform apply
   ───────────────────────────
   
   Phase 1: Read State
   └─ Load: terraform.tfstate (if exists)
   
   Phase 2: Validate Provider
   ├─ Check: Docker provider available
   ├─ Verify: Docker daemon running (unix socket)
   └─ Test: Can reach Docker API
   
   Phase 3: Create Resources (Graph Order!)
   ├─ Parallel (no dependencies):
   │  ├─ docker_network.pg_ha_network
   │  ├─ docker_volume.pg_node_*_data (all 3)
   │  ├─ docker_volume.etcd_data
   │  ├─ docker_volume.pgbackrest_repo
   │  ├─ docker_image.postgres_patroni (compile!)
   │  ├─ docker_image.etcd (pull)
   │  └─ docker_image.dbhub (pull)
   │
   ├─ Sequential (dependency chain):
   │  ├─ docker_container.etcd
   │  │  └─ Waits for: ready to accept connections
   │  ├─ docker_container.pg_node_1
   │  │  └─ Waits for: PostgreSQL initialized (30-45s)
   │  ├─ docker_container.pg_node_2
   │  │  └─ Waits for: pg_node_1 ready (30s)
   │  ├─ docker_container.pg_node_3
   │  │  └─ Waits for: pg_node_2 ready (30s)
   │  └─ docker_container.dbhub
   │     └─ Waits for: all 3 PostgreSQL nodes ready
   │
   └─ Total Time: 2-3 minutes
   
   Phase 4: Calculate Output Values
   ├─ Get container IDs from Docker API
   ├─ Get network IPs from Docker API
   ├─ Construct connection strings
   └─ Format outputs
   
   Phase 5: Write State & Display Outputs
   ├─ Save: terraform.tfstate
   ├─ Display all outputs:
   │  ├─ pg_primary_endpoint
   │  ├─ pg_replica_1_endpoint
   │  ├─ pg_replica_2_endpoint
   │  ├─ dbhub_url
   │  └─ cluster_info
   └─ Success message: "Apply complete!"
```

---

## File Dependencies Graph

```
FILES AND THEIR DEPENDENCIES:
═════════════════════════════

variables-ha.tf
  ├─ Defines all input variables
  ├─ No dependencies on other .tf files
  └─ Used by: main-ha.tf (var.* references)

main-ha.tf
  ├─ Depends on: variables-ha.tf (for var.*)
  ├─ Reads: Dockerfile.patroni (build context)
  ├─ Reads: patroni/patroni-node-*.yml (config mounts)
  ├─ Reads: entrypoint-patroni.sh (entrypoint script)
  └─ Creates: All Docker resources

outputs-ha.tf
  ├─ Depends on: main-ha.tf outputs
  ├─ References: docker_container.* resources
  ├─ References: docker_network.* resources
  └─ Displayed after terraform apply

Dockerfile.patroni
  ├─ FROM: pgvector/pgvector:0.8.1-pg18-trixie
  ├─ Installs: patroni, pgbackrest, python3
  └─ Built by: main-ha.tf (docker_image.postgres_patroni)

entrypoint-patroni.sh
  ├─ Called by: docker_container.pg_node_* (entrypoint)
  ├─ Creates: directories, files, permissions
  ├─ Calls: patroni binary with config
  └─ Responsible for: initial setup before Patroni starts

patroni/patroni-node-1.yml
patroni/patroni-node-2.yml
patroni/patroni-node-3.yml
  ├─ Mounted by: main-ha.tf in docker_container.pg_node_* volumes
  ├─ Read by: Patroni daemon at startup
  ├─ Contains: cluster configuration, roles, replications settings
  └─ Unique to each node (cluster_name same, PATRONI_NAME different)

pgbackrest/pgbackrest.conf
  ├─ Not currently used by containers
  ├─ Optional: for pgbackrest backup/restore configuration
  └─ Useful for: production backup setup

init-pgvector-ha.sql
  ├─ Optional initialization script
  ├─ Not auto-executed by main-ha.tf
  ├─ Usage: manual exec after deployment
  └─ Contains: vector table creation, sample data, indexes

terraform.tfstate & terraform.tfstate.backup
  ├─ Generated by: terraform apply
  ├─ Contains: all resource state
  ├─ Git ignored: yes (.gitignore)
  └─ Security: should never be committed
```

---

## Quick Reference: Typical Operations

### Health Check Commands

```bash
# Check all containers running
docker ps | grep -E "pg-node|etcd|dbhub"

# Check cluster status
docker exec pg-node-1 patronictl list

# Check replication status
docker exec pg-node-1 psql -U postgres -c \
  "SELECT * FROM pg_stat_replication;"

# Check etcd
docker exec etcd etcdctl endpoint health

# Access DBHub
open http://localhost:9090

# Check logs
docker logs pg-node-1
docker logs pg-node-2
docker logs etcd
```

### Failover Testing

```bash
# Monitor in one terminal
watch -n 1 'docker exec pg-node-1 patronictl list'

# Simulate primary failure in another
docker stop pg-node-1

# Observe promotion (30-50 seconds)
# Then restart
docker start pg-node-1
```

---

## Additional Resources

- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [etcd Documentation](https://etcd.io/docs/)
- [SCRAM-SHA-256 RFC 5802](https://tools.ietf.org/html/rfc5802)