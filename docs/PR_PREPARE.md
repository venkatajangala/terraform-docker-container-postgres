PR Preparation & Commit Message (Vault migration)

Commit message (example):
"feat(vault): replace Infisical with HashiCorp Vault (prototype)

- Add Vault prototype (main-vault.tf, vault-bootstrap.sh)
- Add vault-secrets.sh helper and update entrypoints
- Mount approle JSON for dev and add Terraform initializers
- Add Vault Agent sidecar design and Infisical removal plan

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

PR checklist:
- [ ] All tests pass locally (test-comprehensive.sh, test-full-stack.sh, test-liquibase.sh)
- [ ] Sensitive files (.vault-bootstrap/*) are in .gitignore
- [ ] Terraform changes validated: terraform validate && terraform plan
- [ ] Docs updated: README.md, VAULT-INTEGRATION.md, DEPLOYMENT-AND-OPERATIONS-GUIDE.md
- [ ] Rollback plan documented and branch created
- [ ] PR description includes migration steps and verification commands

