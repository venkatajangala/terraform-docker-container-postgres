# Liquibase + HA PostgreSQL Architecture

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          Docker Network: pg-ha-network          │
│                                                                  │
│  ┌──────────────────────┐                                        │
│  │  Liquibase 5.0.1     │ (Migration Engine)                     │
│  │   Container          │                                        │
│  ├──────────────────────┤                                        │
│  │ • Wait for primary   │                                        │
│  │ • Execute changesets │                                        │
│  │ • Track history      │                                        │
│  │ • Support rollback   │                                        │
│  └──────┬───────────────┘                                        │
│         │ JDBC (postgresql driver)                              │
│         │ Port 5432                                             │
│         ▼                                                        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │         HA PostgreSQL Cluster (Patroni)                  │   │
│  ├──────────────────────────────────────────────────────────┤   │
│  │                                                           │   │
│  │  PRIMARY (pg-node-1)                                     │   │
│  │  ┌──────────────────────────────────────────────┐        │   │
│  │  │ PostgreSQL 18 + pgVector + Patroni Leader   │        │   │
│  │  │ • Receives migrations from Liquibase        │        │   │
│  │  │ • Executes DDL/DML changes                  │        │   │
│  │  │ • Replicates to standby nodes               │        │   │
│  │  │ • Maintains databasechangelog table         │        │   │
│  │  │ • Port: 5432 (internal)                     │        │   │
│  │  └──────────────────────────────────────────────┘        │   │
│  │         ▲                                                 │   │
│  │         │ Replication (Streaming)                        │   │
│  │         │                                                 │   │
│  │    ┌────┴────┐                                           │   │
│  │    ▼         ▼                                           │   │
│  │ STANDBY   STANDBY                                        │   │
│  │ (node-2)  (node-3)                                       │   │
│  │ Read-only Read-only                                      │   │
│  │ Replicas  Replicas                                       │   │
│  └──────────────────────────────────────────────────────────┘   │
│         ▲                                                        │
│         │ Patroni Discovery (etcd)                             │
│         │                                                        │
│  ┌──────┴──────┐                                                │
│  │    etcd     │ (DCS - Distributed Configuration Store)       │
│  │   3.5.0     │ Port: 2379                                     │
│  └─────────────┘                                                │
│                                                                  │
│  ┌─────────────────────┐                                        │
│  │   PgBouncer (optional)                                       │
│  │   Connection Pooling  │                                      │
│  │   Port: 6432         │                                      │
│  └─────────────────────┘                                        │
│                                                                  │
│  ┌──────────────────────┐                                       │
│  │ DBHub (Bytebase)    │ (Schema Management UI)                │
│  │ Port: 9090          │                                       │
│  └──────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────┘

External Access:
  • PostgreSQL: localhost:5432 (primary)
  • PostgreSQL: localhost:5433 (replica-1)
  • PostgreSQL: localhost:5434 (replica-2)
  • Patroni API: localhost:8008 (node-1)
  • DBHub: localhost:9090
  • etcd: localhost:2379
  • PgBouncer: localhost:6432 (optional)
```

## Migration Execution Flow

```
┌─────────────────┐
│ terraform apply │
│ liquibase       │
│ _enabled=true   │
└────────┬────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Build liquibase Docker image     │
│ FROM liquibase:5.0.1             │
│ + PostgreSQL client              │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Start liquibase-migrations       │
│ container with:                  │
│ • Mount /liquibase/changelog     │
│ • Network: pg-ha-network         │
│ • Entrypoint: liquibase-entry... │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Wait for PostgreSQL Ready        │ (MAX_RETRIES=30, 5s each)
│ pg_isready -h pg-node-1 -p 5432 │
└────────┬─────────────────────────┘
         │
         ▼ (Ready)
┌──────────────────────────────────┐
│ Wait for Patroni Primary         │ (Check: NOT in recovery)
│ SELECT pg_is_in_recovery()       │
└────────┬─────────────────────────┘
         │
         ▼ (Primary Elected)
┌──────────────────────────────────┐
│ Verify Changelog Files Exist     │
│ /liquibase/changelog/db.change   │
│ -log-master.yml                  │
└────────┬─────────────────────────┘
         │
         ▼ (Files OK)
┌──────────────────────────────────┐
│ Execute: liquibase update        │
│                                  │
│ 1. Include 01-init-schema.yml    │
│    └─> CREATE SCHEMA audit      │
│    └─> CREATE FUNCTION audit... │
│                                  │
│ 2. Include 02-add-extensions.yml │
│    └─> CREATE EXTENSION vector  │
│    └─> CREATE EXTENSION pgcrypto│
│    └─> ... (4 extensions total) │
│                                  │
│ 3. Include 03-create-tables.yml  │
│    └─> CREATE TABLE users       │
│    └─> CREATE TABLE items       │
│    └─> CREATE TABLE sessions    │
│    └─> CREATE TABLE audit_log   │
│    └─> CREATE INDEXES...        │
│    └─> CREATE TRIGGERS...       │
└────────┬─────────────────────────┘
         │
         ▼ (Migration Complete)
┌──────────────────────────────────┐
│ Write to databasechangelog table │
│ (Persistent audit trail)         │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Replication to Standby Nodes     │ (Automatic via WAL streaming)
│ • pg-node-2 (Standby)            │
│ • pg-node-3 (Standby)            │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Container Exits (Status: 0)      │
│ docker ps shows Exited           │
└──────────────────────────────────┘

View Results:
  docker logs liquibase-migrations
  psql ... SELECT * FROM databasechangelog;
```

## Data Flow - Insert Operation with Audit

```
Application Code
      │
      ▼
INSERT INTO users (username, email, password_hash)
VALUES ('test_user', 'test@example.com', 'hash');
      │
      ▼
┌──────────────────────────────┐
│ Primary (pg-node-1)          │
│ Receives INSERT              │
└────────┬─────────────────────┘
         │
         ▼
┌──────────────────────────────┐
│ users_audit_trigger fires    │
│ (AFTER INSERT for EACH ROW)  │
└────────┬─────────────────────┘
         │
         ▼
┌──────────────────────────────┐
│ audit.audit_trigger_func()   │
│ executes:                    │
│ INSERT INTO audit.audit_log: │
│ • table_name: 'users'        │
│ • operation: 'INSERT'        │
│ • new_data: {entire record}  │
│ • changed_at: NOW()          │
└────────┬─────────────────────┘
         │
         ▼
┌──────────────────────────────┐
│ Transaction Commits          │
│ (Both user record + audit)   │
└────────┬─────────────────────┘
         │
         ▼
┌──────────────────────────────┐
│ WAL (Write-Ahead Log) Entry  │
│ • LSN: Sequence Number       │
│ • All changes included       │
└────────┬─────────────────────┘
         │
         ├──────────────────────────────┐
         │ Streaming Replication        │
         ▼                              ▼
┌──────────────────────┐    ┌──────────────────────┐
│ Standby (pg-node-2)  │    │ Standby (pg-node-3)  │
│ • Apply WAL entries  │    │ • Apply WAL entries  │
│ • users table sync   │    │ • users table sync   │
│ • audit table sync   │    │ • audit table sync   │
│ (read-only)          │    │ (read-only)          │
└──────────────────────┘    └──────────────────────┘

All three nodes have consistent state within ~1-2ms
```

## Schema After Migrations

```
PostgreSQL Database: postgres
│
├── Schema: public
│   ├── Table: users
│   │   ├── id (UUID, PK, auto-generated)
│   │   ├── username (VARCHAR, UNIQUE)
│   │   ├── email (VARCHAR, UNIQUE)
│   │   ├── password_hash (VARCHAR)
│   │   ├── created_at (TIMESTAMP, auto-set)
│   │   ├── updated_at (TIMESTAMP, auto-set)
│   │   └── Trigger: users_audit_trigger (AFTER INSERT/UPDATE/DELETE)
│   │
│   ├── Table: items
│   │   ├── id (BIGSERIAL, PK)
│   │   ├── user_id (UUID, FK → users.id)
│   │   ├── name (VARCHAR)
│   │   ├── description (TEXT)
│   │   ├── embedding (vector(1536)) ← OpenAI embeddings
│   │   ├── created_at (TIMESTAMP, auto-set)
│   │   ├── updated_at (TIMESTAMP, auto-set)
│   │   ├── Index: idx_items_user_id
│   │   ├── Index: idx_items_embedding (IVFFLAT for vector search)
│   │   └── Trigger: items_audit_trigger
│   │
│   ├── Table: sessions
│   │   ├── id (UUID, PK, auto-generated)
│   │   ├── user_id (UUID, FK → users.id)
│   │   ├── token (VARCHAR, UNIQUE)
│   │   ├── expires_at (TIMESTAMP)
│   │   ├── created_at (TIMESTAMP, auto-set)
│   │   ├── Index: idx_sessions_user_id
│   │   ├── Index: idx_sessions_expires_at
│   │   └── Trigger: sessions_audit_trigger
│   │
│   ├── Table: databasechangelog (Liquibase internal)
│   │   ├── id
│   │   ├── author
│   │   ├── filename
│   │   ├── dateexecuted
│   │   ├── orderexecuted
│   │   ├── execstatus
│   │   ├── description
│   │   ├── comments
│   │   ├── tag
│   │   ├── liquibase
│   │   ├── contexts
│   │   ├── labels
│   │   ├── deployment_id
│   │   └── execution_time
│   │
│   └── Table: databasechangeloglock (Liquibase internal)
│       ├── id
│       ├── locked
│       ├── lockgranted
│       └── lockedby
│
├── Schema: audit
│   ├── Table: audit_log
│   │   ├── id (BIGSERIAL, PK)
│   │   ├── table_name (VARCHAR)
│   │   ├── operation (VARCHAR: INSERT/UPDATE/DELETE)
│   │   ├── old_data (JSONB) ← Full record before change
│   │   ├── new_data (JSONB) ← Full record after change
│   │   ├── changed_at (TIMESTAMP)
│   │   ├── Index: idx_audit_log_table
│   │   └── Index: idx_audit_log_changed_at
│   │
│   └── Function: audit_trigger_func()
│       ├── Language: plpgsql
│       ├── Return Type: TRIGGER
│       └── Logic: Logs INSERT/UPDATE/DELETE to audit_log
│
└── Extensions
    ├── vector (pgvector) - Similarity search
    ├── pg_stat_statements - Query analytics
    ├── pgcrypto - Cryptographic functions
    ├── uuid-ossp - UUID generation
    └── plpgsql - Procedural language (built-in)
```

## Deployment Timeline

```
Time  Event
─────────────────────────────────────────────────────
0s    terraform apply (Liquibase enabled)
      └─ docker build (Liquibase image)
      
2s    docker run (liquibase-migrations container)
      └─ Start entrypoint.sh
      
3s    Wait for PostgreSQL... (30 attempts × 5s)
      ├─ Attempt 1: No response (pg-node-1 starting)
      ├─ Attempt 2: No response (etcd initializing)
      └─ Attempt N: Connected!
      
~30s  Wait for Patroni primary election
      ├─ pg_is_in_recovery() = true (replica mode)
      └─ Primary elected: pg_is_in_recovery() = false
      
~32s  Verify changelog files
      └─ /liquibase/changelog/db.changelog-master.yml ✓
      
~33s  Execute migrations
      ├─ 01-init-schema: CREATE SCHEMA + FUNCTION (~200ms)
      ├─ 02-add-extensions: 4 extensions (~500ms)
      └─ 03-create-tables: 4 tables + indexes + triggers (~800ms)
      
~34s  Update databasechangelog table
      └─ Record all 7 changesets executed
      
~35s  Replication to standby nodes
      ├─ pg-node-2: Receiving WAL stream
      └─ pg-node-3: Receiving WAL stream
      
~37s  Container exits (Status: 0)
      docker ps -a shows: Exited (0)

~40s  All nodes consistent (standby catch-up)
      Ready for queries and connections
```

## Failover Scenario with Liquibase

```
Before Failover:
  Primary: pg-node-1 ✓
  Standby: pg-node-2 
  Standby: pg-node-3

Failure: pg-node-1 goes down

Timeline:
  T+0s    pg-node-1 lost connection
  T+1s    Patroni detects failure
  T+3s    Failover triggered
  T+4s    pg-node-2 promoted to primary
  T+5s    pg-node-3 syncs from new primary
  T+10s   Cluster healthy again
  
Schema Status:
  • databasechangelog present on new primary (pg-node-2)
  • All migrations already applied (from replication)
  • No re-migration needed
  • Audit trail intact (audit_log table replicated)

Next Liquibase Run:
  • Connects to pg-node-2 (new primary)
  • Skips already-applied changesets (via databasechangelog)
  • Applies only new changesets
  • No conflicts or duplicates
```

---

**Key Takeaways:**
- Liquibase waits for PostgreSQL AND Patroni primary election
- All migrations execute on primary, replicate to standby
- Audit trail persists on all nodes via replication
- Failover doesn't affect migration history
- Container exits after completing migrations (monitor via logs)
- Idempotent: re-running terraform apply is safe
