# Phase 1 - Quick Start Deployment Guide

## Pre-Deployment Checklist

```bash
# 1. Verify Terraform is valid
terraform validate

# 2. Check Docker builds (verify images exist)
docker images | grep -E "postgres-patroni|pgbouncer"

# 3. Review variables
cat variables-ha.tf | grep "default ="

# 4. Check if containers already running
docker ps --filter "name=pg-node" --format "table {{.Names}}\t{{.Status}}"
```

## Option 1: Fresh Deployment (Recommended for New Setup)

```bash
# Step 1: Plan the deployment
terraform plan -out=tfplan

# Step 2: Review the plan
cat tfplan  # or use: terraform show tfplan

# Step 3: Apply the plan
terraform apply tfplan

# Step 4: Verify deployment
terraform output

# Step 5: Check services
docker ps --format "table {{.Names}}\t{{.Status}}" | head -10
```

## Option 2: Rebuild Existing Infrastructure

```bash
# Destroy existing (WARNING: Deletes containers and volumes!)
terraform destroy -auto-approve

# Wait for destruction to complete (30-60 seconds)
sleep 60

# Rebuild everything
terraform apply -auto-approve

# Verify
terraform output
```

## Option 3: Only Rebuild Docker Images

If you only want to update the images without recreating containers:

```bash
# Rebuild Patroni image
docker build -f Dockerfile.patroni -t postgres-patroni:18-pgvector .

# Rebuild PgBouncer image
docker build -f Dockerfile.pgbouncer -t pgbouncer:ha .

# Rebuild Infisical image
docker build -f Dockerfile.infisical -t infisical/infisical:latest .

# Update containers (optional - recreates with new images)
terraform apply -auto-approve
```

## Verification Commands

### Check Services Running

```bash
# All containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# PostgreSQL nodes specifically
docker ps --filter "name=pg-node" --format "table {{.Names}}\t{{.Status}}"

# PgBouncer specifically
docker ps --filter "name=pgbouncer" --format "table {{.Names}}\t{{.Status}}"
```

### Test Connections

```bash
# Connect to primary PostgreSQL (port 5432)
psql -h localhost -p 5432 -U pgadmin -d postgres -c "SELECT version();"

# Connect to PgBouncer (port 6432)
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"

# Connect to etcd (port 2379)
curl http://localhost:2379/version | jq .
```

### Check Logs

```bash
# Patroni node logs
docker logs pg-node-1
docker logs pg-node-2
docker logs pg-node-3

# PgBouncer logs
docker logs pgbouncer-1
docker logs pgbouncer-2

# etcd logs
docker logs etcd

# Infisical logs
docker logs infisical
```

### Verify Cluster Health

```bash
# Check Patroni status on node 1
curl http://localhost:8008 | jq .

# Check Patroni status on node 2
curl http://localhost:8009 | jq .

# Check Patroni status on node 3
curl http://localhost:8010 | jq .

# Check PostgreSQL replication
psql -h localhost -p 5432 -U pgadmin -d postgres \
  -c "SELECT * FROM pg_stat_replication;"
```

### Check Terraform Outputs

```bash
# View all outputs
terraform output

# View specific output
terraform output pg_primary_endpoint

# View sensitive outputs (passwords)
terraform output generated_passwords
```

## Configuration Variables

### Default Configuration

```hcl
# PostgreSQL
postgres_user              = "pgadmin"
postgres_db                = "postgres"

# etcd
etcd_port                  = 2379
etcd_peer_port             = 2380
etcd_memory_mb             = 512

# DBHub / Bytebase
dbhub_port                 = 9090

# PgBouncer (optional)
pgbouncer_enabled          = true
pgbouncer_replicas         = 2
pgbouncer_external_port_base = 6432
pgbouncer_pool_mode        = "transaction"
pgbouncer_max_client_conn  = 1000
pgbouncer_default_pool_size = 25
pgbouncer_memory_mb        = 256

# Infisical (optional)
infisical_enabled          = true
infisical_port             = 8020
infisical_db_port          = 5437
infisical_environment      = "dev"

# PostgreSQL Nodes
pg_node_memory_mb          = 4096
```

### Custom Configuration

Create a `terraform.tfvars` file:

```hcl
postgres_user              = "myuser"
postgres_password          = "securepassword123456"
postgres_db                = "mydb"
pg_node_memory_mb          = 8192     # 8GB per node
pgbouncer_replicas         = 3        # 3 instances
pgbouncer_max_client_conn  = 2000
infisical_enabled          = false    # Disable Infisical
```

Then deploy:

```bash
terraform apply -var-file=terraform.tfvars
```

## Troubleshooting

### Containers Not Starting

```bash
# Check logs for specific container
docker logs pg-node-1

# Check container health
docker inspect pg-node-1 | jq '.State'

# Restart container
docker restart pg-node-1

# Full cleanup and rebuild
terraform destroy -auto-approve
terraform apply -auto-approve
```

### Port Conflicts

```bash
# Check which ports are in use
netstat -tuln | grep -E "2379|2380|5432|5433|5434|6432|8008|8009|8010|8020|9090"

# Find process using specific port
lsof -i :5432

# Change port in terraform.tfvars and reapply
etcd_port = 12379  # Change from 2379
terraform apply
```

### Memory Issues

```bash
# Check Docker memory usage
docker stats --no-stream

# Increase memory limits in terraform.tfvars
pg_node_memory_mb = 8192
pgbouncer_memory_mb = 512

# Reapply
terraform apply -var-file=terraform.tfvars
```

### Image Build Failures

```bash
# Clean Docker state
docker system prune -a

# Rebuild images
docker build -f Dockerfile.patroni -t postgres-patroni:18-pgvector .
docker build -f Dockerfile.pgbouncer -t pgbouncer:ha .
docker build -f Dockerfile.infisical -t infisical/infisical:latest .

# Reapply Terraform
terraform apply
```

## Performance Validation

```bash
# Check image sizes (should be smaller than originals)
docker images | grep -E "postgres-patroni|pgbouncer|infisical"

# Expected sizes:
# postgres-patroni    ~767MB  (was 1200MB)
# pgbouncer           ~35MB   (was 145MB)
# infisical           ~436MB  (was 741MB)

# Check container startup time
time terraform apply -auto-approve

# Should be 2-3x faster than before
```

## Backup & Restore

### Backup Database

```bash
# Create backup
docker exec pg-node-1 pg_dump -U pgadmin postgres > backup.sql

# Or use pgbackrest (if configured)
docker exec pg-node-1 pgbackrest backup

# Check backup location
docker exec pg-node-1 pgbackrest info
```

### Restore Database

```bash
# From SQL dump
cat backup.sql | docker exec -i pg-node-1 psql -U pgadmin

# Or from pgbackrest
docker exec pg-node-1 pgbackrest restore
```

## Performance Monitoring

### Quick Status Check

```bash
# All in one
echo "=== CONTAINERS ===" && \
docker ps -f "label!=test" --format "table {{.Names}}\t{{.Status}}" && \
echo "" && echo "=== PORTS ===" && \
netstat -tuln | grep LISTEN | grep -E "2379|5432|5433|5434|6432|8008|8009|8010|8020|9090" && \
echo "" && echo "=== DISK USAGE ===" && \
docker system df && \
echo "" && echo "=== MEMORY USAGE ===" && \
docker stats --no-stream --format "table {{.Container}}\t{{.MemUsage}}"
```

### Detailed Monitoring

```bash
# Watch resource usage in real-time
docker stats --no-stream

# Check Patroni cluster status
curl -s http://localhost:8008 | jq '.'

# Check PostgreSQL replication lag
psql -h localhost -p 5432 -U pgadmin -d postgres \
  -c "SELECT slot_name, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots;"

# Monitor Patroni API
watch -n 5 'curl -s http://localhost:8008 | jq .state'
```

## Maintenance Tasks

### Health Check

```bash
# Run monthly or quarterly
./health-check.sh  # (if available)

# Manual checks
for port in 5432 5433 5434 6432 8008 8009 8010 8020 2379; do
  echo "Testing port $port..."
  nc -zv localhost $port 2>&1 | tail -1
done
```

### Update Docker Images

```bash
# Pull latest base images
docker pull pgvector/pgvector:0.8.1-pg18-trixie
docker pull alpine:3.19
docker pull node:20-bookworm

# Rebuild images
docker build -f Dockerfile.patroni -t postgres-patroni:18-pgvector .
docker build -f Dockerfile.pgbouncer -t pgbouncer:ha .
docker build -f Dockerfile.infisical -t infisical/infisical:latest .

# Recreate containers
terraform apply -auto-approve
```

### Cleanup

```bash
# Remove unused images
docker image prune -a

# Remove unused volumes
docker volume prune

# Remove unused networks
docker network prune

# Full cleanup (WARNING: Destructive!)
docker system prune -a
```

## Scaling

### Add More PostgreSQL Nodes

Edit `main-ha.tf` and update `local.pg_nodes`:

```hcl
locals {
  pg_nodes = {
    "1" = { external_port = 5432, patroni_api_port = 8008 }
    "2" = { external_port = 5433, patroni_api_port = 8009 }
    "3" = { external_port = 5434, patroni_api_port = 8010 }
    "4" = { external_port = 5435, patroni_api_port = 8011 }  # NEW
    "5" = { external_port = 5436, patroni_api_port = 8012 }  # NEW
  }
}
```

Then apply:

```bash
terraform plan
terraform apply
```

### Increase PgBouncer Replicas

```bash
terraform apply -var="pgbouncer_replicas=3"
```

## Support & Reference

- Terraform Docs: https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs
- PostgreSQL Patroni: https://patroni.readthedocs.io/
- PgBouncer Docs: https://www.pgbouncer.org/
- Docker Multi-stage: https://docs.docker.com/build/building/multi-stage/

---

**Last Updated:** 2024
**Version:** Phase 1 - Production Ready ✓
