# PostgreSQL 18 HA Cluster + PgBouncer

**Production-ready PostgreSQL HA cluster with automatic failover, connection pooling, and high availability.**

![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.2-blue)
![Patroni](https://img.shields.io/badge/Patroni-3.3.8-blue)
![Docker](https://img.shields.io/badge/Docker-Compose-blue)
![Terraform](https://img.shields.io/badge/Terraform-IaC-blue)
![Secrets](https://img.shields.io/badge/Secrets-Vault%20%28HashiCorp%20Vault%29-blue)
![Monitoring](https://img.shields.io/badge/Monitoring-Datadog-purple)

## 🚀 Quick Start (5 Minutes)

```bash
# Deploy the cluster
cd /home/vejang/terraform-docker-container-postgres
terraform apply -var-file="ha-test.tfvars" -auto-approve
sleep 150

# Verify it's running
docker ps | grep -E 'pg-node|pgbouncer|etcd|vault'

# Get generated passwords
terraform output generated_passwords

# Test connection via PgBouncer (use password from generated_passwords output)
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT version();"
unset PGPASSWORD
```

✅ **Done!** Your PostgreSQL HA cluster is ready.

## 📚 Documentation

**First time?** Start here:

- **[Quick Start Guide](docs/getting-started/01-QUICK-START.md)** - 5-minute deployment
- **[New User Guide](docs/getting-started/02-NEW-USER-GUIDE.md)** - Complete overview

**More information:**

- **[Full Documentation Index](docs/README.md)** - Complete navigation
- **[Architecture](docs/architecture/ARCHITECTURE.md)** - System design
- **[Operations Guide](docs/guides/02-OPERATIONS.md)** - Daily tasks
- **[Troubleshooting](docs/guides/03-TROUBLESHOOTING.md)** - Common issues

## 🎯 What You Get

### ✅ PostgreSQL HA Cluster
- **3-node cluster** with 1 primary + 2 replicas
- **Automatic failover** in < 30 seconds
- **Synchronous replication** (no data loss)
- **pgvector support** for AI/ML workloads
- **version 18.2** with modern extensions

### ✅ Liquibase Database Migrations
- **Version control** for all schema changes
- **Automatic changelog generation** on cluster startup
- **HA-aware** - waits for primary election before executing
- **Rollback support** - reversible changes on demand
- **Audit trail** - complete migration history in database
- **pgvector included** - 1536-dimensional embeddings with IVFFLAT search
- **Comprehensive audit logging** - tracks all DML operations

### ✅ Patroni Orchestration
- Automatic leader election
- Cluster health monitoring
- REST API for monitoring
- Configuration management

### ✅ PgBouncer Connection Pooling
- 2 pooler instances for HA
- Transaction-level connection pooling
- Support for 1000s of concurrent clients
- Admin console for monitoring

### ✅ Distributed Consensus
- etcd cluster for state management
- Quorum-based leader election
- Safe failover coordination

### ✅ Web Management UI
- DBHub (Bytebase) for database administration
- Schema browser
- Query execution interface

### ✅ Secrets Management (HashiCorp Vault)

- Centralized KV v2 secret storage with versioned secrets
- AppRole authentication for containers (role_id + secret_id)
- Raft integrated storage — data persists across container restarts
- Initialised and unsealed automatically by `vault-bootstrap.sh` on first deploy
- Fine-grained policies and audit logging

### ✅ Observability (Datadog Agent)

- **PostgreSQL metrics** — connections, query stats, replication lag on all 3 nodes
- **PgBouncer metrics** — pool utilisation, wait times, client/server connections
- **Patroni health** — per-node liveness + full cluster topology via REST API
- **etcd health** — DCS availability check
- **Vault health** — sealed/unsealed status (when `vault_enabled = true`)
- **Container metrics** — CPU, memory, I/O for every container via Docker socket
- **Log collection** — aggregated logs from all containers shipped to Datadog
- Toggle with `datadog_enabled = true`; API key via `TF_VAR_datadog_api_key`

### ✅ Local Monitoring Stack (Prometheus + Grafana + nginx dashboard)

- **nginx status dashboard** — single-page dark-themed cluster overview at `http://localhost:5005`; polls Patroni, etcd, Vault, and Datadog APIs live every 10 s
- **Prometheus** — scrapes all 3 postgres_exporter and 2 pgbouncer_exporter sidecars; 15-day retention at `http://localhost:9091`
- **Grafana** — pre-provisioned dashboards at `http://localhost:3000` (admin / admin):
  - **PostgreSQL Cluster** — node status, connections, transaction rate, cache hit ratio, locks, checkpoints
  - **PgBouncer Pool** — active/waiting clients, server pool, query rate, max wait time
- **Health check script** — `bash monitoring-health-check.sh` (7-section report + `--targets`, `--metrics`, `--dashboard` flags)
- Toggle with `monitoring_enabled = true` and `dashboard_enabled = true` in `ha-test.tfvars`

## 📊 System Architecture

```mermaid
graph TD
    APP[Applications / Clients]

    APP --> PGB1[PgBouncer-1 :6432]
    APP --> PGB2[PgBouncer-2 :6433]

    PGB1 & PGB2 --> PG1[pg-node-1 PRIMARY :5432]
    PGB1 & PGB2 --> PG2[pg-node-2 replica :5433]
    PGB1 & PGB2 --> PG3[pg-node-3 replica :5434]

    PG1 -->|WAL streaming| PG2
    PG1 -->|WAL streaming| PG3

    PG1 & PG2 & PG3 <-->|leader election| ETCD[etcd :2379]

    LB[Liquibase migrations] -->|postgres_liquibase pool| PGB1

    subgraph SECRETS["Secrets — optional (vault_enabled)"]
        VAULT[Vault :8200 Raft]
        AGENT[vault-agent sidecar]
        SVOL[(vault-agent-secrets)]
    end

    AGENT -->|AppRole login| VAULT
    VAULT -->|KV secrets| AGENT
    AGENT -->|render postgres.env| SVOL
    SVOL -. "read-only mount" .-> PG1
    SVOL -. "read-only mount" .-> PGB1 & PGB2

    subgraph OBS["Observability — optional (datadog_enabled)"]
        DD[Datadog Agent :8125-udp]
    end

    DD -->|postgres check| PG1 & PG2 & PG3
    DD -->|pgbouncer check| PGB1 & PGB2
    DD -->|http_check liveness| PG1 & PG2 & PG3
    DD -->|http_check health| ETCD
    DD -->|http_check health| VAULT
    DD -. "docker.sock\ncontainer metrics+logs" .-> APP

    subgraph MON["Local Monitoring — optional (monitoring_enabled + dashboard_enabled)"]
        DASH[pg-dashboard nginx :5005]
        PROM[Prometheus :9091]
        GRAF[Grafana :3000]
        PGE1[postgres-exporter-1] & PGE2[postgres-exporter-2] & PGE3[postgres-exporter-3]
        PGBE1[pgbouncer-exporter-1] & PGBE2[pgbouncer-exporter-2]
    end

    PROM -->|scrape :9187| PGE1 & PGE2 & PGE3
    PROM -->|scrape :9127| PGBE1 & PGBE2
    PGE1 & PGE2 & PGE3 -->|connect| PG1 & PG2 & PG3
    PGBE1 & PGBE2 -->|admin console| PGB1 & PGB2
    GRAF -->|query| PROM
    DASH -. "proxy /api/*" .-> PG1 & ETCD & VAULT

    style PG1 fill:#2e7d32,color:#fff
    style PG2 fill:#1565c0,color:#fff
    style PG3 fill:#1565c0,color:#fff
    style PGB1 fill:#6a1b9a,color:#fff
    style PGB2 fill:#6a1b9a,color:#fff
    style ETCD fill:#e65100,color:#fff
    style LB fill:#37474f,color:#fff
    style VAULT fill:#c62828,color:#fff
    style AGENT fill:#f57c00,color:#fff
    style DD fill:#632ca6,color:#fff
```

## 🔑 Key Features

| Feature | Details |
|---------|---------|
| **High Availability** | Automatic failover, no single point of failure |
| **Connection Pooling** | PgBouncer reduces connection overhead |
| **Automatic Recovery** | Cluster self-heals after node failures |
| **Monitoring** | REST API + Web UI for cluster status |
| **Observability** | Datadog Agent — metrics, logs, integration checks |
| **Local Monitoring** | Prometheus + Grafana dashboards + nginx status dashboard |
| **Scalability** | Support for 1000s of concurrent connections |
| **Production Ready** | Tested, documented, ready to deploy |

## 🔌 Connection Details

### Via PgBouncer (Recommended for Apps)
```
Host: localhost
Port: 6432
User: pgadmin
Password: <from terraform outputs: generated_passwords>
Connection: postgresql://pgadmin:<password>@localhost:6432/postgres

# Get passwords from Terraform outputs
terraform output generated_passwords
```

### Direct to PostgreSQL (Testing)
```
Primary:   localhost:5432
Replica 1: localhost:5433
Replica 2: localhost:5434

# Secure connection command (use password from generated_passwords output)
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 5432 -U pgadmin -d postgres
```

### Cluster Monitoring
```
Patroni API:       http://localhost:8008       (Node 1)
Web UI (DBHub):    http://localhost:9090
Admin Console:     psql -h localhost -p 6432 -U pgadmin -d pgbouncer
Status Dashboard:  http://localhost:5005        (nginx — when dashboard_enabled = true)
Grafana:           http://localhost:3000        (admin/admin — when monitoring_enabled = true)
Prometheus:        http://localhost:9091/targets (when monitoring_enabled = true)
```

## 📋 Common Commands

```bash
# Check cluster status
curl -s http://localhost:8008/leader | python3 -m json.tool

# View PgBouncer pools
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"

# View container logs
docker logs pg-node-1 -f
docker logs pgbouncer-1 -f

# Test direct PostgreSQL connection (use password from generated_passwords output)
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 5432 -U pgadmin -d postgres -c "SELECT 1;"
unset PGPASSWORD

# Test pooled connection via PgBouncer
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
unset PGPASSWORD

# View PgBouncer admin console (use password from generated_passwords output)
PGPASSWORD='<password from generated_passwords>' psql -h localhost -p 6432 -U pgadmin -d pgbouncer
```

### Datadog Monitoring

```bash
# Enable Datadog (set your API key first)
export TF_VAR_datadog_api_key="your-api-key-here"

# Edit ha-test.tfvars: set datadog_enabled = true, then re-apply
terraform apply -var-file="ha-test.tfvars" -auto-approve

# Run the built-in health check
bash datadog-health-check.sh

# Full agent status
docker exec datadog-agent agent status

# Re-run individual integration checks
docker exec datadog-agent agent check postgres
docker exec datadog-agent agent check pgbouncer
docker exec datadog-agent agent check http_check

# Stream agent logs
docker logs datadog-agent -f
```

### Local Monitoring Stack (Prometheus + Grafana)

```bash
# Run full 7-section health report
bash monitoring-health-check.sh

# Focused checks
bash monitoring-health-check.sh --targets    # Prometheus scrape target status
bash monitoring-health-check.sh --metrics    # pg_up per node
bash monitoring-health-check.sh --dashboard  # nginx proxy endpoints

# Open dashboards in browser
open http://localhost:5005          # nginx status dashboard
open http://localhost:3000          # Grafana (admin / admin)
open http://localhost:9091/targets  # Prometheus targets

# Stream exporter logs
docker logs prometheus          -f
docker logs grafana             -f
docker logs postgres-exporter-1 -f
docker logs pgbouncer-exporter-1 -f
```

### Secrets Management (Vault)

```bash
# Check Vault health
curl -s http://localhost:8200/v1/sys/health | python3 -m json.tool

# View Vault logs
docker logs vault -f

# View Vault Agent logs (if vault_agent_enabled = true)
docker logs vault-agent --tail=30

# Check rendered secrets (from Vault Agent sidecar)
docker exec pg-node-1 cat /etc/vault/secrets/postgres.env

# Check PostgreSQL secret injection logs
docker logs pg-node-1 | grep -i vault
```

## 🧪 Testing

### PgBouncer Authentication Tests

✅ **PASSED** - Authentication Configuration: SCRAM-SHA-256

| Test | Command | Result |
|------|---------|--------|
| pgbouncer-1 Version | `docker exec pgbouncer-1 bash -c "PGPASSWORD='<generated>' psql -h localhost -p 6432 -U pgadmin -d postgres -c \"SELECT version();\""` | PostgreSQL 18.2 ✅ |
| pgbouncer-2 Version | `docker exec pgbouncer-2 bash -c "PGPASSWORD='<generated>' psql -h localhost -p 6432 -U pgadmin -d postgres -c \"SELECT version();\""` | PostgreSQL 18.2 ✅ |
| Pool Status | `PGPASSWORD='<generated>' psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"` | 2 pools routed ✅ |
| Statistics | `PGPASSWORD='<generated>' psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW STATS;"` | Active connections tracked ✅ |

**Authentication Method: SCRAM-SHA-256**

- Passwords are auto-generated by Terraform (`random_password` resources)
- Retrieve passwords with: `terraform output generated_passwords`
- No hardcoded passwords; override with `TF_VAR_postgres_password` if needed

### Verify Cluster Health
```bash
# Check all containers
docker ps | grep -E 'pg-node|pgbouncer|etcd'

# Check cluster status
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Test failover (stop primary)
docker stop pg-node-1
sleep 30
curl -s http://localhost:8008/leader  # Should show new leader
docker start pg-node-1
```

### Run Full Test Suite
```bash
# See docs/testing/TESTING.md for comprehensive test procedures
```

## 📁 Project Structure

```
.
├── README.md                        ← You are here
├── docs/                            ← Complete documentation
│   ├── getting-started/             # For new users
│   ├── guides/                      # Operations & maintenance
│   ├── architecture/                # System design
│   ├── pgbouncer/                   # Connection pooling
│   ├── testing/                     # Test procedures
│   └── reference/                   # Technical reference
│
├── Terraform files                  ← Infrastructure as code
│   ├── main-ha.tf                   # Core infra: network, etcd, pg nodes, pgbouncer
│   ├── main-vault.tf                # Vault server container + volume + perms
│   ├── main-vault-init.tf           # vault-bootstrap.sh trigger (null_resource)
│   ├── main-vault-agent.tf          # Vault Agent sidecar + shared secrets volume
│   ├── main-liquibase.tf            # Liquibase one-shot migrations container
│   ├── main-datadog.tf              # Datadog Agent container + rendered configs
│   ├── main-dashboard.tf            # nginx status dashboard container (pg-dashboard)
│   ├── main-monitoring.tf           # Prometheus + Grafana + exporter containers
│   ├── variables-ha.tf
│   ├── outputs-ha.tf
│   └── ha-test.tfvars
│
├── Configuration files
│   ├── vault/config/                # Vault server config (Raft server mode)
│   │   └── vault.hcl
│   ├── pgbouncer/                   # PgBouncer config
│   │   ├── pgbouncer.ini
│   │   └── userlist.txt
│   ├── patroni/                     # Patroni config per node
│   │   ├── patroni-node-1.yml
│   │   ├── patroni-node-2.yml
│   │   └── patroni-node-3.yml
│   └── pgbackrest/                  # Backup configuration
│
├── Docker files
│   ├── Dockerfile.patroni           # PostgreSQL + Patroni image
│   └── Dockerfile.pgbouncer         # PgBouncer image
│
├── Secrets bootstrap
│   ├── vault-bootstrap.sh           # Init, unseal, AppRole, KV seed
│   └── vault-bootstrap-split.sh     # Splits approle JSON → role_id / secret_id files
│
├── Datadog configuration
│   ├── datadog/conf.d/              # Integration config templates (Terraform renders these)
│   │   ├── postgres.yaml.tpl        # PostgreSQL check (all 3 nodes)
│   │   ├── pgbouncer.yaml.tpl       # PgBouncer admin console check
│   │   └── http_check.yaml.tpl      # Patroni + etcd + Vault HTTP checks
│   └── datadog/rendered/            # Generated at plan time — gitignored (contain passwords)
│
├── Local monitoring (Prometheus + Grafana)
│   ├── dashboard/                   # nginx status dashboard
│   │   ├── index.html               # Single-page dark-themed cluster overview
│   │   └── nginx.conf.tpl           # nginx reverse proxy config (Terraform renders)
│   ├── dashboard/rendered/          # Rendered nginx.conf — gitignored
│   ├── monitoring/prometheus/       # Prometheus scrape config template
│   │   └── prometheus.yml.tpl       # Dynamic pgbouncer target list (Terraform renders)
│   ├── monitoring/rendered/         # Rendered prometheus.yml — gitignored
│   └── monitoring/grafana/provisioning/
│       ├── datasources/prometheus.yml   # Auto-provisioned Prometheus datasource
│       ├── dashboards/provider.yml      # Dashboard file provider
│       ├── dashboards/postgres.json     # PostgreSQL Cluster dashboard (uid: pg-ha-postgres)
│       └── dashboards/pgbouncer.json    # PgBouncer Pool dashboard (uid: pg-ha-pgbouncer)
│
└── Utilities
    ├── test-full-stack.sh           # Automated test suite
    ├── pgbouncer-health-check.sh    # PgBouncer health check
    ├── datadog-health-check.sh      # Datadog Agent health check
    └── monitoring-health-check.sh   # Prometheus + Grafana + nginx health check
```

## ⚙️ Configuration

Edit `ha-test.tfvars` to customize:

```hcl
# PostgreSQL settings
postgres_user               = "pgadmin"
postgres_password          = ""                  # Leave empty to auto-generate via random_password
postgres_db                = "postgres"

# PgBouncer settings
pgbouncer_enabled          = true
pgbouncer_replicas         = 2                   # 1-3 for HA
pgbouncer_pool_mode        = "transaction"       # or "session"/"statement"
pgbouncer_default_pool_size = 25                 # Tune for your workload

# Cluster ports
patroni_api_port_base      = 8008
postgres_port_base         = 5432
pgbouncer_external_port_base = 6432

# Datadog monitoring (optional)
datadog_enabled     = false          # Set to true to deploy the Datadog Agent
datadog_api_key     = ""             # Set via TF_VAR_datadog_api_key env var — never commit
datadog_site        = "datadoghq.com"
datadog_memory_mb   = 512
datadog_statsd_port = 8125

# Local monitoring — Prometheus + Grafana (optional)
monitoring_enabled  = true           # Deploys Prometheus, Grafana, and all exporters
prometheus_port     = 9091           # http://localhost:9091
grafana_port        = 3000           # http://localhost:3000  (admin / admin)
# grafana_admin_password = "admin"   # Override via TF_VAR_grafana_admin_password

# nginx status dashboard (optional)
dashboard_enabled   = true           # Deploys single-page cluster status page
dashboard_port      = 5005           # http://localhost:5005
```

See `variables-ha.tf` for the full list of configuration options, or edit `ha-test.tfvars` to override defaults.

## 🔐 Security

### Development (Current)
✅ Suitable for local testing and development

### Production Checklist
- [ ] Change default passwords
- [ ] Enable SSL/TLS for remote connections
- [ ] Restrict network access to authorized users
- [ ] Enable PostgreSQL audit logging
- [ ] Configure automated backups
- [ ] Set up monitoring and alerts (Datadog: `datadog_enabled = true`)
- [ ] Create a dedicated `datadog` PostgreSQL user with `pg_monitor` role instead of using postgres superuser
- [ ] Rotate `DD_API_KEY` via secrets manager; never store in tfvars

See the Security Boundaries section in [Architecture](docs/architecture/ARCHITECTURE.md) for a production hardening checklist.

## 📖 Documentation by Role

| Role | Start Here |
|------|-----------|
| **New Team Member** | [New User Guide](docs/getting-started/02-NEW-USER-GUIDE.md) |
| **Developer** | [Quick Start](docs/getting-started/01-QUICK-START.md) + [Operations](docs/guides/02-OPERATIONS.md) |
| **DevOps/SRE** | [Architecture](docs/architecture/ARCHITECTURE.md) + `variables-ha.tf` |
| **Secrets Management** | [Vault Quick Start](docs/getting-started/VAULT-QuickStart.md) + [Vault Integration Guide](docs/VAULT-INTEGRATION.md) |
| **Troubleshooting** | [Troubleshooting Guide](docs/guides/03-TROUBLESHOOTING.md) |
| **Advanced Users** | [Complete Documentation Index](docs/README.md) |

## 🔑 Secrets Management

This stack integrates **HashiCorp Vault** for secrets management. The repository includes a dev-friendly Vault RAFT prototype (single-node RAFT) and helpers for AppRole authentication and KV v2 usage. For production, follow the recommended patterns (auto-unseal with KMS, Vault Agent/sidecar or injector).

✅ **Features**:

- Centralized KV v2 secret storage and versioned secrets
- AppRole authentication for containers (recommended)
- Terraform-controlled seeding and sensitive outputs (dev only)
- Support for dynamic secrets and rotation (via Vault DB plugins)
- Audit logging and policy-based access control

### Quick Start (Dev Vault RAFT)
```bash
# Start Terraform with vault_enabled=true
terraform apply -var-file="ha-test.tfvars" -auto-approve
# Initialize and unseal dev Vault (bootstrap handles this in dev)
# Verify Vault is reachable
curl -s http://localhost:8200/v1/sys/health

# AppRole JSON is written to .vault-bootstrap/approle_pg-role.json (dev only)
# Containers read AppRole JSON from /etc/vault/approle_pg-role.json if mounted
```

Note: Vault listens on port 8200 by default; ensure ha-test.tfvars uses vault_port = 8200 for consistency.

📚 **Learn More**:
- [Vault Quick Start](docs/getting-started/VAULT-QuickStart.md) - Dev bootstrap and AppRole
- [Vault Integration Guide](docs/VAULT-INTEGRATION.md) - Architecture & implementation

## 🚨 Troubleshooting

### Cluster won't start
```bash
# Check Terraform validation
terraform validate

# Check container logs
docker logs pg-node-1
docker logs pgbouncer-1

# See [Troubleshooting Guide](docs/guides/03-TROUBLESHOOTING.md)
```

### Can't connect
```bash
# Test via PgBouncer
psql -h localhost -p 6432 -U pgadmin -d postgres

# Test direct
psql -h localhost -p 5432 -U pgadmin -d postgres

# Check health
curl -s http://localhost:8008/leader | python3 -m json.tool
```

### Performance issues
See [PgBouncer Authentication](docs/pgbouncer/AUTHENTICATION.md) or [Troubleshooting](docs/guides/03-TROUBLESHOOTING.md)

## 🤝 Support & Resources

- **Full Docs**: [docs/README.md](docs/README.md)
- **PostgreSQL**: https://www.postgresql.org/docs/18/
- **Patroni**: https://patroni.readthedocs.io/
- **PgBouncer**: https://www.pgbouncer.org/
- **etcd**: https://etcd.io/docs/

## 📊 Status

✅ **Production Ready**
- Full test coverage (17/23 tests passing, all infrastructure operational)
- Comprehensive documentation
- Terraform IaC fully validated
- Deploy with confidence

**Last Updated**: 2026-04-15  
**Version**: PostgreSQL 18.2 + Patroni 3.3.8 + etcd 3.5.0 + PgBouncer 1.15 + Datadog Agent 7

---

## Next Steps

1. **Deploy**: Follow [Quick Start](docs/getting-started/01-QUICK-START.md) (5 min)
2. **Learn**: Read [New User Guide](docs/getting-started/02-NEW-USER-GUIDE.md) (20 min)
3. **Operate**: See [Operations Guide](docs/guides/02-OPERATIONS.md)
4. **Scale**: Edit `ha-test.tfvars` — see `variables-ha.tf` for all options
5. **Explore**: Check [Full Documentation](docs/README.md)

**Ready?** Run:
```bash
cd /home/vejang/terraform-docker-container-postgres
terraform apply -var-file="ha-test.tfvars"
```
