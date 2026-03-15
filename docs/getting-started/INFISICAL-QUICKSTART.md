# Infisical Integration - Quick Start Guide

## 5-Minute Setup

This guide covers deploying the PostgreSQL HA cluster with Infisical secrets management integration.

### Prerequisites

- Docker Engine 20.10+
- Terraform 1.0+
- `curl` and `jq` installed locally
- Terminal access

### Step 1: Clone and Navigate

```bash
cd /home/vejang/terraform-docker-container-postgres
git pull origin main
```

### Step 2: Configure Infisical (First Time Only)

Create or update `ha-test.tfvars` with Infisical settings:

```hcl
# Existing configuration
postgres_user         = "pgadmin"
postgres_password     = "pgAdmin1"
postgres_db           = "postgres"
replication_password  = "replicator1"
pgbouncer_enabled     = true
pgbouncer_replicas    = 2

# NEW: Infisical Configuration
infisical_enabled      = true
infisical_port         = 8020
infisical_db_port      = 5437
infisical_environment  = "dev"
generate_new_passwords = true
password_length        = 32
```

**Important**: Set API credentials via environment variables (never commit to git):

```bash
export TF_VAR_infisical_api_key="your-api-key-here"
export TF_VAR_infisical_project_id="your-project-id-here"
```

### Step 3: Deploy Infrastructure

```bash
# Validate configuration
terraform validate

# Show what will be created
terraform plan -var-file="ha-test.tfvars"

# Deploy full stack (takes ~2-3 minutes)
terraform apply -var-file="ha-test.tfvars"
```

**What Gets Created**:
- Infisical service (port 8020)
- Infisical PostgreSQL backend (port 5437)
- 3x PostgreSQL nodes (ports 5432-5434)
- 2x PgBouncer instances (ports 6432-6433)
- etcd configuration store
- Docker network for all services

### Step 4: Initialize Secrets in Infisical

After deployment, Terraform outputs the generated passwords. Store them in Infisical:

```bash
# Get generated passwords from Terraform
terraform output generated_passwords
```

**Output Example**:
```json
{
  "db_admin_password": "xK7mP2qL9nR4sT6vW8yZ1aB3cD5eF7g",
  "db_replication_password": "aB1cD3eF5gH7iJ9kL1mN3oP5qR7sT9u",
  "pgbouncer_admin_password": "iJ1kL3mN5oP7qR9sT1uV3wX5yZ7aB9c",
  "infisical_api_key": "M8nO2pQ4rS6tU8vW0xY2zA4bC6dE8fG"
}
```

Initialize Infisical with secrets:

```bash
# Option A: Via Infisical Web UI (Easiest)
# 1. Open http://localhost:8020 in browser
# 2. Create organization and project
# 3. Add environment "dev"
# 4. Create secrets:
#    - db-admin-password: {db_admin_password}
#    - db-replication-password: {db_replication_password}
#    - pgbouncer-admin-password: {pgbouncer_admin_password}

# Option B: Via API (Scripted)
bash - <<'INIT_SECRETS'
#!/bin/bash
INFISICAL_HOST="http://localhost:8020"
API_KEY=$(terraform output -raw generated_passwords | jq -r '.infisical_api_key')

# Create secrets via API
curl -X POST $INFISICAL_HOST/api/v1/secrets \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Infisical-Project-ID: $(echo 'project-id')" \
  -H "X-Infisical-Environment: dev" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "db-admin-password",
    "value": "'"$(terraform output -raw generated_passwords | jq -r '.db_admin_password')"'"
  }'
INIT_SECRETS
```

### Step 5: Verify Integration

Test the full integration:

```bash
# 1. Check Infisical is running
curl http://localhost:8020/api/v1/health
# Expected: {"status": "ok"}

# 2. Test PostgreSQL connection via PgBouncer
PGPASSWORD='pgAdmin1' psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
# Expected: single row with "1"

# 3. Check Patroni cluster status
curl http://localhost:8008/cluster | jq '.members[] | {name, role, state}'
# Expected: 3 members (1 leader, 2 replicas)

# 4. Verify PgBouncer pools
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"
# Expected: Connection pool information

# 5. Check container logs for secret fetching
docker logs pg-node-1 | grep -i infisical
# Expected: "Fetching secrets from Infisical..." messages
```

### Step 6: Access Services

| Service | URL/Port | Credentials |
|---------|----------|-------------|
| Infisical | http://localhost:8020 | Web UI (self-register first time) |
| Patroni Node 1 | http://localhost:8008 | REST API (no auth) |
| PostgreSQL Direct | localhost:5432 | pgadmin / {from Infisical} |
| PgBouncer Pool | localhost:6432 | pgadmin / {from Infisical} |
| etcd | localhost:12379 | API (no auth) |

## Managing Secrets

### Viewing Current Secrets

```bash
# From PostgreSQL
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT current_user;"

# From Infisical API
curl http://localhost:8020/api/v1/secrets \
  -H "Authorization: Bearer $TF_VAR_infisical_api_key" \
  -H "X-Infisical-Project-ID: $TF_VAR_infisical_project_id"
```

### Rotating Passwords

**Zero-Downtime Rotation** (Recommended for production):

```bash
# 1. Update password in Infisical
curl -X PUT http://localhost:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"value": "new-password-here"}'

# 2. Restart PostgreSQL nodes one by one
docker restart pg-node-2  # Restart replica first
sleep 5
docker restart pg-node-3  # Restart second replica
sleep 5
# Promote replica if needed
docker restart pg-node-1  # Restart primary last

# 3. Verify connectivity
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"

# 4. Update PgBouncer
docker restart pgbouncer-1 pgbouncer-2
```

## Troubleshooting

### Infisical Won't Start

```bash
# Check Infisical logs
docker logs infisical

# Check database connectivity
docker logs infisical-postgres

# Recreate volumes if corrupted
docker volume rm infisical-data infisical-db-data
terraform apply -var-file="ha-test.tfvars"
```

### PostgreSQL Can't Fetch Secrets

```bash
# Check entrypoint logs
docker logs pg-node-1 | tail -20

# Verify Infisical API access from container
docker exec pg-node-1 curl http://infisical:8020/api/v1/health

# Check API key
docker exec pg-node-1 echo $INFISICAL_API_KEY
```

### PgBouncer Userlist.txt Generation Fails

```bash
# Check entrypoint logs
docker logs pgbouncer-1 | tail -20

# Verify configuration was generated
docker exec pgbouncer-1 cat /etc/pgbouncer/userlist.txt

# Check file permissions
docker exec pgbouncer-1 ls -la /etc/pgbouncer/
```

## Production Checklist

- [ ] Generate new strong passwords (done automatically with `password_length=32`)
- [ ] Store API key in secure location (Vault, AWS Secrets Manager, etc.)
- [ ] Enable TLS for Infisical (configure reverse proxy)
- [ ] Set up automated secret rotation (90-day policy)
- [ ] Enable audit logging in Infisical
- [ ] Backup Infisical database regularly
- [ ] Configure backup jobs for PostgreSQL via pgbackrest
- [ ] Set up monitoring and alerts for all services
- [ ] Document disaster recovery procedure
- [ ] Test failover scenarios
- [ ] Train team on secret management workflow

## Next Steps

1. **Read Full Integration Guide**: See [INFISICAL-INTEGRATION.md](../INFISICAL-INTEGRATION.md)
2. **Review Architecture**: See [docs/architecture/ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
3. **Configure Monitoring**: Set up Application Insights or DataDog integration
4. **Automate CI/CD**: Update deployment pipeline to use Infisical
5. **Scale PgBouncer**: Add more replicas by increasing `pgbouncer_replicas` variable

## Common Commands

```bash
# Deploy everything
terraform apply -var-file="ha-test.tfvars"

# Destroy everything
terraform destroy -var-file="ha-test.tfvars"

# Update just PgBouncer replicas
terraform apply -var-file="ha-test.tfvars" \
  -var="pgbouncer_replicas=3"

# Update environment to production
terraform apply -var-file="ha-test.tfvars" \
  -var="infisical_environment=production"

# View Terraform state
terraform state list
terraform state show docker_container.infisical

# Refresh state without applying
terraform refresh -var-file="ha-test.tfvars"
```

## FAQs

**Q: Can I use Infisical without Docker?**
A: Yes, Infisical has self-hosted options and cloud versions. Adjust `main-infisical.tf` accordingly.

**Q: How often should I rotate passwords?**
A: Recommended: Every 90 days, or after any personnel change, or per your security policy.

**Q: Can I use different secrets per environment?**
A: Yes! Set `infisical_environment = "production"` for prod deployments and use separate Infisical projects.

**Q: What if Infisical goes down?**
A: PostgreSQL and PgBouncer can still use cached/initial passwords. Set `generate_new_passwords = false` in production to avoid regenerating on redeployment.

**Q: How do I back up secrets?**
A: Infisical's PostgreSQL database is in a Docker volume. Back it up using standard PostgreSQL backup tools.

---

**Last Updated**: March 15, 2026
**Status**: Production Ready
**Author**: Infrastructure Team
