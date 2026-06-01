variable "postgres_user" {
  type        = string
  default     = "pgadmin"
  description = "PostgreSQL username"
}

variable "postgres_password" {
  type        = string
  sensitive   = true
  default     = "pgAdmin1"
  description = "PostgreSQL password"
}

variable "postgres_db" {
  type        = string
  default     = "postgres"
  description = "PostgreSQL database name"
}
