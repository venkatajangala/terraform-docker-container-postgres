# Deprecated: Infisical (replaced by Vault)

This legacy file is deprecated. See docs/getting-started/VAULT-QuickStart.md and docs/VAULT-INTEGRATION.md for current instructions.

---

# Vault Integration - Troubleshooting Guide

> **Note**: Vault runs from the official `vault/vault:latest` image. There is no custom `Dockerfile.vault` — do not look for or try to rebuild a local image.

## Common Issues and Solutions

### 1. Vault Container Won't Start

**Symptoms**:
```
docker ps | grep vault
# No output or container keeps restarting
```

**Root Causes & Solutions**:

#### A. Database Backend Not Ready

> **Environment variable note**: Vault uses `DB_CONNECTION_URI` for its database connection string. Older documentation or examples may refer to `DATABASE_URL` — this is not the correct variable name for the official Vault image. Use `DB_CONNECTION_URI`.

```bash
# Check if vault-postgres is running
docker ps | grep vault-postgres

# If not running, check logs
docker logs vault-postgres

# If it's in crash loop, check volume
docker volume ls | grep vault-db

# Solution: Destroy and recreate
docker stop vault vault-postgres
docker rm vault vault-postgres
docker volume rm vault-db-data vault-data
terraform apply -var-file="ha-test.tfvars" -target=docker_container.vault_postgres
sleep 30
terraform apply -var-file="ha-test.tfvars" -target=docker_container.vault
```

#### B. Port Conflict

```bash
# Check if port 8020 is already in use
netstat -tulpn | grep 8020
# or
lsof -i :8020

# Solution: Either stop conflicting service or use different port
terraform apply -var-file="ha-test.tfvars" \
  -var="vault_port=8030"
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

### 1b. Vault Restart Loop Due to Missing Redis

Vault requires a Redis instance. The stack includes `vault-redis` (Redis 7 Alpine). If Redis is unavailable, Vault will crash-loop immediately.

**Check:**
```bash
# Verify vault-redis is running
docker ps | grep vault-redis

# Confirm Redis is reachable from Vault
docker exec vault sh -c 'redis-cli -h vault-redis ping'
# Expected: PONG
```

**If vault-redis is missing:**
```bash
# Re-apply the full stack — vault-redis is managed by Terraform
terraform apply -var-file="ha-test.tfvars"

# Bring up vault-redis first, then vault
terraform apply -var-file="ha-test.tfvars" -target=docker_container.vault_redis
sleep 10
terraform apply -var-file="ha-test.tfvars" -target=docker_container.vault
```

**If vault-redis exists but Vault still fails:**
```bash
# Check Redis logs for errors
docker logs vault-redis

# Confirm both containers share pg-ha-network
docker network inspect pg-ha-network | grep -E '"Name"|vault'
```

### 2. PostgreSQL Nodes Can't Connect to Vault

**Symptoms**:
```bash
# Container logs show connection errors
docker logs pg-node-1 | grep -i "vault\|connection refused"

# Output: "Connection refused to vault:8020"
```

**Root Causes & Solutions**:

#### A. Network Connectivity Issue

```bash
# Test from PostgreSQL container
docker exec pg-node-1 bash -c 'curl -v http://vault:8020/api/status'

# If connection refused:
# 1. Verify Vault is running on pg-ha-network
docker network inspect pg-ha-network

# 2. Verify container is connected to network
docker container inspect pg-node-1 | grep -A 20 'Networks'

# Solution: Reconnect container to network
docker network disconnect pg-ha-network pg-node-1
docker network connect pg-ha-network pg-node-1
```

#### B. Vault API Not Ready

```bash
# Check Vault health
curl http://localhost:8020/api/status

# If timeout or error, check container logs
docker logs vault | tail -50

# Solution: Wait for Vault to initialize (typically 15-30 seconds)
sleep 60
terraform apply -var-file="ha-test.tfvars"
```

#### C. API Key or Project ID Missing/Invalid

```bash
# Verify environment variables are set
terraform output generated_passwords

# Check if API key is in Terraform
echo $TF_VAR_vault_api_key

# If empty:
export TF_VAR_vault_api_key="your-key-here"
export TF_VAR_vault_project_id="your-project-id-here"

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
# Check if Vault secrets exist
curl -H "Authorization: Bearer $TF_VAR_vault_api_key" \
  -H "X-Vault-Project-ID: $TF_VAR_vault_project_id" \
  http://localhost:8020/api/v1/secrets/db-admin-password

# If 404 not found, create the secret:
curl -X POST http://localhost:8020/api/v1/secrets \
  -H "Authorization: Bearer $TF_VAR_vault_api_key" \
  -H "X-Vault-Project-ID: $TF_VAR_vault_project_id" \
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

#### A. Password Not Updated in Both Container and Vault

```bash
# Check what password PostgreSQL is using
docker exec pg-node-1 env | grep POSTGRES_PASSWORD

# Check what password Vault has
curl -H "Authorization: Bearer $API_KEY" \
  http://localhost:8020/api/v1/secrets/db-admin-password

# If they don't match, update Vault and restart containers
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
# Update secret in Vault
curl -X PUT http://localhost:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Vault-Project-ID: $PROJECT_ID" \
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

# 1. Update Vault secret
curl -X PUT http://localhost:8020/api/v1/secrets/db-admin-password \
  -H "Authorization: Bearer $TF_VAR_vault_api_key" \
  -H "X-Vault-Project-ID: $TF_VAR_vault_project_id" \
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

### 6. Vault Database Becomes Corrupted

**Symptoms**:
```bash
# Vault starts but API returns 500 errors
curl http://localhost:8020/api/status
# HTTP 500 Internal Server Error

# Or Vault keeps crashing
docker logs vault | grep -i "error\|panic"
```

**Solutions**:

```bash
# Option 1: Backup and restore (if you have previous backup)
docker volume create vault-db-backup
docker run --rm -v vault-db-data:/source -v vault-db-backup:/backup \
  busybox sh -c 'cp -av /source/. /backup/'

# Option 2: Fresh start (data loss)
docker-compose down
docker volume rm vault-db-data vault-data
docker system prune

terraform refresh -var-file="ha-test.tfvars"
terraform apply -var-file="ha-test.tfvars"
```

### 7. Vault Memory/CPU Issues

**Symptoms**:
```bash
# Vault using excessive resources
docker stats | grep vault

# High CPU or memory usage
```

**Solutions**:

```bash
# Check what's consuming resources
docker exec vault ps aux

# Limit resource usage in Terraform (if needed)
# Add to docker_container.vault:
# memory = 512  # MB
# memory_swap = 1024  # MB

# Restart with fresh state
docker restart vault

# Check for memory leaks in logs
docker logs vault | grep -i "memory\|gc\|garbage"
```

### 8. Performance Issues

**Symptoms**:
```bash
# Slow secret fetching
# Connection timeouts to Vault
# High latency on PostgreSQL connections
```

**Optimization Steps**:

```bash
# 1. Monitor Vault performance
curl -s http://localhost:8020/api/status | jq '.'

# 2. Check network latency between containers
docker exec pg-node-1 ping -c 5 vault

# 3. Monitor Docker daemon
docker system df
docker stats

# 4. Increase Vault timeout in entrypoint scripts
# Edit entrypoint-patroni.sh and increase timeout values
# Change: curl ... -m 10  to  curl ... -m 30

# 5. Add retries with backoff
# Already implemented in vault-secrets.sh:
# MAX_RETRIES=5, RETRY_DELAY=2
```

## Diagnostic Commands

### Quick Health Check

```bash
#!/bin/bash
echo "=== System Health Check ==="

# Vault
echo "1. Vault API:"
curl -s http://localhost:8020/api/status || echo "FAILED"

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
docker volume ls | grep -E "vault|postgres|pgbouncer"

# Network
echo -e "\n6. Network Connectivity:"
docker exec pg-node-1 curl -s http://vault:8020/api/status || echo "FAILED"
```

### Collect Debugging Information

```bash
#!/bin/bash
# Collect logs for support/debugging

mkdir -p debug-logs
timestamp=$(date +%Y%m%d_%H%M%S)

echo "Collecting debug logs at $timestamp..."

# Container logs
docker logs vault > debug-logs/vault_$timestamp.log 2>&1
docker logs vault-postgres > debug-logs/vault-postgres_$timestamp.log 2>&1
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
   docker logs vault | tail -100
   docker logs pg-node-1 | grep -i error
   ```

2. **Review This Guide**: Most issues are covered above

3. **Check Vault Docs**: https://vault.com/docs

4. **Enable Debug Logging**:
   ```bash
   # In entrypoint scripts, add:
   set -x  # Enable command echoing
   ```

5. **Recreate Minimal Setup**:
   ```bash
   # Test Vault alone
   terraform apply -target=docker_container.vault_postgres
   terraform apply -target=docker_container.vault
   ```

---

**Last Updated**: March 15, 2026
**Version**: 1.0
