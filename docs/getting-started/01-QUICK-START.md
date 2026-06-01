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

```text
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
- Vault server (Raft backend, secrets management — `vault_enabled`)
- vault-agent sidecar (renders secrets to containers — `vault_enabled`)
- Datadog Agent (metrics, logs, integration checks — `datadog_enabled`)
- nginx status dashboard (cluster overview at :5005 — `dashboard_enabled`)
- Prometheus + Grafana + exporters (dashboards at :3000, metrics at :9090 — `monitoring_enabled`)

### Step 3: Verify (1 minute)

```bash
# Check containers are running
docker ps | grep -E 'pg-node|pgbouncer|etcd'

# Test direct PostgreSQL (no password needed inside container)
docker exec pg-node-1 psql -U postgres -d postgres -c "SELECT version();"

# Get the generated password, then test via PgBouncer
terraform output generated_passwords
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 'Connected via PgBouncer!';"
unset PGPASSWORD
```

**Expected output:**

```text
✓ pg-node-1, pg-node-2, pg-node-3, pgbouncer-1, pgbouncer-2, etcd running
✓ PostgreSQL 18.2 version info
✓ PgBouncer response: "Connected via PgBouncer!"
```

⚠️ **Important:** PgBouncer requires password authentication. Retrieve the generated password with `terraform output generated_passwords`.

### Step 4: Check Cluster Health (1 minute)

```bash
# Verify leader election
curl -s http://localhost:8008/leader | python3 -m json.tool

# View cluster members
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -E '"name"|"state"|"role"'

# Check Vault health (if vault_enabled = true)
curl -s http://localhost:8200/v1/sys/health | python3 -c "
import sys, json; d = json.load(sys.stdin)
print('Vault initialized:', d['initialized'])
print('Vault sealed:     ', d['sealed'])
print('Vault version:    ', d['version'])
"

# Verify vault-agent rendered secrets into containers
for c in pg-node-1 pg-node-2 pg-node-3 pgbouncer-1 pgbouncer-2; do
  echo -n "$c: "
  docker exec "$c" sh -c 'test -f /etc/vault/secrets/postgres.env && echo OK || echo MISSING'
done
```

### Step 5: Verify Datadog Monitoring (optional — if `datadog_enabled = true`)

```bash
# Full 9-section health report
bash datadog-health-check.sh

# Expected: all ✓ green for container, integrations, reachability checks
# Note: 403 errors in section 9 are expected with a test/placeholder API key

# Re-run individual integration checks
docker exec datadog-agent agent check postgres
docker exec datadog-agent agent check pgbouncer
docker exec datadog-agent agent check http_check
```

> To enable Datadog: set `datadog_enabled = true` in `ha-test.tfvars` and pass your API key as
> `export TF_VAR_datadog_api_key="<your-key>"` before running `terraform apply`.

### Step 6: Verify Local Monitoring Stack (if `monitoring_enabled = true`)

The local Prometheus + Grafana stack and nginx status dashboard are enabled by default in `ha-test.tfvars`.

```bash
# Full 7-section health report
bash monitoring-health-check.sh

# Expected output:
#   ✓ postgres-exporter-1/2/3  running
#   ✓ prometheus               running
#   ✓ grafana                  running
#   ✓ All 6 Prometheus targets healthy
#   ✓ pg-node-1/2/3            UP (pg_up = 1)
#   ✓ Both Grafana dashboards provisioned
#   ✓ nginx proxy endpoints responding

# Focused checks
bash monitoring-health-check.sh --targets    # Scrape target status
bash monitoring-health-check.sh --metrics    # pg_up per node
bash monitoring-health-check.sh --dashboard  # nginx proxy HTTP codes
```

**Access the UIs:**

| URL | Service | Credentials |
| --- | ------- | ----------- |
| `http://localhost:5005` | nginx status dashboard | none (anonymous) |
| `http://localhost:3000` | Grafana dashboards | admin / admin |
| `http://localhost:9090` | Prometheus UI | none |
| `http://localhost:9090/targets` | Prometheus scrape targets | none |

## Common Next Steps

### Test Failover

```bash
# Simulate primary failure
docker stop pg-node-1

# Wait and verify new leader elected on pg-node-2 or pg-node-3
sleep 30
curl -s http://localhost:8008/leader

# Bring primary back
docker start pg-node-1
```

### Connect from Application

```bash
# Get password first
terraform output generated_passwords

# Connection string
postgresql://pgadmin:<password from generated_passwords>@localhost:6432/postgres

# Example: Python
psycopg2.connect("dbname=postgres user=pgadmin host=localhost port=6432 password=<password from generated_passwords>")

# Example: Java/JDBC
jdbc:postgresql://localhost:6432/postgres?user=pgadmin&password=<password from generated_passwords>

# Example: CLI
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres
unset PGPASSWORD
```

**Authentication Details:**

- Method: SCRAM-SHA-256 (secure hash negotiation)
- User: `pgadmin`
- Password: auto-generated by Terraform — retrieve with `terraform output generated_passwords`
- Port: `6432` (via PgBouncer) or `5432` (direct PostgreSQL)

## Troubleshooting

| Issue | Fix |
| ----- | --- |
| Terraform init fails | Update Terraform: `terraform -install-upgrade && terraform init` |
| Containers won't start | Check Docker: `docker version`, ensure it's running |
| Connection refused | Wait longer (150s), check: `docker ps -a` |
| psql not found | Install PostgreSQL client: `apt-get install postgresql-client` |
| Port in use | Change ports in `ha-test.tfvars` or stop other services |
| Auth failure | Run `terraform output generated_passwords` for the current password |
| Vault sealed | Unseal: `docker exec vault vault operator unseal $(jq -r '.unseal_keys_b64[0]' .vault-bootstrap/vault-init.json)` |
| Vault permission denied | Fix volume: `docker run --rm -v vault-data:/vault/data alpine sh -c 'chown -R 100:1000 /vault/data'` |
| Vault bootstrap files missing | Re-run bootstrap: `bash vault-bootstrap.sh` (only on fresh deploy) |
| `datadog-agent` not running | Ensure `datadog_enabled = true` in `ha-test.tfvars`; re-apply Terraform |
| Datadog shows `(unhealthy)` | Expected with test API key — ignored; use `bash datadog-health-check.sh` to verify |
| Integration check: no metrics | Cluster may still be starting; wait 60 s and retry `docker exec datadog-agent agent check postgres` |

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

✅ **Vault Secrets Management**

- HashiCorp Vault 1.17.3 (Raft backend)
- AppRole authentication
- KV v2 secrets — PostgreSQL passwords auto-seeded
- vault-agent sidecar injects `postgres.env` into all containers

✅ **Datadog Observability** (optional — `datadog_enabled = true`)

- PostgreSQL metrics for all 3 nodes
- PgBouncer pool & connection metrics
- Patroni REST API health checks
- etcd and Vault health monitoring
- Container-level CPU/memory/IO via Docker socket
- Log collection from all containers

✅ **Local Monitoring Stack** (`monitoring_enabled = true`, `dashboard_enabled = true`)

- nginx status dashboard at `http://localhost:5005` — live Patroni/etcd/Vault/Datadog overview
- Prometheus at `http://localhost:9090` — scrapes all 3 postgres_exporter and 2 pgbouncer_exporter containers
- Grafana at `http://localhost:3000` — two pre-provisioned dashboards (PostgreSQL Cluster + PgBouncer Pool)
- Health check: `bash monitoring-health-check.sh`

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
docker logs vault -f
docker logs vault-agent -f

# Check connectivity
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
unset PGPASSWORD

# Admin console
PGPASSWORD='<password from generated_passwords>' psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Check Vault status
curl -s http://localhost:8200/v1/sys/health | python3 -m json.tool

# Check vault-agent rendered secrets
docker exec pg-node-1 cat /etc/vault/secrets/postgres.env

# Retrieve all generated passwords
terraform output -json generated_passwords | python3 -m json.tool
```

---

✨ **Your PostgreSQL HA cluster is ready to use!**

For more details, see [New User Guide](02-NEW-USER-GUIDE.md) or head to [docs/README.md](../README.md).
