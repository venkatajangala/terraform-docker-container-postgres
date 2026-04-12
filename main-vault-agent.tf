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
    source = docker_volume.vault_agent_secrets[0].name
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

  depends_on = [null_resource.vault_init, null_resource.vault_agent_secrets_perms]

  # Use an explicit entrypoint to run vault agent with config
  command = ["agent", "-config=/etc/vault/agent/agent.hcl"]

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }
}

# Volume for sharing secrets with application containers (only created when vault_agent_enabled)
resource "docker_volume" "vault_agent_secrets" {
  count = var.vault_agent_enabled ? 1 : 0
  name  = "vault-agent-secrets"
}

# Set ownership of vault-agent-secrets volume to vault user (uid=100, gid=1000)
# so the vault-agent process (which drops to the vault user at runtime) can write
# rendered secret files into the volume.
resource "null_resource" "vault_agent_secrets_perms" {
  count = var.vault_agent_enabled ? 1 : 0

  triggers = {
    volume = docker_volume.vault_agent_secrets[0].name
  }

  provisioner "local-exec" {
    command = "docker run --rm -v vault-agent-secrets:/data alpine sh -c 'chown 100:1000 /data && chmod 750 /data'"
  }

  depends_on = [docker_volume.vault_agent_secrets]
}

# Note: To use this sidecar in production, run one agent per host or per pod (K8s recommended).
# Applications should mount the same docker_volume "vault-agent-secrets" at /etc/vault/secrets
# and source the rendered postgres.env file at startup.
