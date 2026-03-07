# 🚀 Quick Start Guide

**Get up and running in 5 minutes!**

## Prerequisites

- Docker & Docker Compose installed
- Terraform installed (`terraform version` to verify)
- `psql` CLI installed (for testing)
- Terminal/bash access
- ~2-3 GB disk space

## 5-Minute Deployment

### Step 1: Initialize (1 minute)

```bash
cd /home/vejang/terraform-docker-container-postgres

# Initialize Terraform
terraform init

# Verify configuration
terraform validate
```

**Expected output:**
```
✓ Terraform has been successfully initialized!
Success! The configuration is valid.
```

### Step 2: Deploy (2 minutes)

```bash
# Apply the configuration
terraform apply -var-file="ha-test.tfvars" -auto-approve

# Wait for containers to initialize
echo "Waiting for initialization..."
sleep 150
```

**What's being deployed:**
- 3 PostgreSQL nodes (Patroni-managed)
- 2 PgBouncer poolers (for connection pooling)
- etcd cluster (for distributed consensus)
- DBHub web UI (optional)

### Step 3: Verify (1 minute)

```bash
# Check containers are running
docker ps | grep -E 'pg-node|pgbouncer|etcd'

# Test direct PostgreSQL
docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT version();"

# Test via PgBouncer (pooled connection)
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 'Connected via PgBouncer!';"
```

**Expected output:**
```
✓ All 7 containers running (pg-node-1, pg-node-2, pg-node-3, pgbouncer-1, pgbouncer-2, etcd, dbhub)
✓ PostgreSQL version query returns version info
✓ PgBouncer query returns "Connected via PgBouncer!"
```

### Step 4: Check Cluster Health (1 minute)

```bash
# Verify leader election
curl -s http://localhost:8008/leader | python3 -m json.tool

# View cluster members
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -E '"name"|"state"|"role"'
```

## Common Next Steps

### Test Failover
```bash
# Simulate primary failure
docker stop pg-node-1

# Wait and verify new leader
sleep 5
curl -s http://localhost:8009/leader

# Bring primary back
docker start pg-node-1
```

### Connect from Application
```bash
# Connection string
postgresql://pgadmin:pgAdmin1@localhost:6432/postgres

# Example: Python
psycopg2.connect("dbname=postgres user=pgadmin host=localhost port=6432 password=pgAdmin1")

# Example: Java/JDBC
jdbc:postgresql://localhost:6432/postgres
```

### Access Web UI
```bash
# Open browser
open http://localhost:9090

# Or check what's available
curl -s http://localhost:9090/api/v1/info
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Terraform init fails | Update Terraform: `terraform -install-upgrade && terraform init` |
| Containers won't start | Check Docker: `docker version`, ensure it's running |
| Connection refused | Wait longer (150s), check: `docker ps -a` |
| psql not found | Install PostgreSQL client: `apt-get install postgresql-client` |
| Port in use | Change ports in `ha-test.tfvars` or stop other services |

## What You Now Have

✅ **3-Node PostgreSQL HA Cluster**
- Automatic failover
- Streaming replication
- pgvector support

✅ **PgBouncer Connection Pooling**
- 2 pooler instances
- Transaction-level pooling
- Admin console access

✅ **Distributed Consensus**
- etcd cluster
- Leader election
- Configuration management

✅ **Web Management UI**
- DBHub (Bytebase)
- Database browser
- Query execution

## Next: Learn More

- **[New User Guide](02-NEW-USER-GUIDE.md)** - Comprehensive overview
- **[Architecture](../architecture/ARCHITECTURE.md)** - How it's designed
- **[Operations](../guides/02-OPERATIONS.md)** - Daily tasks
- **[Troubleshooting](../guides/03-TROUBLESHOOTING.md)** - When things go wrong

## Need Help?

```bash
# Check cluster status
docker ps -a

# View logs
docker logs pg-node-1 -f

# Check connectivity
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"

# Admin console
psql -h localhost -p 6432 -U pgadmin -d pgbouncer
```

---

✨ **Your PostgreSQL HA cluster is ready to use!**

For more details, see [New User Guide](02-NEW-USER-GUIDE.md) or head to [docs/README.md](../README.md).
