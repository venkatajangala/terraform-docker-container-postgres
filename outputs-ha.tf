output "cluster_status" {
  value       = "PostgreSQL HA Cluster successfully deployed"
  description = "Cluster deployment status"
}

output "etcd_endpoint" {
  value       = "http://localhost:${var.etcd_port}"
  description = "etcd endpoint for cluster configuration store"
}

output "pg_nodes" {
  value       = { for k, v in docker_container.pg_node : k => v.name }
  description = "PostgreSQL node container names"
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

output "patroni_api_endpoints" {
  value = {
    "node-1" = "http://localhost:8008"
    "node-2" = "http://localhost:8009"
    "node-3" = "http://localhost:8010"
  }
  description = "Patroni REST API endpoints for all nodes"
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
    cluster_name     = "pg-ha-cluster"
    dcs_type         = "etcd3"
    total_nodes      = 3
    replication_type = "streaming"
    pgvector_version = "0.8.1"
    postgres_version = "18"
    patroni_scope    = "pg-ha-cluster"
  }
  description = "Complete HA cluster information"
}

output "connection_info" {
  value = {
    primary_external   = "localhost:5432"
    replica_1_external = "localhost:5433"
    replica_2_external = "localhost:5434"
    postgres_user      = var.postgres_user
    postgres_db        = var.postgres_db
  }
  description = "Quick connection reference (passwords shown separately)"
}

# ============================================================================
# PgBouncer Connection Pooling Outputs
# ============================================================================

output "pgbouncer_enabled" {
  value       = var.pgbouncer_enabled
  description = "PgBouncer connection pooling status"
}

output "pgbouncer_replicas" {
  value       = var.pgbouncer_enabled ? var.pgbouncer_replicas : 0
  description = "Number of active PgBouncer instances"
}

output "pgbouncer_primary_endpoint" {
  value       = var.pgbouncer_enabled ? "postgresql://${var.postgres_user}:${var.postgres_password}@localhost:${var.pgbouncer_external_port_base}/${var.postgres_db}" : null
  sensitive   = true
  description = "PgBouncer primary pooling endpoint (external)"
}

output "pgbouncer_external_ports" {
  value = var.pgbouncer_enabled ? {
    for k, v in docker_container.pgbouncer : "pgbouncer-${k}" => v.ports[0].external
  } : {}
  description = "External ports for individual PgBouncer instances"
}

output "pgbouncer_internal_endpoints" {
  value = var.pgbouncer_enabled ? [
    for k in keys(docker_container.pgbouncer) : "pgbouncer-${k}:6432"
  ] : []
  description = "Internal container network endpoints for PgBouncer instances"
}

output "pgbouncer_config" {
  value = var.pgbouncer_enabled ? {
    pool_mode         = var.pgbouncer_pool_mode
    max_client_conn   = var.pgbouncer_max_client_conn
    default_pool_size = var.pgbouncer_default_pool_size
    min_pool_size     = var.pgbouncer_min_pool_size
    reserve_pool_size = var.pgbouncer_reserve_pool_size
    port              = var.pgbouncer_port
  } : null
  description = "PgBouncer configuration settings"
}

output "pgbouncer_usage_guide" {
  value = var.pgbouncer_enabled ? {
    description = "Use PgBouncer for connection pooling to improve performance and scalability"
    usage_1     = "Connect via PgBouncer (recommended): psql -h localhost -p ${var.pgbouncer_external_port_base} -U ${var.postgres_user} -d ${var.postgres_db}"
    usage_2     = "Direct PostgreSQL connection: psql -h localhost -p 5432 -U ${var.postgres_user} -d ${var.postgres_db}"
    benefits    = "Reduced connection overhead, better resource utilization, failover support, HA pooling"
    pool_mode   = "Transaction mode - new connection per transaction for maximum compatibility"
  } : null
  description = "PgBouncer usage instructions and benefits"
}
