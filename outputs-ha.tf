output "cluster_status" {
  value       = "PostgreSQL HA Cluster successfully deployed"
  description = "Cluster deployment status"
}

output "etcd_endpoint" {
  value       = "http://localhost:${var.etcd_port}"
  description = "etcd endpoint for cluster configuration store"
}

output "pg_node_1_name" {
  value       = docker_container.pg_node_1.name
  description = "PostgreSQL Node 1 container name"
}

output "pg_node_2_name" {
  value       = docker_container.pg_node_2.name
  description = "PostgreSQL Node 2 container name"
}

output "pg_node_3_name" {
  value       = docker_container.pg_node_3.name
  description = "PostgreSQL Node 3 container name"
}

output "pg_primary_endpoint" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@localhost:5432/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL primary endpoint (auto-elected by Patroni)"
}

output "pg_replica_1_endpoint" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@localhost:5433/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL replica 1 endpoint (read-only)"
}

output "pg_replica_2_endpoint" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@localhost:5434/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL replica 2 endpoint (read-only)"
}

output "pg_internal_primary" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@pg-node-1:5432/${var.postgres_db}?sslmode=disable"
  sensitive   = true
  description = "PostgreSQL primary endpoint (internal - from containers)"
}

output "pg_internal_replica_1" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@pg-node-2:5432/${var.postgres_db}?sslmode=disable"
  sensitive   = true
  description = "PostgreSQL replica 1 endpoint (internal - from containers)"
}

output "pg_internal_replica_2" {
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@pg-node-3:5432/${var.postgres_db}?sslmode=disable"
  sensitive   = true
  description = "PostgreSQL replica 2 endpoint (internal - from containers)"
}

output "patroni_api_node_1" {
  value       = "http://localhost:8008"
  description = "Patroni REST API endpoint for Node 1"
}

output "patroni_api_node_2" {
  value       = "http://localhost:8009"
  description = "Patroni REST API endpoint for Node 2"
}

output "patroni_api_node_3" {
  value       = "http://localhost:8010"
  description = "Patroni REST API endpoint for Node 3"
}

output "dbhub_url" {
  value       = "http://localhost:${var.dbhub_port}"
  description = "DBHub (Bytebase) web interface URL"
}

output "ha_network" {
  value       = docker_network.pg_ha_network.name
  description = "Docker network name for HA cluster"
}

output "cluster_info" {
  value = {
    cluster_name          = "pg-ha-cluster"
    dcs_type              = "etcd3"
    total_nodes           = 3
    replication_type      = "streaming"
    pgvector_version      = "0.8.1"
    postgres_version      = "18"
    patroni_scope         = "pg-ha-cluster"
  }
  description = "Complete HA cluster information"
}

output "connection_info" {
  value = {
    primary_external  = "localhost:5432"
    replica_1_external = "localhost:5433"
    replica_2_external = "localhost:5434"
    postgres_user     = var.postgres_user
    postgres_db       = var.postgres_db
  }
  description = "Quick connection reference (passwords shown separately)"
}
