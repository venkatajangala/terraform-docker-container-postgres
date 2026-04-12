Vault Agent Sidecar (Prototype)

Overview
- Purpose: securely deliver Vault secrets to containers in production without mounting static approle files.
- Pattern: run a Vault Agent alongside the application container (sidecar) that handles AppRole login, token renewal, and templating secrets to a file path the app reads.

Design notes
- Agent runs with a minimal config that authenticates via AppRole (role_id + secret_id provided by orchestrator) and caches a token in a local file.
- Agent uses the template/stats sink to render /etc/vault/secrets/postgres.env with KEY=VALUE lines.
- Application entrypoints source that file or vault-secrets.sh reads it if present.

Example vault agent config (agent.hcl)
```
auto_auth {
  method "approle" {
    config = {
      role_id_file_path = "/etc/vault/role/role_id"
      secret_id_file_path = "/etc/vault/role/secret_id"
    }
  }
  sink "file" {
    config = { path = "/var/run/vault-token/vault-token" }
  }
}

template {
  source = "/etc/vault/templates/postgres.hcl"
  destination = "/etc/vault/secrets/postgres.env"
}

listener "tcp" {
  address = "127.0.0.1:8200"
  tls_disable = true
}
```

Example template (postgres.hcl)
```
{{ with secret "kv/data/postgres" }}
POSTGRES_USER={{ .Data.data.postgres_user }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
REPLICATION_PASSWORD={{ .Data.data.replication_password }}
{{ end }}
```

Terraform notes (prototype)
- Create a docker_container resource for vault_agent_<node> that mounts:
  - role files or use a secure injector to write /etc/vault/role/*
  - agent config and templates
  - a shared tmpfs or volume with the application container (e.g., mount /etc/vault/secrets)
- Ensure depends_on null_resource.vault_init so role_id/secret_id exist before agent starts.

Dockerfile notes
- Use HashiCorp's vault image for the agent or bundle vault binary in app image.
- Start agent as a background process in entrypoint or run both via a small supervisor.

Security considerations
- Avoid committing role_id/secret_id files. Use ephemeral files and set 0600.
- Use policies scoped to KV paths required by the app.
- Production: prefer Vault Agent Injector (K8s) or sidecar approach with ephemeral identities.

References
- https://www.vaultproject.io/docs/agent
- https://www.vaultproject.io/docs/auth/approle
