# Vault Migration Plan

This document summarizes the plan to replace Vault with HashiCorp Vault for secrets management in the Terraform + Docker PostgreSQL HA repository.

## Goal
Replace Vault-based secrets flow with HashiCorp Vault (Raft for dev, production auto-unseal via KMS or managed Vault).

## Scope
- Deploy Vault Docker container(s) (Raft for dev) and provide production guidance (auto-unseal).
- Migrate scripts and entrypoints to use Vault (AppRole auth recommended).
- Seed required secrets via Terraform initializers for dev workflows.
- Remove Vault references after Vault validated; keep rollback toggle.
- Update ops docs and architecture diagrams.

## Key Implementation Points
- Use Terraform to provision a Docker Vault container (main-vault.tf).
- Add null_resource local-exec provisioners to:
  - Initialize Vault (sys/init) if needed and unseal (dev prototype).
  - Create policies granting access to secret paths (eg. secret/data/pg/*).
  - Enable AppRole auth and create an AppRole bound to the policy.
  - Retrieve role_id and generate secret_id (write to sensitive outputs or files with restricted perms for dev).
  - Seed KV v2 secrets needed by DB, PgBouncer, and Liquibase.
- Mark unseal keys/root token/secret_id outputs sensitive and never commit.
- Prefer out-of-band AppRole secret distribution for production; do not rely on root-token outputs.

## Remove Vault References
- Remove or gate main-vault.tf and related Docker images behind feature flag or remove after validation.
- Replace vault-secrets.sh with vault-secrets.sh and update all entrypoints.
- Update CI steps and docs to remove Vault references; maintain a rollback branch.

## Docs & Diagrams
- Update README.md, DEPLOYMENT-AND-OPERATIONS-GUIDE.md, and LIQUIBASE-* docs to describe Vault architecture.
- Replace Vault components in architecture diagrams with Vault and add an AppRole auth flow diagram.
- Add a migration appendix detailing how secrets are mapped, seeding steps, and rollback instructions.

## Test Scenarios (Vault-specific)
- SV1: Initialize single-node Raft Vault, unseal, create AppRole, seed KV v2; verify vault-secrets.sh reads secrets via AppRole.
- SV2: Full stack deploy with vault_enabled=true; run test-comprehensive.sh; validate Liquibase migrations.
- SV3: Failover test: restart primary DB; verify PgBouncer and Patroni failover with Vault-sourced creds.
- SV4: Rotation test: rotate a DB password in Vault and verify containers fetch and use new credentials.
- SV5: Security test: confirm Terraform outputs marked sensitive and no unseal/root secrets appear in logs.
- SV6: Rollback test: re-enable Vault via flag and verify services resume with Vault creds.

## Cleanup, Redeploy & Re-validate
- Stop/remove containers and local state used for dev Vault.
- Redeploy: `terraform apply -var='vault_enabled=true' -var-file=ha-test.tfvars`.
- Run verification scripts: test-comprehensive.sh, test-full-stack.sh, test-liquibase.sh and SV* tests.

## Next Steps / Implementation Tasks
1. Implement Terraform null_resource to initialize/unseal Vault (dev prototype).
2. Implement AppRole creation and sensitive outputs.
3. Implement a seeding step to write KV v2 secrets via null_resource.
4. Update vault-secrets.sh for AppRole auth and KV v2 reads.
5. Update entrypoint scripts to use AppRole (or env-injected credentials for prod).
6. Update all docs and diagrams, then remove Vault references behind a feature flag.
7. Cleanup and run full verification suite; iterate on issues.

## Security Notes
- Never commit unseal keys, root tokens or secret_ids to git.
- Mark Terraform outputs sensitive and avoid printing in CI logs.
- For production use auto-unseal and out-of-band secret distribution.

---

Generated from session plan. Sensitive values must be provisioned at runtime and are explicitly excluded from this file.
