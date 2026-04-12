# Vault Quick Start (Dev)

Bootstrap a dev Vault (Raft) instance and enable AppRole access for containerized workloads.

**Prerequisites:** Docker, Terraform, `jq` or `python3`

---

## 1. Enable Vault in `ha-test.tfvars`

```hcl
vault_enabled       = true
vault_agent_enabled = true   # optional: enable Vault Agent sidecar
```

## 2. Apply Terraform

```bash
terraform init
terraform apply -var-file="ha-test.tfvars" -auto-approve
```

Terraform runs `null_resource.vault_init` which executes `vault-bootstrap.sh` automatically during apply.

## 3. What the Bootstrap Does

`vault-bootstrap.sh` runs inside the Vault container and:

1. Initializes Vault with a single unseal key (dev convenience)
2. Writes the root token to `.vault-bootstrap/dev_root_token` (gitignored)
3. Enables the KV v2 secrets engine at `secret/`
4. Creates a policy `pg-role` granting read on `secret/data/pg/*`
5. Enables AppRole auth and generates a role_id + secret_id
6. Seeds KV secrets with Terraform-generated passwords:
   - `secret/data/pg/postgres` → `postgres_user`, `postgres_password`
   - `secret/data/pg/replication` → `replication_password`
7. Calls `vault-bootstrap-split.sh` to write plain-text files:
   - `.vault-bootstrap/role_id`
   - `.vault-bootstrap/secret_id`

All files under `.vault-bootstrap/` are gitignored — never commit them.

## 4. AppRole Files

Two file formats are maintained under `.vault-bootstrap/`:

| File | Format | Used by |
| ---- | ------ | ------- |
| `approle_pg-role.json` | JSON `{"role_id":"...","secret_id":"..."}` | `entrypoint-patroni.sh`, `entrypoint-pgbouncer.sh` |
| `role_id` | plain text | `vault/agent/agent.hcl` (Vault Agent) |
| `secret_id` | plain text | `vault/agent/agent.hcl` (Vault Agent) |

The split is done by `vault-bootstrap-split.sh`. Run it manually if needed:

```bash
bash vault-bootstrap-split.sh pg-role
```

## 5. Vault Agent Sidecar (optional)

When `vault_agent_enabled = true`, a `vault-agent` container runs alongside the cluster. It:

- Authenticates to Vault via AppRole using `role_id` / `secret_id` files
- Renders `/etc/vault/secrets/postgres.env` with `KEY=VALUE` lines
- Shares the rendered secrets volume with pg-node and pgbouncer containers

Verify the agent rendered secrets correctly:

```bash
docker logs vault-agent --tail=20
docker exec pg-node-1 cat /etc/vault/secrets/postgres.env
```

Expected output:

```text
POSTGRES_USER=pgadmin
POSTGRES_PASSWORD=<generated>
REPLICATION_PASSWORD=<generated>
```

## 6. Verify Vault

```bash
# Health check
curl -s http://localhost:8200/v1/sys/health | python3 -m json.tool

# Read a seeded secret using the root token
VAULT_TOKEN=$(cat .vault-bootstrap/dev_root_token)
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/secret/data/pg/postgres | python3 -m json.tool
```

## 7. Entrypoint Behavior

Container entrypoints call `vault-secrets.sh`, which:

1. Tries AppRole login using the mounted `approle_pg-role.json`
2. Fetches `secret/data/pg/postgres` and `secret/data/pg/replication`
3. Exports credentials as environment variables before starting Patroni/PgBouncer
4. If Vault is unreachable, falls back to `POSTGRES_PASSWORD` / `REPLICATION_PASSWORD` env vars set by Terraform

---

**Notes:**

- This quick start is for local development. For production:
  - Use Vault Auto-Unseal with a supported KMS (AWS KMS, GCP CKMS, Azure Key Vault)
  - Deploy Vault in HA mode (Raft with 3+ nodes or Consul backend)
  - Use Vault Agent Injector (Kubernetes) or the sidecar pattern shown here
  - Avoid static AppRole files — use Vault's response-wrapping or short-TTL secret IDs

**Further reading:**

- [Vault Integration Guide](../VAULT-INTEGRATION.md)
- [Vault Agent Sidecar](../VAULT-AGENT-SIDECAR.md)
- [Vault Troubleshooting](../guides/VAULT-TROUBLESHOOTING.md)
