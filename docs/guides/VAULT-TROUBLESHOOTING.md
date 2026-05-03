# Vault Integration — Troubleshooting Guide

> **Note**: Vault runs from the official `hashicorp/vault` image on port **8200**. There is no custom `Dockerfile.vault`, no `vault-postgres`, and no `vault-redis` — this stack uses HashiCorp Vault's built-in Raft storage backend.

## Common Issues

### 1. Vault Container Won't Start

**Symptoms:**
```bash
docker ps | grep vault
# No output or container keeps restarting
docker logs vault | tail -20
```

**Root Causes & Solutions:**

#### A. Port Conflict

```bash
# Check if port 8200 is already in use
lsof -i :8200
# or
netstat -tulpn | grep 8200

# Solution: stop conflicting service, or set a different port in ha-test.tfvars
# vault_port = 8201
```

#### B. Raft data directory permissions

```bash
# Check for permission errors in logs
docker logs vault | grep -i "permission\|error"

# Solution: destroy and recreate
docker rm -f vault
terraform apply -var-file="ha-test.tfvars" -target=docker_container.vault
```

#### C. Out of Disk Space

```bash
docker system df
docker volume prune   # remove unused volumes
docker image prune    # remove dangling images
```

---

### 2. Vault Unhealthy / Sealed After Restart

HashiCorp Vault in Raft server mode is initialized once. If the `vault-data` volume is recreated, initialization must run again.

**After `terraform destroy` + `terraform apply` (full redeploy):** `null_resource.vault_init` now tracks the volume ID via a `vault_volume_id` trigger — it automatically re-runs `vault-bootstrap.sh` whenever the `vault-data` volume is recreated. No manual steps required.

**After a container restart only (volume intact):** Vault restarts sealed. `vault-bootstrap.sh` re-unseals from the saved keys in `.vault-bootstrap/vault-init.json`.

**Check health:**
```bash
curl -s http://localhost:8200/v1/sys/health | python3 -m json.tool
# sealed: true means Vault is sealed and needs to be unsealed or re-initialized
```

**Re-run bootstrap manually (if needed):**
```bash
# vault-bootstrap.sh checks Vault API — skips init if already initialized, re-unseals if sealed
VAULT_ADDR=http://localhost:8200 bash vault-bootstrap.sh
```

**Or re-apply Terraform** (triggers `null_resource.vault_init` via volume ID change):
```bash
terraform apply -var-file="ha-test.tfvars" -auto-approve
```

---

### 3. AppRole Authentication Fails

**Symptoms:**
```bash
docker logs pg-node-1 | grep -i "vault\|approle\|error"
# "permission denied" or "missing client token"
```

**Causes & Fixes:**

#### A. Bootstrap files missing or wrong permissions

```bash
ls -la .vault-bootstrap/
# Expected: role_id (644), secret_id (644), approle_pg-role.json (600)

# Fix permissions if needed
chmod 644 .vault-bootstrap/role_id .vault-bootstrap/secret_id
chmod 600 .vault-bootstrap/approle_pg-role.json
```

#### B. Split files not created

`vault-bootstrap.sh` calls `vault-bootstrap-split.sh` to split the JSON into separate `role_id` and `secret_id` files that the Vault Agent `agent.hcl` reads. If the split files are missing:

```bash
bash vault-bootstrap-split.sh pg-role
ls .vault-bootstrap/role_id .vault-bootstrap/secret_id
```

#### C. secret_id expired

AppRole secret IDs have a TTL. Regenerate:
```bash
VAULT_TOKEN=$(terraform output -raw vault_root_token 2>/dev/null || echo "dev-root-token")
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/auth/approle/role/pg-role/secret-id | python3 -m json.tool

# Update .vault-bootstrap/secret_id with the new value
```

#### D. Policy too restrictive

```bash
VAULT_TOKEN=$(terraform output -raw vault_root_token 2>/dev/null || echo "dev-root-token")
# Verify policy grants read on the KV paths
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/sys/policy/pg-role | python3 -m json.tool
```

---

### 4. Vault Agent Sidecar Fails to Render Secrets

**Symptoms:**
```bash
docker logs vault-agent | tail -30
# "permission denied", "no such file or directory", or "error writing file"
```

**Common causes and fixes:**

#### A. Sink directory missing or wrong path

`agent.hcl` must write to `/tmp/vault-token` (not `/var/run/vault-token/...`).

```bash
# Check agent.hcl sink path
cat vault/agent/agent.hcl | grep -A3 'sink "file"'
# Should show: path = "/tmp/vault-token"
```

#### B. Secrets volume not writable (permission denied)

The Vault Agent process runs as uid=100 (vault user). The `vault-agent-secrets` volume must be owned by `100:1000`.

```bash
# Re-run the permission fix
docker run --rm -v vault-agent-secrets:/data alpine \
  sh -c 'chown 100:1000 /data && chmod 750 /data'

# Then restart the agent
docker restart vault-agent
```

#### C. Wrong KV path in template

`vault/agent/templates/postgres.hcl` must use the paths seeded by `vault-bootstrap.sh`:

```
secret/data/pg/postgres    → postgres_user, postgres_password
secret/data/pg/replication → replication_password
```

Verify the rendered file after the agent runs:
```bash
docker exec pg-node-1 cat /etc/vault/secrets/postgres.env
# Expected: POSTGRES_USER=..., POSTGRES_PASSWORD=..., REPLICATION_PASSWORD=...
```

#### D. Role files not readable inside the agent container

```bash
# Verify mount is correct
docker exec vault-agent ls -la /etc/vault/role/
# Should show: role_id (644), secret_id (644)

# Fix if needed
chmod 644 .vault-bootstrap/role_id .vault-bootstrap/secret_id
docker restart vault-agent
```

---

### 5. PostgreSQL Nodes Can't Connect to Vault

**Symptoms:**
```bash
docker logs pg-node-1 | grep -i "vault\|connection refused"
# "connection refused to vault:8200"
```

**Fixes:**

```bash
# Test from within a pg-node container
docker exec pg-node-1 curl -s http://vault:8200/v1/sys/health

# Verify vault is on the same network
docker network inspect pg-ha-network | python3 -m json.tool | grep -E '"Name"|vault'

# Reconnect if needed
docker network connect pg-ha-network vault
```

---

### 6. Secret Rotation

**Rotate DB passwords (manual):**

```bash
VAULT_TOKEN=$(terraform output -raw vault_root_token 2>/dev/null || echo "dev-root-token")
NEW_PW=$(openssl rand -base64 24)

# Write new password to Vault
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": {\"postgres_user\": \"pgadmin\", \"postgres_password\": \"$NEW_PW\"}}" \
  http://localhost:8200/v1/secret/data/pg/postgres

# Restart containers to pick up new secret (Vault Agent will re-render automatically)
docker restart vault-agent
sleep 5
docker restart pg-node-1 pg-node-2 pg-node-3
sleep 15
docker restart pgbouncer-1 pgbouncer-2
```

---

## Quick Diagnostic Commands

```bash
#!/bin/bash
echo "=== Vault Health ==="
curl -s http://localhost:8200/v1/sys/health | python3 -m json.tool

echo -e "\n=== Vault Agent Logs ==="
docker logs vault-agent --tail=20 2>&1

echo -e "\n=== Rendered Secrets (pg-node-1) ==="
docker exec pg-node-1 cat /etc/vault/secrets/postgres.env 2>/dev/null || echo "File not found"

echo -e "\n=== Bootstrap Files ==="
ls -la .vault-bootstrap/ 2>/dev/null

echo -e "\n=== Cluster Health ==="
curl -s http://localhost:8008/leader | python3 -m json.tool

echo -e "\n=== PgBouncer Pools ==="
PGPASSWORD="$(terraform output -json generated_passwords 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['postgres_password'])")" \
  psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;" 2>/dev/null || echo "FAILED"
```

---

**See also:**
- [Vault Quick Start](../getting-started/VAULT-QuickStart.md)
- [Vault Integration Guide](../VAULT-INTEGRATION.md)
- [Vault Agent Sidecar](../VAULT-AGENT-SIDECAR.md)

**Last Updated:** 2026-04-12
