# Liquibase Integration with HA PostgreSQL

## Overview

This integration adds **Liquibase 5.0.1** database migration management to your existing HA PostgreSQL cluster. Liquibase provides:

- **Version Control** for schema changes
- **Rollback Support** for failed migrations
- **Multi-environment Support** (dev, staging, production)
- **Audit Trail** of all database changes
- **Safe Deployments** with validation before execution

## Architecture

```
┌─────────────────┐
│ Liquibase 5.0.1 │ (Migration Engine)
│  Container      │
└────────┬────────┘
         │ (JDBC Driver)
         │ (Wait for Primary)
         ▼
┌─────────────────┐
│  Patroni Primary│ (pg-node-1)
│  (PostgreSQL)   │
└────────┬────────┘
         │ (Replication)
         ▼
┌─────────────────┐
│  Patroni Replicas
│  (Standby Nodes)
└─────────────────┘
```

## File Structure

```
.
├── Dockerfile.liquibase              # Liquibase Docker image definition
├── liquibase-entrypoint.sh           # Entrypoint script for container
├── main-liquibase.tf                 # Terraform configuration for Liquibase
├── liquibase/
│   ├── liquibase.properties          # Liquibase configuration file
│   └── changelog/
│       ├── db.changelog-master.yml   # Master changelog (includes all migrations)
│       ├── 01-init-schema.yml        # Schema initialization (audit schema)
│       ├── 02-add-extensions.yml     # PostgreSQL extensions setup
│       └── 03-create-tables.yml      # Application tables with pgvector support
```

## Quick Start

### 1. Deploy with Terraform

The Liquibase container is automatically built and deployed as part of your HA cluster:

```bash
# Enable Liquibase (default: enabled)
terraform apply -var="liquibase_enabled=true"
```

### 2. Monitor Migration Progress

```bash
# View Liquibase container logs
docker logs liquibase-migrations

# Check migration status
docker inspect liquibase-migrations --format='{{.State.Status}}'
```

### 3. Verify Migrations

Connect to PostgreSQL and verify schema:

```bash
# Connect to primary node
psql -h localhost -p 5432 -U pgadmin -d postgres

# List all tables
\dt

# Check audit log
SELECT * FROM audit.audit_log;

# Verify extensions
SELECT extname FROM pg_extension;
```

## Changelog Structure

### Master Changelog (`db.changelog-master.yml`)

Aggregates all migration files in order:

```yaml
databaseChangeLog:
  logicalFilePath: db.changelog-master
  changeSet:
    - include:
        file: changelog/01-init-schema.yml
    - include:
        file: changelog/02-add-extensions.yml
    - include:
        file: changelog/03-create-tables.yml
```

### Migration Files

Each changelog file contains versioned `changeSet` entries:

```yaml
databaseChangeLog:
  logicalFilePath: 01-init-schema
  changeSet:
    - id: 1-create-audit-schema
      author: liquibase
      description: Create audit schema
      changes:
        - sql:
            sql: CREATE SCHEMA IF NOT EXISTS audit;
      rollback:
        - sql:
            sql: DROP SCHEMA IF EXISTS audit CASCADE;
```

## Included Migrations

### 01-init-schema.yml
- Creates `audit` schema for change tracking
- Creates `audit.audit_trigger_func()` for DML logging

### 02-add-extensions.yml
- `vector` - pgvector for embeddings (1536-dim OpenAI support)
- `pg_stat_statements` - Query performance monitoring
- `pgcrypto` - Cryptographic functions
- `uuid-ossp` - UUID generation

### 03-create-tables.yml

**audit.audit_log**
- Tracks all INSERT/UPDATE/DELETE operations
- Stores old/new data as JSONB
- Indexed on table_name and changed_at

**public.users**
- UUID primary key with auto-generation
- Unique constraints on username and email
- Audit triggers enabled

**public.items** (with vector support)
- Links to users via foreign key
- 1536-dimensional OpenAI embeddings
- IVFFLAT vector index for similarity search
- Audit triggers enabled

**public.sessions**
- Session tokens and expiration tracking
- User foreign key with cascade
- Indexes on user_id and expires_at

## Environment Variables

### Database Connection
- `DB_HOST` - PostgreSQL host (default: pg-node-1)
- `DB_PORT` - PostgreSQL port (default: 5432)
- `DB_NAME` - Database name (default: postgres)
- `DB_USER` - Database user (default: postgres)
- `DB_PASSWORD` - Database password (required)

### Retry Configuration
- `MAX_RETRIES` - Retry attempts (default: 30)
- `RETRY_INTERVAL` - Seconds between retries (default: 5)

### Liquibase Options
- `LIQUIBASE_CHANGELOG_FILE` - Changelog file path
- `LIQUIBASE_DRIVER_CLASS_NAME` - JDBC driver class
- `LIQUIBASE_URL` - JDBC URL
- `LIQUIBASE_USERNAME` - Database user
- `LIQUIBASE_PASSWORD` - Database password

## Adding New Migrations

### Step 1: Create New Changelog File

```bash
# Create new migration file in liquibase/changelog/
cat > liquibase/changelog/04-add-new-feature.yml << 'EOF'
databaseChangeLog:
  logicalFilePath: 04-add-new-feature
  changeSet:
    - id: 1-create-products-table
      author: your-name
      description: Create products table
      changes:
        - createTable:
            tableName: products
            columns:
              - column:
                  name: id
                  type: UUID
                  defaultValueComputed: gen_random_uuid()
                  constraints:
                    primaryKey: true
              - column:
                  name: name
                  type: VARCHAR(255)
                  constraints:
                    nullable: false
              - column:
                  name: price
                  type: DECIMAL(10,2)
                  constraints:
                    nullable: false
EOF
```

### Step 2: Add to Master Changelog

```yaml
# Edit liquibase/changelog/db.changelog-master.yml
databaseChangeLog:
  logicalFilePath: db.changelog-master
  changeSet:
    - include:
        file: changelog/01-init-schema.yml
    - include:
        file: changelog/02-add-extensions.yml
    - include:
        file: changelog/03-create-tables.yml
    - include:
        file: changelog/04-add-new-feature.yml  # Add new file here
```

### Step 3: Deploy Migration

```bash
# Rebuild and deploy
terraform apply -var="liquibase_enabled=true"

# Monitor progress
docker logs -f liquibase-migrations

# Verify in PostgreSQL
psql -h localhost -p 5432 -U pgadmin -d postgres -c "\\dt"
```

## Viewing Migration History

### Liquibase History

```sql
-- Connect to PostgreSQL
psql -h localhost -p 5432 -U pgadmin -d postgres

-- View all applied changes
SELECT * FROM public.databasechangelog
ORDER BY orderexecuted DESC;

-- View change details
SELECT id, author, dateexecuted, description 
FROM public.databasechangelog
ORDER BY dateexecuted DESC;
```

### Audit Trail

```sql
-- View all database changes
SELECT * FROM audit.audit_log
ORDER BY changed_at DESC
LIMIT 20;

-- View changes to specific table
SELECT * FROM audit.audit_log
WHERE table_name = 'users'
ORDER BY changed_at DESC;

-- View operations by type
SELECT operation, COUNT(*) as count
FROM audit.audit_log
GROUP BY operation;
```

## Rollback Operations

### Rollback Last Migration

```bash
# Connect to Liquibase container
docker exec -it liquibase-migrations bash

# Count changesets
liquibase --changeLogFile=changelog/db.changelog-master.yml \
          status

# Rollback to specific changeset
liquibase --changeLogFile=changelog/db.changelog-master.yml \
          rollbackCount 1
```

### Rollback to Specific Date

```bash
liquibase --changeLogFile=changelog/db.changelog-master.yml \
          rollbackToDate 2024-01-15T10:00:00
```

## Configuration Files

### liquibase.properties

Standard Liquibase properties file. For production deployments, override with environment variables:

```properties
driver: org.postgresql.Driver
url: jdbc:postgresql://pg-node-1:5432/postgres
username: postgres
password: ${POSTGRES_PASSWORD}
changeLogFile: changelog/db.changelog-master.yml
logLevel: info
```

## Troubleshooting

### Container Exits Immediately

```bash
# Check logs
docker logs liquibase-migrations

# Common issues:
# 1. PostgreSQL not ready - wait 30-60 seconds for cluster startup
# 2. Changelog file not found - verify liquibase/changelog/ directory
# 3. Database connection error - verify DB_HOST, DB_PORT, DB_PASSWORD
```

### Failed Migration

```bash
# View error details
docker logs liquibase-migrations | grep -i error

# In case of partial failure, Liquibase maintains state in:
SELECT * FROM public.databasechangelog
WHERE execstatus = 'failed';

# Manual intervention may be required
```

### Verify Migrations Applied

```bash
# Check applied changesets
docker exec liquibase-migrations \
  liquibase --changeLogFile=changelog/db.changelog-master.yml \
            status

# Expected output shows all changesets marked as EXECUTED
```

## Best Practices

1. **One Change Per ChangeSet**: Keep each logical change in its own changeset for granular rollback control

2. **Always Include Rollback**: Provide rollback logic for every changeset

3. **Idempotent Operations**: Use `IF NOT EXISTS` and `IF EXISTS` to prevent errors on re-runs

4. **Test Migrations**: Test in staging environment before deploying to production

5. **Version Control**: Track all changelog files in Git with descriptive commit messages

6. **Audit Trail**: Review `audit.audit_log` for compliance and troubleshooting

7. **Documentation**: Add descriptions to changesets explaining the business purpose

## Performance Considerations

- **Vector Indexes**: IVFFLAT with 100 lists optimized for OpenAI embeddings (1536 dims)
- **Audit Logging**: Triggers on all user and items tables - may impact write performance
- **Database Locks**: Migration container runs sequentially - no parallel execution
- **Primary Node Only**: All migrations execute on primary node before replicating to standby

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Deploy Database Migrations

on: [push]

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Deploy HA PostgreSQL + Liquibase
        run: |
          terraform apply \
            -var="liquibase_enabled=true" \
            -var="postgres_password=${{ secrets.DB_PASSWORD }}"
            
      - name: Verify Migrations
        run: |
          docker exec liquibase-migrations \
            liquibase status
```

## References

- [Liquibase Documentation](https://docs.liquibase.com/)
- [Liquibase Best Practices](https://docs.liquibase.com/concepts/bestpractices.html)
- [pgvector Documentation](https://github.com/pgvector/pgvector)
- [PostgreSQL Replication](https://www.postgresql.org/docs/18/warm-standby.html)
- [Patroni Documentation](https://patroni.readthedocs.io/)
