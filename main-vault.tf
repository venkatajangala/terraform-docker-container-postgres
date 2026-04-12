# Vault server — production server mode with Raft integrated storage
# Guarded by var.vault_enabled.
#
# IMPORTANT: On first deploy, vault-bootstrap.sh (null_resource.vault_init)
# initialises Vault, writes unseal keys + root token to
# .vault-bootstrap/vault-init.json (chmod 600, gitignored), and unseals.
# On container restarts Vault starts sealed — re-run vault-bootstrap.sh or
# manually unseal with the keys from vault-init.json.

resource "docker_image" "vault" {
  count = var.vault_enabled ? 1 : 0
  name  = "hashicorp/vault:1.17.3"
}

resource "docker_volume" "vault_data" {
  count = var.vault_enabled ? 1 : 0
  name  = "vault-data"
}

resource "docker_container" "vault" {
  count   = var.vault_enabled ? 1 : 0
  name    = "vault"
  image   = docker_image.vault[0].image_id
  restart = "unless-stopped"

  # Run in server mode with the Raft config.
  # No VAULT_DEV_ROOT_TOKEN_ID — dev mode is disabled.
  command = ["server", "-config=/vault/config/vault.hcl"]

  env = [
    "VAULT_ADDR=http://127.0.0.1:${var.vault_port}"
  ]

  # Vault API port
  ports {
    internal = 8200
    external = var.vault_port
  }

  # Raft peer / cluster port (needed even for single-node Raft)
  ports {
    internal = 8201
    external = 8201
  }

  # Persistent data volume for Raft storage
  mounts {
    target = "/vault/data"
    source = docker_volume.vault_data[0].name
    type   = "volume"
  }

  # Vault server config (read-only bind mount)
  mounts {
    target    = "/vault/config"
    source    = abspath("${path.module}/vault/config")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  # Health check: vault CLI is available in the image; wget is used here
  # because curl is not present.
  # ?uninitok=true&sealedok=true → the API returns HTTP 200 while the server
  # is starting up (not yet initialised or still sealed), so Docker reports
  # the container healthy as soon as the listener is up.
  healthcheck {
    test     = ["CMD-SHELL", "wget -q -O /dev/null 'http://127.0.0.1:${var.vault_port}/v1/sys/health?uninitok=true&sealedok=true'"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
    start_period = "10s"
  }

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }
}

output "vault_addr" {
  description = "Vault HTTP address"
  value       = var.vault_enabled ? "http://localhost:${var.vault_port}" : "Vault disabled"
}

output "vault_root_token" {
  description = "Vault root token location — generated on first deploy. Read from .vault-bootstrap/vault-init.json (sensitive, gitignored)."
  sensitive   = false
  value       = var.vault_enabled ? "cat .vault-bootstrap/vault-init.json | jq -r .root_token" : "Vault disabled"
}
