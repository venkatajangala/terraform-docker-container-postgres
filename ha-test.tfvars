// HA Cluster Test Configuration
// IMPORTANT: Passwords are auto-generated on first deploy (terraform apply)
// Set via environment variables to override:
//   export TF_VAR_postgres_password="your-secure-password"
//   export TF_VAR_replication_password="your-secure-password"

postgres_user         = "pgadmin"
postgres_password     = ""  // Leave empty to auto-generate, or set via env var
postgres_db           = "postgres"
replication_password  = ""  // Leave empty to auto-generate, or set via env var
dbhub_port            = 9090
etcd_port             = 12379
etcd_peer_port        = 12380
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

// Infisical Secrets Management Configuration (RECOMMENDED)
// Passwords are automatically generated and securely stored by Infisical
// Set API credentials via environment variables:
//   export TF_VAR_infisical_api_key="<32-char-auto-generated-key>"
//   export TF_VAR_infisical_project_id="your-project-id"
infisical_enabled      = true
infisical_port         = 8020
infisical_db_port      = 5437
infisical_environment  = "dev"
generate_new_passwords = true
password_length        = 32

