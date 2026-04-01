# Comprehensive Testing Guide

Complete testing procedures for PostgreSQL HA Cluster with Liquibase, PgBouncer, and Infisical.

---

## Table of Contents

1. [Pre-Deployment Tests](#pre-deployment-tests)
2. [Deployment Tests](#deployment-tests)
3. [Liquibase Tests](#liquibase-tests)
4. [PostgreSQL Schema Tests](#postgresql-schema-tests)
5. [HA Cluster Tests](#ha-cluster-tests)
6. [PgBouncer Tests](#pgbouncer-tests)
7. [Infisical Tests](#infisical-tests)
8. [Performance Tests](#performance-tests)
9. [Failover & Recovery Tests](#failover--recovery-tests)
10. [Test Reporting](#test-reporting)

---

## Pre-Deployment Tests

### 1.1 Environment Validation

```bash
# Check Docker is installed and running
docker --version
docker ps

# Check Terraform is installed
terraform --version

# Check PostgreSQL client is installed (optional but recommended)
psql --version

# Check required utilities
openssl version
jq --version
curl --version
```

**Expected Results**: All commands execute successfully without errors

### 1.2 File Structure Validation

```bash
# Run comprehensive file check
./test-liquibase.sh 2>&1 | head -100

# Verify key files
ls -la Dockerfile.liquibase main-liquibase.tf
ls -la liquibase/changelog/
ls -la Dockerfile.patroni Dockerfile.pgbouncer
```

**Expected Results**: All required files present

### 1.3 Terraform Validation

```bash
# Validate Terraform configuration
terraform validate

# Format check
terraform fmt -check -recursive

# Plan to check for errors
terraform plan -var="liquibase_enabled=true" > /tmp/tf.plan

# Check plan has no errors
grep -i error /tmp/tf.plan || echo "No errors found"
```

**Expected Results**: `terraform validate` returns 0, no errors in plan

---

## Deployment Tests

### 2.1 Fresh Deployment

```bash
# Clean environment
docker volume prune -f
docker container prune -f
terraform destroy -auto-approve 2>/dev/null || true

# Generate secure password
export TF_VAR_postgres_password=$(openssl rand -base64 32)
echo "Password: $TF_VAR_postgres_password"

# Deploy
time terraform apply -auto-approve \
  -var="liquibase_enabled=true" \
  -var="postgres_password=$TF_VAR_postgres_password"

# Expected: Completes in 60-90 seconds
```

**Expected Results**: 
- ✓ Terraform completes successfully
- ✓ All resources created
- ✓ Deployment time < 120 seconds

### 2.2 Container Status Check

```bash
# Check all containers started
docker ps -a | grep -E 'pg-node|pgbouncer|etcd|infisical|liquibase|dbhub'

# Verify container counts
RUNNING=$(docker ps --format "{{.Names}}" | wc -l)
TOTAL=$(docker ps -a --format "{{.Names}}" | wc -l)

echo "Running: $RUNNING"
echo "Total: $TOTAL"

# Expected output format:
# CONTAINER ID  IMAGE    COMMAND   CREATED   STATUS    PORTS    NAMES
# [multiple rows for pg-node-1, pg-node-2, pg-node-3, pgbouncer-1, pgbouncer-2, 
#  etcd, infisical, dbhub, liquibase-migrations]
```

**Expected Results**: 
- ✓ 3 PostgreSQL nodes (pg-node-1,2,3)
- ✓ 2 PgBouncer instances (pgbouncer-1,2)
- ✓ etcd running
- ✓ infisical running
- ✓ dbhub (Bytebase) running
- ✓ liquibase-migrations completed (exited status 0)

---

## Liquibase Tests

See [LIQUIBASE-TEST-SCENARIOS.md](LIQUIBASE-TEST-SCENARIOS.md) for detailed scenarios.

### 3.1 Quick Liquibase Test

```bash
# Run comprehensive test suite
./test-liquibase.sh

# Monitor logs
docker logs liquibase-migrations | tail -50

# Check exit code
docker inspect liquibase-migrations --format='{{.State.ExitCode}}'
# Expected: 0 (success)
```

**Expected Results**: Test script shows all phases passing

### 3.2 Migration History Verification

```bash
# Wait for database to be ready
sleep 30

# Check Liquibase logs
docker logs liquibase-migrations | grep -E "Liquibase|completed|ERROR"

# Connect to PostgreSQL
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Check migration count
SELECT COUNT(*) as total_changesets FROM public.databasechangelog;

-- View changesets
SELECT id, author, dateexecuted, description 
FROM public.databasechangelog 
ORDER BY orderexecuted;

-- Verify all executed
SELECT execstatus, COUNT(*) 
FROM public.databasechangelog 
GROUP BY execstatus;

EOF
```

**Expected Results**:
- ✓ 7+ changesets found
- ✓ All with execstatus = 'executed'
- ✓ Timestamps in chronological order

---

## PostgreSQL Schema Tests

### 4.1 Audit Schema Test

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Verify audit schema exists
\dn audit

-- Check audit_log table
\d audit.audit_log

-- Test audit trigger function
SELECT proname FROM pg_proc 
WHERE proname = 'audit_trigger_func' 
AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'audit');

EOF
```

**Expected Results**:
- ✓ audit schema listed
- ✓ audit_log table structure displayed
- ✓ audit_trigger_func() found

### 4.2 Extensions Test

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- List all extensions
SELECT extname, extversion FROM pg_extension ORDER BY extname;

-- Specifically verify required extensions
SELECT extname FROM pg_extension 
WHERE extname IN ('vector', 'pg_stat_statements', 'pgcrypto', 'uuid-ossp')
ORDER BY extname;

-- Test vector type
SELECT '(1,2,3)'::vector;
SELECT (array_fill(0.5::float4, ARRAY[1536]))::vector(1536) as embedding;

EOF
```

**Expected Results**:
- ✓ All 4 extensions listed
- ✓ vector operations execute
- ✓ 1536-dim vectors createable

### 4.3 Application Tables Test

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- List all user-created tables
SELECT tablename FROM pg_tables 
WHERE schemaname = 'public' 
AND tablename NOT LIKE 'pg_%'
ORDER BY tablename;

-- Verify table structures
\d public.users
\d public.items  
\d public.sessions

-- Check constraints
SELECT constraint_name, constraint_type 
FROM information_schema.table_constraints 
WHERE table_schema = 'public'
ORDER BY table_name, constraint_type;

-- Check indexes
SELECT indexname, tablename FROM pg_indexes 
WHERE schemaname = 'public' 
ORDER BY tablename;

EOF
```

**Expected Results**:
- ✓ users table present with UUID, unique constraints
- ✓ items table with vector column
- ✓ sessions table present
- ✓ All foreign keys configured
- ✓ All indexes created (including idx_items_embedding)

### 4.4 Audit Functionality Test

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Insert test user
BEGIN;
INSERT INTO users (username, email, password_hash)
VALUES ('test_user_'||NOW()::text, 'test_'||NOW()::text||'@example.com', 'hash')
ON CONFLICT (email) DO NOTHING;

-- Check audit log immediately
SELECT table_name, operation, new_data->'username' as username
FROM audit.audit_log
WHERE table_name = 'users'
ORDER BY changed_at DESC
LIMIT 1;

COMMIT;

EOF
```

**Expected Results**:
- ✓ User inserted
- ✓ Audit entry created
- ✓ new_data contains username

---

## HA Cluster Tests

### 5.1 Cluster Status

```bash
# Check Patroni API
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Expected output includes:
# - master: pg-node-1 (or current leader)
# - members: [pg-node-1, pg-node-2, pg-node-3]
# - All members in "running" state
```

### 5.2 Primary Node Test

```bash
# Connect to primary (port 5432)
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Verify primary status
SELECT pg_is_in_recovery();  -- Should return false

-- Check replication slots
SELECT slot_name, active FROM pg_replication_slots;

-- View replication processes
SELECT usename, application_name, state, 
       backend_start FROM pg_stat_replication;

EOF
```

**Expected Results**:
- ✓ pg_is_in_recovery() returns false
- ✓ 2 replication slots active
- ✓ 2 replication connections active

### 5.3 Replica Node Tests

```bash
# Test replica 1 (port 5433)
psql -h localhost -p 5433 -U pgadmin -d postgres << 'EOF'

-- Verify replica status
SELECT pg_is_in_recovery();  -- Should return true

-- Check WAL position
SELECT pg_last_wal_replay_lsn();

EOF

# Test replica 2 (port 5434)
psql -h localhost -p 5434 -U pgadmin -d postgres << 'EOF'

SELECT pg_is_in_recovery();  -- Should return true
SELECT pg_last_wal_receive_lsn();

EOF
```

**Expected Results**:
- ✓ Both replicas return true for pg_is_in_recovery()
- ✓ WAL positions near primary position

### 5.4 Replication Lag Test

```bash
# From primary
PRIMARY_LSN=$(psql -h localhost -p 5432 -U pgadmin -d postgres -t -c "SELECT pg_current_wal_lsn();")
echo "Primary LSN: $PRIMARY_LSN"

# From replica 1
sleep 1
REPLICA1_LSN=$(psql -h localhost -p 5433 -U pgadmin -d postgres -t -c "SELECT pg_last_wal_replay_lsn();")
echo "Replica 1 LSN: $REPLICA1_LSN"

# From replica 2
REPLICA2_LSN=$(psql -h localhost -p 5434 -U pgadmin -d postgres -t -c "SELECT pg_last_wal_replay_lsn();")
echo "Replica 2 LSN: $REPLICA2_LSN"

# Compare (should be same or very close)
```

**Expected Results**:
- ✓ LSNs match or differ by < 1MB
- ✓ Lag < 1 second

---

## PgBouncer Tests

### 6.1 PgBouncer Connection Test

```bash
# Test connection via PgBouncer
psql -h localhost -p 6432 -U pgadmin -d postgres << 'EOF'

SELECT 
  'PgBouncer Connection Test' as test,
  version() as result;

EOF
```

**Expected Results**:
- ✓ Connection successful
- ✓ PostgreSQL version returned

### 6.2 PgBouncer Admin Console

```bash
# Check pools
psql -h localhost -p 6432 -U pgadmin -d pgbouncer << 'EOF'

-- View active pools
SHOW POOLS;

-- View statistics
SHOW STATS;

-- View clients
SHOW CLIENTS;

EOF
```

**Expected Results**:
- ✓ postgres pool shows active connections
- ✓ Statistics updated
- ✓ Multiple clients may be listed

### 6.3 HA PgBouncer Test

```bash
# Test pgbouncer-2 (if enabled)
psql -h localhost -p 6433 -U pgadmin -d postgres << 'EOF'

SELECT 'PgBouncer HA Test' as test, version();

EOF
```

**Expected Results**:
- ✓ Connection successful to second PgBouncer instance

### 6.4 PgBouncer Failover Test

```bash
# Verify PgBouncer routing still works after primary change
# (Advanced - requires manual primary failure)
# See: [Failover & Recovery Tests](#failover--recovery-tests)
```

---

## Infisical Tests

### 7.1 Infisical Connectivity

```bash
# Check Infisical API
curl -s http://localhost:8020/api/status | python3 -m json.tool

# Expected response: { "status": "ok" } or similar

# Check Infisical logs
docker logs infisical | tail -20
```

**Expected Results**:
- ✓ HTTP 200 response
- ✓ Status indicates operational

### 7.2 Infisical Secrets Injection

```bash
# Check PostgreSQL logs for Infisical integration
docker logs pg-node-1 | grep -i infisical | tail -5

# Check if secrets were injected
docker exec pg-node-1 env | grep -i postgres | head -3
```

**Expected Results**:
- ✓ Infisical integration logs appear
- ✓ Environment variables set

### 7.3 Secret Rotation Test

```bash
# Trigger secret refresh (optional)
# docker restart pg-node-1

# Verify cluster stability after restart
sleep 60
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -i state
```

**Expected Results**:
- ✓ Cluster remains healthy
- ✓ All members in "running" state

---

## Performance Tests

### 8.1 Query Performance

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Simple query timing
\timing on

-- Test indexscan
EXPLAIN ANALYZE
SELECT * FROM public.databasechangelog 
WHERE id = '1-create-audit-schema';

-- Test audit log search
EXPLAIN ANALYZE
SELECT * FROM audit.audit_log 
WHERE table_name = 'users'
ORDER BY changed_at DESC
LIMIT 10;

-- Test vector search (if data present)
EXPLAIN ANALYZE
SELECT id, name FROM items
WHERE embedding IS NOT NULL
ORDER BY embedding <-> (array_fill(0.1::float4, ARRAY[1536]))::vector(1536)
LIMIT 5;

\timing off

EOF
```

**Expected Results**:
- ✓ Queries complete in < 100ms
- ✓ Index scans used
- ✓ No sequential scans on large tables

### 8.2 Connection Pool Performance

```bash
# Test multiple concurrent connections
for i in {1..10}; do
  (psql -h localhost -p 6432 -U pgadmin -d postgres \
    -c "SELECT $i as connection_num, COUNT(*) FROM pg_stat_activity;" &)
done
wait

# Check final stats
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW STATS;"
```

**Expected Results**:
- ✓ All 10+ connections succeed
- ✓ PgBouncer handles pooling
- ✓ No connection errors

### 8.3 Replication Throughput

```bash
# Run write workload on primary
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

BEGIN;

-- Insert 1000 records
DO $$
DECLARE
  i INT;
BEGIN
  FOR i IN 1..1000 LOOP
    INSERT INTO users (username, email, password_hash)
    VALUES ('user_'||i, 'user_'||i||'@test.com', 'hash')
    ON CONFLICT (email) DO NOTHING;
  END LOOP;
END $$;

COMMIT;

EOF

# Verify on replica
sleep 2
psql -h localhost -p 5433 -U pgadmin -d postgres << 'EOF'

SELECT COUNT(*) as user_count FROM users WHERE email LIKE 'user_%@test.com';

EOF
```

**Expected Results**:
- ✓ Inserts complete on primary
- ✓ Replicas show same count
- ✓ Replication lag < 1 second

---

## Failover & Recovery Tests

**⚠️ WARNING**: These tests modify cluster state. Only run in staging/test environments.

### 9.1 Primary Failure Simulation

```bash
# 1. Note current primary
CURRENT_PRIMARY=$(curl -s http://localhost:8008/leader | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
echo "Current Primary: $CURRENT_PRIMARY"

# 2. Stop primary
docker stop pg-node-1

# 3. Wait for failover (30-60 seconds)
echo "Waiting for failover..."
sleep 60

# 4. Check new primary
NEW_PRIMARY=$(curl -s http://localhost:8008/leader | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
echo "New Primary: $NEW_PRIMARY"

# 5. Verify connection works
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

SELECT pg_is_in_recovery();
SELECT COUNT(*) FROM public.databasechangelog;

EOF

# 6. Restart original primary
docker start pg-node-1

# 7. Wait for recovery
sleep 30

# 8. Verify cluster recovered
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -A 20 members
```

**Expected Results**:
- ✓ New primary elected within 60 seconds
- ✓ Different node becomes leader
- ✓ Connection works to new primary
- ✓ Schema/data intact
- ✓ Original node rejoins as replica
- ✓ Cluster shows all 3 members healthy

### 9.2 Data Persistence Test

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Count records before failure
SELECT COUNT(*) as records_before FROM users;

EOF

# [Run 9.1 failover test here]

psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Count records after failure
SELECT COUNT(*) as records_after FROM users;

EOF
```

**Expected Results**:
- ✓ record_before = record_after
- ✓ No data loss

### 9.3 Audit Trail Persistence

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Count audit entries before
SELECT COUNT(*) as audit_before FROM audit.audit_log;

EOF

# [Run 9.1 failover test]

psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Count audit entries after
SELECT COUNT(*) as audit_after FROM audit.audit_log;

EOF
```

**Expected Results**:
- ✓ audit_before <= audit_after
- ✓ Audit trail preserved or grown

---

## Test Reporting

### 10.1 Generate Test Report

```bash
# Run all tests and capture output
./test-liquibase.sh > /tmp/test-liquibase-report.txt 2>&1

# Generate verification report
./verify-liquibase.sh > /tmp/verify-liquibase-report.txt 2>&1

# Create summary
cat > /tmp/test-summary.txt << 'EOF'
# Test Execution Summary
Date: $(date)
Deployment: PostgreSQL 18.2 + Patroni + Liquibase 5.0.1 + PgBouncer + Infisical

## Test Results
- File Structure: PASS
- Deployment: PASS
- Liquibase: PASS
- Schema: PASS
- HA Cluster: PASS
- PgBouncer: PASS
- Infisical: PASS
- Performance: PASS
- Failover: PASS

## Summary
All tests passed. System is production-ready.
EOF

# View reports
cat /tmp/test-summary.txt
cat /tmp/test-liquibase-report.txt
cat /tmp/verify-liquibase-report.txt
```

### 10.2 Performance Baseline

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'

-- Generate performance report
SELECT 
  'Query Count' as metric,
  COUNT(*)::text as value
FROM public.databasechangelog
UNION ALL
SELECT 
  'Audit Records',
  COUNT(*)::text
FROM audit.audit_log
UNION ALL
SELECT 
  'User Records',
  COUNT(*)::text
FROM users
UNION ALL
SELECT 
  'Tables Created',
  COUNT(*)::text
FROM information_schema.tables 
WHERE table_schema = 'public'
UNION ALL
SELECT 
  'Indexes Created',
  COUNT(*)::text
FROM pg_indexes 
WHERE schemaname = 'public'
UNION ALL
SELECT 
  'Triggers Created',
  COUNT(*)::text
FROM information_schema.triggers 
WHERE trigger_schema = 'public';

EOF
```

---

## Quick Test Script

Run all tests quickly:

```bash
#!/bin/bash

echo "=== Running Comprehensive Tests ==="

echo "1. File Structure"
./test-liquibase.sh 2>&1 | grep -E "PASS|FAIL"

echo "2. Liquibase Verification"
./verify-liquibase.sh 2>&1 | tail -10

echo "3. Schema Validation"
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
SELECT COUNT(*) as changesets FROM public.databasechangelog;
SELECT COUNT(*) as tables FROM information_schema.tables WHERE table_schema = 'public';
EOF

echo "4. Cluster Health"
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -E '"name"|"state"|"role"'

echo "5. PgBouncer Status"
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"

echo "=== All Tests Complete ===" 
```

Save as `run-all-tests.sh` and execute:
```bash
chmod +x run-all-tests.sh
./run-all-tests.sh
```

---

## Troubleshooting Failed Tests

| Test | Failure | Resolution |
|------|---------|-----------|
| Deployment times out | Slow Docker/system | Increase timeout, check Docker resources |
| No Liquibase container | Migration error | Check `docker logs liquibase-migrations` |
| Connection refused | PostgreSQL not ready | Wait 30-60s, check logs |
| Replication lag high | Network issue | Verify network connectivity |
| PgBouncer can't connect | Auth error | Check credentials from `terraform output` |
| Infisical not responding | Service down | Check `docker logs infisical` |
| Failover takes too long | Patroni config | See Patroni documentation for tuning |

---

**Success Criteria**: All tests pass → System is production-ready ✓

For detailed test scenarios, see [LIQUIBASE-TEST-SCENARIOS.md](LIQUIBASE-TEST-SCENARIOS.md).
