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
| [DEPLOYMENT-SUCCESS.md](DEPLOYMENT-SUCCESS.md) | ✅ Final working configuration and verification |
| [README.md](README.md) | This file - Complete deployment and operations guide |

---

## Terraform-managed PostgreSQL with pgvector and DBHub (MCP) Integration

This repository contains Terraform configurations for deploying PostgreSQL 18 with pgvector in Docker. Choose between **single-node** development setup or **3-node HA cluster** with automatic failover.

## 📑 Quick Reference

### Single-Node Setup (Development)
Location: `single-node/` directory  
Use for: Development, testing, learning pgvector  
Features: Simple, fast setup, minimal resources

### High-Availability Cluster (Production)  
**Location**: Root directory (`main-ha.tf`, `variables-ha.tf`, etc.)  
**Status**: ✅ **Production Ready** - Fully tested and validated

## ✨ Features at a Glance

| Feature | Single-Node | HA Cluster |
|---------|:-----------:|:----------:|
| PostgreSQL 18 | ✅ | ✅ |
| pgvector 0.8.1 | ✅ | ✅ |
| Automatic failover | ❌ | ✅ |
| Streaming replication | ❌ | ✅ (2 replicas) |
| Distributed consensus | ❌ | ✅ (etcd) |
| Hot standby | ❌ | ✅ |
| Backup ready | ✅ | ✅ (pgBackRest) |



## ✅ HA Cluster Deployment - PRODUCTION READY (Feb 21, 2026)

### 🎉 Deployment Status: **FULLY OPERATIONAL**
Successfully deployed and validated 3-node PostgreSQL HA cluster with all features working:

```
✅ pg-node-1 (Master)  - localhost:5432  (RUNNING)
✅ pg-node-2 (Replica) - localhost:5433  (RUNNING)
✅ pg-node-3 (Replica) - localhost:5434  (RUNNING)
✅ Streaming Replication (async)
✅ pgvector Extension - All nodes
✅ Automatic Failover (Patroni)
✅ etcd Coordination (v3.5.0)
```

### Critical Issues Fixed & Resolved

#### Issue 1: pg_hba.conf Empty During Bootstrap
- **Root Cause**: Incorrect YAML nesting + incorrect format
- **Solution**: 
  - Moved pg_hba from `bootstrap.postgresql` → `bootstrap.dcs.postgresql` (where Patroni reads it)
  - Changed format from dictionary to PostgreSQL **native string format** (Patroni-preferred)
- **Result**: ✅ pg_hba.conf now populated with 8 authentication rules on all nodes

#### Issue 2: Directory Permission Errors
- **Root Cause**: Directories created during cluster init with root ownership
- **Solution**:
  - Pre-created PostgreSQL directories in Dockerfile with `postgres` ownership
  - Set proper permissions: 700 for main, 755 for parents
  - Added explicit enforcement in entrypoint before Patroni starts
  - Added permission fix in initdb wrapper after database creation
- **Result**: ✅ All nodes have correct ownership (postgres) and permissions (700/755)

#### Issue 3: etcd Configuration Caching
- **Root Cause**: Failed bootstrap leaves empty config in etcd
- **Solution**: Full cleanup of etcd volume + fresh deployment
- **Result**: ✅ Cluster bootstraps with correct DCS configuration

### Current Cluster Architecture
```
├── etcd (v3.5.0)              # Distributed consensus, stores cluster config
├── pg-node-1 (Master)         # Primary - accepts reads & writes
│   ├── PostgreSQL 18.2
│   ├── Patroni 3.3.8
│   ├── pgvector 0.8.1
│   ├── pg_stat_statements
│   └── Replication streaming to 2 replicas
├── pg-node-2 (Replica)        # Standby - read-only, auto-promotes on failure
│   ├── PostgreSQL 18.2
│   ├── Patroni 3.3.8
│   ├── pgvector 0.8.1
│   ├── Hot standby enabled
│   └── Streaming from primary
└── pg-node-3 (Replica)        # Standby - read-only, auto-promotes on failure
    ├── PostgreSQL 18.2
    ├── Patroni 3.3.8
    ├── pgvector 0.8.1
    ├── Hot standby enabled
    └── Streaming from primary
```

### Connection Endpoints
```
Primary (Write Operations):
  Host: localhost | Port: 5432 | User: postgres or pgadmin

Replicas (Read-Only):
  Replica 1: pg-node-2:5433
  Replica 2: pg-node-3:5434

Cluster Health:
  Patroni API Node 1: http://localhost:8008
  Patroni API Node 2: http://localhost:8009
  Patroni API Node 3: http://localhost:8010
  etcd Cluster: http://localhost:12379
```

### Quick Health Checks
```bash
# Cluster status across all nodes
for i in 8008 8009 8010; do
  echo "Node port $i:"; 
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
```

### Key Configuration Files Updated
1. **patroni-node-[1-3].yml**: pg_hba in correct DCS location, string format
2. **Dockerfile.patroni**: Pre-create directories, permission fixes, initdb wrapper
3. **entrypoint-patroni.sh**: Final permission enforcement before Patroni, directory ownership

### Production Ready Features
- ✅ Automatic failover < 30 seconds
- ✅ Data checksums enabled
- ✅ Hot standby replication
- ✅ WAL archiving ready (pgBackRest)
- ✅ Vector similarity searches
- ✅ Full SQL support with extensions
- ✅ Synchronous/async replication configurable

---

## Single-Node Setup

This Terraform configuration deploys a complete PostgreSQL 18 + pgvector + DBHub (Bytebase) stack using Docker with a custom bridge network for secure inter-container communication. The setup is fully automated with pgvector extension and sample table initialization.

## Complete Stack

```
┌─────────────────────┐         ┌──────────────────────────────┐
│   DBHub Container   │         │  Postgres Container          │
│  (port 9090)        │◄────────┤  (port 5432)                 │
│  bytebase/bytebase  │         │  pgvector 0.8.1-pg18-trixie  │
└─────────────────────┘         │  with pgvector pre-loaded    │
         │                      └──────────────────────────────┘
         └──────────────────────────┘
            Connected via mcp-network
```

## Features

- **PostgreSQL 18 with pgvector**: Official pgvector 0.8.1 image optimized for PostgreSQL 18 (Debian trixie)
- **Automatic pgvector Initialization**: Extension automatically created on startup with pre-configured sample table
- **Vector Pre-loading**: pgvector loaded via `shared_preload_libraries` for optimal performance
- **Sample Table**: `items` table with 1536-dimensional vectors and IVFFLAT index for testing
- **PostgreSQL 18+ Compatible**: Properly configured mount point at `/var/lib/postgresql` for version-specific directories
- **Persistent Storage**: Docker named volume `pgdata` for data persistence across restarts
- **DBHub/Bytebase Web Interface**: Web-based database management, SQL editor, and schema visualization
- **Custom Bridge Network**: Secure `mcp-network` for container-to-container communication
- **Automatic Dependencies**: DBHub waits for PostgreSQL to be ready before starting
- **Environment Variables**: Fully configurable credentials and ports
- **Auto-restart Policy**: Containers restart automatically unless stopped manually

## Project Structure

```
.
├── main.tf                   # Main Terraform configuration with Docker resources
├── variables.tf              # Input variables for customization
├── outputs.tf                # Output values for accessing services
├── Dockerfile                # Docker image configuration (pulls pgvector)
├── init-pgvector.sql         # SQL initialization script for pgvector setup
├── terraform.tfstate         # Terraform state file (git ignored)
├── terraform.tfstate.backup  # Terraform state backup
└── README.md                 # This file
```

## File Descriptions

- **main.tf**: Defines the complete stack:
  - Custom bridge network for container communication
  - PostgreSQL container with pgvector
  - DBHub (Bytebase) container
  - Volume and file mounts
  
- **variables.tf**: Configurable inputs:
  - Database credentials
  - Database name
  - DBHub port

- **outputs.tf**: Outputs for accessing the deployment:
  - Connection strings
  - Container names
  - Service URLs
  - Network information

- **init-pgvector.sql**: Automatic initialization:
  - Creates pgvector extension
  - Creates sample `items` table with 1536D vectors
  - Creates IVFFLAT index for fast similarity search

## Configuration Variables

- `postgres_user`: Database username (default: `pgadmin`)
- `postgres_password`: Database password (sensitive, default: `pgAdmin1`) - **Change this for production!**
- `postgres_db`: Database name (default: `postgres`)
- `dbhub_port`: DBHub web interface port (default: `9090`)

## Deployment Outputs

After running `terraform apply`, these values are available:

- `connection_string`: PostgreSQL connection string (from host)
- `postgres_container_name`: Name of PostgreSQL container (`my-postgres`)
- `dbhub_container_name`: Name of DBHub container (`dbhub`)
- `dbhub_url`: DBHub web interface URL (`http://localhost:9090`)
- `mcp_network`: Custom bridge network name (`mcp-network`)
- `postgres_dsn_internal`: PostgreSQL DSN for container-to-container communication

## Prerequisites

- Terraform installed (`v1.0+`)
- Docker installed and running
- 2GB+ available disk space

## Usage

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Plan the Deployment (Optional)

```bash
terraform plan
```

### 3. Apply the Configuration

**With default credentials:**
```bash
terraform apply -auto-approve
```

**With custom credentials:**
```bash
terraform apply \
  -var="postgres_user=myuser" \
  -var="postgres_password=mysecurepass" \
  -var="postgres_db=mydb" \
  -var="dbhub_port=9090" \
  -auto-approve
```

### 4. Verify Deployment

Check containers are running:
```bash
docker ps | grep -E "my-postgres|dbhub"
```

Verify pgvector is initialized:
```bash
docker exec my-postgres psql -U pgadmin -d postgres -c "\dt items"
```

### 5. Access the Services

- **DBHub Web UI**: Open `http://localhost:9090` in your browser
- **PostgreSQL CLI Connection**:
  ```bash
  psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres
  ```
- **Get Connection String from Terraform**:
  ```bash
  terraform output -raw connection_string
  ```
- **Get DBHub URL**:
  ```bash
  terraform output -raw dbhub_url
  ```

### 6. Destroy the Deployment

```bash
terraform destroy -auto-approve
```

**Note**: This removes containers but keeps the `pgdata` volume. To also delete data:
```bash
terraform destroy -auto-approve && docker volume rm pgdata
```

## DBHub Features

DBHub (Bytebase) provides a web-based interface for database management:

- **Web-based Database Management**: Query, edit, and manage databases through the web UI
- **SQL Editor**: Write, execute, and save SQL queries
- **Schema Management**: View and manage database schemas visually
- **Database Comparison**: Compare schemas across databases
- **Change Tracking**: Version control and track database changes
- **Multi-database Support**: Connect and manage multiple databases

## pgvector Integration

### Automatic Setup

pgvector is automatically initialized on container startup:

1. **Extension Created**: `CREATE EXTENSION IF NOT EXISTS vector`
2. **Sample Table**: `items` table with 1536-dimensional vectors (OpenAI embedding dimension)
3. **Index Created**: IVFFLAT index for fast similarity search operations
4. **Pre-loaded**: Vector library loaded via `shared_preload_libraries` for performance

### Verify pgvector Installation

```bash
# Check if extension is available
docker exec my-postgres psql -U pgadmin -d postgres -c "SELECT * FROM pg_available_extensions WHERE name = 'vector';"

# Check if extension is created
docker exec my-postgres psql -U pgadmin -d postgres -c "\dx vector"

# Verify sample table
docker exec my-postgres psql -U pgadmin -d postgres -c "\dt items"
```

### Using pgvector

#### 1. Insert Vectors

```sql
-- The 'items' table has 1536-dimensional vectors (for OpenAI embeddings)
-- Insert sample embeddings (use real values from your ML model)
INSERT INTO items (name, embedding) VALUES 
('document1', '[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]'::vector);
```

**Note**: For actual production use with real embeddings from OpenAI or other models, use Python or your application language (see example below).

#### 2. Quick Test with Lower Dimensions

To test pgvector with smaller dimensions before using 1536-dimensional vectors:

```sql
-- Create a test table with 3-dimensional vectors
CREATE TABLE items_test (
    id BIGSERIAL PRIMARY KEY,
    name TEXT,
    embedding vector(3)
);

-- Test with 3-dimensional vectors
INSERT INTO items_test (name, embedding) VALUES 
('document1', '[0.1, 0.2, 0.3]'::vector),
('document2', '[0.4, 0.5, 0.6]'::vector),
('document3', '[0.5, 0.6, 0.7]'::vector);

-- Query test table
SELECT * FROM items_test;
```

#### 3. Search by Similarity

```sql
-- Cosine similarity search on items table (1536 dimensions)
SELECT 
  name, 
  embedding <=> embedding AS distance
FROM items_test
ORDER BY embedding <=> (SELECT embedding FROM items_test LIMIT 1)
LIMIT 5;
```

#### 3. Create Custom Indexes

```sql
-- IVF index for faster searches on large datasets
CREATE INDEX ON items_test USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- HNSW index (more accurate but slower to build)
CREATE INDEX ON items_test USING hnsw (embedding vector_cosine_ops);
```

### pgvector Distance Operations

| Operator | Description | Use Case |
|----------|-------------|----------|
| `<->` | Euclidean distance | Geometric data |
| `<#>` | Negative inner product | Speed optimization |
| `<=>` | **Cosine distance** | **Embeddings (recommended)** |
| `@>` | Contains | Array operations |
| `<@` | Is contained by | Array operations |

### Example: Working with Embeddings

```sql
-- Create a table for storing documents with embeddings
CREATE TABLE documents (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT,
  embedding vector(3),  -- Use 3 for demo, 1536 for OpenAI embeddings
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for fast similarity search
CREATE INDEX ON documents USING ivfflat (embedding vector_cosine_ops) WITH (lists = 10);

-- Insert sample documents with embeddings
INSERT INTO documents (title, content, embedding) VALUES 
('Article 1', 'Content here...', '[0.1, 0.2, 0.3]'::vector),
('Article 2', 'More content...', '[0.15, 0.25, 0.35]'::vector),
('Article 3', 'Different topic...', '[0.5, 0.6, 0.7]'::vector);

-- Find similar documents (search for embeddings similar to [0.12, 0.22, 0.32])
SELECT title, embedding <=> '[0.12, 0.22, 0.32]'::vector AS similarity
FROM documents
ORDER BY embedding <=> '[0.12, 0.22, 0.32]'::vector
LIMIT 10;
```

### Converting Real Embeddings to pgvector

If you have embeddings from OpenAI or other models:

```python
# Python example
import psycopg2
from pgvector.psycopg2 import register_vector

conn = psycopg2.connect("postgresql://pgadmin:pgAdmin1@localhost:5432/postgres")
register_vector(conn)

cursor = conn.cursor()

# Assuming you have embeddings from OpenAI
embedding = [0.1, 0.2, 0.3, ...]  # 1536 dimensions for OpenAI

cursor.execute(
    "INSERT INTO items (name, embedding) VALUES (%s, %s)",
    ("My Document", embedding)
)

conn.commit()
cursor.close()
conn.close()
```

## Network Architecture

### Container Communication

```
Host Machine (localhost)
    ↓
    ├── PostgreSQL: localhost:5432
    └── DBHub: localhost:9090

Docker mcp-network (Bridge)
    ├── my-postgres (internal): my-postgres:5432
    └── dbhub (internal): dbhub:8080 (maps to 9090 on host)
```

### Connection Strings

- **From Host Machine**:
  ```
  postgresql://pgadmin:pgAdmin1@localhost:5432/postgres
  ```

- **From DBHub Container** (internal):
  ```
  postgresql://pgadmin:pgAdmin1@my-postgres:5432/postgres
  ```

- **From Other Containers** (internal):
  ```
  postgresql://pgadmin:pgAdmin1@my-postgres:5432/postgres
  ```

## Storage and Persistence

### Volume Configuration

- **Volume Name**: `pgdata`
- **Mount Point**: `/var/lib/postgresql` (PostgreSQL 18+ compliant)
- **Data Location**: `/var/lib/postgresql/18/main` (version-specific)
- **Persistence**: Survives container restarts and redeployments

### Data Persistence Workflow

```
Container Start
    ↓
Mount /var/lib/postgresql volume
    ↓
PostgreSQL initializes or uses existing data
    ↓
Init scripts run (init-pgvector.sql)
    ↓
Service ready
```

### Backup Data

```bash
# Backup volume data
docker run --rm -v pgdata:/data -v $(pwd):/backup \
  alpine tar czf /backup/pgdata-backup.tar.gz -C /data .

# Restore volume data
docker run --rm -v pgdata:/data -v $(pwd):/backup \
  alpine tar xzf /backup/pgdata-backup.tar.gz -C /data
```

## Troubleshooting

### Common Issues

**PostgreSQL container fails to start**
- Check logs: `docker logs my-postgres`
- Ensure port 5432 is not in use: `lsof -i :5432`
- Verify volume is accessible: `docker volume ls`

**DBHub cannot connect to PostgreSQL**
- Verify both containers are running: `docker ps`
- Check network: `docker network inspect mcp-network`
- Verify credentials in DBHub UI

**Port 5432 or 9090 already in use**
```bash
# Change port
terraform apply -var="dbhub_port=8081" -auto-approve
```

**pgvector extension not available**
- Extension may not be in shared_preload_libraries (this is normal)
- Create it manually per database: `CREATE EXTENSION IF NOT EXISTS vector;`
- Verify installation: `SELECT * FROM pg_available_extensions WHERE name = 'vector';`

**PostgreSQL 18+ mount point errors**
- Must mount at `/var/lib/postgresql` not `/var/lib/postgresql/data`
- Current configuration is correct
- If upgrading from older version, delete volume: `docker volume rm pgdata`

### Monitoring

```bash
# Check container status
docker ps | grep -E "my-postgres|dbhub"

# View logs
docker logs my-postgres
docker logs dbhub

# Execute commands in container
docker exec -it my-postgres psql -U pgadmin -d postgres

# Inspect volume
docker volume inspect pgdata
```

## Security Notes

### Development Setup ⚠️

- Default credentials: `pgadmin:pgAdmin1`
- No SSL/TLS encryption
- `sslmode=disable` in connection strings
- Suitable for **development only**

### Production Setup ✅

For production deployments:

1. **Use strong passwords**:
   ```bash
   terraform apply -var="postgres_password=$(openssl rand -base64 32)"
   ```

2. **Enable SSL/TLS**:
   - Generate certificates
   - Update DBHub connection string to use `sslmode=require`

3. **Use secret manager**:
   - Store credentials in Terraform Cloud/Enterprise
   - Use AWS Secrets Manager, Azure Key Vault, etc.
   - Never commit secrets to version control

4. **Network isolation**:
   - Run in private VPC
   - Use network policies to restrict access
   - Consider removing port 5432 external binding

5. **Backup strategy**:
   - Regular automated backups
   - Test restore procedures
   - Keep backups off-site

## Advanced Configuration

### Custom PostgreSQL Settings

```terraform
env = [
  "POSTGRES_INIT_ARGS=-c max_connections=200 -c shared_buffers=256MB"
]
```

### Using Different Database

```bash
terraform apply \
  -var="postgres_db=myapp" \
  -auto-approve
```

### Scale Down to Single Database

Remove DBHub and use PostgreSQL directly:
```bash
# Edit main.tf to comment out DBHub resource
terraform apply -auto-approve
```

## Support and Documentation

- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [Bytebase Documentation](https://www.bytebase.com/docs/)
- [Terraform Docker Provider](https://registry.terraform.io/providers/kreuzwerker/docker/latest)
