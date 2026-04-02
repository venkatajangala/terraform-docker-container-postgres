# 📚 Documentation

Welcome! Organized documentation for the PostgreSQL 18 HA + PgBouncer infrastructure.

## 🚀 Getting Started

Start here if you're new to this project:

- **[Quick Start](getting-started/01-QUICK-START.md)** — Deploy in 5 minutes
- **[New User Guide](getting-started/02-NEW-USER-GUIDE.md)** — Comprehensive overview for beginners
- **[Architecture Overview](architecture/ARCHITECTURE.md)** — Understand what you're deploying

## 📖 Operational Guides

- **[Operations & Maintenance](guides/02-OPERATIONS.md)** — Day-to-day cluster operations
- **[Troubleshooting](guides/03-TROUBLESHOOTING.md)** — Common issues and solutions

## 🔐 Secrets Management (Infisical)

- **[Infisical Quick Start](getting-started/INFISICAL-QUICKSTART.md)** — Enable and verify in 5 minutes
- **[Integration Guide](INFISICAL-INTEGRATION.md)** — Architecture and implementation details
- **[Infisical Troubleshooting](guides/INFISICAL-TROUBLESHOOTING.md)** — Common secrets issues

## 🔌 Connection Pooling (PgBouncer)

- **[Authentication Guide](pgbouncer/AUTHENTICATION.md)** — Password methods, userlist, SCRAM-SHA-256

## 🗄️ Schema Migrations (Liquibase)

- **[Quick Reference](../LIQUIBASE-QUICK-REFERENCE.md)** — Common commands at a glance
- **[Deployment Guide](../LIQUIBASE-DEPLOYMENT.md)** — HA-aware migration workflow
- **[Test Scenarios](../LIQUIBASE-TEST-SCENARIOS.md)** — Validation and rollback testing

## 🧪 Testing & Validation

- **[Testing Guide](testing/TESTING.md)** — Full test suite: cluster health, failover, pooling
- **[Testing Guide (root)](../TESTING-GUIDE.md)** — Alternate test reference

## ⚙️ Infrastructure Reference

- **[Terraform Commands](../TERRAFORM-COMMANDS-REFERENCE.md)** — All Terraform operations and outputs
- **Configuration** — Edit `ha-test.tfvars` for ports, pool sizes, feature flags; see `variables-ha.tf` for all knobs

## 🎯 Recommended Paths by Role

### 👤 New Team Member (30 min)

1. Read [New User Guide](getting-started/02-NEW-USER-GUIDE.md)
2. Review [Architecture Overview](architecture/ARCHITECTURE.md)
3. Follow [Quick Start](getting-started/01-QUICK-START.md) to deploy locally
4. Bookmark [Operations & Maintenance](guides/02-OPERATIONS.md)

### 🛠️ Operator / DevOps (1-2 hours)

1. Review [Architecture Overview](architecture/ARCHITECTURE.md)
2. Run [Testing Guide](testing/TESTING.md)
3. Bookmark [Troubleshooting](guides/03-TROUBLESHOOTING.md)
4. Review [Operations & Maintenance](guides/02-OPERATIONS.md)

### 🏗️ Infrastructure / Platform Engineer (2-4 hours)

1. Full [Architecture Overview](architecture/ARCHITECTURE.md)
2. Review `variables-ha.tf` for all configuration options
3. Review `main-ha.tf` for resource definitions
4. Study [Terraform Commands](../TERRAFORM-COMMANDS-REFERENCE.md)

### 🔍 Troubleshooting an Issue (15-30 min)

1. Check [Troubleshooting](guides/03-TROUBLESHOOTING.md)
2. Run diagnostic commands from [Operations Guide](guides/02-OPERATIONS.md)
3. For secrets issues: [Infisical Troubleshooting](guides/INFISICAL-TROUBLESHOOTING.md)

## 📁 Current Documentation Structure

```
docs/
├── README.md                          ← You are here
│
├── getting-started/
│   ├── 01-QUICK-START.md             # 5-minute deployment
│   ├── 02-NEW-USER-GUIDE.md          # Comprehensive introduction
│   └── INFISICAL-QUICKSTART.md       # Secrets management quick start
│
├── guides/
│   ├── 02-OPERATIONS.md              # Running & maintenance
│   ├── 03-TROUBLESHOOTING.md         # Common issues & fixes
│   └── INFISICAL-TROUBLESHOOTING.md  # Secrets-specific issues
│
├── pgbouncer/
│   └── AUTHENTICATION.md             # PgBouncer auth & userlist
│
├── testing/
│   └── TESTING.md                    # Test procedures & scenarios
│
├── architecture/
│   └── ARCHITECTURE.md               # Full system architecture
│
└── INFISICAL-INTEGRATION.md          # Infisical architecture & implementation
```

## 🔍 Quick Command Reference

```bash
# Deploy
terraform apply -var-file="ha-test.tfvars" -auto-approve
sleep 150

# Get generated passwords
terraform output generated_passwords

# Test connection via PgBouncer
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
unset PGPASSWORD

# Cluster health
curl -s http://localhost:8008/leader | python3 -m json.tool

# PgBouncer admin console
PGPASSWORD='<password from generated_passwords>' psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"
```

## 📈 Infrastructure Status

- ✅ PostgreSQL 18.2 (3-node HA cluster)
- ✅ Patroni orchestration + automatic failover
- ✅ etcd distributed consensus
- ✅ PgBouncer connection pooling (2 instances)
- ✅ Liquibase schema migrations (HA-aware)
- ✅ Infisical secrets management (optional)
- ✅ pgvector support (1536-dim IVFFLAT)

---

**Next Step**: [Quick Start](getting-started/01-QUICK-START.md) or [New User Guide](getting-started/02-NEW-USER-GUIDE.md)
