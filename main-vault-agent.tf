# Vault Agent sidecar prototype for Docker (dev/prod guidance)
# This file is a prototype and guarded by variable `vault_agent_enabled`.
# It creates a Vault Agent docker image and container that renders secrets to
# /etc/vault/secrets/postgres.env which can be shared with application containers.

resource "docker_image" "vault_agent" {
  count = var.vault_agent_enabled ? 1 : 0
  name  = "hashicorp/vault:1.13.3"
}

resource "docker_container" "vault_agent" {
  count   = var.vault_agent_enabled ? 1 : 0
  name    = "vault-agent"
  image   = docker_image.vault_agent[0].image_id
  restart = "unless-stopped"

  env = [
    "VAULT_ADDR=http://vault:${var.vault_port}"
  ]

  mounts {
    target    = "/etc/vault/agent"
    source    = abspath("${path.module}/vault/agent")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/etc/vault/secrets"
    source = "vault-agent-secrets"
    type   = "volume"
  }

  # Mount agreed role files for AppRole (populated by null_resource.vault_init in dev)
  mounts {
    target    = "/etc/vault/role"
    source    = abspath("${path.module}/.vault-bootstrap")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [null_resource.vault_init]

  # Use an explicit entrypoint to run vault agent with config
  command = ["agent", "-config=/etc/vault/agent/agent.hcl"]

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }
}

# Volume for sharing secrets with application containers
resource "docker_volume" "vault_agent_secrets" {
  name = "vault-agent-secrets"
}

# Note: To use this sidecar in production, run one agent per host or per pod (K8s recommended).
# Applications should mount the same docker_volume "vault-agent-secrets" at /etc/vault/secrets
# and source the rendered postgres.env file at startup.
