output "connection_string" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@localhost:5432/${var.postgres_db}"
  sensitive   = true
  description = "Connection string for PostgreSQL from host machine"
}

output "postgres_container_name" {
  value       = docker_container.postgres.name
  description = "Name of the PostgreSQL container"
}

output "dbhub_container_name" {
  value       = docker_container.dbhub.name
  description = "Name of the DBHub container"
}

output "dbhub_url" {
  value       = "http://localhost:${var.dbhub_port}"
  description = "DBHub web interface URL"
}

output "mcp_network" {
  value       = docker_network.mcp_network.name
  description = "Custom bridge network name for Postgres and DBHub communication"
}

output "postgres_dsn_internal" {
  value       = "postgres://${var.postgres_user}:${var.postgres_password}@my-postgres:5432/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL DSN for DBHub container (uses internal network DNS)"
}
