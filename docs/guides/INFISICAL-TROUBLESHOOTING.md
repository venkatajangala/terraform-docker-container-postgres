# Infisical Integration - Troubleshooting Guide

## Common Issues and Solutions

### 1. Infisical Container Won't Start

**Symptoms**:
```
docker ps | grep infisical
# No output or container keeps restarting
```

**Root Causes & Solutions**:

#### A. Database Backend Not Ready

```bash
# Check if infisical-postgres is running
docker ps | grep infisical-postgres

# If not running, check logs
docker logs infisical-postgres

# If it's in crash loop, check volume
docker volume ls | grep infisical-db

# Solution: Destroy and recreate
docker stop infisical infisical-postgres
docker rm infisical infisical-postgres
docker volume rm infisical-db-data infisical-data
terraform apply -var-file="ha-test.tfvars" -target=docker_container.infisical_postgres
sleep 30
terraform apply -var-file="ha-test.tfvars" -target=docker_container.infisical
```

#### B. Port Conflict

```bash
# Check if port 8020 is already in use
netstat -tulpn | grep 8020
# or
lsof -i :8020

# Solution: Either stop conflicting service or use different port
terraform apply -var-file="ha-test.tfvars" \
  -var="infisical_port=8030"
```

#### C. Out of Disk Space

```bash
# Check Docker volume space
docker system df

# Clean up unused volumes and images
docker volume prune
docker image prune

# Solution: Increase available disk space
```

### 2. PostgreSQL Nodes Can't Connect to Infisical

**Symptoms**:
```bash
# Container logs show connection errors
docker logs pg-node-1 | grep -i "infisical\|connection refused"

# Output: "Connection refused to infisical:8020"
```

**Root Causes & Solutions**:

#### A. Network Connectivity Issue

```bash
# Test from PostgreSQL container
docker exec pg-node-1 bash -c 'curl -v http://infisical:8020/api/v1/health'

# If connection refused:
# 1. Verify Infisical is running on pg-ha-network
docker network inspect pg-ha-network

# 2. Verify container is connected to network
docker container inspect pg-node-1 | grep -A 20 'Networks'

# Solution: Reconnect container to network
docker network disconnect pg-ha-network pg-node-1
docker network connect pg-ha-network pg-node-1
```

#### B. Infisical API Not Ready

```bash
# Check Infisical health
curl http://localhost:8020/api/v1/health

# If timeout or error, check container logs
docker logs infisical | tail -50

# Solution: Wait for Infisical to initialize (typically 15-30 seconds)
sleep 60
terraform apply -var-file="ha-test.tfvars"
```

#### C. API Key or Project ID Missing/Invalid

```bash
# Verify environment variables are set
terraform output generated_passwords

# Check if API key is in Terraform
echo $TF_VAR_infisical_api_key

# If empty:
export TF_VAR_infisical_api_key="your-key-here"
export TF_VAR_infisical_project_id="your-project-id-here"

# Re-apply Terraform
terraform apply -var-file="ha-test.tfvars"

# Restart containers to pick up new env vars
docker restart pg-node-1 pg-node-2 pg-node-3
```

### 3. PgBouncer Userlist.txt Generation Fails

**Symptoms**:
```bash
# PgBouncer won't start
docker logs pgbouncer-1

# Output: "invalid auth file: /etc/pgbouncer/userlist.txt"
```

**Root Causes & Solutions**:

#### A. Entrypoint Script Errors

```bash
# Check entrypoint script execution
docker logs pgbouncer-1 | head -100

# If script fails early, check syntax
bash -n /home/vejang/terraform-docker-container-postgres/entrypoint-pgbouncer.sh

# If syntax error, fix the script
vim entrypoint-pgbouncer.sh
```

#### B. Secret Fetching Failed

```bash
# Check if Infisical secrets exist
curl -H "Authorization: Bearer $TF_VAR_infisical_api_key" \
  -H "X-Infisical-Project-ID: $TF_VAR_infisical_project_id" \
  http://localhost:8020/api/v1/secrets/db-admin-password

# If 404 not found, create the secret:
curl -X POST http://localhost:8020/api/v1/secrets \
  -H "Authorization: Bearer $TF_VAR_infisical_api_key" \
  -H "X-Infisical-Project-ID: $TF_VAR_infisical_project_id" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "db-admin-password",
    "value": "secure-password-here"
  }'
```

#### C. Userlist.txt Permissions

```bash
# Check if file was created with correct permissions
docker exec pgbouncer-1 ls -la /etc/pgbouncer/

# Expected output shows postgres:postgres ownership and 640 permissions
# If different, PgBouncer can't read it

# Solution: Restart container with fresh entrypoint
docker container rm -f pgbouncer-1
terraform apply -var-file="ha-test.tfvars"
```

### 4. PostgreSQL Admin Password Not Working

**Symptoms**:
```bash
# Connection fails with authentication error
psql -h localhost -p 5432 -U pgadmin -d postgres
# psql: error: fe_sendauth: no password supplied

# Or with password:
# psql: error: FATAL:  password authentication failed for user "pgadmin"
```

**Root Causes & Solutions**:

#### A. Password Not Updated in Both Container and Infisical

```bash
# Check what password PostgreSQL is using
docker exec pg-node-1 env | grep POSTGRES_PASSWORD

# Check what password Infisical has
curl -H "Authorization: Bearer $API_KEY" \
  http://localhost:8020/api/v1/secrets/db-admin-password

# If they don't match, update Infisical and restart containers
curl -X PUT http://localhost:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"value": "'"$(docker exec pg-node-1 env | grep POSTGRES_PASSWORD | cut -d= -f2)"'"}'

docker restart pg-node-1 pg-node-2 pg-node-3
```

#### B. Password Contains Special Characters Breaking Shell

```bash
# If password has special chars like $, ', ", \, escape them properly
# In entrypoint-patroni.sh, ensure quotes are correct:

# WRONG:
export POSTGRES_PASSWORD=$fetched_password

# RIGHT:
export POSTGRES_PASSWORD="$fetched_password"

# Fix the script and redeploy
```

#### C. SCRAM-SHA-256 Auth Type Issue

```bash
# Check PostgreSQL authentication method
docker exec pg-node-1 cat /var/lib/postgresql/18/main/pg_hba.conf | grep -v '^#'

# Should show scram-sha-256 for remote connections
# If it shows "md5" or "password", update pg_hba.conf:

# 1. Edit pg_hba.conf in PostgreSQL container
# 2. Change authentication method to scram-sha-256
# 3. Reload PostgreSQL (does not require restart)
docker exec pg-node-1 sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

### 5. Secrets Rotation Fails

**Symptoms**:
```bash
# After rotating password, connections fail
docker logs pg-node-1 | grep -i "password"

# Output: "FATAL: password authentication failed"
```

**Root Causes & Solutions**:

#### A. Containers Not Restarted After Secret Update

```bash
# Update secret in Infisical
curl -X PUT http://localhost:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Infisical-Project-ID: $PROJECT_ID" \
  -d '{"value": "new-password"}'

# Restart containers to fetch new secret
docker restart pg-node-1
sleep 10  # Wait for PostgreSQL to start
docker restart pg-node-2
sleep 10
docker restart pg-node-3
sleep 10
docker restart pgbouncer-1 pgbouncer-2
```

#### B. Temporary Connection Loss During Rotation

For **zero-downtime rotation**:

```bash
#!/bin/bash
set -e

echo "Starting zero-downtime password rotation..."

# 1. Update Infisical secret
curl -X PUT http://localhost:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $TF_VAR_infisical_api_key" \
  -H "X-Infisical-Project-ID: $TF_VAR_infisical_project_id" \
  -d '{"value": "new-password-here"}'

# 2. Restart replicas first (won't cause failover)
docker restart pg-node-2 && sleep 15
docker restart pg-node-3 && sleep 15

# 3. Promote one replica if needed (optional)
# docker exec pg-node-2 patronictl switchover --master=pg-node-1 --candidate=pg-node-2

# 4. Restart primary
docker restart pg-node-1 && sleep 15

# 5. Update PgBouncer
docker restart pgbouncer-1 pgbouncer-2

# 6. Verify
sleep 5
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
echo "Password rotation completed successfully!"
```

### 6. Infisical Database Becomes Corrupted

**Symptoms**:
```bash
# Infisical starts but API returns 500 errors
curl http://localhost:8020/api/v1/health
# HTTP 500 Internal Server Error

# Or Infisical keeps crashing
docker logs infisical | grep -i "error\|panic"
```

**Solutions**:

```bash
# Option 1: Backup and restore (if you have previous backup)
docker volume create infisical-db-backup
docker run --rm -v infisical-db-data:/source -v infisical-db-backup:/backup \
  busybox sh -c 'cp -av /source/. /backup/'

# Option 2: Fresh start (data loss)
docker-compose down
docker volume rm infisical-db-data infisical-data
docker system prune

terraform refresh -var-file="ha-test.tfvars"
terraform apply -var-file="ha-test.tfvars"
```

### 7. Infisical Memory/CPU Issues

**Symptoms**:
```bash
# Infisical using excessive resources
docker stats | grep infisical

# High CPU or memory usage
```

**Solutions**:

```bash
# Check what's consuming resources
docker exec infisical ps aux

# Limit resource usage in Terraform (if needed)
# Add to docker_container.infisical:
# memory = 512  # MB
# memory_swap = 1024  # MB

# Restart with fresh state
docker restart infisical

# Check for memory leaks in logs
docker logs infisical | grep -i "memory\|gc\|garbage"
```

### 8. Performance Issues

**Symptoms**:
```bash
# Slow secret fetching
# Connection timeouts to Infisical
# High latency on PostgreSQL connections
```

**Optimization Steps**:

```bash
# 1. Monitor Infisical performance
curl -s http://localhost:8020/api/v1/health | jq '.'

# 2. Check network latency between containers
docker exec pg-node-1 ping -c 5 infisical

# 3. Monitor Docker daemon
docker system df
docker stats

# 4. Increase Infisical timeout in entrypoint scripts
# Edit entrypoint-patroni.sh and increase timeout values
# Change: curl ... -m 10  to  curl ... -m 30

# 5. Add retries with backoff
# Already implemented in infisical-secrets.sh:
# MAX_RETRIES=5, RETRY_DELAY=2
```

## Diagnostic Commands

### Quick Health Check

```bash
#!/bin/bash
echo "=== System Health Check ==="

# Infisical
echo "1. Infisical API:"
curl -s http://localhost:8020/api/v1/health || echo "FAILED"

# PostgreSQL
echo -e "\n2. PostgreSQL Primary:"
curl -s http://localhost:8008/cluster || echo "FAILED"

# PgBouncer
echo -e "\n3. PgBouncer Pools:"
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;" 2>/dev/null || echo "FAILED"

# Patroni Cluster
echo -e "\n4. Patroni Cluster Status:"
curl -s http://localhost:8008 | jq '.members[] | {name, role, state}' || echo "FAILED"

# Docker Volumes
echo -e "\n5. Docker Volumes:"
docker volume ls | grep -E "infisical|postgres|pgbouncer"

# Network
echo -e "\n6. Network Connectivity:"
docker exec pg-node-1 curl -s http://infisical:8020/api/v1/health || echo "FAILED"
```

### Collect Debugging Information

```bash
#!/bin/bash
# Collect logs for support/debugging

mkdir -p debug-logs
timestamp=$(date +%Y%m%d_%H%M%S)

echo "Collecting debug logs at $timestamp..."

# Container logs
docker logs infisical > debug-logs/infisical_$timestamp.log 2>&1
docker logs infisical-postgres > debug-logs/infisical-postgres_$timestamp.log 2>&1
docker logs pg-node-1 > debug-logs/pg-node-1_$timestamp.log 2>&1
docker logs pgbouncer-1 > debug-logs/pgbouncer-1_$timestamp.log 2>&1

# System info
docker ps > debug-logs/docker-ps_$timestamp.txt
docker volume ls > debug-logs/volumes_$timestamp.txt
docker network ls > debug-logs/networks_$timestamp.txt

# Terraform state (sanitized)
terraform state list > debug-logs/terraform-state_$timestamp.txt

echo "Logs collected in debug-logs/ directory"
tar -czf debug-logs_$timestamp.tar.gz debug-logs/
echo "Compressed: debug-logs_$timestamp.tar.gz"
```

## Getting Help

1. **Check Logs First**:
   ```bash
   docker logs infisical | tail -100
   docker logs pg-node-1 | grep -i error
   ```

2. **Review This Guide**: Most issues are covered above

3. **Check Infisical Docs**: https://infisical.com/docs

4. **Enable Debug Logging**:
   ```bash
   # In entrypoint scripts, add:
   set -x  # Enable command echoing
   ```

5. **Recreate Minimal Setup**:
   ```bash
   # Test Infisical alone
   terraform apply -target=docker_container.infisical_postgres
   terraform apply -target=docker_container.infisical
   ```

---

**Last Updated**: March 15, 2026
**Version**: 1.0
