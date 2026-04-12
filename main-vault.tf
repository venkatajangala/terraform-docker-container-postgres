# Vault Docker prototype (enabled via var.vault_enabled)

resource "docker_image" "vault" {
  count = var.vault_enabled ? 1 : 0
  name  = "vault:1.13.3"
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

  env = [
    "VAULT_DEV_ROOT_TOKEN_ID=${var.vault_root_token}",
    "VAULT_ADDR=http://0.0.0.0:${var.vault_port}"
  ]

  ports {
    internal = 8200
    external = var.vault_port
  }

  mounts {
    target = "/vault/data"
    source = docker_volume.vault_data[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  healthcheck {
    test     = ["CMD-SHELL", "curl -fsS http://localhost:${var.vault_port}/v1/sys/health || exit 1"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
  }
}

output "vault_addr" {
  description = "Vault HTTP address"
  value       = var.vault_enabled ? "http://localhost:${var.vault_port}" : "Vault disabled"
}

output "vault_root_token" {
  description = "Vault root token for prototype (sensitive)"
  sensitive   = true
  value       = var.vault_enabled ? var.vault_root_token : ""
}
