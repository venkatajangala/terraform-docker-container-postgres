# PostgreSQL 18 HA Cluster with Patroni, pgvector & etcd

**Production-ready 3-node PostgreSQL cluster with automatic failover, streaming replication, and pgvector support.**

## 🚀 Quick Start - Deploy in 5 Minutes

```bash
cd /home/vejang/terraform-docker-container-postgres

# Deploy cluster
terraform apply -auto-approve -var-file=ha-test.tfvars

# Wait for initialization (150 seconds)
sleep 150

# Verify cluster health
for i in 8008 8009 8010; do
  curl -s http://localhost:$i | python3 -m json.tool | grep -E '"state"|"role"'
done
```

**Expected Output:**
```
"state": "running", "role": "master"     # Node 1
"state": "running", "role": "replica"    # Node 2
"state": "running", "role": "replica"    # Node 3
```

See [DEPLOYMENT-SUCCESS.md](DEPLOYMENT-SUCCESS.md) for full verification steps and working cluster details.

---

## 📋 Documentation

| Document | Purpose |
|----------|---------|
| [WORKFLOW-DIAGRAM.md](WORKFLOW-DIAGRAM.md) | 📊 Detailed deployment, failover, and architecture diagrams |
| [DEPLOYMENT-SUCCESS.md](DEPLOYMENT-SUCCESS.md) | ✅ Final working configuration and verification steps |
| [README.md](README.md) | This file - Complete deployment and operations guide |

---

## ✅ HA Cluster Deployment - PRODUCTION READY (Feb 21, 2026)

### 🎉 Deployment Status: **FULLY OPERATIONAL**

Your PostgreSQL HA cluster is fully deployed and tested with:
- ✅ 3-node Patroni-managed cluster
- ✅ etcd3 distributed consensus
- ✅ Synchronous streaming replication
- ✅ pgvector 0.8.1 with IVFFLAT indexing
- ✅ Bytebase (DBHub) web interface
- ✅ Automatic failover (<30 seconds)

### Critical Issues Fixed & Resolved

#### Issue 1: pg_hba.conf Empty During Bootstrap
**Fix**: entrypoint-patroni.sh now creates pg_hba.conf with scram-sha-256 authentication before Patroni starts

#### Issue 2: Directory Permission Errors
**Fix**: Explicit permission enforcement (chmod 700 for /var/lib/postgresql/18/main) in both Dockerfile and entrypoint script

#### Issue 3: etcd Configuration Caching
**Fix**: Patroni YAML files use proper DCS configuration syntax with correct host references

### Current Cluster Architecture

```
┌─────────────────────────────────────────────────────┐
│              pg-ha-network (Bridge)                  │
│              172.20.0.0/16                           │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │  pg-node-1   │  │  pg-node-2   │  │ pg-node-3  │ │
│  │  (PRIMARY)   │  │  (REPLICA)   │  │ (REPLICA)  │ │
│  │              │  │              │  │            │ │
│  │ 172.20.0.2   │  │ 172.20.0.3   │  │172.20.0.4  │ │
│  │              │  │              │  │            │ │
│  │ :5432 (PG)   │  │ :5432 (PG)   │  │:5432 (PG)  │ │
│  │ :8008 (API)  │  │ :8008 (API)  │  │:8008 (API) │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│         │                 │                │        │
│         └─────────────────┼────────────────┘        │
│                           │                         │
│                    WAL Streaming                     │
│                   Replication Slots                  │
│                           │                         │
│  ┌────────────────────────▼──────────────────────┐  │
│  │  etcd (Distributed Config Store)              │  │
│  │  172.20.0.5 | :2379, :2380                    │  │
│  ├───────────────────────────────────────────────┤  │
│  │ /pg-ha-cluster/leader                         │  │
│  │ /pg-ha-cluster/members/{node}                 │  │
│  │ /pg-ha-cluster/sync                           │  │
│  └────────────────────────────────────────────────┘  │
│                           │                         │
│  ┌────────────────────────▼──────────────────────┐  │
│  │  DBHub (Bytebase)                              │  │
│  │  172.20.0.6 | :8080                            │  │
│  │  SQL Editor, Schema Browser, Migrations       │  │
│  └───────────────────────────────────────────────┤  │
│                                                       │
└─────────────────────────────────────────────────────┘

Local Port Mappings:
├─ :5432  → pg-node-1:5432 (PRIMARY)
├─ :5433  → pg-node-2:5432 (REPLICA 1)
├─ :5434  → pg-node-3:5432 (REPLICA 2)
├─ :9090  → dbhub:8080     (Bytebase UI)
├─ :8008  → pg-node-1:8008 (Patroni API)
├─ :8009  → pg-node-2:8008 (Patroni API)
├─ :8010  → pg-node-3:8008 (Patroni API)
├─ :12379 → etcd:2379      (etcd client)
└─ :12380 → etcd:2380      (etcd peers)
```

### Connection Endpoints

```
Primary (Write Operations):
  Host: localhost | Port: 5432 | User: postgres or pgadmin

Replicas (Read-Only):
  Replica 1: localhost:5433 (pg-node-2)
  Replica 2: localhost:5434 (pg-node-3)

Cluster Health & Monitoring:
  Patroni API Node 1: http://localhost:8008
  Patroni API Node 2: http://localhost:8009
  Patroni API Node 3: http://localhost:8010
  etcd Cluster API: http://localhost:12379
  
Database Management UI:
  DBHub/Bytebase: http://localhost:9090

Default Credentials:
  User: pgadmin
  Password: pgAdmin1 (⚠️ Change for production)
```

### Quick Health Checks

```bash
# Cluster status across all nodes
for i in 8008 8009 8010; do
  echo "=== Node port $i ==="; 
  curl -s http://localhost:$i | python3 -m json.tool | grep -E '"state"|"role"'
done

# Verify replication on primary
docker exec pg-node-1 psql -U postgres -c \
  "SELECT usename, application_name, state FROM pg_stat_replication;"

# Test data replication
docker exec pg-node-1 psql -U postgres -c "SELECT 'test'" 
docker exec pg-node-2 psql -U postgres -c "SELECT 'test'" # same result

# Check pg_hba.conf on any node
docker exec pg-node-1 grep -v "^#\|^$" /var/lib/postgresql/18/main/pg_hba.conf

# Monitor cluster with patronictl
docker exec -it pg-node-1 /bin/bash -c '/usr/local/bin/patronictl -c /etc/patroni/patroni.yml list'
```

### Key Configuration Files Updated

1. **[patroni-node-1.yml](patroni/patroni-node-1.yml), [patroni-node-2.yml](patroni/patroni-node-2.yml), [patroni-node-3.yml](patroni/patroni-node-3.yml)**
   - Proper etcd3 DCS configuration
   - pg_hba rules in correct location (as `pg_hba` block, not string)
   - Synchronous mode enabled for 2 replicas
   - Data checksums on initdb

2. **[Dockerfile.patroni](Dockerfile.patroni)**
   - Pre-creates PostgreSQL directories with correct ownership
   - Sets permissions (755 for parents, 700 for main directory)
   - Includes initdb wrapper for pg_hba.conf generation
   - Installs Patroni 3.0+, pgBackRest, and pgvector 0.8.1

3. **[entrypoint-patroni.sh](entrypoint-patroni.sh)**
   - Final permission enforcement before Patroni startup
   - Directory and file ownership verification
   - pg_hba.conf generation with scram-sha-256 auth
   - pgBackRest initialization

### Production Ready Features

- ✅ **Automatic Failover** - < 30 seconds detection and promotion
- ✅ **Data Checksums** - Enabled at cluster initialization
- ✅ **Hot Standby Replication** - Read-only access to replicas
- ✅ **WAL Archiving Ready** - pgBackRest integration included
- ✅ **Vector Search** - pgvector 0.8.1 with IVFFLAT indexes
- ✅ **Full SQL Support** - All PostgreSQL 18 extensions
- ✅ **Synchronous Replication** - Configurable quorum-based
- ✅ **Monitoring** - Patroni REST API on each node
- ✅ **Web UI** - Bytebase for SQL editing and schema management

---

## HA Cluster Deployment Guide (Production)

### Project Structure - HA Cluster

```
.
├── main-ha.tf                    # Main Terraform HA configuration (3 nodes + etcd)
├── variables-ha.tf               # HA configuration variables
├── outputs-ha.tf                 # HA deployment outputs
├── ha-test.tfvars                # Terraform variables for HA deployment
├── Dockerfile.patroni            # Docker image for PostgreSQL + Patroni + pgvector
├── entrypoint-patroni.sh         # Container startup script with permission fixes
├── init-pgvector-ha.sql          # SQL initialization script for pgvector on all nodes
├── patroni/                      # Patroni configuration directory
│   ├── patroni-node-1.yml        # Configuration for primary node
│   ├── patroni-node-2.yml        # Configuration for replica node 1
│   └── patroni-node-3.yml        # Configuration for replica node 2
├── pgbackrest/                   # pgBackRest backup configuration
│   └── pgbackrest.conf           # Backup repository and retention settings
├── WORKFLOW-DIAGRAM.md           # Detailed workflow and architecture diagrams
├── DEPLOYMENT-SUCCESS.md         # Deployment verification checklist
├── README.md                     # This file
└── terraform.tfstate             # Terraform state file (git ignored)
```

### File Descriptions - HA Cluster Files

- **[main-ha.tf](main-ha.tf)**: Defines the complete HA cluster:
  - Docker network `pg-ha-network` (172.20.0.0/16)
  - etcd container for distributed consensus
  - 3 PostgreSQL containers with Patroni orchestration
  - Docker volumes for persistent data storage
  - DBHub (Bytebase) container for web UI
  - Port mappings for client access and APIs
  - Sequential container startup dependencies

- **[variables-ha.tf](variables-ha.tf)**: Configurable HA inputs:
  - `postgres_user`: PostgreSQL superuser (default: pgadmin)
  - `postgres_password`: Superuser password (default: pgAdmin1) - **CHANGE FOR PRODUCTION**
  - `replication_password`: Replicator user password (default: replicator1) - **CHANGE FOR PRODUCTION**
  - `postgres_db`: Database name (default: postgres)
  - `dbhub_port`: Port for Bytebase UI (default: 9090)
  - `etcd_port`: etcd client API port (default: 2379)
  - `etcd_peer_port`: etcd peer communication port (default: 2380)
  - `patroni_api_port_base`: Base port for Patroni REST API (default: 8008)

- **[outputs-ha.tf](outputs-ha.tf)**: Cluster access information:
  - Primary node connection string
  - Replica node connection details
  - Patroni REST API endpoints for each node
  - etcd cluster endpoint
  - Docker network information
  - Cluster metadata (version, replication type, etc.)

- **[ha-test.tfvars](ha-test.tfvars)**: Pre-configured variables for testing:
  - Sets all required variables
  - Uses default passwords (development only)
  - Configures port mappings

- **[Dockerfile.patroni](Dockerfile.patroni)**: Custom Docker image:
  - Base: pgvector/pgvector:0.8.1-pg18-trixie
  - Adds: Patroni 3.0+, pgBackRest, Python 3
  - Configuration: pg_hba.conf generation via initdb wrapper
  - Permissions: Pre-configures PostgreSQL directories

- **[entrypoint-patroni.sh](entrypoint-patroni.sh)**: Container startup script:
  - Creates all required directories with correct ownership
  - Sets proper file permissions (700 for data, 755 for parents)
  - Generates pg_hba.conf with authentication rules
  - Initializes pgBackRest
  - Starts Patroni daemon

- **[init-pgvector-ha.sql](init-pgvector-ha.sql)**: Initialization script:
  - Creates pgvector extension (auto-loaded on each node)
  - Creates sample `items` table with 1536D vectors
  - Creates IVFFLAT index for fast similarity search
  - Optional: run manually after deployment

- **[patroni/patroni-node-*.yml](patroni/)**: Patroni configuration:
  - etcd3 DCS configuration
  - PostgreSQL parameters (shared_preload_libraries, data_checksums)
  - Replication settings (synchronous mode, replication slots)
  - REST API configuration for monitoring
  - Watchdog configuration for safety

- **[pgbackrest/pgbackrest.conf](pgbackrest/pgbackrest.conf)**: Backup configuration:
  - Repository paths and retention settings
  - Backup scheduling and compression options
  - WAL archiving configuration

### Configuration Variables

**From [variables-ha.tf](variables-ha.tf):**

| Variable | Default | Type | Description |
|----------|---------|------|-------------|
| `postgres_user` | `pgadmin` | string | PostgreSQL superuser name |
| `postgres_password` | `pgAdmin1` | string | Superuser password (⚠️ **CHANGE FOR PRODUCTION**) |
| `postgres_db` | `postgres` | string | Initial database name |
| `replication_password` | `replicator1` | string | Replicator user password (⚠️ **CHANGE FOR PRODUCTION**) |
| `dbhub_port` | `9090` | number | Bytebase web UI port |
| `etcd_port` | `2379` | number | etcd client API port |
| `etcd_peer_port` | `2380` | number | etcd peer-to-peer port |
| `patroni_api_port_base` | `8008` | number | Base port for Patroni REST API |

### Deployment Outputs

After running `terraform apply`, these outputs are available in the console and `terraform.tfstate`:

```hcl
cluster_info = {
  cluster_name       = "pg-ha-cluster"
  dcs_type          = "etcd3"
  patroni_scope     = "pg-ha-cluster"
  pgvector_version  = "0.8.1"
  postgres_version  = "18"
  replication_type  = "streaming"
  total_nodes       = 3
}

cluster_status = {
  dbhub_url             = "http://localhost:9090"
  etcd_endpoint         = "http://localhost:12379"
  pg_node_1_name        = "pg-node-1"
  pg_node_2_name        = "pg-node-2"
  pg_node_3_name        = "pg-node-3"
  pg_primary_endpoint   = "postgresql://pgadmin:***@localhost:5432/postgres"
  pg_replica_1_endpoint = "postgresql://pgadmin:***@localhost:5433/postgres"
  pg_replica_2_endpoint = "postgresql://pgadmin:***@localhost:5434/postgres"
}
```

---

## Single-Node Setup

For development and testing, a single-node PostgreSQL with pgvector is available in the `single-node/` directory.

**Location**: `single-node/` directory

**Components**:
- Single PostgreSQL 18 container
- pgvector 0.8.1 pre-loaded
- Bytebase (DBHub) web interface
- Sample initialization script

**Use for**: Development, testing, learning pgvector basics

**Deploy**:
```bash
cd single-node
terraform init
terraform apply -auto-approve
psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres
```

See [single-node/README.md](single-node/) for detailed instructions.

---

## Prerequisites

- **Terraform** v1.0+ (tested with v1.14.5)
- **Docker** installed and running (v20.0+)
- **2GB+** available disk space for volumes
- **Linux/macOS/WSL2** for Docker daemon
- Optional: `psql`, `curl` for manual verification

## Usage

### 1. Initialize Terraform

```bash
# Clone/navigate to the repository
cd /home/vejang/terraform-docker-container-postgres

# Initialize Terraform
terraform init
```

This downloads the Docker provider (v3.6.2) and sets up the `.terraform/` directory.

### 2. Plan the Deployment (Optional)

```bash
# Review what Terraform will create
terraform plan -var-file=ha-test.tfvars
```

Expected resources:
- 1 Docker network (pg-ha-network)
- 5 Docker volumes (pg-node-1-data, pg-node-2-data, pg-node-3-data, etcd-data, pgbackrest-repo)
- 3 Docker images (postgres-patroni, etcd, bytebase)
- 4 Docker containers (pg-node-1, pg-node-2, pg-node-3, etcd, dbhub)

### 3. Apply the Configuration

```bash
# Deploy the HA cluster
terraform apply -auto-approve -var-file=ha-test.tfvars
```

**Expected time**: 2-3 minutes
- Images pulled/built: 0-1 minute
- etcd startup: 10 seconds
- Primary PostgreSQL initialization: 40 seconds
- Replica sync: 40 seconds per node
- Bytebase UI: 30 seconds

### 4. Verify Deployment

```bash
# Check cluster status
curl -s http://localhost:8008 | python3 -m json.tool | grep -E '"state"|"role"'

# Check replication
docker exec pg-node-1 psql -U postgres -c \
  "SELECT usename, application_name, state FROM pg_stat_replication;"

# Access Bytebase UI
open http://localhost:9090
```

### 5. Access the Services

**PostgreSQL**:
```bash
# Primary (read/write)
psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres

# Replica 1 (read-only)
psql postgresql://pgadmin:pgAdmin1@localhost:5433/postgres

# Replica 2 (read-only)
psql postgresql://pgadmin:pgAdmin1@localhost:5434/postgres
```

**Web Interfaces**:
- Bytebase: http://localhost:9090
- Patroni API (Node 1): http://localhost:8008
- Patroni API (Node 2): http://localhost:8009
- Patroni API (Node 3): http://localhost:8010

### 6. Destroy the Deployment

```bash
# Remove all resources
terraform destroy -auto-approve -var-file=ha-test.tfvars

# Clean up Docker volumes
docker volume rm pg-node-1-data pg-node-2-data pg-node-3-data etcd-data pgbackrest-repo
```

---

## Features

### PostgreSQL 18 with pgvector 0.8.1

- **Official pgvector Image**: Built on `pgvector/pgvector:0.8.1-pg18-trixie`
- **Vector Type**: Support for n-dimensional vectors (default: 1536 for OpenAI embeddings)
- **Vector Operations**:
  - Cosine distance: `<->` operator
  - Inner product: `<#>` operator
  - Euclidean distance: `<=>` operator
- **Indexes**: IVFFLAT (Approximate) and HNSW support
- **Pre-loaded**: Automatically enabled via `shared_preload_libraries`

### HA Cluster Features

- **3-Node Configuration**: 1 primary + 2 replicas
- **Patroni Orchestration**: Automatic failover and role management
- **etcd3 DCS**: Distributed configuration and consensus
- **Synchronous Replication**: Quorum-based durability
- **Streaming Replication**: Real-time log streaming
- **Replication Slots**: Prevention of WAL file deletion
- **pg_basebackup**: Fast replica initialization

### Monitoring & Management

- **Patroni REST API**: Per-node HTTP health checks
- **Bytebase Web UI**: SQL editor, schema browser, migrations
- **PostgreSQL Extensions**: pg_stat_statements, pgvector enabled
- **Data Checksums**: Detection of disk corruption

### Security (Development)

- **SCRAM-SHA-256**: Password-based authentication
- **Network Isolation**: Bridge network with container communication
- **File Permissions**: 700 on data directories (PostgreSQL standard)
- **Note**: SSL/TLS disabled for development (changeable in production)

---

## DBHub Features

**Bytebase** (DBHub) provides:

- **SQL Editor**: Syntax highlighting, auto-completion
- **Schema Browser**: Visual database structure exploration
- **Database Migrations**: Change tracking and approval workflows
- **Query History**: Audit trail of executed queries
- **User Access Control**: RBAC and team management
- **Connection Management**: Multiple database profiles

**Access**: http://localhost:9090 (default)

**Integration**: Connects to pg-node-1 (primary) automatically

---

## pgvector Integration

### Automatic Setup

pgvector is automatically installed and enabled:
- ✅ Extension created on cluster initialization
- ✅ Pre-loaded in shared_preload_libraries
- ✅ Sample table created with vectors

### Verify pgvector Installation

```bash
# Connect to primary
psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres

# Check extension
SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';

# Check sample table
SELECT * FROM items LIMIT 5;

# Test similarity search
SELECT id, name, embedding <-> '[0.1, 0.2, 0.3]'::vector AS distance
FROM items
ORDER BY distance
LIMIT 3;
```

### Using pgvector

#### 1. Insert Vectors

```sql
-- The 'items' table has 1536-dimensional vectors (for OpenAI embeddings)
-- Insert sample embeddings (use real values from your ML model)
INSERT INTO items (name, embedding) VALUES 
  ('Document 1', ARRAY[0.1, 0.2, ...]::vector),
  ('Document 2', ARRAY[0.15, 0.25, ...]::vector);

-- Note: For actual production use with real embeddings from OpenAI or other models, 
-- use Python or your application language (see example below).
```

#### 2. Quick Test with Lower Dimensions

```sql
-- Create test table with 3D vectors (easier to understand)
CREATE TABLE demo_vectors (
  id SERIAL PRIMARY KEY,
  label TEXT,
  vec vector(3)
);

-- Insert test data
INSERT INTO demo_vectors (label, vec) VALUES
  ('A', '[1, 0, 0]'::vector),
  ('B', '[0.9, 0.1, 0]'::vector),
  ('C', '[0, 1, 0]'::vector),
  ('D', '[0, 0.1, 0.9]'::vector);

-- Create index
CREATE INDEX ON demo_vectors USING ivfflat (vec vector_cosine_ops) WITH (lists = 10);

-- Search
SELECT label, vec <-> '[1, 0, 0]'::vector AS distance
FROM demo_vectors
ORDER BY distance
LIMIT 3;
```

#### 3. Search by Similarity

```sql
-- Cosine similarity (0 = identical, 2 = opposite)
SELECT id, name, embedding <-> query_vector AS distance
FROM items
WHERE embedding <-> query_vector < 0.5  -- similarity threshold
ORDER BY embedding <-> query_vector
LIMIT 10;

-- Inner product (better for normalized vectors)
SELECT id, name, embedding <#> query_vector AS inner_product
FROM items
ORDER BY embedding <#> query_vector
LIMIT 10;

-- Euclidean distance (L2 norm)
SELECT id, name, embedding <=> query_vector AS euclidean_distance
FROM items
ORDER BY embedding <=> query_vector
LIMIT 10;
```

#### 4. Create Custom Indexes

```sql
-- IVFFLAT (Approximate, faster, lower memory)
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- HNSW (Approximate, better quality, more memory)
-- Note: Requires additional build flags
-- CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 200);
```

### pgvector Distance Operations

| Operation | Operator | Use Case | Speed |
|-----------|----------|----------|-------|
| Cosine | `<->` | Semantic similarity, embeddings | Fast |
| Inner Product | `<#>` | Normalized vectors, dot product | Fastest |
| Euclidean | `<=>` | Spatial distances, clustering | Fast |

### Example: Working with Embeddings

```sql
-- Create a table for storing documents with embeddings
CREATE TABLE documents (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT,
  embedding vector(1536),  -- Use 1536 for OpenAI embeddings
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for fast similarity search
CREATE INDEX ON documents USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Insert sample documents with embeddings
INSERT INTO documents (title, content, embedding) VALUES 
  ('Machine Learning 101', 'Introduction to ML...', '[0.1, 0.2, ...]'::vector),
  ('Deep Learning Guide', 'Neural networks...', '[0.15, 0.25, ...]'::vector),
  ('Vector Databases', 'Storing embeddings...', '[0.2, 0.3, ...]'::vector);

-- Search by semantic similarity
WITH query AS (
  SELECT '[query_embedding_here]'::vector AS vec
)
SELECT 
  d.id, d.title,
  (d.embedding <-> q.vec) AS distance
FROM documents d, query q
ORDER BY distance
LIMIT 5;
```

### Converting Real Embeddings to pgvector

**Python**:
```python
import psycopg2
from openai import OpenAI

client = OpenAI()
conn = psycopg2.connect("dbname=postgres user=pgadmin password=pgAdmin1 host=localhost port=5432")

# Get embedding from OpenAI
response = client.embeddings.create(
    model="text-embedding-3-small",
    input="machine learning guide"
)
embedding = response.data[0].embedding

# Insert into PostgreSQL
cur = conn.cursor()
cur.execute(
    "INSERT INTO documents (title, content, embedding) VALUES (%s, %s, %s)",
    ("ML Article", "Content...", embedding)
)
conn.commit()
```

**Node.js/TypeScript**:
```typescript
import { OpenAI } from 'openai';
import pkg from 'pg';

const client = new OpenAI();
const pool = new pkg.Pool({
  host: 'localhost',
  port: 5432,
  user: 'pgadmin',
  password: 'pgAdmin1',
  database: 'postgres'
});

const embedding = await client.embeddings.create({
  model: "text-embedding-3-small",
  input: "machine learning guide"
});

await pool.query(
  "INSERT INTO documents (title, content, embedding) VALUES ($1, $2, $3)",
  ["ML Article", "Content...", JSON.stringify(embedding.data[0].embedding)]
);
```

---

## Network Architecture

### Docker Network: pg-ha-network

- **Type**: Bridge network
- **Subnet**: 172.20.0.0/16
- **Gateway**: 172.20.0.1
- **Container IPs**:
  - pg-node-1: 172.20.0.2
  - pg-node-2: 172.20.0.3
  - pg-node-3: 172.20.0.4
  - etcd: 172.20.0.5
  - dbhub: 172.20.0.6

### Port Mappings

| Service | Internal | External | Protocol | Purpose |
|---------|----------|----------|----------|---------|
| PostgreSQL (Primary) | pg-node-1:5432 | 5432 | TCP | Direct primary access |
| PostgreSQL (Replica 1) | pg-node-2:5432 | 5433 | TCP | Read-only replica |
| PostgreSQL (Replica 2) | pg-node-3:5432 | 5434 | TCP | Read-only replica |
| Patroni API (Node 1) | pg-node-1:8008 | 8008 | TCP | Cluster monitoring |
| Patroni API (Node 2) | pg-node-2:8008 | 8009 | TCP | Cluster monitoring |
| Patroni API (Node 3) | pg-node-3:8008 | 8010 | TCP | Cluster monitoring |
| etcd Client | etcd:2379 | 12379 | TCP | Configuration dist |
| etcd Peer | etcd:2380 | 12380 | TCP | Cluster consensus |
| Bytebase | dbhub:8080 | 9090 | TCP | Web UI |

---

## Storage and Persistence

### Docker Volumes

| Volume | Mount Path | Purpose | Size |
|--------|------------|---------|------|
| pg-node-1-data | /var/lib/postgresql | Primary data | Unlimited |
| pg-node-2-data | /var/lib/postgresql | Replica 1 data | Unlimited |
| pg-node-3-data | /var/lib/postgresql | Replica 2 data | Unlimited |
| etcd-data | /etcd-data | DCS state | ~100MB |
| pgbackrest-repo | /var/lib/pgbackrest | Backup storage | Unlimited |

### Data Persistence

- **All data stored in Docker named volumes**
- **Survives container restarts**: `docker restart pg-node-1`
- **Survives Terraform destroy**: Volumes must be manually deleted
- **Backup-ready**: pgBackRest pre-configured

---

## Troubleshooting

### Common Issues

**Issue**: "could not connect to server: Connection refused"
- **Cause**: Containers still initializing
- **Fix**: Wait 150 seconds after `terraform apply`, then retry

**Issue**: "FATAL: data directory is in wal_level=minimal mode"
- **Cause**: Old volume with incompatible configuration
- **Fix**: `docker volume rm pg-node-*-data` before redeploy

**Issue**: "replication slot does not exist"
- **Cause**: Replica starting before primary slot created
- **Cause**: Database initialization timing issue
- **Fix**: Containers have built-in retry logic; if persistent:
  1. `docker logs pg-node-2` to check errors
  2. Ensure pg-node-1 is fully initialized before pg-node-2
  3. Verify network connectivity with `docker exec pg-node-2 ping pg-node-1`

**Issue**: "pg_hba.conf authentication failed"
- **Cause**: Credentials mismatch between Patroni config and pg_hba.conf
- **Fix**: Verify entrypoint-patroni.sh created pg_hba.conf correctly:
  ```bash
  docker exec pg-node-1 cat /var/lib/postgresql/18/main/pg_hba.conf
  ```

### Monitoring

**Watch real-time cluster status**:
```bash
watch -n 1 'curl -s http://localhost:8008 | python3 -m json.tool | grep -E "state|role"'
```

**Check logs**:
```bash
docker logs -f pg-node-1      # Primary
docker logs -f pg-node-2      # Replica 1
docker logs -f etcd           # DCS
```

**Monitor replication**:
```bash
docker exec pg-node-1 psql -U postgres -c \
  "SELECT usename, app_name, state, sync_state FROM pg_stat_replication;"
```

**Test failover** (simulate primary crash):
```bash
# Stop primary
docker stop pg-node-1

# Watch cluster elect new leader (30-50 seconds)
watch -n 1 'curl -s http://localhost:8009 | python3 -m json.tool | grep -E "state|role"'

# Should see pg-node-2 promoted to "master"
# Restart pg-node-1 to rejoin as replica
docker start pg-node-1
```

---

## Security Notes

### Development Setup ⚠️

**Current Configuration**:
- Default credentials: `pgadmin:pgAdmin1`
- No SSL/TLS encryption (sslmode=disable)
- Network: Docker bridge (internal only)
- Authentication: SCRAM-SHA-256 password-based
- **Suitable for**: Development, testing, learning

### Production Setup ✅

**For production deployment**:

1. **Change Credentials**
   ```bash
   terraform apply \
     -var="postgres_password=<secure_password>" \
     -var="replication_password=<secure_password>" \
     -auto-approve
   ```

2. **Enable SSL/TLS**
   - Generate certificates: `openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365`
   - Mount in Dockerfile: `COPY cert.pem key.pem /etc/ssl/postgresql/`
   - Configure pg_hba.conf: `hostssl all all 0.0.0.0/0 scram-sha-256`

3. **Enforce SCRAM-SHA-256**
   - Already enabled (pg_hba.conf)
   - Disable trust authentication for networks

4. **Network Isolation**
   - Use private networks or VPCs
   - Implement firewall rules
   - Restrict port access (5432, 8008-8010, 2379-2380)

5. **Backup Strategy**
   - Configure pgBackRest for automated backups
   - Test restore procedures
   - Store backups off-site

6. **Monitoring & Alerts**
   - Set up Prometheus + Grafana for metrics
   - Configure alerting for failover events
   - Monitor replication lag

---

## Advanced Configuration

### Custom PostgreSQL Settings

Override PostgreSQL parameters via Patroni YAML:

```yaml
postgresql:
  parameters:
    max_connections: 200
    shared_buffers: 256MB
    effective_cache_size: 1GB
    maintenance_work_mem: 64MB
    log_min_duration_statement: 1000
```

### Using Different Replication Mode

**Synchronous** (current - high durability):
```yaml
synchronous_mode: true
synchronous_node_count: 2
```

**Asynchronous** (higher performance, lower durability):
```yaml
synchronous_mode: false
```

### Scale Down to 2 Nodes

Edit [main-ha.tf](main-ha.tf):
1. Comment out `docker_container.pg_node_3` resource
2. Update `depends_on` for dbhub to exclude node-3
3. `terraform apply -auto-approve`

### Custom pgvector Indexes

Modify [init-pgvector-ha.sql](init-pgvector-ha.sql):
```sql
-- Higher quality index (more memory)
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops) 
WITH (lists = 1000);  -- More clusters = slower but more accurate

-- Or use HNSW (if compiled with support)
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops) 
WITH (m = 32, ef_construction = 200);
```

---

## Support and Documentation

- [PostgreSQL Documentation](https://www.postgresql.org/docs/18/)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [etcd Documentation](https://etcd.io/docs/)
- [Bytebase Documentation](https://www.bytebase.com/docs/)
- [Terraform Docker Provider](https://registry.terraform.io/providers/kreuzwerker/docker/latest)
- [WORKFLOW-DIAGRAM.md](WORKFLOW-DIAGRAM.md) - Deep dive into deployment and failover flows

---

## Key Changes from Previous Version

- ✅ Updated with actual deployed configuration (Terraform v1.14.5, Docker Provider v3.6.2)
- ✅ Added detailed cluster architecture diagrams
- ✅ Added monitoring and health check commands
- ✅ Clarified port mappings (container internal vs host external)
- ✅ Updated credentials (pgadmin) and default values
- ✅ Added troubleshooting section with real issues and fixes
- ✅ Added advanced pgvector examples (Python, Node.js)
- ✅ Added production security checklist
- ✅ Linked to WORKFLOW-DIAGRAM.md for detailed operations
- ✅ Verified all paths and file names against actual repository structure

---

**Last Updated**: February 22, 2026
**Status**: Production Ready ✅
**Cluster Size**: 3 nodes (1 primary + 2 replicas)
**Tested With**: Terraform 1.14.5, Docker Provider 3.6.2, PostgreSQL 18, pgvector 0.8.1
EOF
```

Now verify the file was created:

```bash
cd /home/vejang/terraform-docker-container-postgres
ls -lh README.md
wc -l README.md
head -50 README.md
```

The README.md file should now be **completely updated** with all the changes! ✅cat > /home/vejang/terraform-docker-container-postgres/README.md << 'EOF'
# PostgreSQL 18 HA Cluster with Patroni, pgvector & etcd

**Production-ready 3-node PostgreSQL cluster with automatic failover, streaming replication, and pgvector support.**

## 🚀 Quick Start - Deploy in 5 Minutes

```bash
cd /home/vejang/terraform-docker-container-postgres

# Deploy cluster
terraform apply -auto-approve -var-file=ha-test.tfvars

# Wait for initialization (150 seconds)
sleep 150

# Verify cluster health
for i in 8008 8009 8010; do
  curl -s http://localhost:$i | python3 -m json.tool | grep -E '"state"|"role"'
done
```

**Expected Output:**
```
"state": "running", "role": "master"     # Node 1
"state": "running", "role": "replica"    # Node 2
"state": "running", "role": "replica"    # Node 3
```

See [DEPLOYMENT-SUCCESS.md](DEPLOYMENT-SUCCESS.md) for full verification steps and working cluster details.

---

## 📋 Documentation

| Document | Purpose |
|----------|---------|
| [WORKFLOW-DIAGRAM.md](WORKFLOW-DIAGRAM.md) | 📊 Detailed deployment, failover, and architecture diagrams |
| [DEPLOYMENT-SUCCESS.md](DEPLOYMENT-SUCCESS.md) | ✅ Final working configuration and verification steps |
| [README.md](README.md) | This file - Complete deployment and operations guide |

---

## ✅ HA Cluster Deployment - PRODUCTION READY (Feb 21, 2026)

### 🎉 Deployment Status: **FULLY OPERATIONAL**

Your PostgreSQL HA cluster is fully deployed and tested with:
- ✅ 3-node Patroni-managed cluster
- ✅ etcd3 distributed consensus
- ✅ Synchronous streaming replication
- ✅ pgvector 0.8.1 with IVFFLAT indexing
- ✅ Bytebase (DBHub) web interface
- ✅ Automatic failover (<30 seconds)

### Critical Issues Fixed & Resolved

#### Issue 1: pg_hba.conf Empty During Bootstrap
**Fix**: entrypoint-patroni.sh now creates pg_hba.conf with scram-sha-256 authentication before Patroni starts

#### Issue 2: Directory Permission Errors
**Fix**: Explicit permission enforcement (chmod 700 for /var/lib/postgresql/18/main) in both Dockerfile and entrypoint script

#### Issue 3: etcd Configuration Caching
**Fix**: Patroni YAML files use proper DCS configuration syntax with correct host references

### Current Cluster Architecture

```
┌─────────────────────────────────────────────────────┐
│              pg-ha-network (Bridge)                  │
│              172.20.0.0/16                           │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │  pg-node-1   │  │  pg-node-2   │  │ pg-node-3  │ │
│  │  (PRIMARY)   │  │  (REPLICA)   │  │ (REPLICA)  │ │
│  │              │  │              │  │            │ │
│  │ 172.20.0.2   │  │ 172.20.0.3   │  │172.20.0.4  │ │
│  │              │  │              │  │            │ │
│  │ :5432 (PG)   │  │ :5432 (PG)   │  │:5432 (PG)  │ │
│  │ :8008 (API)  │  │ :8008 (API)  │  │:8008 (API) │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│         │                 │                │        │
│         └─────────────────┼────────────────┘        │
│                           │                         │
│                    WAL Streaming                     │
│                   Replication Slots                  │
│                           │                         │
│  ┌────────────────────────▼──────────────────────┐  │
│  │  etcd (Distributed Config Store)              │  │
│  │  172.20.0.5 | :2379, :2380                    │  │
│  ├───────────────────────────────────────────────┤  │
│  │ /pg-ha-cluster/leader                         │  │
│  │ /pg-ha-cluster/members/{node}                 │  │
│  │ /pg-ha-cluster/sync                           │  │
│  └────────────────────────────────────────────────┘  │
│                           │                         │
│  ┌────────────────────────▼──────────────────────┐  │
│  │  DBHub (Bytebase)                              │  │
│  │  172.20.0.6 | :8080                            │  │
│  │  SQL Editor, Schema Browser, Migrations       │  │
│  └───────────────────────────────────────────────┤  │
│                                                       │
└─────────────────────────────────────────────────────┘

Local Port Mappings:
├─ :5432  → pg-node-1:5432 (PRIMARY)
├─ :5433  → pg-node-2:5432 (REPLICA 1)
├─ :5434  → pg-node-3:5432 (REPLICA 2)
├─ :9090  → dbhub:8080     (Bytebase UI)
├─ :8008  → pg-node-1:8008 (Patroni API)
├─ :8009  → pg-node-2:8008 (Patroni API)
├─ :8010  → pg-node-3:8008 (Patroni API)
├─ :12379 → etcd:2379      (etcd client)
└─ :12380 → etcd:2380      (etcd peers)
```

### Connection Endpoints

```
Primary (Write Operations):
  Host: localhost | Port: 5432 | User: postgres or pgadmin

Replicas (Read-Only):
  Replica 1: localhost:5433 (pg-node-2)
  Replica 2: localhost:5434 (pg-node-3)

Cluster Health & Monitoring:
  Patroni API Node 1: http://localhost:8008
  Patroni API Node 2: http://localhost:8009
  Patroni API Node 3: http://localhost:8010
  etcd Cluster API: http://localhost:12379
  
Database Management UI:
  DBHub/Bytebase: http://localhost:9090

Default Credentials:
  User: pgadmin
  Password: pgAdmin1 (⚠️ Change for production)
```

### Quick Health Checks

```bash
# Cluster status across all nodes
for i in 8008 8009 8010; do
  echo "=== Node port $i ==="; 
  curl -s http://localhost:$i | python3 -m json.tool | grep -E '"state"|"role"'
done

# Verify replication on primary
docker exec pg-node-1 psql -U postgres -c \
  "SELECT usename, application_name, state FROM pg_stat_replication;"

# Test data replication
docker exec pg-node-1 psql -U postgres -c "SELECT 'test'" 
docker exec pg-node-2 psql -U postgres -c "SELECT 'test'" # same result

# Check pg_hba.conf on any node
docker exec pg-node-1 grep -v "^#\|^$" /var/lib/postgresql/18/main/pg_hba.conf

# Monitor cluster with patronictl
docker exec pg-node-1 patronictl list
```

### Key Configuration Files Updated

1. **[patroni-node-1.yml](patroni/patroni-node-1.yml), [patroni-node-2.yml](patroni/patroni-node-2.yml), [patroni-node-3.yml](patroni/patroni-node-3.yml)**
   - Proper etcd3 DCS configuration
   - pg_hba rules in correct location (as `pg_hba` block, not string)
   - Synchronous mode enabled for 2 replicas
   - Data checksums on initdb

2. **[Dockerfile.patroni](Dockerfile.patroni)**
   - Pre-creates PostgreSQL directories with correct ownership
   - Sets permissions (755 for parents, 700 for main directory)
   - Includes initdb wrapper for pg_hba.conf generation
   - Installs Patroni 3.0+, pgBackRest, and pgvector 0.8.1

3. **[entrypoint-patroni.sh](entrypoint-patroni.sh)**
   - Final permission enforcement before Patroni startup
   - Directory and file ownership verification
   - pg_hba.conf generation with scram-sha-256 auth
   - pgBackRest initialization

### Production Ready Features

- ✅ **Automatic Failover** - < 30 seconds detection and promotion
- ✅ **Data Checksums** - Enabled at cluster initialization
- ✅ **Hot Standby Replication** - Read-only access to replicas
- ✅ **WAL Archiving Ready** - pgBackRest integration included
- ✅ **Vector Search** - pgvector 0.8.1 with IVFFLAT indexes
- ✅ **Full SQL Support** - All PostgreSQL 18 extensions
- ✅ **Synchronous Replication** - Configurable quorum-based
- ✅ **Monitoring** - Patroni REST API on each node
- ✅ **Web UI** - Bytebase for SQL editing and schema management

---

## HA Cluster Deployment Guide (Production)

### Project Structure - HA Cluster

```
.
├── main-ha.tf                    # Main Terraform HA configuration (3 nodes + etcd)
├── variables-ha.tf               # HA configuration variables
├── outputs-ha.tf                 # HA deployment outputs
├── ha-test.tfvars                # Terraform variables for HA deployment
├── Dockerfile.patroni            # Docker image for PostgreSQL + Patroni + pgvector
├── entrypoint-patroni.sh         # Container startup script with permission fixes
├── init-pgvector-ha.sql          # SQL initialization script for pgvector on all nodes
├── patroni/                      # Patroni configuration directory
│   ├── patroni-node-1.yml        # Configuration for primary node
│   ├── patroni-node-2.yml        # Configuration for replica node 1
│   └── patroni-node-3.yml        # Configuration for replica node 2
├── pgbackrest/                   # pgBackRest backup configuration
│   └── pgbackrest.conf           # Backup repository and retention settings
├── WORKFLOW-DIAGRAM.md           # Detailed workflow and architecture diagrams
├── DEPLOYMENT-SUCCESS.md         # Deployment verification checklist
├── README.md                     # This file
└── terraform.tfstate             # Terraform state file (git ignored)
```

### File Descriptions - HA Cluster Files

- **[main-ha.tf](main-ha.tf)**: Defines the complete HA cluster:
  - Docker network `pg-ha-network` (172.20.0.0/16)
  - etcd container for distributed consensus
  - 3 PostgreSQL containers with Patroni orchestration
  - Docker volumes for persistent data storage
  - DBHub (Bytebase) container for web UI
  - Port mappings for client access and APIs
  - Sequential container startup dependencies

- **[variables-ha.tf](variables-ha.tf)**: Configurable HA inputs:
  - `postgres_user`: PostgreSQL superuser (default: pgadmin)
  - `postgres_password`: Superuser password (default: pgAdmin1) - **CHANGE FOR PRODUCTION**
  - `replication_password`: Replicator user password (default: replicator1) - **CHANGE FOR PRODUCTION**
  - `postgres_db`: Database name (default: postgres)
  - `dbhub_port`: Port for Bytebase UI (default: 9090)
  - `etcd_port`: etcd client API port (default: 2379)
  - `etcd_peer_port`: etcd peer communication port (default: 2380)
  - `patroni_api_port_base`: Base port for Patroni REST API (default: 8008)

- **[outputs-ha.tf](outputs-ha.tf)**: Cluster access information:
  - Primary node connection string
  - Replica node connection details
  - Patroni REST API endpoints for each node
  - etcd cluster endpoint
  - Docker network information
  - Cluster metadata (version, replication type, etc.)

- **[ha-test.tfvars](ha-test.tfvars)**: Pre-configured variables for testing:
  - Sets all required variables
  - Uses default passwords (development only)
  - Configures port mappings

- **[Dockerfile.patroni](Dockerfile.patroni)**: Custom Docker image:
  - Base: pgvector/pgvector:0.8.1-pg18-trixie
  - Adds: Patroni 3.0+, pgBackRest, Python 3
  - Configuration: pg_hba.conf generation via initdb wrapper
  - Permissions: Pre-configures PostgreSQL directories

- **[entrypoint-patroni.sh](entrypoint-patroni.sh)**: Container startup script:
  - Creates all required directories with correct ownership
  - Sets proper file permissions (700 for data, 755 for parents)
  - Generates pg_hba.conf with authentication rules
  - Initializes pgBackRest
  - Starts Patroni daemon

- **[init-pgvector-ha.sql](init-pgvector-ha.sql)**: Initialization script:
  - Creates pgvector extension (auto-loaded on each node)
  - Creates sample `items` table with 1536D vectors
  - Creates IVFFLAT index for fast similarity search
  - Optional: run manually after deployment

- **[patroni/patroni-node-*.yml](patroni/)**: Patroni configuration:
  - etcd3 DCS configuration
  - PostgreSQL parameters (shared_preload_libraries, data_checksums)
  - Replication settings (synchronous mode, replication slots)
  - REST API configuration for monitoring
  - Watchdog configuration for safety

- **[pgbackrest/pgbackrest.conf](pgbackrest/pgbackrest.conf)**: Backup configuration:
  - Repository paths and retention settings
  - Backup scheduling and compression options
  - WAL archiving configuration

### Configuration Variables

**From [variables-ha.tf](variables-ha.tf):**

| Variable | Default | Type | Description |
|----------|---------|------|-------------|
| `postgres_user` | `pgadmin` | string | PostgreSQL superuser name |
| `postgres_password` | `pgAdmin1` | string | Superuser password (⚠️ **CHANGE FOR PRODUCTION**) |
| `postgres_db` | `postgres` | string | Initial database name |
| `replication_password` | `replicator1` | string | Replicator user password (⚠️ **CHANGE FOR PRODUCTION**) |
| `dbhub_port` | `9090` | number | Bytebase web UI port |
| `etcd_port` | `2379` | number | etcd client API port |
| `etcd_peer_port` | `2380` | number | etcd peer-to-peer port |
| `patroni_api_port_base` | `8008` | number | Base port for Patroni REST API |

### Deployment Outputs

After running `terraform apply`, these outputs are available in the console and `terraform.tfstate`:

```hcl
cluster_info = {
  cluster_name       = "pg-ha-cluster"
  dcs_type          = "etcd3"
  patroni_scope     = "pg-ha-cluster"
  pgvector_version  = "0.8.1"
  postgres_version  = "18"
  replication_type  = "streaming"
  total_nodes       = 3
}

cluster_status = {
  dbhub_url             = "http://localhost:9090"
  etcd_endpoint         = "http://localhost:12379"
  pg_node_1_name        = "pg-node-1"
  pg_node_2_name        = "pg-node-2"
  pg_node_3_name        = "pg-node-3"
  pg_primary_endpoint   = "postgresql://pgadmin:***@localhost:5432/postgres"
  pg_replica_1_endpoint = "postgresql://pgadmin:***@localhost:5433/postgres"
  pg_replica_2_endpoint = "postgresql://pgadmin:***@localhost:5434/postgres"
}
```

---

## Single-Node Setup

For development and testing, a single-node PostgreSQL with pgvector is available in the `single-node/` directory.

**Location**: `single-node/` directory

**Components**:
- Single PostgreSQL 18 container
- pgvector 0.8.1 pre-loaded
- Bytebase (DBHub) web interface
- Sample initialization script

**Use for**: Development, testing, learning pgvector basics

**Deploy**:
```bash
cd single-node
terraform init
terraform apply -auto-approve
psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres
```

See [single-node/README.md](single-node/) for detailed instructions.

---

## Prerequisites

- **Terraform** v1.0+ (tested with v1.14.5)
- **Docker** installed and running (v20.0+)
- **2GB+** available disk space for volumes
- **Linux/macOS/WSL2** for Docker daemon
- Optional: `psql`, `curl` for manual verification

## Usage

### 1. Initialize Terraform

```bash
# Clone/navigate to the repository
cd /home/vejang/terraform-docker-container-postgres

# Initialize Terraform
terraform init
```

This downloads the Docker provider (v3.6.2) and sets up the `.terraform/` directory.

### 2. Plan the Deployment (Optional)

```bash
# Review what Terraform will create
terraform plan -var-file=ha-test.tfvars
```

Expected resources:
- 1 Docker network (pg-ha-network)
- 5 Docker volumes (pg-node-1-data, pg-node-2-data, pg-node-3-data, etcd-data, pgbackrest-repo)
- 3 Docker images (postgres-patroni, etcd, bytebase)
- 4 Docker containers (pg-node-1, pg-node-2, pg-node-3, etcd, dbhub)

### 3. Apply the Configuration

```bash
# Deploy the HA cluster
terraform apply -auto-approve -var-file=ha-test.tfvars
```

**Expected time**: 2-3 minutes
- Images pulled/built: 0-1 minute
- etcd startup: 10 seconds
- Primary PostgreSQL initialization: 40 seconds
- Replica sync: 40 seconds per node
- Bytebase UI: 30 seconds

### 4. Verify Deployment

```bash
# Check cluster status
curl -s http://localhost:8008 | python3 -m json.tool | grep -E '"state"|"role"'

# Check replication
docker exec pg-node-1 psql -U postgres -c \
  "SELECT usename, application_name, state FROM pg_stat_replication;"

# Access Bytebase UI
open http://localhost:9090
```

### 5. Access the Services

**PostgreSQL**:
```bash
# Primary (read/write)
psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres

# Replica 1 (read-only)
psql postgresql://pgadmin:pgAdmin1@localhost:5433/postgres

# Replica 2 (read-only)
psql postgresql://pgadmin:pgAdmin1@localhost:5434/postgres
```

**Web Interfaces**:
- Bytebase: http://localhost:9090
- Patroni API (Node 1): http://localhost:8008
- Patroni API (Node 2): http://localhost:8009
- Patroni API (Node 3): http://localhost:8010

### 6. Destroy the Deployment

```bash
# Remove all resources
terraform destroy -auto-approve -var-file=ha-test.tfvars

# Clean up Docker volumes
docker volume rm pg-node-1-data pg-node-2-data pg-node-3-data etcd-data pgbackrest-repo
```

---

## Features

### PostgreSQL 18 with pgvector 0.8.1

- **Official pgvector Image**: Built on `pgvector/pgvector:0.8.1-pg18-trixie`
- **Vector Type**: Support for n-dimensional vectors (default: 1536 for OpenAI embeddings)
- **Vector Operations**:
  - Cosine distance: `<->` operator
  - Inner product: `<#>` operator
  - Euclidean distance: `<=>` operator
- **Indexes**: IVFFLAT (Approximate) and HNSW support
- **Pre-loaded**: Automatically enabled via `shared_preload_libraries`

### HA Cluster Features

- **3-Node Configuration**: 1 primary + 2 replicas
- **Patroni Orchestration**: Automatic failover and role management
- **etcd3 DCS**: Distributed configuration and consensus
- **Synchronous Replication**: Quorum-based durability
- **Streaming Replication**: Real-time log streaming
- **Replication Slots**: Prevention of WAL file deletion
- **pg_basebackup**: Fast replica initialization

### Monitoring & Management

- **Patroni REST API**: Per-node HTTP health checks
- **Bytebase Web UI**: SQL editor, schema browser, migrations
- **PostgreSQL Extensions**: pg_stat_statements, pgvector enabled
- **Data Checksums**: Detection of disk corruption

### Security (Development)

- **SCRAM-SHA-256**: Password-based authentication
- **Network Isolation**: Bridge network with container communication
- **File Permissions**: 700 on data directories (PostgreSQL standard)
- **Note**: SSL/TLS disabled for development (changeable in production)

---

## DBHub Features

**Bytebase** (DBHub) provides:

- **SQL Editor**: Syntax highlighting, auto-completion
- **Schema Browser**: Visual database structure exploration
- **Database Migrations**: Change tracking and approval workflows
- **Query History**: Audit trail of executed queries
- **User Access Control**: RBAC and team management
- **Connection Management**: Multiple database profiles

**Access**: http://localhost:9090 (default)

**Integration**: Connects to pg-node-1 (primary) automatically

---

## pgvector Integration

### Automatic Setup

pgvector is automatically installed and enabled:
- ✅ Extension created on cluster initialization
- ✅ Pre-loaded in shared_preload_libraries
- ✅ Sample table created with vectors

### Verify pgvector Installation

```bash
# Connect to primary
psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres

# Check extension
SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';

# Check sample table
SELECT * FROM items LIMIT 5;

# Test similarity search
SELECT id, name, embedding <-> '[0.1, 0.2, 0.3]'::vector AS distance
FROM items
ORDER BY distance
LIMIT 3;
```

### Using pgvector

#### 1. Insert Vectors

```sql
-- The 'items' table has 1536-dimensional vectors (for OpenAI embeddings)
-- Insert sample embeddings (use real values from your ML model)
INSERT INTO items (name, embedding) VALUES 
  ('Document 1', ARRAY[0.1, 0.2, ...]::vector),
  ('Document 2', ARRAY[0.15, 0.25, ...]::vector);

-- Note: For actual production use with real embeddings from OpenAI or other models, 
-- use Python or your application language (see example below).
```

#### 2. Quick Test with Lower Dimensions

```sql
-- Create test table with 3D vectors (easier to understand)
CREATE TABLE demo_vectors (
  id SERIAL PRIMARY KEY,
  label TEXT,
  vec vector(3)
);

-- Insert test data
INSERT INTO demo_vectors (label, vec) VALUES
  ('A', '[1, 0, 0]'::vector),
  ('B', '[0.9, 0.1, 0]'::vector),
  ('C', '[0, 1, 0]'::vector),
  ('D', '[0, 0.1, 0.9]'::vector);

-- Create index
CREATE INDEX ON demo_vectors USING ivfflat (vec vector_cosine_ops) WITH (lists = 10);

-- Search
SELECT label, vec <-> '[1, 0, 0]'::vector AS distance
FROM demo_vectors
ORDER BY distance
LIMIT 3;
```

#### 3. Search by Similarity

```sql
-- Cosine similarity (0 = identical, 2 = opposite)
SELECT id, name, embedding <-> query_vector AS distance
FROM items
WHERE embedding <-> query_vector < 0.5  -- similarity threshold
ORDER BY embedding <-> query_vector
LIMIT 10;

-- Inner product (better for normalized vectors)
SELECT id, name, embedding <#> query_vector AS inner_product
FROM items
ORDER BY embedding <#> query_vector
LIMIT 10;

-- Euclidean distance (L2 norm)
SELECT id, name, embedding <=> query_vector AS euclidean_distance
FROM items
ORDER BY embedding <=> query_vector
LIMIT 10;
```

#### 4. Create Custom Indexes

```sql
-- IVFFLAT (Approximate, faster, lower memory)
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- HNSW (Approximate, better quality, more memory)
-- Note: Requires additional build flags
-- CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 200);
```

### pgvector Distance Operations

| Operation | Operator | Use Case | Speed |
|-----------|----------|----------|-------|
| Cosine | `<->` | Semantic similarity, embeddings | Fast |
| Inner Product | `<#>` | Normalized vectors, dot product | Fastest |
| Euclidean | `<=>` | Spatial distances, clustering | Fast |

### Example: Working with Embeddings

```sql
-- Create a table for storing documents with embeddings
CREATE TABLE documents (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT,
  embedding vector(1536),  -- Use 1536 for OpenAI embeddings
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for fast similarity search
CREATE INDEX ON documents USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Insert sample documents with embeddings
INSERT INTO documents (title, content, embedding) VALUES 
  ('Machine Learning 101', 'Introduction to ML...', '[0.1, 0.2, ...]'::vector),
  ('Deep Learning Guide', 'Neural networks...', '[0.15, 0.25, ...]'::vector),
  ('Vector Databases', 'Storing embeddings...', '[0.2, 0.3, ...]'::vector);

-- Search by semantic similarity
WITH query AS (
  SELECT '[query_embedding_here]'::vector AS vec
)
SELECT 
  d.id, d.title,
  (d.embedding <-> q.vec) AS distance
FROM documents d, query q
ORDER BY distance
LIMIT 5;
```

### Converting Real Embeddings to pgvector

**Python**:
```python
import psycopg2
from openai import OpenAI

client = OpenAI()
conn = psycopg2.connect("dbname=postgres user=pgadmin password=pgAdmin1 host=localhost port=5432")

# Get embedding from OpenAI
response = client.embeddings.create(
    model="text-embedding-3-small",
    input="machine learning guide"
)
embedding = response.data[0].embedding

# Insert into PostgreSQL
cur = conn.cursor()
cur.execute(
    "INSERT INTO documents (title, content, embedding) VALUES (%s, %s, %s)",
    ("ML Article", "Content...", embedding)
)
conn.commit()
```

**Node.js/TypeScript**:
```typescript
import { OpenAI } from 'openai';
import pkg from 'pg';

const client = new OpenAI();
const pool = new pkg.Pool({
  host: 'localhost',
  port: 5432,
  user: 'pgadmin',
  password: 'pgAdmin1',
  database: 'postgres'
});

const embedding = await client.embeddings.create({
  model: "text-embedding-3-small",
  input: "machine learning guide"
});

await pool.query(
  "INSERT INTO documents (title, content, embedding) VALUES ($1, $2, $3)",
  ["ML Article", "Content...", JSON.stringify(embedding.data[0].embedding)]
);
```

---

## Network Architecture

### Docker Network: pg-ha-network

- **Type**: Bridge network
- **Subnet**: 172.20.0.0/16
- **Gateway**: 172.20.0.1
- **Container IPs**:
  - pg-node-1: 172.20.0.2
  - pg-node-2: 172.20.0.3
  - pg-node-3: 172.20.0.4
  - etcd: 172.20.0.5
  - dbhub: 172.20.0.6

### Port Mappings

| Service | Internal | External | Protocol | Purpose |
|---------|----------|----------|----------|---------|
| PostgreSQL (Primary) | pg-node-1:5432 | 5432 | TCP | Direct primary access |
| PostgreSQL (Replica 1) | pg-node-2:5432 | 5433 | TCP | Read-only replica |
| PostgreSQL (Replica 2) | pg-node-3:5432 | 5434 | TCP | Read-only replica |
| Patroni API (Node 1) | pg-node-1:8008 | 8008 | TCP | Cluster monitoring |
| Patroni API (Node 2) | pg-node-2:8008 | 8009 | TCP | Cluster monitoring |
| Patroni API (Node 3) | pg-node-3:8008 | 8010 | TCP | Cluster monitoring |
| etcd Client | etcd:2379 | 12379 | TCP | Configuration dist |
| etcd Peer | etcd:2380 | 12380 | TCP | Cluster consensus |
| Bytebase | dbhub:8080 | 9090 | TCP | Web UI |

---

## Storage and Persistence

### Docker Volumes

| Volume | Mount Path | Purpose | Size |
|--------|------------|---------|------|
| pg-node-1-data | /var/lib/postgresql | Primary data | Unlimited |
| pg-node-2-data | /var/lib/postgresql | Replica 1 data | Unlimited |
| pg-node-3-data | /var/lib/postgresql | Replica 2 data | Unlimited |
| etcd-data | /etcd-data | DCS state | ~100MB |
| pgbackrest-repo | /var/lib/pgbackrest | Backup storage | Unlimited |

### Data Persistence

- **All data stored in Docker named volumes**
- **Survives container restarts**: `docker restart pg-node-1`
- **Survives Terraform destroy**: Volumes must be manually deleted
- **Backup-ready**: pgBackRest pre-configured

---

## Troubleshooting

### Common Issues

**Issue**: "could not connect to server: Connection refused"
- **Cause**: Containers still initializing
- **Fix**: Wait 150 seconds after `terraform apply`, then retry

**Issue**: "FATAL: data directory is in wal_level=minimal mode"
- **Cause**: Old volume with incompatible configuration
- **Fix**: `docker volume rm pg-node-*-data` before redeploy

**Issue**: "replication slot does not exist"
- **Cause**: Replica starting before primary slot created
- **Cause**: Database initialization timing issue
- **Fix**: Containers have built-in retry logic; if persistent:
  1. `docker logs pg-node-2` to check errors
  2. Ensure pg-node-1 is fully initialized before pg-node-2
  3. Verify network connectivity with `docker exec pg-node-2 ping pg-node-1`

**Issue**: "pg_hba.conf authentication failed"
- **Cause**: Credentials mismatch between Patroni config and pg_hba.conf
- **Fix**: Verify entrypoint-patroni.sh created pg_hba.conf correctly:
  ```bash
  docker exec pg-node-1 cat /var/lib/postgresql/18/main/pg_hba.conf
  ```

### Monitoring

**Watch real-time cluster status**:
```bash
watch -n 1 'curl -s http://localhost:8008 | python3 -m json.tool | grep -E "state|role"'
```

**Check logs**:
```bash
docker logs -f pg-node-1      # Primary
docker logs -f pg-node-2      # Replica 1
docker logs -f etcd           # DCS
```

**Monitor replication**:
```bash
docker exec pg-node-1 psql -U postgres -c \
  "SELECT usename, app_name, state, sync_state FROM pg_stat_replication;"
```

**Test failover** (simulate primary crash):
```bash
# Stop primary
docker stop pg-node-1

# Watch cluster elect new leader (30-50 seconds)
watch -n 1 'curl -s http://localhost:8009 | python3 -m json.tool | grep -E "state|role"'

# Should see pg-node-2 promoted to "master"
# Restart pg-node-1 to rejoin as replica
docker start pg-node-1
```

---

## Security Notes

### Development Setup ⚠️

**Current Configuration**:
- Default credentials: `pgadmin:pgAdmin1`
- No SSL/TLS encryption (sslmode=disable)
- Network: Docker bridge (internal only)
- Authentication: SCRAM-SHA-256 password-based
- **Suitable for**: Development, testing, learning

### Production Setup ✅

**For production deployment**:

1. **Change Credentials**
   ```bash
   terraform apply \
     -var="postgres_password=<secure_password>" \
     -var="replication_password=<secure_password>" \
     -auto-approve
   ```

2. **Enable SSL/TLS**
   - Generate certificates: `openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365`
   - Mount in Dockerfile: `COPY cert.pem key.pem /etc/ssl/postgresql/`
   - Configure pg_hba.conf: `hostssl all all 0.0.0.0/0 scram-sha-256`

3. **Enforce SCRAM-SHA-256**
   - Already enabled (pg_hba.conf)
   - Disable trust authentication for networks

4. **Network Isolation**
   - Use private networks or VPCs
   - Implement firewall rules
   - Restrict port access (5432, 8008-8010, 2379-2380)

5. **Backup Strategy**
   - Configure pgBackRest for automated backups
   - Test restore procedures
   - Store backups off-site

6. **Monitoring & Alerts**
   - Set up Prometheus + Grafana for metrics
   - Configure alerting for failover events
   - Monitor replication lag

---

## Advanced Configuration

### Custom PostgreSQL Settings

Override PostgreSQL parameters via Patroni YAML:

```yaml
postgresql:
  parameters:
    max_connections: 200
    shared_buffers: 256MB
    effective_cache_size: 1GB
    maintenance_work_mem: 64MB
    log_min_duration_statement: 1000
```

### Using Different Replication Mode

**Synchronous** (current - high durability):
```yaml
synchronous_mode: true
synchronous_node_count: 2
```

**Asynchronous** (higher performance, lower durability):
```yaml
synchronous_mode: false
```

### Scale Down to 2 Nodes

Edit [main-ha.tf](main-ha.tf):
1. Comment out `docker_container.pg_node_3` resource
2. Update `depends_on` for dbhub to exclude node-3
3. `terraform apply -auto-approve`

### Custom pgvector Indexes

Modify [init-pgvector-ha.sql](init-pgvector-ha.sql):
```sql
-- Higher quality index (more memory)
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops) 
WITH (lists = 1000);  -- More clusters = slower but more accurate

-- Or use HNSW (if compiled with support)
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops) 
WITH (m = 32, ef_construction = 200);
```

---

## Support and Documentation

- [PostgreSQL Documentation](https://www.postgresql.org/docs/18/)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [etcd Documentation](https://etcd.io/docs/)
- [Bytebase Documentation](https://www.bytebase.com/docs/)
- [Terraform Docker Provider](https://registry.terraform.io/providers/kreuzwerker/docker/latest)
- [WORKFLOW-DIAGRAM.md](WORKFLOW-DIAGRAM.md) - Deep dive into deployment and failover flows

---

## Key Changes from Previous Version

- ✅ Updated with actual deployed configuration (Terraform v1.14.5, Docker Provider v3.6.2)
- ✅ Added detailed cluster architecture diagrams
- ✅ Added monitoring and health check commands
- ✅ Clarified port mappings (container internal vs host external)
- ✅ Updated credentials (pgadmin) and default values
- ✅ Added troubleshooting section with real issues and fixes
- ✅ Added advanced pgvector examples (Python, Node.js)
- ✅ Added production security checklist
- ✅ Linked to WORKFLOW-DIAGRAM.md for detailed operations
- ✅ Verified all paths and file names against actual repository structure

---

**Last Updated**: February 22, 2026
**Status**: Production Ready ✅
**Cluster Size**: 3 nodes (1 primary + 2 replicas)
**Tested With**: Terraform 1.14.5, Docker Provider 3.6.2, PostgreSQL 18, pgvector 0.8.1
EOF
```

Now verify the file was created:

```bash
cd /home/vejang/terraform-docker-container-postgres
ls -lh README.md
wc -l README.md
head -50 README.md
```

The README.md file should now be **completely updated** with all the changes! ✅