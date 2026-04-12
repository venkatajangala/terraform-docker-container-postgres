Infisical Removal Plan (Safe, feature-flagged)

Goals
- Remove Infisical-specific Terraform, Dockerfiles, and scripts once Vault is confirmed in prod.

Steps
1. Audit: grep for 'infisical' occurrences and list files to update.
2. Create a feature-flag (infisical_enabled) to toggle removal. Default: keep enabled until final cutover.
3. Replace infisical-secrets.sh references with vault-secrets.sh but keep infisical-compat shim that no-ops when infisical_enabled=false.
4. Update Dockerfiles to stop copying infisical scripts into images when vault_enabled=true.
5. Deprecate main-infisical.tf by renaming to main-infisical.tf.deprecated and leave as recovery plan in a branch.
6. Run full test suite with infisical_enabled=false and vault_enabled=true and validate.
7. Remove files and refs, open PR, and keep a rollback branch containing the deprecated Infisical Terraform.

Checklist
- [ ] Inventory complete
- [ ] Backups of secrets taken
- [ ] PR for removal prepared and reviewed
- [ ] Rollback branch created

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
