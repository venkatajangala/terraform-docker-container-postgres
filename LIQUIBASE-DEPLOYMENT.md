# Liquibase Integration - Deployment Guide

## Overview

This guide walks you through integrating and deploying Liquibase 5.0.1 with your existing HA PostgreSQL infrastructure.

## Prerequisites

- Docker installed and running
- Terraform installed (v1.0+)
- PostgreSQL client tools (psql) - optional but recommended
- Existing HA PostgreSQL cluster (Patroni + etcd)

## Installation & Deployment

### Step 1: Verify Files Are in Place

```bash
# Check that all Liquibase files exist
ls -la Dockerfile.liquibase
ls -la liquibase-entrypoint.sh
ls -la main-liquibase.tf
ls -la liquibase/changelog/

# Expected output:
# -rw-r--r-- Dockerfile.liquibase
# -rwxr-xr-x liquibase-entrypoint.sh
# -rw-r--r-- main-liquibase.tf
# -rw-r--r-- liquibase/liquibase.properties
# -rw-r--r-- liquibase/changelog/db.changelog-master.yml
# -rw-r--r-- liquibase/changelog/01-init-schema.yml
# -rw-r--r-- liquibase/changelog/02-add-extensions.yml
# -rw-r--r-- liquibase/changelog/03-create-tables.yml
```

### Step 2: Review Variables

Open `variables-ha.tf` and verify Liquibase configuration:

```hcl
variable "liquibase_enabled" {
  type        = bool
  default     = true
  description = "Enable Liquibase database migration container"
}

variable "liquibase_memory_mb" {
  type        = number
  default     = 512
  description = "Memory limit for Liquibase migration container (MB)"
}

variable "liquibase_max_retries" {
  type        = number
  default     = 30
  description = "Maximum retry attempts for Liquibase to connect to PostgreSQL"
}

variable "liquibase_retry_interval" {
  type        = number
  default     = 5
  description = "Retry interval in seconds for Liquibase connection attempts"
}

variable "liquibase_auto_run" {
  type        = bool
  default     = true
  description = "Automatically run Liquibase migrations on container startup"
}
```

### Step 3: Deploy Infrastructure

**Option A: Deploy Everything (Recommended for Fresh Start)**

```bash
# Generate secure password
DB_PASSWORD=$(openssl rand -base64 32)

# Deploy with Liquibase enabled
terraform apply \
  -var="liquibase_enabled=true" \
  -var="postgres_password=$DB_PASSWORD"

# Save password for later
echo "DB_PASSWORD=$DB_PASSWORD" > .env.local
chmod 600 .env.local
```

**Option B: Add Liquibase to Existing Deployment**

If you already have the HA cluster running:

```bash
# Check current status
terraform state list | grep docker_container

# Enable Liquibase
terraform apply -var="liquibase_enabled=true"
```

### Step 4: Monitor Deployment

```bash
# Watch Liquibase container logs
docker logs -f liquibase-migrations

# Expected output:
# [INFO] Liquibase Migration Container Started
# [INFO] Waiting for PostgreSQL at pg-node-1:5432...
# [INFO] PostgreSQL is ready!
# [INFO] Waiting for Patroni primary to be elected...
# [INFO] Patroni primary is ready and accepting writes
# [INFO] Changelog file verified: /liquibase/changelog/db.changelog-master.yml
# [INFO] Starting Liquibase migrations...
# Starting Liquibase at [timestamp]
# ...
# [INFO] Liquibase migrations completed successfully
```

### Step 5: Verify Migrations

```bash
# Run verification script
./verify-liquibase.sh

# Check migration history
docker exec liquibase-migrations \
  bash -c "cd /liquibase/changelog && \
  liquibase --changeLogFile=db.changelog-master.yml status"

# Expected: All changesets marked as EXECUTED
```

## Connecting to PostgreSQL

### Connect to Primary Node

```bash
# Using password from environment
psql -h localhost -p 5432 \
     -U pgadmin \
     -d postgres

# Or with explicit password
PGPASSWORD="$DB_PASSWORD" psql \
  -h localhost -p 5432 \
  -U pgadmin \
  -d postgres
```

### Query Applied Migrations

```bash
# Inside psql
SELECT 
  id,
  author,
  dateexecuted,
  description,
  execstatus
FROM public.databasechangelog
ORDER BY orderexecuted DESC;
```

### Check Schema Objects

```bash
-- List schemas
SELECT schema_name FROM information_schema.schemata;

-- List extensions
SELECT extname FROM pg_extension;

-- List tables in public schema
\dt public.*

-- View audit log entries
SELECT * FROM audit.audit_log LIMIT 10;
```

## Verifying Each Migration

### 1. Audit Schema (01-init-schema.yml)

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
-- Check audit schema
SELECT schema_name FROM information_schema.schemata 
WHERE schema_name = 'audit';

-- Check trigger function
SELECT proname, pg_get_functiondef(oid) 
FROM pg_proc 
WHERE proname = 'audit_trigger_func' 
AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'audit');
EOF
```

### 2. Extensions (02-add-extensions.yml)

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
-- List installed extensions
SELECT extname, extversion FROM pg_extension 
WHERE extname IN ('vector', 'pg_stat_statements', 'pgcrypto', 'uuid-ossp')
ORDER BY extname;

-- Expected: 4 rows with vector, pg_stat_statements, pgcrypto, uuid-ossp
EOF
```

### 3. Tables (03-create-tables.yml)

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
-- List application tables
SELECT tablename FROM pg_tables 
WHERE schemaname = 'public'
AND tablename IN ('users', 'items', 'sessions', 'audit_log');

-- Check table structure
\d users
\d items
\d sessions
\d audit.audit_log

-- Verify indexes
SELECT indexname FROM pg_indexes 
WHERE tablename IN ('users', 'items', 'sessions')
AND schemaname = 'public';
EOF
```

## Testing Audit Triggers

Verify audit logging is working:

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
-- Insert a test user
INSERT INTO users (username, email, password_hash)
VALUES ('test_user', 'test@example.com', 'hashed_password')
ON CONFLICT (email) DO NOTHING;

-- Check audit log
SELECT 
  table_name,
  operation,
  new_data,
  changed_at
FROM audit.audit_log
WHERE table_name = 'users'
ORDER BY changed_at DESC
LIMIT 1;

-- Expected: One INSERT entry with new_data showing the user record
EOF
```

## Testing Vector Functionality

If you have OpenAI embeddings:

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
-- Get a test user
WITH test_user AS (
  SELECT id FROM users LIMIT 1
)
-- Insert test item with embedding
INSERT INTO items (user_id, name, description, embedding)
SELECT 
  id,
  'Test Item',
  'This is a test item for vector search',
  '[0.1, 0.2, 0.3, ...]'::vector(1536)  -- Replace with actual 1536-dim vector
FROM test_user;

-- Verify vector index
SELECT indexname FROM pg_indexes 
WHERE tablename = 'items' 
AND indexname LIKE '%embedding%';
EOF
```

## Rollback Procedures

### Scenario 1: Immediate Rollback (Before Verification)

If migrations fail immediately:

```bash
# Check error logs
docker logs liquibase-migrations

# Rebuild and re-run
terraform destroy -target=docker_container.liquibase[0]
terraform apply -var="liquibase_enabled=true"
```

### Scenario 2: Partial Failure Detection

```bash
# Check for failed changesets
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
SELECT * FROM public.databasechangelog 
WHERE execstatus != 'executed';
EOF
```

### Scenario 3: Rollback Last Migration

```bash
# Identify which changeset to rollback
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml status | tail -20
EOF

# Rollback last changeset
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml rollbackCount 1
EOF

# Verify
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml status
EOF
```

## Customization

### Adjust Resource Limits

```bash
# Increase memory for large migrations
terraform apply \
  -var="liquibase_enabled=true" \
  -var="liquibase_memory_mb=1024"

# Increase retry attempts for slower clusters
terraform apply \
  -var="liquibase_enabled=true" \
  -var="liquibase_max_retries=60"
```

### Disable Auto-Run

For testing/staging where you want manual control:

```bash
# Deploy without auto-running migrations
terraform apply \
  -var="liquibase_enabled=true" \
  -var="liquibase_auto_run=false"

# Later, manually trigger
docker exec liquibase-migrations bash << 'EOF'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml update
EOF
```

## Adding Custom Migrations

### Create New Migration

```bash
# Create migration file
cat > liquibase/changelog/04-add-custom-schema.yml << 'EOF'
databaseChangeLog:
  logicalFilePath: 04-add-custom-schema
  changeSet:
    - id: 1-create-custom-table
      author: your-team
      description: Create custom application table
      changes:
        - createTable:
            tableName: custom_table
            columns:
              - column:
                  name: id
                  type: UUID
                  defaultValueComputed: gen_random_uuid()
                  constraints:
                    primaryKey: true
              - column:
                  name: data
                  type: JSONB
                  constraints:
                    nullable: false
      rollback:
        - dropTable:
            tableName: custom_table
EOF
```

### Include in Master Changelog

```bash
# Update master file
cat >> liquibase/changelog/db.changelog-master.yml << 'EOF'
    - include:
        file: changelog/04-add-custom-schema.yml
EOF
```

### Deploy

```bash
# Reapply Terraform
terraform apply -var="liquibase_enabled=true"

# Monitor
docker logs -f liquibase-migrations
```

## Cleanup

### Disable Liquibase (Keep Data)

```bash
terraform apply -var="liquibase_enabled=false"

# This removes the migration container but keeps applied migrations in databasechangelog table
```

### Full Cleanup (Destructive)

```bash
# Remove Liquibase container and image
terraform destroy -target=docker_container.liquibase[0]
terraform destroy -target=docker_image.liquibase[0]

# To reset migrations (requires manual SQL):
# TRUNCATE TABLE databasechangelog;
# TRUNCATE TABLE databasechangeloglock;
```

## Troubleshooting

### Issue: Container Exits Immediately

**Symptom**: `docker ps -a` shows `liquibase-migrations` with status `Exited`

**Debug**:
```bash
docker logs liquibase-migrations | tail -50
```

**Common Causes**:
- PostgreSQL not ready: Wait 30-60s
- Connection refused: Verify DB credentials in environment
- Changelog not found: Check `liquibase/changelog/` directory

### Issue: "Could not connect to PostgreSQL"

**Debug**:
```bash
# Test connectivity from container
docker exec liquibase-migrations \
  pg_isready -h pg-node-1 -p 5432 -U postgres

# Test with explicit password
docker exec liquibase-migrations bash << 'EOF'
psql -h pg-node-1 -p 5432 -U postgres -d postgres \
  -c "SELECT version();"
EOF
```

### Issue: Partial Migration Failure

**Debug**:
```bash
# Check failed changesets
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
SELECT id, dateexecuted, execstatus, description 
FROM public.databasechangelog 
WHERE execstatus = 'failed';
EOF
```

**Resolution**:
1. Review the failed changeset SQL
2. Fix the migration file
3. Either manually revert and retry, or contact database team

## Documentation

- Full documentation: `LIQUIBASE-INTEGRATION.md`
- Quick reference: `LIQUIBASE-QUICK-REFERENCE.md`
- Liquibase docs: https://docs.liquibase.com/
- PostgreSQL docs: https://www.postgresql.org/docs/18/

---

**Need help?** Run `./verify-liquibase.sh` to diagnose common issues.
