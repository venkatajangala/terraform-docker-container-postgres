#!/bin/bash
# ============================================================================
# Liquibase Integration - Example Usage Script
# ============================================================================
# This script demonstrates common Liquibase operations with your HA PostgreSQL cluster

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_header() {
  echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

# ============================================================================
# 1. Basic Deployment
# ============================================================================

example_1_deploy() {
  log_header "Example 1: Deploy Liquibase with HA PostgreSQL"
  
  cat << 'EOF'
# Generate secure password
DB_PASSWORD=$(openssl rand -base64 32)
echo "DB_PASSWORD=$DB_PASSWORD" > .env.local
chmod 600 .env.local

# Deploy HA cluster with Liquibase
terraform apply \
  -var="liquibase_enabled=true" \
  -var="postgres_password=$DB_PASSWORD"

# Monitor deployment
docker logs -f liquibase-migrations
EOF

  log_info "Command saved. Run it to deploy."
}

# ============================================================================
# 2. Monitor Migrations
# ============================================================================

example_2_monitor() {
  log_header "Example 2: Monitor Migration Progress"
  
  cat << 'EOF'
# Watch Liquibase logs in real-time
docker logs -f liquibase-migrations

# Check container status
docker ps -a | grep liquibase-migrations

# View migration history
docker exec liquibase-migrations bash << 'INNER'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml status
INNER
EOF

  log_info "These commands monitor your migrations."
}

# ============================================================================
# 3. Verify Migrations in PostgreSQL
# ============================================================================

example_3_verify_postgres() {
  log_header "Example 3: Verify Migrations in PostgreSQL"
  
  cat << 'EOF'
# Load password
source .env.local

# Connect to PostgreSQL
psql -h localhost -p 5432 -U pgadmin -d postgres

# Inside psql, run these queries:

-- View all applied migrations
SELECT 
  id,
  author,
  dateexecuted,
  description,
  execstatus
FROM public.databasechangelog
ORDER BY orderexecuted DESC;

-- Check audit schema
SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'audit';

-- Check installed extensions
SELECT extname FROM pg_extension WHERE extname IN ('vector', 'pg_stat_statements', 'pgcrypto', 'uuid-ossp');

-- List tables
\dt public.*
\dt audit.*

-- View audit log
SELECT * FROM audit.audit_log LIMIT 5;
EOF

  log_info "Use these queries to verify your database schema."
}

# ============================================================================
# 4. Test Audit Logging
# ============================================================================

example_4_test_audit() {
  log_header "Example 4: Test Audit Logging (DML Tracking)"
  
  cat << 'EOF'
# Load password and connect
source .env.local
psql -h localhost -p 5432 -U pgadmin -d postgres << 'INNER'

-- Insert a test user
INSERT INTO users (username, email, password_hash)
VALUES ('audit_test_user', 'audit_test@example.com', 'hashed_password')
ON CONFLICT (email) DO NOTHING;

-- Check the audit log
SELECT 
  table_name,
  operation,
  changed_at,
  jsonb_pretty(new_data) as new_data
FROM audit.audit_log
WHERE table_name = 'users'
ORDER BY changed_at DESC
LIMIT 1;

-- Update the user and check again
UPDATE users 
SET password_hash = 'new_hashed_password'
WHERE email = 'audit_test@example.com';

SELECT 
  operation,
  jsonb_pretty(old_data) as old_data,
  jsonb_pretty(new_data) as new_data,
  changed_at
FROM audit.audit_log
WHERE table_name = 'users' AND operation = 'UPDATE'
ORDER BY changed_at DESC
LIMIT 1;

INNER
EOF

  log_info "This demonstrates audit logging on INSERT and UPDATE operations."
}

# ============================================================================
# 5. Test Vector Search
# ============================================================================

example_5_test_vectors() {
  log_header "Example 5: Test Vector Search with pgvector"
  
  cat << 'EOF'
source .env.local
psql -h localhost -p 5432 -U pgadmin -d postgres << 'INNER'

-- Get a test user
WITH test_user AS (
  SELECT id FROM users LIMIT 1
)
-- Insert test items with embeddings
INSERT INTO items (user_id, name, description, embedding)
SELECT 
  u.id,
  'AI Documentation',
  'Vector search documentation for AI models',
  -- Sample 1536-dimensional vector (all zeros for demo)
  (array_fill(0::float4, ARRAY[1536]))::vector(1536)
FROM test_user u
ON CONFLICT DO NOTHING;

-- Verify vector index exists
SELECT indexname FROM pg_indexes 
WHERE tablename = 'items' AND indexname LIKE '%embedding%';

-- Simulate similarity search
SELECT 
  name,
  description,
  embedding <-> (array_fill(0.1::float4, ARRAY[1536]))::vector(1536) as distance
FROM items
ORDER BY distance
LIMIT 5;

INNER
EOF

  log_info "This demonstrates pgvector functionality for embeddings."
}

# ============================================================================
# 6. Add New Migration
# ============================================================================

example_6_new_migration() {
  log_header "Example 6: Add a New Migration"
  
  cat << 'EOF'
# Step 1: Create migration file
cat > liquibase/changelog/04-add-products.yml << 'INNER_EOF'
databaseChangeLog:
  logicalFilePath: 04-add-products
  changeSet:
    - id: 1-create-products-table
      author: dev-team
      description: Create products table for e-commerce
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
                    nullable: false
              - column:
                  name: name
                  type: VARCHAR(255)
                  constraints:
                    nullable: false
              - column:
                  name: description
                  type: TEXT
              - column:
                  name: price
                  type: DECIMAL(10,2)
                  constraints:
                    nullable: false
              - column:
                  name: created_at
                  type: TIMESTAMP
                  defaultValueComputed: NOW()
                  constraints:
                    nullable: false
        - createIndex:
            tableName: products
            indexName: idx_products_name
            columns:
              - column:
                  name: name
      rollback:
        - dropTable:
            tableName: products
INNER_EOF

# Step 2: Update master changelog
cat >> liquibase/changelog/db.changelog-master.yml << 'INNER_EOF'
    - include:
        file: changelog/04-add-products.yml
INNER_EOF

# Step 3: Deploy
terraform apply -var="liquibase_enabled=true"

# Step 4: Monitor
docker logs -f liquibase-migrations

# Step 5: Verify
source .env.local
psql -h localhost -p 5432 -U pgadmin -d postgres -c "\\dt public.products"
EOF

  log_info "Follow these steps to add a new migration."
}

# ============================================================================
# 7. Rollback Operations
# ============================================================================

example_7_rollback() {
  log_header "Example 7: Rollback Last Migration"
  
  cat << 'EOF'
# Step 1: View applied changesets
docker exec liquibase-migrations bash << 'INNER'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml status
INNER

# Step 2: Rollback last changeset
docker exec liquibase-migrations bash << 'INNER'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml rollbackCount 1
INNER

# Step 3: Verify rollback
docker exec liquibase-migrations bash << 'INNER'
cd /liquibase/changelog
liquibase --changeLogFile=db.changelog-master.yml status
INNER

# Step 4: Check database
source .env.local
psql -h localhost -p 5432 -U pgadmin -d postgres \
  -c "SELECT * FROM public.databasechangelog ORDER BY orderexecuted DESC LIMIT 5;"
EOF

  log_info "Use these commands to rollback the last migration."
}

# ============================================================================
# 8. View Migration History
# ============================================================================

example_8_history() {
  log_header "Example 8: View Complete Migration History"
  
  cat << 'EOF'
source .env.local
psql -h localhost -p 5432 -U pgadmin -d postgres << 'INNER'

-- Complete migration history
SELECT 
  orderexecuted as "Order",
  id as "ID",
  author as "Author",
  description as "Description",
  dateexecuted as "Executed",
  execstatus as "Status",
  execution_time as "Time (ms)"
FROM public.databasechangelog
ORDER BY orderexecuted DESC;

-- Migrations by author
SELECT 
  author,
  COUNT(*) as count,
  MAX(dateexecuted) as last_executed
FROM public.databasechangelog
GROUP BY author;

-- Recent changes
SELECT 
  dateexecuted,
  id,
  description
FROM public.databasechangelog
ORDER BY dateexecuted DESC
LIMIT 10;

INNER
EOF

  log_info "These queries show your complete migration history."
}

# ============================================================================
# 9. Audit Trail Queries
# ============================================================================

example_9_audit_trail() {
  log_header "Example 9: Review Audit Trail (Who Changed What)"
  
  cat << 'EOF'
source .env.local
psql -h localhost -p 5432 -U pgadmin -d postgres << 'INNER'

-- All changes to users table
SELECT 
  changed_at,
  operation,
  jsonb_pretty(old_data) as old_data,
  jsonb_pretty(new_data) as new_data
FROM audit.audit_log
WHERE table_name = 'users'
ORDER BY changed_at DESC;

-- Summary of changes by operation type
SELECT 
  table_name,
  operation,
  COUNT(*) as count,
  MIN(changed_at) as first_change,
  MAX(changed_at) as last_change
FROM audit.audit_log
GROUP BY table_name, operation
ORDER BY table_name, operation;

-- Specific field changes
SELECT 
  changed_at,
  operation,
  new_data -> 'email' as email,
  new_data -> 'username' as username
FROM audit.audit_log
WHERE table_name = 'users'
ORDER BY changed_at DESC;

INNER
EOF

  log_info "Use these queries to audit database changes."
}

# ============================================================================
# 10. Generate Migration SQL Preview
# ============================================================================

example_10_sql_preview() {
  log_header "Example 10: Preview Migration SQL"
  
  cat << 'EOF'
# Generate SQL for new migrations (without executing)
docker exec liquibase-migrations bash << 'INNER'
cd /liquibase/changelog
liquibase \
  --changeLogFile=db.changelog-master.yml \
  --verbose \
  updateSQL > /tmp/migration_preview.sql

cat /tmp/migration_preview.sql
INNER

# View as readable SQL
docker exec liquibase-migrations cat /tmp/migration_preview.sql | head -100
EOF

  log_info "Generate and review SQL before applying migrations."
}

# ============================================================================
# Main Menu
# ============================================================================

show_menu() {
  echo -e "\n${BLUE}Liquibase Integration - Example Usage${NC}\n"
  echo "Choose an example to display:"
  echo ""
  echo "1) Deploy Liquibase with HA PostgreSQL"
  echo "2) Monitor Migration Progress"
  echo "3) Verify Migrations in PostgreSQL"
  echo "4) Test Audit Logging"
  echo "5) Test Vector Search"
  echo "6) Add a New Migration"
  echo "7) Rollback Operations"
  echo "8) View Migration History"
  echo "9) Review Audit Trail"
  echo "10) Generate Migration SQL Preview"
  echo "11) Show All Examples"
  echo "0) Exit"
  echo ""
}

# If no argument, show interactive menu
if [ $# -eq 0 ]; then
  while true; do
    show_menu
    read -p "Enter choice [0-11]: " choice
    
    case $choice in
      1) example_1_deploy ;;
      2) example_2_monitor ;;
      3) example_3_verify_postgres ;;
      4) example_4_test_audit ;;
      5) example_5_test_vectors ;;
      6) example_6_new_migration ;;
      7) example_7_rollback ;;
      8) example_8_history ;;
      9) example_9_audit_trail ;;
      10) example_10_sql_preview ;;
      11) 
        example_1_deploy
        example_2_monitor
        example_3_verify_postgres
        example_4_test_audit
        example_5_test_vectors
        example_6_new_migration
        example_7_rollback
        example_8_history
        example_9_audit_trail
        example_10_sql_preview
        ;;
      0) log_success "Exiting"; exit 0 ;;
      *) log_info "Invalid choice" ;;
    esac
  done
else
  # Run specific example
  case $1 in
    1) example_1_deploy ;;
    2) example_2_monitor ;;
    3) example_3_verify_postgres ;;
    4) example_4_test_audit ;;
    5) example_5_test_vectors ;;
    6) example_6_new_migration ;;
    7) example_7_rollback ;;
    8) example_8_history ;;
    9) example_9_audit_trail ;;
    10) example_10_sql_preview ;;
    *) log_info "Usage: $0 [1-10]"; exit 1 ;;
  esac
fi
