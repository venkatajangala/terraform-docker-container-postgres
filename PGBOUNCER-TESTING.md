# PgBouncer Testing and Validation Guide

## 📋 Pre-Deployment Checklist

- [ ] All 3 Patroni nodes (pg-node-1, pg-node-2, pg-node-3) are running
- [ ] etcd is running and healthy
- [ ] Docker network `pg-ha-network` is created
- [ ] PostgreSQL credentials are correct
- [ ] No port conflicts (6432, 6433, 6434 are available)

```bash
# Verify prerequisites
docker ps | grep -E 'pg-node|etcd'
docker network ls | grep pg-ha-network
```

## 🧪 Step-by-Step Testing

### Test 1: Terraform Validation

```bash
cd /home/vejang/terraform-docker-container-postgres

# Validate syntax
terraform validate

# Plan deployment
terraform plan -var-file="ha-test.tfvars"

# Expected: No errors, shows 3 new resources
# - docker_image.pgbouncer[0]
# - docker_container.pgbouncer_1[0]
# - docker_container.pgbouncer_2[0]
```

✅ **Pass Criteria**: `terraform validate` returns no errors

### Test 2: Docker Image Build

```bash
# Build PgBouncer image
docker build -f Dockerfile.pgbouncer -t pgbouncer:test .

# Expected output: Successfully built [hash] pgbouncer:test
```

✅ **Pass Criteria**: Image builds successfully without errors

### Test 3: Container Startup

```bash
# Check current containers
docker ps | grep pgbouncer

# Should initially show 0 PgBouncer containers

# Deploy via Terraform
terraform apply -var-file="ha-test.tfvars" -auto-approve

# Expected: Creates pgbouncer-1 and pgbouncer-2 (or -3)
```

✅ **Pass Criteria**: `docker ps | grep pgbouncer` shows running containers

### Test 4: Container Health

```bash
# Check health status
docker inspect pgbouncer-1 --format='{{.State.Health.Status}}'
docker inspect pgbouncer-2 --format='{{.State.Health.Status}}'

# Expected: "healthy" (may take 20-30 seconds after start)

# Wait for health checks to complete
sleep 30

# Check again
docker inspect pgbouncer-1 --format='{{.State.Health}}'
```

✅ **Pass Criteria**: Both show `"Status": "healthy"`

### Test 5: Network Connectivity

```bash
# Test from PgBouncer to PostgreSQL nodes
docker exec pgbouncer-1 nc -zv pg-node-1 5432
docker exec pgbouncer-1 nc -zv pg-node-2 5432
docker exec pgbouncer-1 nc -zv pg-node-3 5432

# Expected: Successfully connected to [ip] port 5432

# Verify from host
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"

# Expected: Returns (1 row)
```

✅ **Pass Criteria**: All connectivity tests succeed

### Test 6: Basic Connection Test

```bash
# Connect directly to pgbouncer-1
psql -h localhost -p 6432 -U pgadmin -d postgres \
  -c "SELECT version();"

# Expected output:
# PostgreSQL 18.x on ...
```

✅ **Pass Criteria**: Returns PostgreSQL version string

### Test 7: PgBouncer Admin Console

```bash
# Connect to pgbouncer admin database
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Try commands
pgbouncer=> SHOW VERSION;
pgbouncer=> SHOW CONFIG;
pgbouncer=> SHOW POOLS;
pgbouncer=> \q

# Should not get "database does not exist" error
```

Expected output for SHOW POOLS:
```
 name     | database | user    | cl_active | cl_waiting | sv_active | sv_idle | sv_used
----------+----------+---------+-----------+------------+-----------+---------+--------
 postgres | postgres | pgadmin |         0 |          0 |         0 |       5 |      0
```

✅ **Pass Criteria**: All commands work in admin console

### Test 8: Connection Pool Growth

```bash
# Terminal 1: Monitor pool
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

pgbouncer=> SELECT database, cl_active, sv_active FROM pgbouncer.pools;

# Terminal 2: Create load
for i in {1..5}; do
  psql -h localhost -p 6432 -U pgadmin -d postgres \
    -c "SELECT pg_sleep(2);" &
done
wait

# Back in Terminal 1: Watch numbers increase/decrease
pgbouncer=> SELECT database, cl_active, sv_active FROM pgbouncer.pools;

# Should show increased connections during load
```

✅ **Pass Criteria**: `cl_active` increases during load, decreases after

### Test 9: Failover Test

```bash
# Terminal 1: Connect to primary
psql -h localhost -p 6432 -U pgadmin -d postgres

# Terminal 2: Kill primary
docker exec pg-node-1 pg_ctl stop -m fast

# Back in Terminal 1: Verify still connected
postgres=> SELECT version();

# Should still work (Patroni triggers failover)
# May see brief connection error, then auto-recovery
```

✅ **Pass Criteria**: Connection either succeeds or auto-reconnects after failover

### Test 10: Query Performance

```bash
# Test concurrent queries
pgbench -h localhost -p 6432 -U pgadmin -d postgres \
  -c 10 -j 4 -t 100

# Expected: Consistent throughput

# Compare with direct PostgreSQL (without pooling)
pgbench -h localhost -p 5432 -U pgadmin -d postgres \
  -c 10 -j 4 -t 100

# PgBouncer should be faster or equal for concurrent connections
```

✅ **Pass Criteria**: No errors, throughput is acceptable

### Test 11: Multiple Instances

```bash
# If pgbouncer_replicas >= 2

# Test both instances
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
psql -h localhost -p 6433 -U pgadmin -d postgres -c "SELECT 1;"

# Expected: Both return (1 row)

# If pgbouncer_replicas >= 3
psql -h localhost -p 6434 -U pgadmin -d postgres -c "SELECT 1;"
```

✅ **Pass Criteria**: All instances respond to queries

### Test 12: Configuration Reload

```bash
# Edit pgbouncer/pgbouncer.ini
# Change default_pool_size = 25 to default_pool_size = 30

# Reload configuration
psql -h localhost -p 6432 -U pgadmin -d pgbouncer \
  -c "RELOAD;"

# Verify change applied
psql -h localhost -p 6432 -U pgadmin -d pgbouncer \
  -c "SHOW CONFIG LIKE 'default_pool_size';"

# Should show 30
```

✅ **Pass Criteria**: Configuration reloads without errors

### Test 13: Statistics Collection

```bash
# Connect to admin console
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Check stats
pgbouncer=> SELECT 
    database,
    client_connections,
    server_connections,
    events_waited,
    query_time
FROM pgbouncer.stats;

# Should show statistics accumulated
pgbouncer=> \q
```

✅ **Pass Criteria**: Statistics data is present and being updated

### Test 14: Logging Verification

```bash
# Check logs are being written
docker logs pgbouncer-1 | head -20

# Should show connection attempts, pool operations
# Expected log entries:
# - "listening on 0.0.0.0:6432"
# - "new connection: pg-node-1:5432/postgres"
# - "pool postgres connected"
```

✅ **Pass Criteria**: Logs show normal operations

### Test 15: Cleanup and Redeployment

```bash
# Destroy resources
terraform destroy -var-file="ha-test.tfvars" -auto-approve

# Verify removed
docker ps | grep pgbouncer
# Should show nothing

# Redeploy
terraform apply -var-file="ha-test.tfvars" -auto-approve

# Verify running again
docker ps | grep pgbouncer
# Should show pgbouncer-1, pgbouncer-2, etc.
```

✅ **Pass Criteria**: Complete destroy and redeploy cycle succeeds

## 📊 Testing Checklist Summary

| Test | Status | Notes |
|------|--------|-------|
| Terraform Validation | ⬜ | Run: `terraform validate` |
| Docker Image Build | ⬜ | Run: `docker build -f Dockerfile.pgbouncer` |
| Container Startup | ⬜ | Run: `terraform apply` |
| Container Health | ⬜ | Check: `docker inspect` health status |
| Network Connectivity | ⬜ | Test: `nc -zv` and `psql` commands |
| Basic Connection | ⬜ | Test: `psql -h localhost -p 6432` |
| Admin Console | ⬜ | Connect to pgbouncer database |
| Connection Pool Growth | ⬜ | Monitor pools during load |
| Failover Test | ⬜ | Kill primary, reconnect |
| Query Performance | ⬜ | Run pgbench test |
| Multiple Instances | ⬜ | Test all PgBouncer ports |
| Configuration Reload | ⬜ | Modify and reload config |
| Statistics Collection | ⬜ | Check stats tables |
| Logging Verification | ⬜ | Review docker logs |
| Cleanup/Redeploy | ⬜ | Full destroy/create cycle |

## 🔍 Advanced Testing

### Test Memory Usage

```bash
# Monitor memory during load
docker stats pgbouncer-1 pgbouncer-2 --no-stream

# Run queries
psql -h localhost -p 6432 -U pgadmin -d postgres \
  -c "SELECT * FROM generate_series(1, 1000000);" > /dev/null &

# Watch memory in another terminal
docker stats pgbouncer-1 pgbouncer-2 --format "table {{.Container}}\t{{.MemUsage}}"
```

### Test Database-Specific Pooling

```bash
# Create multiple database connections
for i in {1..3}; do
  psql -h localhost -p 6432 -U pgadmin -d postgres \
    -c "SELECT 1 FROM pg_sleep(5);" &
done

# Monitor individual database pools
psql -h localhost -p 6432 -U pgadmin -d pgbouncer \
  -c "SELECT database, cl_active, sv_active FROM pgbouncer.pools;"

wait
```

### Test Load Balancing

```bash
# If multiple replicas exist
for i in {1..100}; do
  psql -h localhost -p 6432 -U pgadmin -d postgres \
    -c "SELECT inet_server_addr();" 2>/dev/null
done | sort | uniq -c

# Should show connections distributed across nodes
```

## ✅ Success Criteria Summary

Your PgBouncer setup is **READY FOR PRODUCTION** when:

✅ All 15 core tests pass  
✅ No errors in `terraform apply`  
✅ Health checks show "healthy"  
✅ Connections can connect via port 6432  
✅ Admin console responds to all commands  
✅ Configuration reload works  
✅ Failover is automatic and seamless  
✅ Performance is acceptable or improved  
✅ Logs are clean and informative  
✅ Statistics are being collected  

## 🐛 If Tests Fail

### Common Issues

**Issue**: Health check fails
```bash
# Solution: Wait longer (health checks take 20-30 seconds)
sleep 30
docker inspect pgbouncer-1 --format='{{.State.Health}}'
```

**Issue**: "Connection refused"
```bash
# Solution: Check if PostgreSQL nodes are running
docker ps | grep pg-node
# If not, focus on bringing up PostgreSQL first
```

**Issue**: "Authentication failed"
```bash
# Solution: Verify userlist.txt has correct users
cat pgbouncer/userlist.txt
# Compare with PostgreSQL users
docker exec pg-node-1 psql -U pgadmin -c "SELECT usename FROM pg_user;"
```

**Issue**: "Database does not exist"
```bash
# Solution: Ensure you're connecting to 'postgres' database
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
# NOT:
# psql -h localhost -p 6432 -U pgadmin -d pgbouncer  (admin only)
```

---

**All tests passing?** 🎉 Your PgBouncer HA setup is ready!

**Need help?** See [PGBOUNCER-SETUP.md](./PGBOUNCER-SETUP.md) for detailed troubleshooting.
