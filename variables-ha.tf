variable "postgres_user" {
  type        = string
  default     = "pgadmin"
  description = "PostgreSQL superuser username"
}

variable "postgres_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "PostgreSQL superuser password. Leave empty to use randomly generated password from random_password.db_admin_password. Set via TF_VAR_postgres_password or ha-test.tfvars."
}

variable "postgres_db" {
  type        = string
  default     = "postgres"
  description = "Default PostgreSQL database name"
}

variable "replication_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "PostgreSQL replication user password. Leave empty to use randomly generated password from random_password.db_replication_password. Set via TF_VAR_replication_password or ha-test.tfvars."
}

variable "etcd_port" {
  type        = number
  default     = 2379
  description = "etcd client API port"
}

variable "etcd_peer_port" {
  type        = number
  default     = 2380
  description = "etcd peer communication port"
}

variable "patroni_api_port_base" {
  type        = number
  default     = 8008
  description = "Base port for Patroni REST API (increments per node)"
}

variable "pgbouncer_enabled" {
  type        = bool
  default     = true
  description = "Enable PgBouncer connection pooling"
}

variable "pgbouncer_replicas" {
  type        = number
  default     = 2
  description = "Number of PgBouncer instances for high availability"
  validation {
    condition     = var.pgbouncer_replicas >= 1 && var.pgbouncer_replicas <= 3
    error_message = "pgbouncer_replicas must be between 1 and 3."
  }
}

variable "pgbouncer_port" {
  type        = number
  default     = 6432
  description = "PgBouncer connection pooling port"
}

variable "pgbouncer_external_port_base" {
  type        = number
  default     = 6432
  description = "Base external port for PgBouncer instances"
}

variable "pgbouncer_pool_mode" {
  type        = string
  default     = "transaction"
  description = "PgBouncer pool mode: session, transaction, or statement"
  validation {
    condition     = contains(["session", "transaction", "statement"], var.pgbouncer_pool_mode)
    error_message = "pgbouncer_pool_mode must be 'session', 'transaction', or 'statement'."
  }
}

variable "pgbouncer_max_client_conn" {
  type        = number
  default     = 1000
  description = "Maximum number of client connections per PgBouncer instance"
}

variable "pgbouncer_default_pool_size" {
  type        = number
  default     = 25
  description = "Default size of connection pool"
}

variable "pgbouncer_min_pool_size" {
  type        = number
  default     = 5
  description = "Minimum number of connections to keep available"
}

variable "pgbouncer_reserve_pool_size" {
  type        = number
  default     = 5
  description = "Number of connections to reserve for emergencies"
}

# ============================================================================
# Vault Secrets Management
# ============================================================================

variable "vault_enabled" {
  type        = bool
  default     = true
  description = "Enable Vault secrets management integration"
}

variable "vault_port" {
  type        = number
  default     = 8200
  description = "Vault API server port"
}

variable "vault_db_port" {
  type        = number
  default     = 5437
  description = "Internal PostgreSQL database port for Vault"
}

variable "vault_project_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Vault project ID for secret access (leave empty for new project creation)"
}

variable "vault_environment" {
  type        = string
  default     = "dev"
  description = "Vault environment: dev, staging, or production"
  validation {
    condition     = contains(["dev", "staging", "production"], var.vault_environment)
    error_message = "vault_environment must be 'dev', 'staging', or 'production'."
  }
}

variable "vault_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Vault API key for service-to-service authentication (use TF_VAR_vault_api_key env var)"
}

variable "vault_master_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Vault master encryption key (auto-generated if empty)"
}

variable "vault_root_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Unused in server mode. Vault generates a root token on first init; it is stored in .vault-bootstrap/vault-init.json. Kept for backward compatibility only."
}

variable "vault_auto_unseal" {
  type        = bool
  default     = false
  description = "If true, configure Vault for auto-unseal with an external KMS (production)."
}

variable "vault_raft_nodes" {
  type        = number
  default     = 1
  description = "Number of Vault Raft nodes for HA when using docker-compose/terraform. For production, consider external storage and auto-unseal."
}

variable "generate_new_passwords" {
  type        = bool
  default     = true
  description = "Generate new secure passwords on first deployment"
}

variable "password_length" {
  type        = number
  default     = 32
  description = "Length of generated passwords"
  validation {
    condition     = var.password_length >= 16 && var.password_length <= 128
    error_message = "password_length must be between 16 and 128 characters."
  }
}


# ============================================================================
# Resource Limits & Performance Tuning
# ============================================================================

variable "pg_node_memory_mb" {
  type        = number
  default     = 4096
  description = "Memory limit per PostgreSQL node (MB)"

  validation {
    condition     = var.pg_node_memory_mb >= 512 && var.pg_node_memory_mb <= 65536
    error_message = "Memory must be between 512MB and 64GB."
  }
}

variable "pgbouncer_memory_mb" {
  type        = number
  default     = 256
  description = "Memory limit per PgBouncer instance (MB)"

  validation {
    condition     = var.pgbouncer_memory_mb >= 64 && var.pgbouncer_memory_mb <= 2048
    error_message = "Memory must be between 64MB and 2GB."
  }
}

variable "etcd_memory_mb" {
  type        = number
  default     = 512
  description = "Memory limit for etcd (MB)"

  validation {
    condition     = var.etcd_memory_mb >= 256 && var.etcd_memory_mb <= 4096
    error_message = "Memory must be between 256MB and 4GB."
  }
}

# ============================================================================
# Liquibase Migration Configuration
# ============================================================================

variable "liquibase_enabled" {
  type        = bool
  default     = true
  description = "Enable Liquibase database migration container"
}

variable "liquibase_memory_mb" {
  type        = number
  default     = 512
  description = "Memory limit for Liquibase migration container (MB)"

  validation {
    condition     = var.liquibase_memory_mb >= 256 && var.liquibase_memory_mb <= 2048
    error_message = "Memory must be between 256MB and 2GB."
  }
}

variable "liquibase_max_retries" {
  type        = number
  default     = 30
  description = "Maximum retry attempts for Liquibase to connect to PostgreSQL"
}

variable "liquibase_retry_interval" {
  type        = number
  default     = 5
  description = "Retry interval in seconds for Liquibase connection attempts"
}

variable "liquibase_auto_run" {
  type        = bool
  default     = true
  description = "Automatically run Liquibase migrations on container startup"
}

# ============================================================================
# Datadog Agent — Monitoring & Observability
# ============================================================================

variable "datadog_enabled" {
  type        = bool
  default     = false
  description = "Enable Datadog Agent container for metrics, logs, and integration checks"
}

variable "datadog_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Datadog API key. Set via TF_VAR_datadog_api_key env var or ha-test.tfvars (never commit)."
}

variable "datadog_site" {
  type        = string
  default     = "datadoghq.com"
  description = "Datadog intake site. Use 'datadoghq.eu' for EU region, 'us3.datadoghq.com' for US3, etc."
}

variable "datadog_memory_mb" {
  type        = number
  default     = 512
  description = "Memory limit for Datadog Agent container (MB)"

  validation {
    condition     = var.datadog_memory_mb >= 256 && var.datadog_memory_mb <= 2048
    error_message = "datadog_memory_mb must be between 256MB and 2GB."
  }
}

variable "datadog_statsd_port" {
  type        = number
  default     = 8125
  description = "Host port mapped to Datadog DogStatsD (UDP). Applications send custom metrics here."
}

# ── Local status dashboard ───────────────────────────────────────────────────

variable "dashboard_enabled" {
  type        = bool
  default     = false
  description = "Enable the local nginx status dashboard (http://localhost:<dashboard_port>)."
}

variable "dashboard_port" {
  type        = number
  default     = 5005
  description = "Host port for the local cluster status dashboard."
}

# ── Prometheus + Grafana monitoring stack ─────────────────────────────────────

variable "monitoring_enabled" {
  type        = bool
  default     = false
  description = "Enable Prometheus + Grafana + postgres_exporter + pgbouncer_exporter stack."
}

variable "prometheus_port" {
  type        = number
  default     = 9090
  description = "Host port for Prometheus UI (http://localhost:<prometheus_port>)."
}

variable "grafana_port" {
  type        = number
  default     = 3000
  description = "Host port for Grafana UI (http://localhost:<grafana_port>)."
}

variable "grafana_admin_password" {
  type        = string
  default     = "admin"
  sensitive   = true
  description = "Grafana admin password. Override via TF_VAR_grafana_admin_password."
}

# ── Apache Airflow ETL Platform ───────────────────────────────────────────────

variable "airflow_enabled" {
  type        = bool
  default     = false
  description = "Enable Apache Airflow ETL platform (webserver + scheduler + init)."
}

variable "airflow_port" {
  type        = number
  default     = 8081
  description = "Host port for Airflow webserver UI (http://localhost:<airflow_port>)."
}

variable "airflow_memory_mb" {
  type        = number
  default     = 2048
  description = "Memory limit per Airflow container (webserver and scheduler) in MB."

  validation {
    condition     = var.airflow_memory_mb >= 512 && var.airflow_memory_mb <= 8192
    error_message = "airflow_memory_mb must be between 512 MB and 8 GB."
  }
}

variable "airflow_admin_user" {
  type        = string
  default     = "admin"
  description = "Airflow web UI admin username."
}

variable "airflow_admin_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Airflow web UI admin password. Leave empty to auto-generate."
}
