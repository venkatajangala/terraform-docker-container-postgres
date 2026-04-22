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
  name  = "hashicorp/vault:1.21.2"
}

resource "docker_volume" "vault_data" {
  count = var.vault_enabled ? 1 : 0
  name  = "vault-data"
}

resource "null_resource" "vault_data_perms" {
  count = var.vault_enabled ? 1 : 0

  triggers = {
    # Use volume id (not name) so this reruns whenever the volume is recreated.
    # The name "vault-data" never changes; the id changes on every create.
    volume_id = docker_volume.vault_data[0].id
  }

  # The vault process runs as uid=100 (vault user). The Docker volume root is
  # owned by root by default, causing "permission denied" on the Raft db file.
  provisioner "local-exec" {
    command = "docker run --rm --user root --entrypoint sh -v vault-data:/vault/data hashicorp/vault:1.21.2 -c 'chown -R 100:1000 /vault/data && chmod 750 /vault/data'"
  }

  depends_on = [docker_volume.vault_data, docker_image.vault[0]]
}

resource "docker_container" "vault" {
  count   = var.vault_enabled ? 1 : 0
  name    = "vault"
  image   = docker_image.vault[0].image_id
  restart = "unless-stopped"

  # The hashicorp/vault entrypoint always prepends -config=/vault/config (the
  # full directory) to the vault server args.  Passing an explicit
  # -config=/vault/config/vault.hcl would make vault load vault.hcl TWICE —
  # two identical listeners → "address already in use".  Pass only "server" so
  # the entrypoint loads the config directory once.
  # VAULT_DEV_ROOT_TOKEN_ID is intentionally absent — dev mode is disabled.
  command = ["server"]

  env = [
    "VAULT_ADDR=http://127.0.0.1:${var.vault_port}",
    # Suppress the harmless "Could not chown /vault/config" warning that fires
    # because the config bind-mount is read-only.
    "SKIP_CHOWN=true"
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

  depends_on = [null_resource.vault_data_perms]

  # Health check: use the vault CLI bundled in the image.
  # `vault status` exit codes: 0 = active, 1 = unreachable (error), 2 = sealed/uninitialized.
  # We accept exit 2 — the process is up and serving the API, just not yet unsealed.
  # Only exit 1 (listener not reachable) is treated as unhealthy.
  healthcheck {
    test         = ["CMD-SHELL", "VAULT_ADDR=http://127.0.0.1:${var.vault_port} vault status 2>&1; ret=$?; [ $ret -eq 0 ] || [ $ret -eq 2 ]"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 5
    start_period = "15s"
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
