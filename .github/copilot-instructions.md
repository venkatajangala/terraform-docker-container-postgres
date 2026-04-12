# Copilot Instructions for PostgreSQL HA Cluster Repository

This file helps Copilot and other AI assistants work effectively in this repository. See `CLAUDE.md` for more detailed architecture and patterns.

## Project Overview

**Production-ready PostgreSQL 18 High Availability cluster** with Terraform + Docker:
- 3-node Patroni cluster (1 primary + 2 replicas) with etcd consensus
- PgBouncer connection pooling (2 instances, transaction mode)
- Liquibase schema migrations (HA-aware)
- Optional Vault secrets management
- pgvector extension for AI/ML embeddings

## Build, Test, and Deploy Commands

### Terraform Validation & Planning
```bash
# Validate syntax
terraform validate

# Check formatting (shows errors, doesn't apply)
terraform fmt -check -recursive

# Dry-run deployment plan
terraform plan -var-file="ha-test.tfvars" -out=/tmp/plan.tfplan

# Apply plan (PRODUCTION: omit -auto-approve)
terraform apply -var-file="ha-test.tfvars" -auto-approve

# Destroy all infrastructure
terraform destroy -var-file="ha-test.tfvars" -auto-approve
```

### Test Scripts (Pre-Deployment & Post-Deployment)
```bash
# Comprehensive test suite (run after terraform apply)
bash test-comprehensive.sh       # Validates all components

# Full stack test with health checks
bash test-full-stack.sh         # Tests cluster + PgBouncer + Vault

# Liquibase-specific tests
bash test-liquibase.sh          # Validates migrations + changelog

# Post-deployment verification
bash verify-liquibase.sh        # Checks schema migrations executed
bash verify-phase1.sh           # Phase 1 component validation
```

### Connect & Verify
```bash
# Get generated passwords from Terraform
terraform output generated_passwords

# Connect via PgBouncer (recommended for apps)
psql -h localhost -p 6432 -U pgadmin -d postgres

# Check cluster health
curl -s http://localhost:8008/leader | python3 -m json.tool
curl -s http://localhost:8008/cluster | python3 -m json.tool

# View container logs
docker logs pg-node-1 -f
docker logs pgbouncer-1 -f
docker logs etcd -f
```

### Liquibase Migrations (Run Inside Container or Locally)
```bash
# Check migration status
liquibase --changeLogFile="liquibase/changelog/db.changelog-master.yml" status

# Apply all pending migrations
liquibase --changeLogFile="liquibase/changelog/db.changelog-master.yml" update

# Rollback N changesets
liquibase --changeLogFile="liquibase/changelog/db.changelog-master.yml" rollback-count 1
```

## High-Level Architecture

### Infrastructure as Code (Terraform)
- **main-ha.tf** — Core infrastructure: Docker network, etcd, 3 PostgreSQL nodes, 2 PgBouncer instances, optional Vault stack
- **main-liquibase.tf** — One-shot Liquibase container that waits for primary election
- **main-vault.tf** — Vault stack (secrets server + its own PostgreSQL + Redis)
- **variables-ha.tf** — All tunable parameters: passwords, pool sizes, memory limits, feature flags
- **outputs-ha.tf** — Connection strings, endpoints, generated credentials

### Container Stack Architecture
```
Applications/Clients
    ↓
PgBouncer instances (:6432, :6433) — transaction-mode pooling
    ↓
    ├── pg-node-1 (:5432) — primary
    ├── pg-node-2 (:5433) — replica
    └── pg-node-3 (:5434) — replica
        (Patroni-managed streaming replication + failover)
    ↓
etcd (:2379) — distributed consensus for leader election
    ↓
Liquibase — one-shot container (runs after primary elected)
```

All containers share `pg-ha-network` (Docker bridge, `172.18.0.0/16`).

**Optional: Vault Stack**
- Vault server (:8200) — HashiCorp Vault, Raft backend (no external DB or Redis)
- vault-agent — sidecar that renders secrets to shared volume (vault_agent_enabled)

### Shell Script Roles
| Script | Purpose |
|--------|---------|
| `entrypoint-patroni.sh` | Bootstrap each node: fetch secrets from Vault (if enabled), wait for etcd, start Patroni |
| `entrypoint-pgbouncer.sh` | Generate `pgbouncer.ini` dynamically, create userlist, optionally fetch credentials from Vault |
| `liquibase-entrypoint.sh` | Poll `pg_isready` on primary via `postgres_liquibase` pool, check `pg_is_in_recovery()`, then run migrations |
| `vault-secrets.sh` | Library functions: `fetch_secret_from_vault()`, `create_secret_in_vault()` |
| `pgbouncer-health-check.sh` | Connectivity checks for all PostgreSQL nodes (nc -z) |

### Liquibase Changelog Structure
```
liquibase/changelog/
├── db.changelog-master.yml       # includes sequence below
├── 01-init-schema.yml            # audit schema + audit_trigger_func()
├── 02-add-extensions.yml         # pgvector, pg_stat_statements, pgcrypto, uuid-ossp
├── 03-create-tables.yml          # audit_log, users, items (vector), sessions + indexes
└── 04-add-products.yml           # products table with audit trigger
```

All changesets include rollback blocks; use `rollback-count N` to revert.

## Key Conventions & Patterns

### Feature Flags (Toggle Without Editing Resources)
Located in `variables-ha.tf`. Set via `ha-test.tfvars` or `-var` flags:
- `liquibase_enabled` — Deploy Liquibase container?
- `vault_enabled` — Deploy Vault secrets stack?
- `pgbouncer_enabled` — Deploy PgBouncer?
- `pgbouncer_replicas` — Number of PgBouncer instances

**Example**: `terraform apply -var="vault_enabled=false" -var-file="ha-test.tfvars"`

### Secrets Flow
- **When Vault disabled**: Terraform generates passwords via `random_password` resources, passes as env vars to containers
- **When Vault enabled**: Containers fetch/rotate credentials via Vault HTTP API at startup (`vault-secrets.sh` library)
- Password generation uses `override_special = "!_-+"` (excludes shell/JDBC/URL-breaking chars)

### Liquibase HA Awareness
`liquibase-entrypoint.sh` does:
1. Connect to PgBouncer's `postgres_liquibase` pool (routes to primary only, `pool_mode=session` for advisory locks)
2. Poll until `pg_is_in_recovery()` returns `f` (i.e., primary is elected)
3. Run `liquibase update` only after leader election

This prevents migrations from running on replicas or before cluster stability.

### Patroni Configuration (Passwords)
- Rendered at `terraform apply` time via `patroni/patroni-node.yml.tpl`
- Output files: `patroni/rendered/patroni-node-N.yml` (gitignored — never commit)
- **Never edit `pg_hba.conf` directly** — Patroni manages it via YAML
- Authentication uses SCRAM-SHA-256 everywhere (no MD5)
- Docker subnet (`172.18.0.0/16`) trusts SCRAM; `localhost` (`127.0.0.1/32`) uses trust

### PgBouncer Userlist & Pool Modes
- Generated by `entrypoint-pgbouncer.sh` at container startup
- Contains users: `pgadmin`, `postgres`, `replicator`
- `postgres` superuser included (required for Liquibase DDL)
- Pool modes:
  - `postgres` pool: round-robin across all nodes (transaction mode)
  - `postgres_liquibase` pool: routes only to primary, session mode (advisory locks)

**PgBouncer startup**: `ignore_startup_parameters = extra_float_digits` (JDBC driver compatibility)

### pgvector Configuration
- Extension added via `02-add-extensions.yml` changeset
- Items table: `embedding vector(1536)` column (OpenAI-compatible dimensions)
- Index: IVFFLAT with `lists=100` (cosine similarity search)

### Docker Network & Naming
- Network: `pg-ha-network` (bridge, `172.18.0.0/16`)
- Node hostnames: `pg-node-1`, `pg-node-2`, `pg-node-3` (Patroni uses DNS)
- PgBouncer: `pgbouncer-1`, `pgbouncer-2`
- etcd: `etcd`
- Vault (if enabled): `vault`, `vault-agent` (sidecar, if vault_agent_enabled)

### Liquibase YAML Format Requirements
Liquibase 5.x requires:
- List syntax: `- changeSet:` (dash prefix), NOT `changeSet:` as map key
- Multi-statement SQL (e.g., PL/pgSQL with `$$`): include `splitStatements: false` to prevent semicolon-splitting

**Example**:
```yaml
- changeSet:
    id: create-function
    author: you
    changes:
      - sql:
          splitStatements: false
          sql: |
            CREATE OR REPLACE FUNCTION audit_trigger_func() RETURNS TRIGGER AS $$
            BEGIN
              ...
            END;
            $$ LANGUAGE plpgsql;
```

### Terraform Variable Overrides
- Default values in `variables-ha.tf`
- Override via:
  - `ha-test.tfvars` (checked in, used for dev/testing)
  - Environment: `export TF_VAR_postgres_password='...'`
  - CLI: `-var="postgres_password=..."`
- Sensitive variables (passwords) marked `sensitive = true` in output

### Terraform State Files
- State stored locally (`terraform.tfstate`, `.tfstate.backup`)
- **Gitignored** — never commit
- Use `-state` flag to specify alternate state file if needed
- For teams, configure S3/Terraform Cloud backend in `terraform {}` block

## Common Development Workflows

### Deploying a New Environment
```bash
# 1. Validate configuration
terraform validate
terraform fmt -check -recursive

# 2. Plan deployment
terraform plan -var-file="ha-test.tfvars" -out=/tmp/plan.tfplan

# 3. Apply (wait ~2-3 mins for containers to start)
terraform apply /tmp/plan.tfplan

# 4. Wait for Patroni leader election
sleep 150

# 5. Verify health
bash test-comprehensive.sh

# 6. Get credentials
terraform output generated_passwords
```

### Modifying Schema via Liquibase
```bash
# 1. Create new changeset file (e.g., 05-new-feature.yml)
# Follow YAML format from existing files (list syntax, split statements)

# 2. Include it in db.changelog-master.yml

# 3. Validate locally (optional, requires Liquibase CLI)
liquibase status

# 4. Let cluster deploy it automatically, OR manually:
liquibase update

# 5. Verify in database
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT * FROM databasechangelog;"
```

### Toggling Features
```bash
# Disable Vault (already running cluster)
terraform apply -var="vault_enabled=false" -var-file="ha-test.tfvars" -auto-approve

# Add a third PgBouncer instance
terraform apply -var="pgbouncer_replicas=3" -var-file="ha-test.tfvars" -auto-approve

# Enable Liquibase (was disabled)
terraform apply -var="liquibase_enabled=true" -var-file="ha-test.tfvars" -auto-approve
```

### Debugging
```bash
# Tail logs from a specific node
docker logs pg-node-1 -f

# Check Patroni leader status
curl -s http://localhost:8008/leader | jq .

# Query Patroni cluster state
curl -s http://localhost:8008/cluster | jq .

# List PgBouncer pools and connection counts
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"

# Check PostgreSQL replication status
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT client_addr, state FROM pg_stat_replication;"

# Verify Liquibase migrations
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT * FROM databasechangelog ORDER BY dateexecuted DESC LIMIT 5;"
```

## Documentation References

- **CLAUDE.md** — Detailed architecture, patterns, and advanced usage
- **README.md** — Quick start and overview
- **TERRAFORM-COMMANDS-REFERENCE.md** — Full Terraform CLI reference
- **TESTING-GUIDE.md** — Comprehensive test procedures
- **LIQUIBASE-\*.md** — Liquibase-specific docs (architecture, deployment, scenarios)
- **DEPLOYMENT-AND-OPERATIONS-GUIDE.md** — Operations and troubleshooting

## Notes for AI Assistants

1. **State mutations**: Terraform state files are not committed. When modifying infrastructure, always plan before applying.
2. **Container startup times**: Patroni leader election takes ~2–3 minutes. Don't verify cluster health immediately after `terraform apply`.
3. **Secrets sensitivity**: Password variables are marked sensitive; their values won't appear in logs/output unless explicitly requested.
4. **Feature interactions**: Disabling `liquibase_enabled` doesn't remove the migration container immediately; it just won't create it on next apply.
5. **Vault optional**: The stack works fully without Vault (secrets passed as env vars). Vault enables rotation and centralized management.
6. **Port allocation**: Check `variables-ha.tf` for default port assignments; they're tunable but affect connection strings.
7. **Docker network**: All containers use the shared `pg-ha-network`; can't access external services without explicit networking configuration.
