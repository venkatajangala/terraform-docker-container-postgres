# PostgreSQL HA Cluster - Quick Start (5 Minutes)

**For experienced DevOps engineers who want to deploy immediately.**

If you prefer a guided walkthrough, see [HA-DEPLOYMENT.md](HA-DEPLOYMENT.md) instead.

---

## Prerequisites

```bash
✓ Terraform v1.0+: terraform version
✓ Docker v20.10+: docker version
✓ 8GB+ RAM
✓ 20GB+ disk space
```

---

## Deploy (1 minute)

```bash
# 1. Initialize Terraform
terraform init

# 2. Deploy (5 defaults: postgres_user=pgadmin, postgres_password=pgAdmin1, etc.)
terraform apply -auto-approve \
  -var="postgres_password=MySecurePass123!" \
  -var="replication_password=ReplicaPass456!"

# Expected: "Apply complete! Resources: 13 added"
# Timeline: ~60 seconds until full cluster ready
```

---

## Verify (30 seconds)

```bash
# Check containers running
docker ps | grep -E "pg-node|etcd|dbhub"
# Expected: 5 containers, all "Up"

# Check primary elected
curl http://localhost:8008/leader
# Expected: {"leader": "pg-node-1"} (or another node)

# Check replication
curl -s http://localhost:8008/cluster | jq '.members[] | {name: .name, role: .role, state: .state}'
# Expected: 1 primary, 2 replicas all "in_sync"
```

---

## Connect

```bash
# PostgreSQL primary (write)
psql postgresql://pgadmin:MySecurePass123!@localhost:5432/postgres

# Or use terraform output
psql $(terraform output -raw pg_primary_endpoint)

# PostgreSQL replica-1 (read-only)
psql postgresql://pgadmin:MySecurePass123!@localhost:5433/postgres

# DBHub web UI
open http://localhost:9090
# Login: admin@bytebase.com / bytebase
```

---

## Initialize pgvector

```bash
# One-time initialization (run on primary)
docker exec pg-node-1 psql -U pgadmin postgres \
  -f /var/lib/postgresql/init-pgvector-ha.sql

# Verify
docker exec pg-node-1 psql -U pgadmin postgres -c "SELECT COUNT(*) FROM items;"
# Expected: 0 (empty table, ready for use)
```

---

## Test Failover (30 seconds)

```bash
# Monitor current primary
LEADER1=$(curl -s http://localhost:8008/leader | jq -r '.leader')
echo "Current primary: $LEADER1"

# Kill primary (simulates failure)
docker kill pg-node-$LEADER1

# Watch replica take over (wait 30 seconds)
for i in {1..30}; do
  LEADER=$(curl -s http://localhost:8008/leader 2>/dev/null | jq -r '.leader // "NONE"')
  echo "[$i] Primary: $LEADER"
  [ "$LEADER" != "NONE" ] && [ "$LEADER" != "$LEADER1" ] && break
  sleep 1
done

# Restart failed primary (becomes replica)
docker start pg-node-$LEADER1

# Verify cluster rebuilt
curl -s http://localhost:8008/cluster | jq '.members[] | {name: .name, state: .state}'
# Expected: 3 members, 2+ "in_sync"
```

---

## Backup & Restore

```bash
# Create backup
docker exec pg-node-1 pgbackrest backup --type=full

# Verify backup
docker exec pg-node-1 pgbackrest info
# Expected: "backup:" section with timestamp and size

# To restore: See [HA-OPERATIONS.md](HA-OPERATIONS.md#point-in-time-recovery-pitr)
```

---

## Daily Health Check

```bash
# One-liner to verify cluster health
curl -s http://localhost:8008/cluster | jq '{
  primary: [.members[] | select(.role=="primary") | .name][0],
  replicas_in_sync: [.members[] | select(.role=="replica" and .state=="in_sync")] | length,
  total_members: .members | length
}'

# Expected:
# {"primary": "pg-node-1", "replicas_in_sync": 2, "total_members": 3}
```

---

## Common Commands

| Command | Purpose |
|---------|---------|
| `curl http://localhost:8008/cluster` | Full cluster status (JSON) |
| `curl http://localhost:8008/leader` | Current primary node |
| `docker logs -f pg-node-1` | View logs from primary |
| `docker exec pg-node-1 pgbackrest info` | Backup status |
| `docker ps` | Running containers |
| `terraform output` | All connection endpoints |
| `terraform destroy -auto-approve` | Delete entire cluster (⚠️ data loss) |

---

## Production Checklist

- [ ] Change default passwords before deploying
- [ ] Configure external backup storage (S3, GCS)
- [ ] Set up monitoring/alerting (Prometheus, Grafana)
- [ ] Test failover monthly
- [ ] Document your runbooks
- [ ] Set up automated backups
- [ ] Enable SSL/TLS for connections
- [ ] Review [HA-SETUP-GUIDE.md#production-checklist](HA-SETUP-GUIDE.md#production-checklist)

---

## Full Documentation

- **Architecture & Features**: [HA-SETUP-GUIDE.md](HA-SETUP-GUIDE.md)
- **Detailed Deployment**: [HA-DEPLOYMENT.md](HA-DEPLOYMENT.md)
- **Monitoring & Health**: [HA-MONITORING.md](HA-MONITORING.md)
- **Troubleshooting**: [HA-TROUBLESHOOTING.md](HA-TROUBLESHOOTING.md)
- **Daily Operations**: [HA-OPERATIONS.md](HA-OPERATIONS.md)
- **File Reference**: [HA-FILES.md](HA-FILES.md)

---

## Support

All files include detailed references to official documentation for PostgreSQL, Patroni, pgBackRest, and etcd.

**Stuck?** Check [HA-TROUBLESHOOTING.md](HA-TROUBLESHOOTING.md) first.
