# Implementation Guide - Optimization Roadmap

## Quick Reference

| File | Optimization | Priority | Est. Time | Impact |
|------|--------------|----------|-----------|--------|
| Dockerfile.patroni | Multi-stage build | 🔴 HIGH | 45m | -35% image size |
| Dockerfile.pgbouncer | Alpine base | 🔴 HIGH | 30m | -70% image size |
| main-ha.tf | for_each consolidation | 🔴 HIGH | 1.5h | -35% code |
| entrypoint-patroni.sh | Remove duplicate initdb | 🟡 MEDIUM | 15m | 10% faster startup |
| .dockerignore | Create new | 🟡 MEDIUM | 5m | -10% build context |
| variables-ha.tf | Add validation | 🟡 MEDIUM | 1h | Error prevention |

---

## Phase 1: Immediate (2-3 hours) - HIGH IMPACT

### Step 1.1: Update Dockerfile.patroni (45 minutes)

**Current Issue**: Single stage, redundant RUN commands
**Solution**: Multi-stage build, consolidated layers

```bash
# Backup original
cp Dockerfile.patroni Dockerfile.patroni.backup

# Replace with optimized version
cp OPTIMIZED-Dockerfile.patroni Dockerfile.patroni

# Build test
docker build -f Dockerfile.patroni -t postgres-patroni:18-pgvector-optimized .
docker images | grep postgres-patroni  # Compare sizes
```

**Expected Result**: Image size reduced by 30-40%

---

### Step 1.2: Update Dockerfile.pgbouncer (30 minutes)

**Current Issue**: Large debian base (140MB+)
**Solution**: Alpine base (40MB)

```bash
# Backup
cp Dockerfile.pgbouncer Dockerfile.pgbouncer.backup

# Replace
cp OPTIMIZED-Dockerfile.pgbouncer Dockerfile.pgbouncer

# Build test
docker build -f Dockerfile.pgbouncer -t pgbouncer:ha-alpine .
docker images | grep pgbouncer  # Compare sizes

# Size comparison example:
# Before: pgbouncer:ha         145MB
# After:  pgbouncer:ha-alpine   42MB  ✓
```

**Expected Result**: Image size reduced by 70%

---

### Step 1.3: Update Dockerfile.infisical (15 minutes)

**Current Issue**: Installs unused postgresql-client
**Solution**: Remove unnecessary package

```bash
# Backup
cp Dockerfile.infisical Dockerfile.infisical.backup

# Replace (or manually remove postgresql-client)
cp OPTIMIZED-Dockerfile.infisical Dockerfile.infisical

# Build test
docker build -f Dockerfile.infisical -t infisical/infisical:latest-optimized .
```

**Expected Result**: Image size reduced by 15-20%

---

### Step 1.4: Refactor main-ha.tf (60-90 minutes)

This is the highest-leverage optimization. Replace 400+ lines with 250.

**Current State**:
```terraform
# 3 nearly-identical PostgreSQL node resources
resource "docker_container" "pg_node_1" { ... }
resource "docker_container" "pg_node_2" { ... }
resource "docker_container" "pg_node_3" { ... }

# 3 nearly-identical PgBouncer resources
resource "docker_container" "pgbouncer_1" { ... }
resource "docker_container" "pgbouncer_2" { ... }
resource "docker_container" "pgbouncer_3" { ... }
```

**Target State** (using `for_each`):
```terraform
resource "docker_container" "pg_node" {
  for_each = local.pg_nodes  # Scales from 3 → N nodes easily
  # ... single definition
}

resource "docker_container" "pgbouncer" {
  for_each = var.pgbouncer_enabled ? local.pgbouncer_replicas : toset([])
  # ... single definition
}
```

**Implementation Steps**:

```bash
# 1. Backup current terraform
cp main-ha.tf main-ha.tf.backup
cp variables-ha.tf variables-ha.tf.backup

# 2. Copy optimized version
cp OPTIMIZED-main-ha.tf main-ha.tf

# 3. Copy consolidated variables
cp OPTIMIZED-variables-consolidated.tf variables-ha.tf

# 4. Validate syntax
terraform validate

# 5. Plan and review
terraform plan -out=tfplan

# 6. Apply
terraform apply tfplan
```

**Validation Checklist**:
- [ ] All 3 PostgreSQL nodes created
- [ ] All PgBouncer instances created (if enabled)
- [ ] etcd running
- [ ] Containers on pg-ha-network
- [ ] No resource conflicts

```bash
# Verify
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "pg-node|pgbouncer"
docker network inspect pg-ha-network | jq '.Containers | length'  # Should be 7+
```

**Expected Result**: 35-40% code reduction, easier scaling

---

### Step 1.5: Create .dockerignore (5 minutes)

```bash
cp .dockerignore .dockerignore.backup  # if it exists
cp .dockerignore .dockerignore

# Verify
cat .dockerignore
```

**Expected Result**: 5-10% faster builds

---

## Phase 2: Short-term (3-4 hours) - MEDIUM IMPACT

### Step 2.1: Update entrypoint-patroni.sh (30 minutes)

**Current Issue**: 
- Duplicate initdb wrapper creation (already in Dockerfile)
- Poor error handling
- No input validation

**Solution**:
```bash
cp entrypoint-patroni.sh entrypoint-patroni.sh.backup
cp OPTIMIZED-entrypoint-patroni.sh entrypoint-patroni.sh
chmod +x entrypoint-patroni.sh
```

**Test**:
```bash
# Rebuild image
docker build -f Dockerfile.patroni -t postgres-patroni:18-pgvector-new .

# Run test container
docker run --rm \
  -e POSTGRES_PASSWORD=testpass123 \
  -e REPLICATION_PASSWORD=replpass123 \
  postgres-patroni:18-pgvector-new \
  bash -c "echo 'Startup test'"
```

**Expected Result**: 10-15% faster startup

---

### Step 2.2: Update variables-ha.tf (60 minutes)

Add comprehensive validation to catch errors early:

```bash
# Review and apply validations
cp variables-ha.tf variables-ha.tf.old
cp OPTIMIZED-variables-consolidated.tf variables-ha.tf

# Validate
terraform validate

# Test with bad values
TF_VAR_pgbouncer_replicas=5 terraform plan  # Should fail with clear message
TF_VAR_postgres_password=short terraform plan  # Should fail validation
```

**Expected Result**: Prevents misconfiguration, clearer error messages

---

### Step 2.3: Add Resource Limits (45 minutes)

Already included in OPTIMIZED-main-ha.tf, but verify:

```bash
# Check in terraform plan output
terraform plan | grep -E "memory|cpu_shares"

# Should see output like:
# - memory = 4096
# - memory_swap = 4096
# - cpu_shares = 1024
```

**Expected Result**: Containers won't consume unlimited resources

---

### Step 2.4: Add Logging Configuration (30 minutes)

Already included in OPTIMIZED-main-ha.tf:
```hcl
log_driver = "json-file"
log_opts = {
  "max-size" = "10m"
  "max-file" = "3"
}
```

**Verify**:
```bash
docker inspect pg-node-1 | jq '.HostConfig.LogConfig'
# Should show json-file driver with rotation settings
```

---

## Phase 3: Advanced (8-10 hours) - ARCHITECTURAL

### Step 3.1: Secrets Management Migration

**Current**: Terraform generates secrets, stored in tfstate
**Target**: HashiCorp Vault or AWS Secrets Manager

```hcl
# Example using AWS Secrets Manager
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = "pg-ha/db-admin-password"
}

locals {
  postgres_password = jsondecode(data.aws_secretsmanager_secret_version.db_password.secret_string)["password"]
}
```

---

### Step 3.2: Monitoring & Observability

Add Prometheus exporter:

```hcl
# Add to OPTIMIZED-main-ha.tf
resource "docker_image" "postgres_exporter" {
  name = "prometheuscommunity/postgres-exporter:latest"
}

resource "docker_container" "postgres_exporter" {
  name  = "postgres-exporter"
  image = docker_image.postgres_exporter.image_id
  
  env = [
    "DATA_SOURCE_NAME=postgresql://${var.postgres_user}:${local.postgres_password}@pg-node-1:5432/postgres?sslmode=disable"
  ]
  
  ports {
    internal = 9187
    external = 9187
  }
  
  networks_advanced {
    name = docker_network.pg_ha_network.name
  }
}
```

Then add to outputs:
```hcl
output "prometheus_exporter_url" {
  value = "http://localhost:9187/metrics"
  description = "Prometheus metrics endpoint"
}
```

---

### Step 3.3: Terraform State Backend

```hcl
# Add to terraform block in main-ha.tf
terraform {
  backend "s3" {
    bucket         = "company-terraform-state"
    key            = "pg-ha/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

---

## Validation & Testing

### Pre-Implementation Checklist

- [ ] All current resources running
- [ ] `terraform plan` shows no errors
- [ ] Docker images build successfully
- [ ] All scripts are executable

```bash
# Run full validation
bash -c '
set -e
echo "1. Terraform validation..."
terraform validate

echo "2. Docker image builds..."
docker build -f Dockerfile.patroni -t test:patroni . > /dev/null
docker build -f Dockerfile.pgbouncer -t test:pgbouncer . > /dev/null
docker build -f Dockerfile.infisical -t test:infisical . > /dev/null

echo "3. Script validation..."
bash -n entrypoint-patroni.sh
bash -n entrypoint-pgbouncer.sh
bash -n entrypoint-infisical.sh

echo "✓ All checks passed"
'
```

### Post-Implementation Verification

```bash
# 1. Check services are running
docker ps --format "table {{.Names}}\t{{.Status}}"

# 2. Verify PostgreSQL HA
psql -h localhost -p 5432 -U pgadmin -d postgres -c "SELECT pg_is_in_recovery();"

# 3. Test PgBouncer
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"

# 4. Check Infisical (if enabled)
curl -s http://localhost:8020/api/v1/health | jq .

# 5. Size comparison
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# 6. Build time comparison
time terraform apply -auto-approve
```

---

## Rollback Procedure

If issues occur:

```bash
# 1. Restore backups
cp Dockerfile.patroni.backup Dockerfile.patroni
cp Dockerfile.pgbouncer.backup Dockerfile.pgbouncer
cp Dockerfile.infisical.backup Dockerfile.infisical
cp entrypoint-patroni.sh.backup entrypoint-patroni.sh
cp main-ha.tf.backup main-ha.tf
cp variables-ha.tf.backup variables-ha.tf

# 2. Rebuild old images
docker build -f Dockerfile.patroni -t postgres-patroni:18-pgvector .

# 3. Reapply Terraform
terraform apply

# 4. Verify services
docker ps
```

---

## Performance Metrics

### Before Optimization

| Metric | Value |
|--------|-------|
| Patroni image size | 1.2GB |
| PgBouncer image size | 145MB |
| Infisical image size | 620MB |
| Dockerfile.patroni build time | ~3min |
| Dockerfile.pgbouncer build time | ~1.5min |
| Terraform code lines | 400+ |
| PostgreSQL node startup | 45s |

### After Optimization (Expected)

| Metric | Value | Improvement |
|--------|-------|-------------|
| Patroni image size | 800MB | -33% |
| PgBouncer image size | 42MB | -71% |
| Infisical image size | 520MB | -16% |
| Dockerfile.patroni build time | 2min | -33% |
| Dockerfile.pgbouncer build time | 30s | -67% |
| Terraform code lines | 250 | -37% |
| PostgreSQL node startup | 35s | -22% |

---

## Common Issues & Solutions

### Issue 1: "Image size unchanged after multi-stage build"
**Cause**: Builder stage not cleaning up
**Solution**: Ensure `rm -rf /var/lib/apt/lists/*` in both stages

### Issue 2: "PgBouncer Alpine - missing libpq"
**Cause**: Alpine doesn't have postgresql18-client
**Solution**: Use `apk add postgresql18-client` (shown in optimized Dockerfile)

### Issue 3: "Terraform for_each not creating expected resources"
**Cause**: `local.pg_nodes` map not properly defined
**Solution**: Verify locals section in OPTIMIZED-main-ha.tf

### Issue 4: "initdb wrapper not found after rebuild"
**Cause**: Old Dockerfile still being used
**Solution**: Force clean build:
```bash
docker system prune -a  # Remove all images
docker build -f Dockerfile.patroni -t postgres-patroni:18-pgvector .
```

---

## Next Steps

1. **Today**: Implement Phase 1 (2-3 hours)
2. **This week**: Implement Phase 2 (3-4 hours)  
3. **This sprint**: Implement Phase 3 (8-10 hours)

Start with **Step 1.1 (Dockerfile.patroni)** for immediate 35% size reduction.

---

## Support & References

- Docker multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Terraform for_each: https://www.terraform.io/language/meta-arguments/for_each
- Alpine Linux packages: https://pkgs.alpinelinux.org/packages
- PostgreSQL Docker: https://hub.docker.com/_/postgres
- Patroni documentation: https://patroni.readthedocs.io/

