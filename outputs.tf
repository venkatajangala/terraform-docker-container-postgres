output "connection_string" {
  value     = "postgresql://${var.postgres_user}:${var.postgres_password}@localhost:5432/${var.postgres_db}"
  sensitive = true
}
