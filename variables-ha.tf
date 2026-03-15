variable "postgres_user" {
  type        = string
  default     = "pgadmin"
  description = "PostgreSQL superuser username"
}

variable "postgres_password" {
  type        = string
  sensitive   = true
  default     = "pgAdmin1"
  description = "PostgreSQL superuser password - CHANGE THIS FOR PRODUCTION!"
}

variable "postgres_db" {
  type        = string
  default     = "postgres"
  description = "Default PostgreSQL database name"
}

variable "replication_password" {
  type        = string
  sensitive   = true
  default     = "replicator1"
  description = "PostgreSQL replication user password - CHANGE THIS FOR PRODUCTION!"
}

variable "dbhub_port" {
  type        = number
  default     = 9090
  description = "DBHub (Bytebase) web interface port"
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
# Infisical Secrets Management
# ============================================================================

variable "infisical_enabled" {
  type        = bool
  default     = true
  description = "Enable Infisical secrets management integration"
}

variable "infisical_port" {
  type        = number
  default     = 8020
  description = "Infisical API server port"
}

variable "infisical_db_port" {
  type        = number
  default     = 5437
  description = "Internal PostgreSQL database port for Infisical"
}

variable "infisical_project_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Infisical project ID for secret access (leave empty for new project creation)"
}

variable "infisical_environment" {
  type        = string
  default     = "dev"
  description = "Infisical environment: dev, staging, or production"
  validation {
    condition     = contains(["dev", "staging", "production"], var.infisical_environment)
    error_message = "infisical_environment must be 'dev', 'staging', or 'production'."
  }
}

variable "infisical_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Infisical API key for service-to-service authentication (use TF_VAR_infisical_api_key env var)"
}

variable "infisical_master_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Infisical master encryption key (auto-generated if empty)"
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
