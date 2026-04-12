# Vault Integration Guide

Overview
--------
This document describes how HashiCorp Vault is integrated into the PostgreSQL HA Terraform + Docker stack.

Key points
- Auth method: AppRole for containers (recommended)
- Secrets engine: KV v2 for static secrets; consider Database secrets engine for dynamic DB credentials
- Dev-mode: single-node RAFT prototype initialized via `vault-bootstrap.sh` and Terraform null_resource
- Production: use Auto-Unseal with a supported KMS and Vault cluster for HA

KV Layout
- secret/data/pg/postgres  -> { postgres_user, postgres_password, pgadmin_user... }
- secret/data/pg/replication -> { replicator_user, replicator_password }
- secret/data/pgbouncer -> { pgbouncer_user, pgbouncer_password }

AppRole Flow
1. Bootstrap creates a policy `pg-role` granting read/list on `secret/data/pg/*` and `secret/data/pgbouncer/*`.
2. AppRole is created and a secret_id is generated; role_id + secret_id are written to `.vault-bootstrap/approle_pg-role.json` (dev only).
3. During dev, Terraform mounts the approle JSON into containers at `/etc/vault/approle_pg-role.json`.
4. Entrypoints call `vault-secrets.sh` to login using AppRole and fetch KV data.

Bootstrap & Seeding
- `vault-bootstrap.sh` initializes Vault (dev), writes a policy, enables AppRole, and seeds KV v2 with Terraform-generated passwords.
- `main-vault-init.tf` contains a `null_resource` that executes the bootstrap script during `terraform apply` (dev convenience).

Security Notes
- `.vault-bootstrap/approle_pg-role.json` contains secret_id: do NOT commit this file; it is gitignored.
- In production, use Vault Agent/sidecar or the injector to deliver credentials; avoid static secret files.
- Make Terraform outputs with sensitive secrets marked `sensitive = true`.

Troubleshooting
- If entrypoints fail to fetch secrets, check Vault reachability (`curl http://localhost:8200/v1/sys/health`).
- Ensure approle JSON is present or environment variables VAULT_ROLE_ID/VAULT_SECRET_ID are set.

Further reading
- docs/vault-migration-plan.md
- HashiCorp Vault docs: https://www.vaultproject.io/docs
