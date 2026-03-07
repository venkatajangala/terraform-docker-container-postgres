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
