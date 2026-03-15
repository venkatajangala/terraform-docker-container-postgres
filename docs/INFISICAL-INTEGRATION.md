# Infisical Integration Guide

## Overview

This guide documents the full integration of **Infisical** (open-source secrets management platform) with the PostgreSQL HA cluster infrastructure (Patroni + PgBouncer). Infisical provides secure, encrypted secret management with rotation capabilities and audit logs.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Infisical Service                        │
│  - Port: 8020                                               │
│  - Stores: DB passwords, replication creds, API keys        │
│  - Database: PostgreSQL (internal)                          │
│  - Volume: /var/lib/infisical (persistent)                 │
└─────────────────────────────────────────────────────────────┘
        ↓           ↓           ↓           ↓
    ┌──────┐   ┌──────┐   ┌──────────┐  ┌─────────┐
    │pg-   │   │pg-   │   │pg-       │  │pgbouncer│
    │node-1│   │node-2│   │node-3    │  │cluster  │
    │ (Pri)│   │(Rep) │   │(Rep)     │  │         │
    └──────┘   └──────┘   └──────────┘  └─────────┘
       ↑          ↑           ↑            ↑
    [Fetch secrets from Infisical via REST API]
```

## Secrets Management

### Stored Secrets in Infisical

| Secret Name | Purpose | Generated Value | Rotation |
|-------------|---------|-----------------|----------|
| `db-admin-user` | PostgreSQL admin username | `pgadmin` | Manual |
| `db-admin-password` | PostgreSQL admin password | *Auto-generated* | Recommended |
| `db-replication-password` | PostgreSQL replication password | *Auto-generated* | Recommended |
| `pgbouncer-admin-user` | PgBouncer admin username | `pgadmin` | Manual |
| `pgbouncer-admin-password` | PgBouncer admin password | *Auto-generated* | Recommended |
| `infisical-api-key` | Master API key for fetching secrets | *Generated on first run* | Before rotation |

### Password Generation

On first deployment, Terraform generates secure passwords:
- PostgreSQL admin: 32-character alphanumeric + special chars
- Replication: 32-character alphanumeric + special chars
- PgBouncer admin: 32-character alphanumeric + special chars

## Deployment Architecture

### 1. Infisical Service Setup

**Container**: `infisical:latest`
**Port**: 8020 (HTTP API)
**Volume**: `/var/lib/infisical` (persistent data)
**Network**: `pg-ha-network`

Infisical runs as a standalone secrets server in the Docker network:

```bash
docker ps | grep infisical
infisical [port 8020]
```

### 2. Secret Retrieval Flow

#### PostgreSQL/Patroni Flow:
```
1. Container starts (entrypoint-patroni.sh)
2. Call Infisical API: GET /api/v1/secrets/db-admin-password
3. Store in environment: export POSTGRES_PASSWORD=<secret>
4. Initialize database with Patroni
5. Set replication password from Infisical
```

#### PgBouncer Flow:
```
1. Container starts (entrypoint-pgbouncer.sh)
2. Call Infisical API: GET /api/v1/secrets/pgbouncer-admin-password
3. Call Infisical API: GET /api/v1/secrets/db-replication-password
4. Generate userlist.txt dynamically with fetched credentials
5. Start PgBouncer with generated config
```

### 3. Key Integration Points

#### A. PostgreSQL Nodes (pg-node-1, pg-node-2, pg-node-3)

**Environment Variables**:
```bash
POSTGRES_USER=${var.postgres_user}
POSTGRES_PASSWORD=${var.postgres_password}  # Initially from Terraform
INFISICAL_API_KEY=${var.infisical_api_key}
INFISICAL_PROJECT_ID=${var.infisical_project_id}
INFISICAL_ENVIRONMENT=${var.infisical_environment}
```

**Entrypoint Changes** (`entrypoint-patroni.sh`):
```bash
# 1. Fetch secrets from Infisical
POSTGRES_PASSWORD=$(fetch_secret_from_infisical "db-admin-password")
REPLICATION_PASSWORD=$(fetch_secret_from_infisical "db-replication-password")

# 2. Export for initialization
export POSTGRES_PASSWORD REPLICATION_PASSWORD

# 3. Initialize Patroni with fetched secrets
```

#### B. PgBouncer Nodes (pgbouncer-1, pgbouncer-2, ...)

**Entrypoint Changes** (`entrypoint-pgbouncer.sh`):
```bash
# 1. Fetch all required secrets
pgbouncer_admin_pass=$(fetch_secret_from_infisical "pgbouncer-admin-password")
db_admin_pass=$(fetch_secret_from_infisical "db-admin-password")

# 2. Generate userlist.txt dynamically
cat > /etc/pgbouncer/userlist.txt <<EOF
"pgadmin" "$pgbouncer_admin_pass"
"replicator" "$(fetch_secret_from_infisical "db-replication-password")"
EOF

# 3. Start PgBouncer
pgbouncer /etc/pgbouncer/pgbouncer.ini
```

## Configuration Files

### 1. Terraform Variables (`variables-ha.tf`)

**New Variables**:
```hcl
variable "infisical_enabled" {
  type        = bool
  default     = true
  description = "Enable Infisical secrets management"
}

variable "infisical_port" {
  type        = number
  default     = 8020
  description = "Infisical API port"
}

variable "infisical_project_id" {
  type        = string
  sensitive   = true
  description = "Infisical project ID"
}

variable "infisical_environment" {
  type        = string
  default     = "dev"
  description = "Infisical environment (dev, staging, production)"
}

variable "infisical_api_key" {
  type        = string
  sensitive   = true
  description = "Infisical API key for service authentication"
}

variable "generate_new_passwords" {
  type        = bool
  default     = true
  description = "Generate new secure passwords on first deploy"
}
```

### 2. Terraform Values (`ha-test.tfvars`)

```hcl
infisical_enabled        = true
infisical_port          = 8020
infisical_environment   = "dev"
infisical_project_id    = "project-id-from-infisical"
infisical_api_key       = "k8Jwk...secure-key..."  # Set via env vars or vault
generate_new_passwords  = true
```

### 3. New Entrypoint Script (`entrypoint-infisical-secrets.sh`)

Helper script for fetching secrets:
```bash
#!/bin/bash
# Fetch secret from Infisical API
fetch_secret_from_infisical() {
  local secret_key=$1
  local api_key=${INFISICAL_API_KEY}
  local project_id=${INFISICAL_PROJECT_ID}
  local environment=${INFISICAL_ENVIRONMENT:-dev}
  local infisical_host=${INFISICAL_HOST:-https://infisical:8020}

  curl -s -X GET \
    "${infisical_host}/api/v1/secrets/${secret_key}" \
    -H "Authorization: Bearer ${api_key}" \
    -H "X-Infisical-Project-ID: ${project_id}" \
    -H "X-Infisical-Environment: ${environment}" \
    | jq -r '.secret.value'
}
```

## Setup Instructions

### Phase 1: Initial Deployment

#### Step 1: Set Infisical Configuration

```bash
# Set Infisical credentials as environment variables
export INFISICAL_PROJECT_ID="your-project-id"
export INFISICAL_API_KEY="your-api-key"

# Or update ha-test.tfvars:
cat >> ha-test.tfvars <<EOF
infisical_enabled = true
infisical_project_id = "prj-xxxxx"
infisical_api_key = "k8Jwk..."
EOF
```

#### Step 2: Deploy Infisical Container

```bash
terraform apply -var-file="ha-test.tfvars" -target=docker_container.infisical
```

This creates:
- Infisical service running on port 8020
- PostgreSQL backend for Infisical
- Network connectivity to pg-ha-network

#### Step 3: Initialize Secrets in Infisical

```bash
# Run Terraform to create initial secrets
terraform apply -var-file="ha-test.tfvars" -target=local_exec.infisical_init_secrets
```

This generates and stores:
- `db-admin-password`
- `db-replication-password`
- `pgbouncer-admin-password`

#### Step 4: Deploy Full Cluster

```bash
terraform apply -var-file="ha-test.tfvars"
```

### Phase 2: Runtime Secret Fetching

Once deployment is complete:

1. **PostgreSQL nodes** fetch secrets from Infisical on startup
2. **PgBouncer nodes** generate configuration from fetched secrets
3. All credentials are **never stored** in config files
4. Secrets are **encrypted at rest** in Infisical

## Security Best Practices

### 1. API Key Management
- Store `infisical_api_key` in:
  - **CI/CD**: GitHub Secrets, GitLab CI, etc.
  - **Local Dev**: `.envrc` (git-ignored) or environment variable
  - **Production**: Vault, AWS Secrets Manager, Azure Key Vault

```bash
# Never commit to git:
echo "infisical_api_key = \"k8Jwk...\"" >> ha-test.tfvars  # ❌ DO NOT COMMIT

# Use environment variable instead:
export TF_VAR_infisical_api_key="k8Jwk..."  # ✅ SECURE
terraform apply -var-file="ha-test.tfvars"
```

### 2. Secret Rotation
- Rotate passwords every 90 days:

```bash
# Update secret in Infisical UI or via API
curl -X PUT https://infisical:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $INFISICAL_API_KEY" \
  -d '{"value": "new-secure-password"}'

# Restart affected containers
docker restart pg-node-1 pg-node-2 pg-node-3 pgbouncer-1 pgbouncer-2
```

### 3. Network Isolation
- Infisical listens only on `pg-ha-network`
- No external access to Infisical port 8020
- Use strong authentication between containers

### 4. Audit Logging
- Enable Infisical audit logs:

```bash
docker logs infisical | grep "secret_accessed"
```

## Testing the Integration

### Test 1: Verify Infisical is Running

```bash
curl http://localhost:8020/api/v1/health
# Response: {"status": "ok"}
```

### Test 2: Verify Secret Retrieval

```bash
# From inside a container:
docker exec pg-node-1 bash -c '
  curl -X GET http://infisical:8020/api/v1/secrets/db-admin-password \
    -H "Authorization: Bearer $INFISICAL_API_KEY" \
    -H "X-Infisical-Project-ID: $INFISICAL_PROJECT_ID"
'
```

### Test 3: Connect via PgBouncer

```bash
# Fetch password from Infisical first
DB_PASSWORD=$(curl -s http://localhost:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $INFISICAL_API_KEY" | jq -r '.value')

# Connect
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
# (Password will be fetched dynamically by PgBouncer)
```

### Test 4: Verify Logs

```bash
# Check PgBouncer logs for secret retrieval
docker logs pgbouncer-1 | grep "infisical"

# Check PostgreSQL/Patroni logs
docker logs pg-node-1 | grep -i "password"
```

## Troubleshooting

### Issue: "Connection refused" to Infisical

```bash
# Check if Infisical container is running
docker ps | grep infisical

# Verify network connectivity
docker exec pg-node-1 curl http://infisical:8020/api/v1/health
```

### Issue: "Unauthorized" when fetching secrets

```bash
# Verify API key is correct and still valid
echo $INFISICAL_API_KEY

# Check secret exists in Infisical
curl -X GET http://infisical:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $INFISICAL_API_KEY"
```

### Issue: PostgreSQL fails to start with "invalid password"

```bash
# Check if entrypoint script is fetching secrets correctly
docker logs pg-node-1 | grep -A5 "fetch_secret"

# Verify secret value contains no special chars that break shell
```

## Rotation Flow

### Step 1: Update Secret in Infisical
```bash
curl -X PUT http://infisical:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $INFISICAL_API_KEY" \
  -d '{"value": "new-secure-password-here"}'
```

### Step 2: Verify Change
```bash
curl -X GET http://infisical:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $INFISICAL_API_KEY"
```

### Step 3: Restart Affected Containers
```bash
# Option A: Restart all at once (brief downtime)
docker restart pg-node-1 pg-node-2 pg-node-3 pgbouncer-1 pgbouncer-2

# Option B: Rolling restart (no downtime)
docker restart pg-node-2 && sleep 10 && docker restart pg-node-3
# Promote replica to primary if needed, then restart old primary
```

### Step 4: Verify Connectivity
```bash
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
```

## Integration Checklist

- [ ] Infisical service deployed and running
- [ ] PostgreSQL admin password stored in Infisical
- [ ] Replication password stored in Infisical
- [ ] PgBouncer admin password stored in Infisical
- [ ] All PostgreSQL nodes fetch secrets on startup
- [ ] All PgBouncer nodes generate configs from secrets
- [ ] No hardcoded passwords in config files
- [ ] Secrets never exposed in logs or env files
- [ ] API keys stored securely (not in git)
- [ ] Rotation procedure tested and documented
- [ ] Health checks verify secret retrieval
- [ ] Audit logging enabled in Infisical

## Recommended Reading

- [Infisical Documentation](https://infisical.com/docs)
- [Infisical API Reference](https://infisical.com/docs/api-reference/overview)
- [Secrets Management Best Practices](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
- [PostgreSQL Security](https://www.postgresql.org/docs/current/sql-syntax.html)

## Support & Issues

For issues with the integration:

1. Check [Infisical Docs](https://infisical.com)
2. Review container logs: `docker logs infisical`
3. Verify network communication: `docker exec pg-node-1 curl http://infisical:8020/api/v1/health`
4. Test API key permissions in Infisical UI

---

**Last Updated**: March 15, 2026
**Status**: Complete Integration Guide
**PostgreSQL Version**: 18.2
**PgBouncer Version**: 18.3
**Infisical Version**: Latest
