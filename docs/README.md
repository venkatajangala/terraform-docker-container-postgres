# 📚 Documentation Structure

Welcome! This folder contains organized documentation for the PostgreSQL HA + PgBouncer infrastructure. Choose your path based on your needs.

## 🚀 Getting Started (5-15 minutes)

Start here if you're new to this project:

- **[Quick Start](getting-started/01-QUICK-START.md)** - Deploy in 5 minutes
- **[New User Guide](getting-started/02-NEW-USER-GUIDE.md)** - Comprehensive overview for beginners
- **[Architecture Overview](architecture/ARCHITECTURE.md)** - Understand what you're deploying

## 📖 Detailed Guides (For Daily Use)

- **[PostgreSQL HA Setup](guides/01-POSTGRES-HA.md)** - Understanding the cluster
- **[PgBouncer Configuration](pgbouncer/01-PGBOUNCER-SETUP.md)** - Connection pooling setup & tuning
- **[Operations & Maintenance](guides/02-OPERATIONS.md)** - How to run and maintain the system
- **[Troubleshooting](guides/03-TROUBLESHOOTING.md)** - Common issues and solutions

## 🧪 Testing & Validation

- **[Testing Guide](testing/TESTING.md)** - Comprehensive test suite with 15+ scenarios
- **[Test Report](testing/TEST-REPORT.md)** - Latest test execution results
- **[Health Checks](testing/HEALTH-CHECKS.md)** - How to verify system health

## 🔧 Reference & Advanced

- **[Terraform Configuration](reference/TERRAFORM.md)** - Infrastructure code details
- **[Configuration Reference](reference/CONFIG-REFERENCE.md)** - All variables and settings
- **[API Reference](reference/API-REFERENCE.md)** - REST APIs and query examples
- **[Security Hardening](reference/SECURITY.md)** - Security best practices

## 📊 Diagrams & Visuals

- **[Architecture Diagrams](architecture/DIAGRAMS.md)** - Network, failover, and component diagrams
- **[Workflow Diagrams](architecture/WORKFLOWS.md)** - Deployment and operation flows

## 🎯 Recommended Paths by Role

### 👤 I'm a New Team Member
**Time: 30 minutes**
1. Read [New User Guide](getting-started/02-NEW-USER-GUIDE.md)
2. Review [Architecture Overview](architecture/ARCHITECTURE.md)
3. Follow [Quick Start](getting-started/01-QUICK-START.md) to deploy locally
4. Review [Operations & Maintenance](guides/02-OPERATIONS.md)

### 🛠️ I'm an Operator/DevOps
**Time: 1-2 hours**
1. Read [PostgreSQL HA Setup](guides/01-POSTGRES-HA.md)
2. Review [PgBouncer Configuration](pgbouncer/01-PGBOUNCER-SETUP.md)
3. Run [Testing Guide](testing/TESTING.md)
4. Bookmark [Troubleshooting](guides/03-TROUBLESHOOTING.md)
5. Review [Operations & Maintenance](guides/02-OPERATIONS.md)

### 🏗️ I'm Infrastructure/Platform Engineer
**Time: 2-4 hours**
1. Review full [Architecture Overview](architecture/ARCHITECTURE.md)
2. Study [Terraform Configuration](reference/TERRAFORM.md)
3. Understand [Configuration Reference](reference/CONFIG-REFERENCE.md)
4. Review [Security Hardening](reference/SECURITY.md)
5. Plan scaling strategy using [Advanced Tuning](reference/CONFIG-REFERENCE.md#advanced-tuning)

### 🔍 I'm Troubleshooting an Issue
**Time: 15-30 minutes**
1. Check [Troubleshooting](guides/03-TROUBLESHOOTING.md)
2. Run diagnostic commands from [Health Checks](testing/HEALTH-CHECKS.md)
3. Review relevant logs
4. Consult [Operations & Maintenance](guides/02-OPERATIONS.md) for procedures

## 📁 File Organization

```
docs/
├── README.md                           ← You are here
│
├── getting-started/                    ← Begin here
│   ├── 01-QUICK-START.md              # 5-minute deployment
│   └── 02-NEW-USER-GUIDE.md           # Comprehensive introduction
│
├── guides/                             ← Daily operations
│   ├── 01-POSTGRES-HA.md              # Cluster details
│   ├── 02-OPERATIONS.md               # Running & maintenance
│   └── 03-TROUBLESHOOTING.md          # Common issues & fixes
│
├── pgbouncer/                          ← Connection pooling
│   ├── 01-PGBOUNCER-SETUP.md          # Configuration guide
│   ├── 02-PGBOUNCER-TUNING.md         # Performance optimization
│   └── 03-PGBOUNCER-MONITORING.md     # Monitoring & statistics
│
├── testing/                            ← Quality assurance
│   ├── TESTING.md                     # Test procedures
│   ├── TEST-REPORT.md                 # Recent results
│   └── HEALTH-CHECKS.md               # Verification commands
│
├── architecture/                       ← System design
│   ├── ARCHITECTURE.md                # Overall architecture
│   ├── DIAGRAMS.md                    # Visual diagrams
│   └── WORKFLOWS.md                   # Operation flows
│
└── reference/                          ← Technical details
    ├── TERRAFORM.md                   # IaC code details
    ├── CONFIG-REFERENCE.md            # All variables
    ├── API-REFERENCE.md               # REST APIs
    └── SECURITY.md                    # Security guide
```

## ⏱️ Time Estimates

- **Quick Start**: 5 minutes
- **New User Guide**: 20 minutes
- **Full Setup & Verification**: 1 hour
- **Complete Deep Dive**: 4 hours

## 🆘 Getting Help

| Question | Read This |
|----------|-----------|
| How do I deploy? | [Quick Start](getting-started/01-QUICK-START.md) |
| How do I configure PgBouncer? | [PgBouncer Setup](pgbouncer/01-PGBOUNCER-SETUP.md) |
| How do I run tests? | [Testing Guide](testing/TESTING.md) |
| What's the architecture? | [Architecture Overview](architecture/ARCHITECTURE.md) |
| Something is broken! | [Troubleshooting](guides/03-TROUBLESHOOTING.md) |
| I need a specific command | [Health Checks](testing/HEALTH-CHECKS.md) or [API Reference](reference/API-REFERENCE.md) |
| How do I secure this? | [Security Hardening](reference/SECURITY.md) |
| What are my options? | [Configuration Reference](reference/CONFIG-REFERENCE.md) |

## 🔍 Quick Command Reference

```bash
# Deploy
cd /home/vejang/terraform-docker-container-postgres
terraform apply -var-file="ha-test.tfvars"

# Test connection
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"

# View logs
docker logs pgbouncer-1 -f

# Check health
curl -s http://localhost:8008/leader | python3 -m json.tool

# Access admin console
psql -h localhost -p 6432 -U pgadmin -d pgbouncer
```

## 📈 Infrastructure Status

- ✅ PostgreSQL 18 (3-node HA cluster)
- ✅ Patroni orchestration
- ✅ etcd distributed consensus
- ✅ PgBouncer connection pooling
- ✅ DBHub/Bytebase web UI
- ✅ pgvector support

**Last Updated**: 2026-03-07  
**Status**: Production Ready ✅

---

**Next Step**: Choose your path above or start with [Quick Start](getting-started/01-QUICK-START.md)
