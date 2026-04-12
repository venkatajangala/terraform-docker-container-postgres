auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      # In dev the approle file may contain role_id and secret_id as JSON; a wrapper script
      # or a small helper should write them to separate files if needed by the agent.
      role_id_file_path   = "/etc/vault/role/role_id"
      secret_id_file_path = "/etc/vault/role/secret_id"
    }
  }

  sink "file" {
    config = { path = "/var/run/vault-token/vault-token" }
  }
}

template {
  source      = "/etc/vault/agent/templates/postgres.hcl"
  destination = "/etc/vault/secrets/postgres.env"
  command     = "true"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
