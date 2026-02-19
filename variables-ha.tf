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
