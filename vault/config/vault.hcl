# Production Vault server configuration
# Uses Raft integrated storage — data persists in the vault-data Docker volume.
# TLS is disabled for the internal Docker bridge network; add a TLS stanza with
# cert/key mounts when exposing Vault outside the host.

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-node-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Raft peer communication port.
# Must be an address this node can connect back to — never "0.0.0.0".
# Docker's embedded DNS resolves "vault" to this container's IP on pg-ha-network.
cluster_addr = "http://vault:8201"

# Advertised API address — used by Vault Agent and the vault CLI to reach this node.
api_addr = "http://vault:8200"

# Required in containers — prevents Vault from calling mlock(2) which needs
# the IPC_LOCK capability.  Remove if you add cap_add = ["IPC_LOCK"] to the
# container and want memory-locked secrets.
disable_mlock = true

# Enable the embedded web UI (accessible at http://localhost:8200/ui)
ui = true

log_level = "warn"
