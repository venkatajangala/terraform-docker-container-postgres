// HA Cluster Test Configuration
// IMPORTANT: Passwords are auto-generated on first deploy (terraform apply)
// Set via environment variables to override:
//   export TF_VAR_postgres_password="your-secure-password"
//   export TF_VAR_replication_password="your-secure-password"

postgres_user         = "pgadmin"
postgres_password     = "" // Leave empty to auto-generate, or set via env var
postgres_db           = "postgres"
replication_password  = "" // Leave empty to auto-generate, or set via env var
dbhub_port            = 9080
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

// Vault Secrets Management Configuration (Raft server mode)
// Vault runs in server mode with Raft integrated storage (persistent).
// vault-bootstrap.sh initialises + unseals on first deploy and writes
// the root token / unseal keys to .vault-bootstrap/vault-init.json.
vault_enabled          = true
vault_port             = 8200
vault_raft_nodes       = 1
vault_agent_enabled    = true

// Liquibase tuning: give Patroni leader election extra time when Vault startup adds overhead
liquibase_max_retries  = 60  // 60 x 5s = 5 min (default 30 x 5s = 2.5 min was too short)

// Datadog Agent Configuration
// Set datadog_enabled = true and supply your API key to activate monitoring.
// NEVER commit a real API key — use the TF_VAR_datadog_api_key env var instead:
//   export TF_VAR_datadog_api_key="your-actual-api-key"
//   terraform apply -var-file="ha-test.tfvars" -auto-approve
datadog_enabled     = false
datadog_api_key     = ""           // Leave empty and set via TF_VAR_datadog_api_key
datadog_site        = "datadoghq.com"  // Change to "datadoghq.eu" for EU region
datadog_memory_mb   = 512
datadog_statsd_port = 8125         // Host UDP port for DogStatsD custom metrics

// Local Status Dashboard
dashboard_enabled = true
dashboard_port    = 5005           // http://localhost:5005

// Prometheus + Grafana Monitoring Stack
monitoring_enabled     = true
prometheus_port        = 9090      // http://localhost:9090
grafana_port           = 3000      // http://localhost:3000  (admin / admin)
// grafana_admin_password = "admin" // override via TF_VAR_grafana_admin_password
