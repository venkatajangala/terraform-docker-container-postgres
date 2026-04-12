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

# Raft peer communication port
cluster_addr = "http://0.0.0.0:8201"

# Advertised API address (used by Vault Agent and CLI to find this node)
api_addr = "http://0.0.0.0:8200"

# Required in containers — prevents Vault from calling mlock(2) which needs
# the IPC_LOCK capability.  Remove if you add cap_add = ["IPC_LOCK"] to the
# container and want memory-locked secrets.
disable_mlock = true

# Enable the embedded web UI (accessible at http://localhost:8200/ui)
ui = true

log_level = "warn"
