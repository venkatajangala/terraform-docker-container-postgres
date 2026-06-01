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

output "generated_passwords" {
  description = "Auto-generated passwords for the PostgreSQL cluster (sensitive)"
  sensitive   = true
  value = {
    postgres_password    = local.postgres_password
    replication_password = local.replication_password
  }
}

output "pg_primary_endpoint" {
  value       = "postgresql://${var.postgres_user}:${local.postgres_password}@localhost:5432/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL primary endpoint (auto-elected by Patroni)"
}

output "pg_replica_1_endpoint" {
  value       = "postgresql://${var.postgres_user}:${local.postgres_password}@localhost:5433/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL replica 1 endpoint (read-only)"
}

output "pg_replica_2_endpoint" {
  value       = "postgresql://${var.postgres_user}:${local.postgres_password}@localhost:5434/${var.postgres_db}"
  sensitive   = true
  description = "PostgreSQL replica 2 endpoint (read-only)"
}

output "pg_internal_primary" {
  value       = "postgresql://${var.postgres_user}:${local.postgres_password}@pg-node-1:5432/${var.postgres_db}?sslmode=disable"
  sensitive   = true
  description = "PostgreSQL primary endpoint (internal - from containers)"
}

output "pg_internal_replica_1" {
  value       = "postgresql://${var.postgres_user}:${local.postgres_password}@pg-node-2:5432/${var.postgres_db}?sslmode=disable"
  sensitive   = true
  description = "PostgreSQL replica 1 endpoint (internal - from containers)"
}

output "pg_internal_replica_2" {
  value       = "postgresql://${var.postgres_user}:${local.postgres_password}@pg-node-3:5432/${var.postgres_db}?sslmode=disable"
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
  value       = var.pgbouncer_enabled ? "postgresql://${var.postgres_user}:${local.postgres_password}@localhost:${var.pgbouncer_external_port_base}/${var.postgres_db}" : null
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

# ============================================================================
# Datadog Agent Outputs
# ============================================================================

output "datadog_enabled" {
  value       = var.datadog_enabled
  description = "Whether the Datadog Agent container is deployed"
}

# ============================================================================
# Airflow ETL Platform Outputs
# ============================================================================

output "airflow_enabled" {
  value       = var.airflow_enabled
  description = "Whether the Apache Airflow ETL platform is deployed"
}

output "airflow_url" {
  value       = var.airflow_enabled ? "http://localhost:${var.airflow_port}" : null
  description = "Airflow webserver UI URL"
}

output "airflow_credentials" {
  sensitive   = true
  description = "Airflow web UI and database credentials"
  value = var.airflow_enabled ? {
    web_user     = var.airflow_admin_user
    web_password = local.airflow_admin_password
    db_user      = "airflow_user"
    db_password  = local.airflow_db_password
    db_url_note  = "Both DB URLs built dynamically by airflow-entrypoint.sh (direct to Patroni primary)"
    etl_db       = "postgres (pgadmin user, direct to primary via postgres_ha connection)"
  } : null
}

output "airflow_info" {
  value = var.airflow_enabled ? {
    webserver_url    = "http://localhost:${var.airflow_port}"
    scheduler        = "docker logs airflow-scheduler -f"
    init_logs        = "docker logs airflow-init"
    health_check     = "bash verify-airflow.sh"
    re_init          = "terraform apply -replace=docker_container.airflow_init[0] -var-file=ha-test.tfvars -auto-approve"
    re_run_liquibase = "terraform apply -replace=docker_container.liquibase[0] -var-file=ha-test.tfvars -auto-approve"
    dags_dir         = "${path.cwd}/dags"
  } : null
  description = "Airflow operational quick-reference"
}

output "datadog_agent_info" {
  value = var.datadog_enabled ? {
    container_name  = docker_container.datadog_agent[0].name
    statsd_endpoint = "localhost:${var.datadog_statsd_port}/udp"
    site            = var.datadog_site
    integrations    = "postgres (3 nodes), pgbouncer (${var.pgbouncer_replicas} instances), http_check (Patroni+etcd${var.vault_enabled ? "+Vault" : ""}), docker, process"
    health_check    = "bash datadog-health-check.sh"
    agent_status    = "docker exec datadog-agent agent status"
  } : null
  description = "Datadog Agent connection details and quick-reference commands"
}
