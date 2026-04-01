# Liquibase + HA PostgreSQL Architecture

## System Architecture

```mermaid
graph TD
    TF[terraform apply\nliquibase_enabled=true]
    LB[Liquibase 5.0.1\nMigration Container\nExits after completion]
    PGB[PgBouncer\npostgres_liquibase pool\nsession mode]
    PG1[pg-node-1\nPatroni Primary\nPostgreSQL 18]
    PG2[pg-node-2\nStandby Replica]
    PG3[pg-node-3\nStandby Replica]
    ETCD[etcd :2379\nLeader Election]

    TF -->|builds + starts| LB
    LB -->|JDBC :6432\nwaits for primary| PGB
    PGB -->|routes exclusively\nto primary| PG1
    PG1 -->|WAL streaming| PG2
    PG1 -->|WAL streaming| PG3
    PG1 & PG2 & PG3 <-->|consensus| ETCD

    style LB fill:#37474f,color:#fff
    style PGB fill:#6a1b9a,color:#fff
    style PG1 fill:#2e7d32,color:#fff
    style PG2 fill:#1565c0,color:#fff
    style PG3 fill:#1565c0,color:#fff
    style ETCD fill:#e65100,color:#fff
```

External access ports:

| Endpoint | Port | Purpose |
| --- | --- | --- |
| PgBouncer (apps) | 6432 / 6433 | Recommended for applications |
| pg-node-1 direct | 5432 | Primary PostgreSQL |
| pg-node-2 direct | 5433 | Replica |
| pg-node-3 direct | 5434 | Replica |
| Patroni API | 8008 / 8009 / 8010 | Cluster health |
| etcd | 2379 | DCS |

## Migration Execution Flow

```mermaid
flowchart TD
    A[terraform apply] --> B[Build Dockerfile.liquibase\nFROM liquibase:5.0.1\n+ lpm add postgresql]
    B --> C[Start liquibase-migrations container\nMount /liquibase/changelog\nNetwork: pg-ha-network]
    C --> D{PgBouncer ready?\npostgres_liquibase :6432\nMAX_RETRIES=30 × 5s}
    D -->|No| D
    D -->|Yes| E{Patroni primary elected?\npg_is_in_recovery = false\nMAX_RETRIES=30 × 5s}
    E -->|No - replica| E
    E -->|Yes| F[liquibase update\nvia CLI args]
    F --> G[01-init-schema.yml\nCREATE SCHEMA audit\nCREATE FUNCTION audit_trigger_func]
    G --> H[02-add-extensions.yml\nvector, pg_stat_statements\npgcrypto, uuid-ossp]
    H --> I[03-create-tables.yml\nusers, items, sessions\naudit_log + indexes + triggers]
    I --> J[04-add-products.yml\nproducts + indexes\naudit trigger]
    J --> K[Write 11 rows to\ndatabasechangelog]
    K --> L[WAL replicates schema\nto pg-node-2 and pg-node-3]
    L --> M[Container exits\nExit code 0]
```

## Data Flow — Insert Operation with Audit

```mermaid
sequenceDiagram
    participant App
    participant PGB as PgBouncer
    participant PG1 as pg-node-1 Primary
    participant AT as audit_trigger_func
    participant AL as audit.audit_log
    participant PG2 as pg-node-2 Replica
    participant PG3 as pg-node-3 Replica

    App->>PGB: INSERT INTO users (...)
    PGB->>PG1: Forward INSERT
    PG1->>AT: users_audit_trigger fires\n(AFTER INSERT FOR EACH ROW)
    AT->>AL: INSERT {table_name, operation, new_data, changed_at}
    PG1-->>App: Transaction committed
    PG1->>PG2: WAL stream (users + audit_log)
    PG1->>PG3: WAL stream (users + audit_log)
    Note over PG2,PG3: Consistent within ~1-2ms
```

## Schema After Migrations

```text
PostgreSQL Database: postgres
│
├── Schema: public
│   ├── Table: users
│   │   ├── id (UUID, PK, auto-generated)
│   │   ├── username (VARCHAR, UNIQUE)
│   │   ├── email (VARCHAR, UNIQUE)
│   │   ├── password_hash (VARCHAR)
│   │   ├── created_at / updated_at (TIMESTAMP)
│   │   └── Trigger: users_audit_trigger
│   │
│   ├── Table: items
│   │   ├── id (BIGSERIAL, PK)
│   │   ├── user_id (UUID, FK → users.id)
│   │   ├── name (VARCHAR 512)
│   │   ├── description (TEXT)
│   │   ├── embedding (vector(1536))  ← OpenAI embeddings
│   │   ├── created_at / updated_at (TIMESTAMP)
│   │   ├── Index: idx_items_user_id
│   │   ├── Index: idx_items_embedding (IVFFLAT, lists=100)
│   │   └── Trigger: items_audit_trigger
│   │
│   ├── Table: sessions
│   │   ├── id (UUID, PK, auto-generated)
│   │   ├── user_id (UUID, FK → users.id)
│   │   ├── token (VARCHAR 512, UNIQUE)
│   │   ├── expires_at (TIMESTAMP)
│   │   ├── created_at (TIMESTAMP)
│   │   ├── Index: idx_sessions_user_id
│   │   ├── Index: idx_sessions_expires_at
│   │   └── Trigger: sessions_audit_trigger
│   │
│   ├── Table: products
│   │   ├── id (UUID, PK, auto-generated)
│   │   ├── name (VARCHAR 255, NOT NULL)
│   │   ├── description (TEXT)
│   │   ├── price (DECIMAL 10,2, NOT NULL)
│   │   ├── stock_quantity (INTEGER, default 0)
│   │   ├── created_at / updated_at (TIMESTAMP)
│   │   ├── Index: idx_products_name
│   │   ├── Index: idx_products_price
│   │   └── Trigger: products_audit_trigger
│   │
│   ├── Table: databasechangelog  (Liquibase — 11 rows after full run)
│   └── Table: databasechangeloglock  (Liquibase advisory lock)
│
├── Schema: audit
│   ├── Table: audit_log
│   │   ├── id (BIGSERIAL, PK)
│   │   ├── table_name / operation (VARCHAR)
│   │   ├── old_data / new_data (JSONB)
│   │   ├── changed_at (TIMESTAMP)
│   │   ├── Index: idx_audit_log_table
│   │   └── Index: idx_audit_log_changed_at
│   └── Function: audit_trigger_func()  (plpgsql TRIGGER)
│
└── Extensions
    ├── vector (pgvector) — similarity search
    ├── pg_stat_statements — query analytics
    ├── pgcrypto — cryptographic functions
    └── uuid-ossp — UUID generation
```

## Deployment Timeline

```text
Time  Event
──────────────────────────────────────────────────────────
0s    terraform apply starts
      └─ docker build Dockerfile.liquibase (lpm add postgresql)

~10s  liquibase-migrations container starts
      └─ liquibase-entrypoint.sh begins

~10s  Wait for PgBouncer :6432 (postgres_liquibase pool)
      ├─ Retry until PgBouncer reports ready
      └─ Ensures session pool for advisory lock support

~120s Patroni primary elected (pg-node-1)
      ├─ pg_is_in_recovery() = false on pg-node-1
      └─ Replicas streaming

~121s Execute: liquibase update (11 changesets)
      ├─ 01-init-schema     : audit schema + trigger function  (~300ms)
      ├─ 02-add-extensions  : 4 extensions                    (~600ms)
      ├─ 03-create-tables   : 4 tables + indexes + triggers   (~800ms)
      └─ 04-add-products    : products table + indexes        (~300ms)

~123s Write 11 rows to databasechangelog

~123s Schema replicates to pg-node-2 and pg-node-3 via WAL

~124s Container exits — Exit code 0
      docker ps -a shows: Exited (0)
```

## Failover Scenario

```mermaid
sequenceDiagram
    participant E as etcd
    participant PG1 as pg-node-1 (was primary)
    participant PG2 as pg-node-2
    participant PG3 as pg-node-3
    participant PGB as PgBouncer

    Note over PG1: T+0s — pg-node-1 fails
    PG1--xE: heartbeat lost
    E->>PG2: leader lock expires, election
    E->>PG3: leader lock expires, election
    Note over PG2: T+4s — pg-node-2 wins election
    PG2->>E: acquire leader lock
    PG2->>PGB: new primary announcement
    PGB->>PG2: redirect connections

    Note over PG1: T+10s — pg-node-1 recovers
    PG1->>PG2: rejoin as replica
    Note over PG1,PG3: All 3 nodes healthy\ndatabasechangelog intact on pg-node-2\nno re-migration needed
```

---

**Key Takeaways:**

- Liquibase connects via the `postgres_liquibase` **session-mode** PgBouncer pool — never directly to PostgreSQL. This ensures advisory locks work and routing always hits the primary.
- All 11 changesets execute on the primary, then replicate automatically to standbys via WAL.
- Failover does not affect migration history — `databasechangelog` is replicated.
- Re-running `terraform apply` is safe: Liquibase skips already-executed changesets.
- `04-add-products.yml` includes rollback blocks — use `rollback-count 1` to revert.
