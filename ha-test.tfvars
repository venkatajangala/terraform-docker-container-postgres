// HA Cluster Test Configuration
// IMPORTANT: Passwords are auto-generated on first deploy (terraform apply)
// Set via environment variables to override:
//   export TF_VAR_postgres_password="your-secure-password"
//   export TF_VAR_replication_password="your-secure-password"

postgres_user         = "pgadmin"
postgres_password     = "" // Leave empty to auto-generate, or set via env var
postgres_db           = "postgres"
replication_password  = "" // Leave empty to auto-generate, or set via env var
dbhub_port            = 9090
etcd_port             = 2379
etcd_peer_port        = 2380
patroni_api_port_base = 8008

// PgBouncer Configuration
pgbouncer_enabled            = true
pgbouncer_replicas           = 2
pgbouncer_external_port_base = 6432
pgbouncer_pool_mode          = "transaction"
pgbouncer_max_client_conn    = 1000
pgbouncer_default_pool_size  = 25
pgbouncer_min_pool_size      = 5
pgbouncer_reserve_pool_size  = 5

// Vault Secrets Management Configuration (DEV Raft)
// Use Vault in dev mode with AppRole for container auth.
vault_enabled          = true
vault_port             = 8200
vault_raft_nodes       = 1
vault_root_token       = "dev-root-token"
vault_agent_enabled    = true


