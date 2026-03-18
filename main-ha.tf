terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

# ============================================================================
# Consolidated Configuration via Locals
# ============================================================================

locals {
  # PostgreSQL node definitions
  pg_nodes = {
    "1" = {
      external_port    = 5432
      patroni_api_port = 8008
    }
    "2" = {
      external_port    = 5433
      patroni_api_port = 8009
    }
    "3" = {
      external_port    = 5434
      patroni_api_port = 8010
    }
  }

  # PgBouncer replicas (simplified)
  pgbouncer_replicas = toset([
    for i in range(1, var.pgbouncer_replicas + 1) : tostring(i)
  ])

  # Common environment variables
  common_pg_env = [
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD=${local.postgres_password}",
    "POSTGRES_DB=${var.postgres_db}",
    "REPLICATION_PASSWORD=${local.replication_password}",
  ]

  # Patroni core settings (same for all nodes)
  patroni_base_env = [
    "PATRONI_SCOPE=pg-ha-cluster",
    "PATRONI_POSTGRESQL__DATA_DIR=/var/lib/postgresql/18/main",
    "PATRONI_POSTGRESQL__PARAMETERS__SHARED_PRELOAD_LIBRARIES=vector,pg_stat_statements",
    "PATRONI_POSTGRESQL__PGCTLCLUSTER=18-main",
    "PATRONI_POSTGRESQL__INITDB__ENCODING=UTF8",
    "PATRONI_POSTGRESQL__INITDB__LOCALE=en_US.UTF-8",
    "PATRONI_POSTGRESQL__REMOVE_DATA_DIRECTORY_ON_DIVERGENCE=true",
    "PATRONI_DCS_TYPE=etcd3",
    "PATRONI_ETCD__HOSTS=etcd:2379",
    "PATRONI_ETCD__PROTOCOL=http"
  ]

  # Infisical credentials (if enabled)
  infisical_env = var.infisical_enabled ? [
    "INFISICAL_API_KEY=${var.infisical_api_key}",
    "INFISICAL_PROJECT_ID=${var.infisical_project_id}",
    "INFISICAL_ENVIRONMENT=${var.infisical_environment}",
    "INFISICAL_HOST=http://infisical:${var.infisical_port}"
  ] : []

  # Use random passwords if not explicitly provided
  postgres_password    = var.postgres_password != "" ? var.postgres_password : random_password.db_admin_password.result
  replication_password = var.replication_password != "" ? var.replication_password : random_password.db_replication_password.result
}

# ============================================================================
# Random Password Generation
# ============================================================================

resource "random_password" "db_admin_password" {
  length  = var.password_length
  special = true
}

resource "random_password" "db_replication_password" {
  length  = var.password_length
  special = true
}

resource "random_password" "pgbouncer_admin_password" {
  length  = var.password_length
  special = true
}

resource "random_password" "infisical_api_key" {
  length  = 32
  special = true
}

resource "random_password" "infisical_db_password" {
  length  = var.password_length
  special = true
}

# ============================================================================
# HA PostgreSQL Cluster with Patroni + etcd
# ============================================================================

resource "docker_network" "pg_ha_network" {
  name   = "pg-ha-network"
  driver = "bridge"
}

# ============================================================================
# ETCD - Distributed Configuration Store (DCS)
# ============================================================================

resource "docker_image" "etcd" {
  name = "quay.io/coreos/etcd:v3.5.0"
}

resource "docker_volume" "etcd_data" {
  name = "etcd-data"
}

resource "docker_container" "etcd" {
  name    = "etcd"
  image   = docker_image.etcd.image_id
  restart = "unless-stopped"

  env = [
    "ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379",
    "ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379",
    "ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380",
    "ETCD_INITIAL_ADVERTISE_PEER_URLS=http://etcd:2380",
    "ETCD_INITIAL_CLUSTER=etcd=http://etcd:2380",
    "ETCD_CLUSTER_STATE=new",
    "ETCD_NAME=etcd"
  ]

  ports {
    internal = 2379
    external = var.etcd_port
  }

  ports {
    internal = 2380
    external = var.etcd_peer_port
  }

  mounts {
    target = "/etcd-data"
    source = docker_volume.etcd_data.name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  memory       = var.etcd_memory_mb
  stop_signal  = "SIGTERM"
  stop_timeout = 30
}

# ============================================================================
# PostgreSQL Custom Image Build (Patroni + pgvector)
# ============================================================================

resource "docker_image" "postgres_patroni" {
  name = "postgres-patroni:18-pgvector"
  build {
    context    = path.module
    dockerfile = "Dockerfile.patroni"
  }
}

# ============================================================================
# Shared Volumes for PostgreSQL HA Cluster
# ============================================================================

resource "docker_volume" "pgbackrest_repo" {
  name = "pgbackrest-repo"
}

resource "docker_volume" "pg_node_data" {
  for_each = local.pg_nodes
  name     = "pg-node-${each.key}-data"
}

# ============================================================================
# PostgreSQL Nodes (Consolidated via for_each)
# ============================================================================

resource "docker_container" "pg_node" {
  for_each = local.pg_nodes

  name    = "pg-node-${each.key}"
  image   = docker_image.postgres_patroni.image_id
  restart = "unless-stopped"

  # Consolidated environment variables
  env = concat(
    local.common_pg_env,
    local.patroni_base_env,
    [
      "PATRONI_NAME=pg-node-${each.key}",
      "PATRONI_RESTAPI__LISTEN=0.0.0.0:8008",
      "PATRONI_RESTAPI__CONNECT_ADDRESS=pg-node-${each.key}:8008",
      "PATRONI_POSTGRESQL__LISTEN=0.0.0.0:5432",
      "PATRONI_POSTGRESQL__CONNECT_ADDRESS=pg-node-${each.key}:5432",
    ],
    local.infisical_env
  )

  # External PostgreSQL port
  ports {
    internal = 5432
    external = each.value.external_port
  }

  # Patroni REST API port
  ports {
    internal = 8008
    external = each.value.patroni_api_port
  }

  # Volume for data
  mounts {
    target = "/var/lib/postgresql"
    source = docker_volume.pg_node_data[each.key].name
    type   = "volume"
  }

  # Patroni configuration
  mounts {
    target    = "/etc/patroni/patroni.yml"
    source    = abspath("${path.module}/patroni/patroni-node-${each.key}.yml")
    type      = "bind"
    read_only = true
  }

  # pgBackRest repository and logs
  mounts {
    target = "/var/lib/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  mounts {
    target = "/var/log/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  # Resource limits
  memory      = var.pg_node_memory_mb
  memory_swap = var.pg_node_memory_mb
  cpu_shares  = 1024

  # Logging configuration
  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  # Health check
  healthcheck {
    test     = ["CMD", "pg_isready", "-U", "postgres", "-d", var.postgres_db]
    interval = "30s"
    timeout  = "10s"
    retries  = 3
  }

  stop_signal  = "SIGTERM"
  stop_timeout = 30

  # Dependency on etcd
  depends_on = [docker_container.etcd]
}

# ============================================================================
# DBHub (Bytebase) - Connects to Primary Node
# ============================================================================

resource "docker_image" "dbhub" {
  name = "bytebase/bytebase:latest"
}

resource "docker_container" "dbhub" {
  name    = "dbhub"
  image   = docker_image.dbhub.image_id
  restart = "unless-stopped"

  ports {
    internal = 8080
    external = var.dbhub_port
  }

  env = [
    "BYTEBASE_POSTGRES_URL=postgres://${var.postgres_user}:${local.postgres_password}@pg-node-1:5432/${var.postgres_db}?sslmode=disable"
  ]

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [docker_container.pg_node]
}

# ============================================================================
# PgBouncer - Connection Pooling Layer (Consolidated via for_each)
# ============================================================================

resource "docker_image" "pgbouncer" {
  count = var.pgbouncer_enabled ? 1 : 0
  name  = "pgbouncer:ha"
  build {
    context    = path.module
    dockerfile = "Dockerfile.pgbouncer"
  }
}

resource "docker_volume" "pgbouncer_logs" {
  count = var.pgbouncer_enabled ? 1 : 0
  name  = "pgbouncer-logs"
}

resource "docker_container" "pgbouncer" {
  for_each = var.pgbouncer_enabled ? local.pgbouncer_replicas : toset([])

  name    = "pgbouncer-${each.key}"
  image   = docker_image.pgbouncer[0].image_id
  restart = "unless-stopped"

  env = concat([
    "PGBOUNCER_CONFIG_DIR=/etc/pgbouncer",
    "PGBOUNCER_LOG_DIR=/var/log/pgbouncer",
    "PGBOUNCER_PORT=6432",
    "DB_ADMIN_USER=${var.postgres_user}",
    "DB_ADMIN_PASSWORD=${local.postgres_password}",
    "DB_REPLICATION_USER=replicator",
    "DB_REPLICATION_PASSWORD=${local.replication_password}"
  ], local.infisical_env)

  ports {
    internal = 6432
    external = var.pgbouncer_external_port_base + (tonumber(each.key) - 1)
  }

  mounts {
    target    = "/etc/pgbouncer/pgbouncer.ini"
    source    = abspath("${path.module}/pgbouncer/pgbouncer.ini")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/var/log/pgbouncer"
    source = docker_volume.pgbouncer_logs[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  # Resource limits
  memory      = var.pgbouncer_memory_mb
  memory_swap = var.pgbouncer_memory_mb

  # Logging configuration
  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  # Health check
  healthcheck {
    test     = ["CMD", "pg_isready", "-h", "localhost", "-p", "6432"]
    interval = "10s"
    timeout  = "5s"
    retries  = 3
  }

  stop_signal  = "SIGTERM"
  stop_timeout = 30

  depends_on = [docker_container.pg_node]
}
