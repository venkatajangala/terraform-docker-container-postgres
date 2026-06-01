output "connection_string" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@localhost:5432/${var.postgres_db}"
  sensitive   = true
  description = "Connection string for PostgreSQL from host machine"
}

output "postgres_container_name" {
  value       = docker_container.postgres.name
  description = "Name of the PostgreSQL container"
}

output "mcp_network" {
  value       = docker_network.mcp_network.name
  description = "Custom bridge network name (reserved for future MCP / AI agent components)"
}

output "postgres_dsn_internal" {
  value       = "postgres://${var.postgres_user}:${var.postgres_password}@my-postgres:5432/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL DSN on the internal network (uses container DNS name my-postgres)"
}
