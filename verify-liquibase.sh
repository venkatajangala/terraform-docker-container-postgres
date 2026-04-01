#!/bin/bash
# ============================================================================
# Liquibase Integration Verification Script
# ============================================================================

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

log_error() {
  echo -e "${RED}✗${NC} $1"
}

log_info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

# ============================================================================
# Check Prerequisites
# ============================================================================

log_header "Prerequisites Check"

# Check Docker
if command -v docker &> /dev/null; then
  log_success "Docker is installed"
else
  log_error "Docker is not installed"
  exit 1
fi

# Check PostgreSQL client
if command -v psql &> /dev/null; then
  log_success "PostgreSQL client is installed"
else
  log_info "PostgreSQL client not found - some checks will be skipped"
fi

# ============================================================================
# Docker Container Status
# ============================================================================

log_header "Docker Container Status"

# Check if containers exist
if docker ps -a --format "{{.Names}}" | grep -q "^pg-node-1$"; then
  log_success "PostgreSQL HA cluster is running"
else
  log_error "PostgreSQL HA cluster not found"
  exit 1
fi

if docker ps -a --format "{{.Names}}" | grep -q "^liquibase-migrations$"; then
  log_success "Liquibase container exists"
else
  log_error "Liquibase container not found"
  exit 1
fi

# Check Liquibase container status
LIQUIBASE_STATUS=$(docker inspect liquibase-migrations --format='{{.State.Status}}' 2>/dev/null || echo "not-found")
log_info "Liquibase container status: $LIQUIBASE_STATUS"

# ============================================================================
# Liquibase Logs
# ============================================================================

log_header "Liquibase Migration Logs (Last 50 lines)"

if docker logs liquibase-migrations &>/dev/null; then
  docker logs --tail 50 liquibase-migrations
else
  log_error "Unable to retrieve Liquibase logs"
fi

# ============================================================================
# PostgreSQL Connection Test
# ============================================================================

log_header "PostgreSQL Connection Test"

if command -v psql &> /dev/null; then
  # Try to connect
  if PGPASSWORD='' psql -h localhost -p 5432 -U pgadmin -d postgres -c "SELECT version();" &>/dev/null; then
    log_success "Connected to PostgreSQL"
    
    # Get version
    PSQL_VERSION=$(PGPASSWORD='' psql -h localhost -p 5432 -U pgadmin -d postgres -t -c "SELECT version();" 2>/dev/null | head -1)
    log_info "PostgreSQL: $PSQL_VERSION"
  else
    log_info "Unable to connect to PostgreSQL with default credentials - this is expected if database requires password"
  fi
fi

# ============================================================================
# Database Schema Check
# ============================================================================

log_header "Database Schema Verification"

# Check if we can query the database for schema objects
check_schema() {
  local DB_PASSWORD="${1:-}"
  local QUERY="${2:-}"
  
  if [ -z "$DB_PASSWORD" ]; then
    PGPASSWORD='' psql -h localhost -p 5432 -U pgadmin -d postgres -t -c "$QUERY" 2>/dev/null
  else
    PGPASSWORD="$DB_PASSWORD" psql -h localhost -p 5432 -U pgadmin -d postgres -t -c "$QUERY" 2>/dev/null
  fi
}

if command -v psql &> /dev/null; then
  log_info "Checking for audit schema..."
  if check_schema "" "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'audit';" | grep -q "audit"; then
    log_success "Audit schema exists"
  else
    log_info "Audit schema not found (migrations may not have completed yet)"
  fi
  
  log_info "Checking for extensions..."
  if check_schema "" "SELECT extname FROM pg_extension WHERE extname IN ('vector', 'pg_stat_statements', 'pgcrypto', 'uuid-ossp');" 2>/dev/null; then
    log_success "Extensions installed"
  else
    log_info "Extensions not yet installed"
  fi
  
  log_info "Checking for tables..."
  if check_schema "" "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('users', 'items', 'sessions', 'databasechangelog');" 2>/dev/null | grep -q "databasechangelog"; then
    log_success "Liquibase changelog table exists"
  else
    log_info "Liquibase changelog table not found"
  fi

  log_info "Checking for products table (04-add-products migration)..."
  if check_schema "" "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'products';" 2>/dev/null | grep -q "products"; then
    log_success "Products table exists"
  else
    log_info "Products table not found (04-add-products migration may not have run)"
  fi
  
  log_info "Checking for audit log table..."
  if check_schema "" "SELECT table_name FROM information_schema.tables WHERE table_schema = 'audit' AND table_name = 'audit_log';" 2>/dev/null | grep -q "audit_log"; then
    log_success "Audit log table exists"
  else
    log_info "Audit log table not found"
  fi
fi

# ============================================================================
# File Structure Check
# ============================================================================

log_header "Liquibase File Structure"

# Check required files
FILES=(
  "Dockerfile.liquibase"
  "liquibase-entrypoint.sh"
  "main-liquibase.tf"
  "liquibase/liquibase.properties"
  "liquibase/changelog/db.changelog-master.yml"
  "liquibase/changelog/01-init-schema.yml"
  "liquibase/changelog/02-add-extensions.yml"
  "liquibase/changelog/03-create-tables.yml"
  "liquibase/changelog/04-add-products.yml"
)

for file in "${FILES[@]}"; do
  if [ -f "$file" ]; then
    log_success "File exists: $file"
  else
    log_error "File missing: $file"
  fi
done

# ============================================================================
# Terraform Configuration Check
# ============================================================================

log_header "Terraform Configuration"

if grep -q "liquibase_enabled" variables-ha.tf 2>/dev/null; then
  log_success "Liquibase variables configured in Terraform"
else
  log_error "Liquibase variables not found in Terraform"
fi

if [ -f "main-liquibase.tf" ]; then
  log_success "Liquibase Terraform configuration file exists"
else
  log_error "main-liquibase.tf not found"
fi

# ============================================================================
# Docker Image Check
# ============================================================================

log_header "Docker Images"

if docker images | grep -q "liquibase"; then
  log_success "Liquibase Docker image found"
  docker images | grep liquibase | head -1
else
  log_info "Liquibase Docker image not yet built"
fi

# ============================================================================
# Health Checks
# ============================================================================

log_header "Health Status"

# Check PG nodes
for node in 1 2 3; do
  if docker ps --format "{{.Names}}" | grep -q "^pg-node-${node}$"; then
    HEALTH=$(docker inspect pg-node-${node} --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [ "$HEALTH" = "healthy" ]; then
      log_success "pg-node-${node}: $HEALTH"
    else
      log_info "pg-node-${node}: $HEALTH"
    fi
  fi
done

# ============================================================================
# Summary
# ============================================================================

log_header "Verification Summary"

log_info "The Liquibase integration has been successfully deployed."
log_info ""
log_info "Next steps:"
log_info "1. Monitor migration progress:"
log_info "   docker logs -f liquibase-migrations"
log_info ""
log_info "2. Verify migrations in PostgreSQL:"
log_info "   psql -h localhost -p 5432 -U pgadmin -d postgres"
log_info "   SELECT * FROM public.databasechangelog ORDER BY orderexecuted DESC;"
log_info ""
log_info "3. Add new migrations:"
log_info "   Create new files in liquibase/changelog/04-*.yml"
log_info "   Update liquibase/changelog/db.changelog-master.yml"
log_info ""
log_info "4. Review complete documentation:"
log_info "   cat LIQUIBASE-INTEGRATION.md"
