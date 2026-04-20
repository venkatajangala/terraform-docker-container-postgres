# 🚨 Troubleshooting Guide

Common issues and their solutions.

## Connection Issues

### Can't Connect via PgBouncer

**Symptom**: `psql: error: could not connect to server: Connection refused`

**Check 1: Is PgBouncer running?**

```bash
docker ps | grep pgbouncer

# If not running:
docker logs pgbouncer-1
terraform apply -var-file="ha-test.tfvars"
```

**Check 2: Is the correct port?**

```bash
# Should be 6432, not 5432
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
```

**Check 3: Are credentials correct?**

```bash
# Passwords are auto-generated — check current password via Terraform output
terraform output -json generated_passwords

# Check userlist.txt reflects the current password
cat pgbouncer/userlist.txt
```

**Check 4: Network connectivity?**

```bash
# Test from inside container
docker exec pgbouncer-1 psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Test from host using docker network
docker run --rm --network pg-ha-network postgres:18 psql -h pgbouncer-1 -p 6432 -U pgadmin -d postgres
```

### Can't Connect Directly to PostgreSQL

**Symptom**: `psql: error: could not connect to server: Connection refused`

**Solution:**

```bash
# Use port 5432 for primary, not 6432
psql -h localhost -p 5432 -U pgadmin -d postgres -c "SELECT 1;"

# Replicas: 5433, 5434
psql -h localhost -p 5433 -U pgadmin -d postgres  # Replica 1
psql -h localhost -p 5434 -U pgadmin -d postgres  # Replica 2
```

## Cluster Status Issues

### Can't Determine Cluster Status

**Symptom**: `curl http://localhost:8008/leader` returns error

**Check 1: Is Patroni running?**

```bash
docker ps | grep pg-node

# If not running, check logs:
docker logs pg-node-1
```

**Check 2: Is etcd running?**

```bash
docker ps | grep etcd

# Check etcd connectivity:
curl -s http://localhost:2379/v3/cluster/member/list | python3 -m json.tool
```

**Check 3: Are ports exposed?**

```bash
# Verify port mapping
docker port pg-node-1 | grep 8008

# Should show: 8008/tcp -> 0.0.0.0:8008
```

### No Leader Elected

**Symptom**: Both `curl http://localhost:8008/leader` and `curl http://localhost:8009/leader` return "no leader"

**Likely Cause**: etcd cluster unhealthy or no quorum

**Solution:**

```bash
# Step 1: Check etcd status
docker logs etcd | grep -i "cluster"

# Step 2: Check member count
curl -s http://localhost:2379/v3/cluster/member/list | python3 -m json.tool | grep -c '"id"'

# Step 3: Force Patroni election
docker restart pg-node-1 pg-node-2 pg-node-3

# Step 4: Wait and verify
sleep 30
curl -s http://localhost:8008/leader | python3 -m json.tool
```

## Data Replication Issues

### Replication Lag Too High

**Symptom**: `9999 bytes` or more in replication lag

**Check 1: Network latency?**

```bash
docker exec pg-node-1 ping -c 3 pg-node-2
docker exec pg-node-1 ping -c 3 pg-node-3
```

**Check 2: Replica can't keep up?**

```bash
docker exec pg-node-1 psql -U postgres -c \
  "SELECT application_name, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
```

**Solution: Increase cache on replica**

```bash
# Increase effective_cache_size in variables-ha.tf or ha-test.tfvars, then:
terraform apply -var-file="ha-test.tfvars"
```

### Data Not Replicating

**Symptom**: Query results differ between primary and replica

**Check 1: Are nodes in same cluster?**

```bash
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -c '"name"'

# Should show 3
```

**Check 2: Is replica in recovery?**

```bash
docker exec pg-node-2 psql -U postgres -c "SELECT pg_is_in_recovery();"

# Should return: t (true = it's a replica)
```

**Check 3: Check replication status**

```bash
docker exec pg-node-1 psql -U postgres -c \
  "SELECT usename, application_name, backend_start, state FROM pg_stat_replication;"

# pgnode2 and pgnode3 should be in "streaming" state
```

**Solution: Force resync**

```bash
# On primary, drop the replication slot
docker exec pg-node-1 psql -U postgres -c \
  "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'pgnode_2';"

# Restart replica
docker restart pg-node-2

# Wait for sync
sleep 30

# Verify
docker exec pg-node-1 psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

## Failover Issues

### Failover Too Slow (> 30 seconds)

**Symptom**: Primary down, but new primary takes > 30 seconds to elect

**Check: etcd responsiveness**

```bash
# Time an etcd operation
time curl -s http://localhost:2379/v3/cluster/member/list > /dev/null

# Should be < 100ms
```

**Solution: Check etcd health**

```bash
docker logs etcd | tail -20

# If unhealthy, restart:
docker restart etcd
sleep 10

# Retry failover test
docker stop pg-node-1
sleep 30
curl -s http://localhost:8008/leader
docker start pg-node-1
```

### Failed Node Won't Rejoin Cluster

**Symptom**: `docker start pg-node-1` fails, or node shows as "offline"

**Check 1: Check logs**

```bash
docker logs pg-node-1 | tail -50 | grep -i "error\|failed\|fatal"
```

**Check 2: Check permissions**

```bash
docker exec pg-node-1 ls -la /var/lib/postgresql/18/main

# Should show: drwx------ ... main/
```

**Solution: Hard reset node**

```bash
# Stop node
docker stop pg-node-1

# Clean data volume
docker volume rm pg-node-1_pgdata  # or equivalent

# Restart
docker start pg-node-1

# Wait for rejoin
sleep 60

# Verify
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

## Performance Issues

### Slow Queries

**Symptom**: Queries take > 1 second

**Check 1: Is it the network?**

```bash
psql -h localhost -p 5432 -U pgadmin -d postgres << 'EOF'
\timing
SELECT 1;
SELECT count(*) FROM large_table;
EOF

# Compare with:
psql -h localhost -p 6432 -U pgadmin -d postgres << 'EOF'
\timing
SELECT 1;
SELECT count(*) FROM large_table;
EOF
```

**Check 2: Find slow queries**

```bash
docker exec pg-node-1 psql -U postgres -d postgres << 'EOF'
SELECT query, mean_exec_time, calls
FROM pg_stat_statements
ORDER BY mean_exec_time DESC LIMIT 10;
EOF
```

**Solution: Analyze & optimize**

```sql
-- Get query plan
EXPLAIN ANALYZE SELECT ...;

-- Create missing indexes
CREATE INDEX idx_name ON table(column);

-- Update statistics
ANALYZE table_name;
```

### Connection Pool Exhaustion

**Symptom**: `FATAL: remaining connection slots are reserved for non-replication superuser connections`

**Check: Pool status**

```bash
psql -h localhost -p 6432 -U pgadmin -d pgbouncer << 'EOF'
SHOW POOLS;
EOF

# Look for: cl_waiting > 0
```

**Solution: Increase pool size**

```bash
# Edit ha-test.tfvars
# pgbouncer_default_pool_size = 50  # increase from 25
# pgbouncer_max_client_conn = 2000  # increase from 1000

# Redeploy
terraform apply -var-file="ha-test.tfvars"
```

### High Memory Usage

**Symptom**: Container memory > 80% of limit

**Check 1: What's using memory?**

```bash
docker stats pg-node-1

# Also check:
docker exec pg-node-1 ps aux | sort -k 3 -nr | head -5
```

**Check 2: PostgreSQL cache size**

```bash
docker exec pg-node-1 psql -U postgres -c "SHOW shared_buffers;"

# Typical: 256MB
```

**Solution: Increase memory or optimize**

```bash
# Option 1: Increase container memory limit in variables-ha.tf / ha-test.tfvars, then:
terraform apply -var-file="ha-test.tfvars"

# Option 2: Reduce pool size to lower backend connection memory
# pgbouncer_default_pool_size = 10  # decrease from 25
```

## Docker & Terraform Issues

### Terraform Apply Fails

**Check logs:**

```bash
terraform init
terraform validate
terraform plan

# If error in plan:
terraform apply -var-file="ha-test.tfvars" -auto-approve

# Check what failed:
docker ps -a | grep -v running
```

### Container Won't Start

**Symptom**: `docker ps` doesn't show container

**Check logs:**

```bash
docker logs container_name

# Common issues:
docker logs pg-node-1 | grep -i "permission denied\|could not open\|fatal"
```

**Solution:**

```bash
# Fix permissions
docker exec pg-node-1 chmod 700 /var/lib/postgresql/18/main

# Or rebuild
docker stop container_name
docker rm container_name
terraform apply -var-file="ha-test.tfvars"
```

### Port Already in Use

**Symptom**: `bind: address already in use`

**Find what's using the port:**

```bash
# Linux
lsof -i :5432
lsof -i :6432
lsof -i :8008

# Kill it:
kill -9 <PID>

# Or change ports in ha-test.tfvars:
# postgres_port_base = 5500  # instead of 5432
# pgbouncer_external_port_base = 6500  # instead of 6432
```

## Vault & Secret Management Issues

### PgBouncer Authentication Failed (Password Out of Sync)

**Symptom**: `FATAL: password authentication failed for user "pgadmin"` when connecting through PgBouncer, but direct PostgreSQL connection also fails.

**Cause**: Terraform regenerated a new random password and applied it to the container environment, but the PostgreSQL `pgadmin` user's password was not updated in the running cluster.

**Solution:**

```bash
# Step 1: Get the current generated password
terraform output -json generated_passwords

# Step 2: Apply the updated password in PostgreSQL on the primary node
LEADER=$(curl -s http://localhost:8008/cluster | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(m['name'] for m in d['members'] if m['role']=='leader'))")
docker exec -it "$LEADER" psql -U postgres -d postgres -c \
  "ALTER USER pgadmin PASSWORD '<password from generated_passwords>';"

# Step 3: Restart PgBouncer to pick up the new userlist
docker restart pgbouncer-1 pgbouncer-2

# Step 4: Verify
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
unset PGPASSWORD
```

### Vault Container Restart Loop

**Symptom**: The `vault` container keeps restarting.

**Cause**: Vault uses an internal Raft backend (no external Redis or Postgres required). Common causes are port conflicts, missing data volume, or a sealed state after restart.

**Check:**

```bash
# View Vault logs
docker logs vault | tail -30

# Check Vault health
curl -s http://localhost:8200/v1/sys/health | python3 -m json.tool

# If sealed, re-run bootstrap (dev only)
bash vault-bootstrap.sh
```

**If Vault is unhealthy after a full destroy/apply cycle:**

```bash
# Re-apply to recreate Vault and re-run bootstrap
terraform apply -var-file="ha-test.tfvars" -auto-approve
```

### Node Shows "start failed" (Timeline Divergence)

**Symptom**: `patronictl list` shows a node with state `start failed`, and the node logs mention timeline divergence.

**Cause**: The replica's WAL timeline diverged from the current primary (typically after a failover). The node cannot replay WAL and refuses to start.

**Solution:** Run `patronictl reinit` from the current primary:

```bash
# Step 1: Identify the current primary and the failed node
curl -s http://localhost:8008/cluster | python3 -m json.tool | grep -E '"name"|"state"|"role"'

# Step 2: Run reinit targeting the failed node from the primary
docker exec <primary-node> patronictl -c /etc/patroni/patroni.yml \
  reinit pg-ha-cluster <failed-node> --force

# Example:
docker exec pg-node-1 patronictl -c /etc/patroni/patroni.yml \
  reinit pg-ha-cluster pg-node-2 --force

# Step 3: Verify the node recovers
sleep 30
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

### pg_stat_replication Returns Empty

**Symptom**: `SELECT * FROM pg_stat_replication;` returns no rows even though replicas appear healthy.

**Cause**: The query is being run as the `pgadmin` user, which may lack sufficient privileges. `pg_stat_replication` requires the `pg_monitor` role or superuser access to see rows.

**Solution:**

```bash
# Option 1: Run as the postgres superuser
docker exec pg-node-1 psql -U postgres -d postgres \
  -c "SELECT application_name, state, sync_state, write_lag FROM pg_stat_replication;"

# Option 2: Verify pgadmin has pg_monitor (should already be granted)
docker exec pg-node-1 psql -U postgres -d postgres \
  -c "\du pgadmin"
# Look for pg_monitor in the role list

# If pg_monitor is missing, grant it:
docker exec pg-node-1 psql -U postgres -d postgres \
  -c "GRANT pg_monitor TO pgadmin;"
```

## Datadog Observability Issues

### Datadog Agent Not Starting

**Symptom**: `docker ps` shows no `datadog-agent` container, or container exits immediately.

**Check 1: Feature flag enabled?**

```bash
grep "datadog_enabled" ha-test.tfvars
# Must be: datadog_enabled = true
```

**Check 2: API key set?**

```bash
# The variable must be non-empty at apply time
echo ${TF_VAR_datadog_api_key:-"NOT SET"}
# If empty, set it before applying:
export TF_VAR_datadog_api_key="your-api-key-here"
terraform apply -var-file="ha-test.tfvars" -auto-approve
```

**Check 3: View agent startup logs**

```bash
docker logs datadog-agent 2>&1 | head -40
```

---

### Datadog Agent Shows `(unhealthy)` in `docker ps`

**Symptom**: `docker ps` shows `datadog-agent ... (unhealthy)`

**Cause A** (expected): Using a test/placeholder API key. The custom `DD_HEALTH_PORT=5555` healthcheck probes a local HTTP endpoint, so `(healthy)` only requires the agent process to be alive — not a valid API key. If the container still shows `(unhealthy)`, the agent process itself has not started.

**Cause B**: Agent process crash (OOM, missing Docker socket, config error).

**Resolution:**

```bash
# Check the actual health probe
docker exec datadog-agent curl -sf http://localhost:5555 && echo "health OK"

# View agent errors
docker logs datadog-agent 2>&1 | grep -iE "error|fatal|panic" | head -20

# Check memory — agent may be OOM-killed
docker stats datadog-agent --no-stream

# Increase memory limit if needed (edit ha-test.tfvars):
# datadog_memory_mb = 768
terraform apply -var-file="ha-test.tfvars" -auto-approve
```

---

### Integration Check Returns "No Series" or Error

**Symptom**: `docker exec datadog-agent agent check postgres` shows no `=== Series ===` section, or reports `CRITICAL`.

**Check 1: Is the cluster reachable from the agent container?**

```bash
# Test TCP reachability to each node
docker exec datadog-agent bash -c \
  "timeout 3 bash -c 'echo >/dev/tcp/pg-node-1/5432' && echo reachable || echo unreachable"
```

**Check 2: Are the rendered config files present?**

```bash
ls -la datadog/rendered/
# Must contain: postgres.yaml, pgbouncer.yaml, http_check.yaml
# If missing, re-apply Terraform:
terraform apply -var-file="ha-test.tfvars" -auto-approve
```

**Check 3: Verify config contains correct credentials**

```bash
# Check that postgres.yaml has a password set
grep -c "password:" datadog/rendered/postgres.yaml
# Should be > 0

# Check that host entries are correct
grep "host:" datadog/rendered/postgres.yaml
```

**Check 4: Run the full health check to isolate which check is failing**

```bash
bash datadog-health-check.sh --checks
```

**Resolution — password mismatch:**

```bash
# Confirm the current postgres password
terraform output -json generated_passwords

# Re-render configs with fresh passwords by forcing re-apply of local_file resources
terraform apply -var-file="ha-test.tfvars" \
  -replace='local_file.datadog_postgres_conf[0]' \
  -replace='local_file.datadog_pgbouncer_conf[0]' \
  -replace='local_file.datadog_http_check_conf[0]' \
  -auto-approve

# Then replace the agent to pick up the new mounts
terraform apply -var-file="ha-test.tfvars" \
  -replace='docker_container.datadog_agent[0]' -auto-approve
```

---

### PgBouncer Check Fails but postgres Check Passes

**Symptom**: `agent check pgbouncer` reports connection error; `agent check postgres` works.

**Cause**: `pgbouncer_enabled = false` in `ha-test.tfvars`, or PgBouncer admin user credentials are wrong.

```bash
# Confirm pgbouncer containers are running
docker ps | grep pgbouncer

# Test admin console directly
PGPASSWORD="$(terraform output -json generated_passwords | python3 -c \
  'import sys,json; print(json.load(sys.stdin)["postgres_password"])')" \
  psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW VERSION;"

# Check the rendered pgbouncer config
cat datadog/rendered/pgbouncer.yaml
```

---

### HTTP Check Shows Endpoint DOWN

**Symptom**: `agent check http_check` reports one or more endpoints as `DOWN`.

```bash
# Test the failing endpoint manually from inside the agent container
docker exec datadog-agent curl -sv http://pg-node-1:8008/liveness
docker exec datadog-agent curl -sv http://etcd:2379/health
docker exec datadog-agent curl -sv http://vault:8200/v1/sys/health

# Common causes:
# - Patroni not yet elected a leader (wait and retry)
# - Vault sealed: curl http://localhost:8200/v1/sys/health returns 503
#   Fix: docker exec vault vault operator unseal $(jq -r '.unseal_keys_b64[0]' .vault-bootstrap/vault-init.json)
```

---

### Agent Logs Flooded with 403 / 401 Errors

**Symptom**: `docker logs datadog-agent` shows many `code=403` or `code=401` lines.

**Cause** (expected): Placeholder or invalid Datadog API key — the forwarder cannot reach `datadoghq.com`. This does **not** affect local integration checks or the health check script.

```bash
# These are filtered in the health check script — confirm section 9 is clean
bash datadog-health-check.sh 2>&1 | grep -A3 "9. Recent"
# Expected: ✓ No actionable errors
#           → 403 API key errors present (expected if using a test/placeholder key)
```

To fix for production: set a valid key and re-apply.

```bash
export TF_VAR_datadog_api_key="<real-api-key>"
terraform apply -var-file="ha-test.tfvars" \
  -replace='docker_container.datadog_agent[0]' -auto-approve
```

## Getting Help

### Collect Diagnostic Information

```bash
# Create diagnostics bundle
mkdir diagnostics

# Container status
docker ps -a > diagnostics/containers.txt
docker ps -a --no-trunc > diagnostics/containers_full.txt

# All logs
docker logs pg-node-1 > diagnostics/pg-node-1.log 2>&1
docker logs pg-node-2 > diagnostics/pg-node-2.log 2>&1
docker logs pg-node-3 > diagnostics/pg-node-3.log 2>&1
docker logs pgbouncer-1 > diagnostics/pgbouncer-1.log 2>&1
docker logs pgbouncer-2 > diagnostics/pgbouncer-2.log 2>&1
docker logs etcd > diagnostics/etcd.log 2>&1
docker logs datadog-agent > diagnostics/datadog-agent.log 2>&1 || true

# Cluster status
curl -s http://localhost:8008/cluster | python3 -m json.tool > diagnostics/cluster.json 2>&1

# PgBouncer status
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;" > diagnostics/pools.txt 2>&1

# Datadog integration check results (if agent running)
docker exec datadog-agent agent check postgres  > diagnostics/dd-check-postgres.txt  2>&1 || true
docker exec datadog-agent agent check pgbouncer > diagnostics/dd-check-pgbouncer.txt 2>&1 || true
docker exec datadog-agent agent check http_check > diagnostics/dd-check-http.txt     2>&1 || true

# Share this bundle with support
tar czf diagnostics.tar.gz diagnostics/
```

### Common Error Messages

| Error | Meaning | Fix |
| ----- | ------- | --- |
| `FATAL: remaining connection slots reserved` | Pool exhausted | Increase `pgbouncer_default_pool_size` in `ha-test.tfvars` |
| `could not connect to server` | Network/port issue | Check ports exposed with `docker port` |
| `password authentication failed` | Password out of sync | Run `terraform output -json generated_passwords`; `ALTER USER pgadmin PASSWORD '...'` on primary |
| `replication slot does not exist` | Replication broken | Restart replicas |
| `no leader elected` | etcd or Patroni issue | Restart cluster containers |
| `permission denied` | Directory permissions | Check `chmod`/ownership inside container |
| `out of memory` | RAM limit hit | Increase memory limit or reduce pool size |
| `datadog-agent` not in `docker ps` | `datadog_enabled = false` or apply needed | Set `datadog_enabled = true` and re-apply |
| DD check: `no series output` | Cluster not yet ready or bad credentials | Wait 60 s, re-render configs; check `datadog/rendered/postgres.yaml` |
| DD check: `CRITICAL` / auth error | Wrong password in rendered config | Force re-apply of `local_file.datadog_postgres_conf[0]` and restart agent |
| DD logs: `code=403` / `code=401` | Invalid/test API key | Expected in dev; set real key via `TF_VAR_datadog_api_key` for production |
| DD container `(unhealthy)` | Agent process not responding on port 5555 | Check `docker logs datadog-agent`; increase `datadog_memory_mb` if OOM |

---

For more help, see [Operations Guide](02-OPERATIONS.md) or [Documentation Index](../README.md)
