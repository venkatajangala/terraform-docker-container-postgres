# Liquibase + HA PostgreSQL - Quick Reference

## Deploy

```bash
# Enable Liquibase and deploy HA cluster
terraform apply \
  -var="liquibase_enabled=true" \
  -var="postgres_password=$(openssl rand -base64 32)"

# Monitor migrations
docker logs -f liquibase-migrations
```

## Verify

```bash
# Run verification script
./verify-liquibase.sh

# Check migration status
docker exec liquibase-migrations \
  liquibase --changeLogFile=changelog/db.changelog-master.yml status

# Query applied changesets
psql -h localhost -p 5432 -U pgadmin -d postgres \
  -c "SELECT id, author, dateexecuted FROM public.databasechangelog ORDER BY orderexecuted DESC;"
```

## Add New Migration

### 1. Create Migration File

```bash
cat > liquibase/changelog/04-add-products.yml << 'EOF'
databaseChangeLog:
  changeSet:
    - id: 1-create-products-table
      author: dev-team
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
EOF
```

### 2. Update Master Changelog

```bash
cat >> liquibase/changelog/db.changelog-master.yml << 'EOF'
    - include:
        file: changelog/04-add-products.yml
EOF
```

### 3. Deploy

```bash
# Rebuild and apply
terraform apply -var="liquibase_enabled=true"

# Monitor
docker logs -f liquibase-migrations
```

## Common Tasks

### View All Migrations

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
SELECT 
  id, 
  author, 
  dateexecuted, 
  description,
  execstatus
FROM public.databasechangelog
ORDER BY orderexecuted DESC;
EOF
```

### View Audit Trail

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
SELECT 
  table_name,
  operation,
  changed_at,
  jsonb_pretty(new_data) as changes
FROM audit.audit_log
ORDER BY changed_at DESC
LIMIT 10;
EOF
```

### Rollback Latest

```bash
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml rollbackCount 1
EOF
```

### Disable Auto-Run

Edit `variables-ha.tf` and set `liquibase_auto_run = false`, then:

```bash
terraform apply -var="liquibase_auto_run=false"
```

To manually run later:

```bash
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml update
EOF
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Container exits immediately | Check `docker logs liquibase-migrations` for PostgreSQL connection errors |
| "Database not ready" | Wait 30-60s for Patroni to elect primary and replicas to sync |
| Changelog file not found | Verify `liquibase/changelog/` directory exists with all YAML files |
| Permission denied | Run `chmod +x liquibase-entrypoint.sh` |
| Partial migration failure | Check `databasechangelog` table for failed changesets; manual intervention required |

## Files Overview

| File | Purpose |
|------|---------|
| `Dockerfile.liquibase` | Build Liquibase image with PostgreSQL driver |
| `liquibase-entrypoint.sh` | Wait for DB readiness, execute migrations |
| `main-liquibase.tf` | Terraform resource definitions |
| `variables-ha.tf` | Added Liquibase variables (liquibase_enabled, memory, retries) |
| `liquibase/liquibase.properties` | Liquibase configuration |
| `liquibase/changelog/db.changelog-master.yml` | Master changelog includes |
| `liquibase/changelog/01-init-schema.yml` | Audit schema + trigger function |
| `liquibase/changelog/02-add-extensions.yml` | pgvector, pg_stat_statements, pgcrypto, uuid-ossp |
| `liquibase/changelog/03-create-tables.yml` | Users, items, sessions tables with audit triggers |
| `LIQUIBASE-INTEGRATION.md` | Detailed documentation |
| `verify-liquibase.sh` | Deployment verification script |

## Environment Variables

```bash
# Set before terraform apply
export TF_VAR_liquibase_enabled=true
export TF_VAR_liquibase_memory_mb=512
export TF_VAR_liquibase_max_retries=30
export TF_VAR_liquibase_retry_interval=5
```

## Integration Points

### With HA Cluster
- Connects to `pg-node-1` (primary) via Patroni
- Waits for primary election before running migrations
- Migrations replicate to standby nodes automatically
- No impact on failover or replica status

### With Existing Schema
- Idempotent: Uses `IF NOT EXISTS` to prevent duplicates
- Non-blocking: Runs after cluster health checks
- Rollback-compatible: Each changeset has rollback logic
- Audit-enabled: All DDL/DML tracked in `audit.audit_log`

## Advanced Usage

### Dry Run (Validate Without Executing)

```bash
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase \
  --changeLogFile=db.changelog-master.yml \
  --verbose \
  status
EOF
```

### Generate SQL Preview

```bash
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase \
  --changeLogFile=db.changelog-master.yml \
  updateSQL > /tmp/migration.sql
cat /tmp/migration.sql
EOF
```

### Run Specific Changeset

```bash
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase \
  --changeLogFile=db.changelog-master.yml \
  runWith=liquibase.CommandLineResourceAccessor \
  tag v1.0.0-pre
EOF
```

## Monitoring

```bash
# Watch container logs in real-time
docker logs -f liquibase-migrations

# Get container stats
docker stats liquibase-migrations

# Check applied migrations (SQL)
docker exec -it liquibase-migrations psql \
  -h pg-node-1 \
  -U postgres \
  -d postgres \
  -c "SELECT * FROM databasechangelog ORDER BY orderexecuted DESC;"
```

## Performance Impact

- **CPU**: Minimal (migration execution time ~1-2 seconds per changeset)
- **Memory**: ~512MB (configurable via `liquibase_memory_mb`)
- **I/O**: Sequential writes to primary, then replicated
- **Replication Lag**: Typically <1s for schema changes
- **No Downtime**: Container runs after cluster is ready; clients unaffected

---

For full documentation, see `LIQUIBASE-INTEGRATION.md`
