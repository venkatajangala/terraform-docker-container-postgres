# Vault Quick Start (Dev)

This quick start shows how to bootstrap a dev Vault (RAFT) and enable AppRole access for containerized workloads.

Prerequisites:
- Docker
- Terraform
- jq

1. Enable Vault in ha-test.tfvars:

```hcl
vault_enabled = true
infisical_enabled = false
```

2. Apply Terraform to create containers (Vault included):

```bash
terraform init
terraform apply -var-file="ha-test.tfvars" -auto-approve
```

3. Vault bootstrap (dev):
- The repository includes `vault-bootstrap.sh` which initializes Vault, creates a policy, enables AppRole, and seeds KV v2 secrets for PostgreSQL and replication.
- Terraform runs a null_resource (`main-vault-init.tf`) that executes the bootstrap during `apply` in dev.

4. AppRole JSON:
- The bootstrap writes `.vault-bootstrap/approle_pg-role.json` (role_id + secret_id) for local development. This file is gitignored and set to 600.
- During dev, Terraform mounts this file into containers at `/etc/vault/approle_pg-role.json` so entrypoints can login via AppRole.

5. Verify Vault:

```bash
# Health
curl -s http://localhost:8200/v1/sys/health | jq .

# Read seeded secret (example)
VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=$(cat .vault-bootstrap/dev_root_token 2>/dev/null || echo "")
curl -s --header "X-Vault-Token: $VAULT_TOKEN" http://localhost:8200/v1/secret/data/pg/postgres | jq .
```

6. Entrypoint behavior:
- Containers source `/etc/vault/vault-secrets.sh` which supports AppRole login (from mounted approle JSON) or token-based fallback.
- When Vault is available, entrypoints fetch `secret/data/pg/postgres` and `secret/data/pg/replication` to get DB credentials.

Notes:
- This quick start is intended for local development. For production, use Vault Auto-Unseal (KMS), Vault Agent/sidecar or injector for secrets distribution, and avoid static approle files.
